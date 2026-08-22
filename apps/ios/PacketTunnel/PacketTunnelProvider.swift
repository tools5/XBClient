import NetworkExtension
import Darwin

// NEPacketTunnelProvider：本切片的核心。流程严格按设计 §1/§2/§3：
//   (1) 从 App Group 读粘贴的 node JSON；(2) 解析服务器 host→IP 供 excludedRoutes 防回环；
//   (3) setTunnelNetworkSettings；(4) 仅在其 completion 里用 wireguard 式 fd 扫描定位 utun fd，
//   (5) 组装 StartVpnRequest JSON（含 tun_fd + iOS 默认值）交给 aerion_start_vpn。
// 全程只驱动 fd，绝不触碰 packetFlow（两者并用会互抢包）。
// packet_information 不入 JSON——iOS 由 Rust 内核内部强制为 true。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    // iOS 默认值（设计 §4 推荐）。
    private static let mtu = 1500
    private static let dnsAddr = "198.18.0.2"
    private static let virtualDnsPool = "198.18.0.0/15"
    // utun 对端地址：tun2proxy 是 L3，地址仅占位，避开常见 LAN 段即可。
    private static let tunnelClientV4 = "172.19.0.1"

    private let bridge = AerionBridge()
    private var sessionId: Int64 = 0
    // 规则分流模式下的本地 mihomo 路由会话 id（0 = 未启用）。
    private var routeSessionId: Int64 = 0

    // 状态全部在串行队列上变更：回调来自 tokio 线程、setTunnelNetworkSettings completion 来自
    // 系统队列，统一收敛避免竞态。
    private let statusQueue = DispatchQueue(label: "moe.telecom.xbclient.pt-status")
    private var currentStatus = TunnelStatus.empty

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        bridge.onLog = { [weak self] level, message in self?.appendLog("[\(level)] \(message)") }
        bridge.onEvent = { [weak self] json in self?.handleEvent(json) }
        bridge.install()

        setState(.connecting, message: "读取节点配置")

        let node: Any
        do {
            node = try loadNode()
        } catch {
            finishStart(error: error, completionHandler: completionHandler)
            return
        }

        // excludedRoutes：当前节点服务器 IP + App 预先解析的全部订阅节点 IP。
        // 前者防代理外连回环（设计 §3）；后者让规则模式路由外连与 App 内测速
        // 都不被自己的隧道套圈（测速数值才是真实直连延迟）。
        var serverIPs = (extractHost(from: node).map { resolveIPv4($0) }) ?? []
        serverIPs.append(contentsOf: loadExcludeIPs())
        serverIPs = Array(Set(serverIPs)).sorted()
        if serverIPs.isEmpty {
            appendLog("[warn] 无法从 node 提取/解析服务器 IPv4；未设置 excludedRoutes，代理套接字可能回环（设计 §3）")
        } else {
            appendLog("[info] excludedRoutes 服务器 IP: \(serverIPs.joined(separator: ", "))")
        }

        let settings = makeTunnelSettings(serverIPv4s: serverIPs)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.finishStart(error: error, completionHandler: completionHandler)
                return
            }
            // utun 接口（及其 fd）只有在此 completion 触发后才存在。
            guard let fd = self.locateUtunFD() else {
                self.finishStart(
                    error: NSError(domain: "aerion", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "定位 utun fd 失败"]),
                    completionHandler: completionHandler)
                return
            }
            self.appendLog("[info] 定位到 utun fd = \(fd)")

            // 规则分流：先起本地 mihomo 路由 SOCKS，再把隧道出口指向它；
            // 失败则回退为全局（纯节点），保证至少能连上。
            let tunnelNode = self.makeTunnelNode(from: node)

            let json: String
            do {
                json = try self.buildStartJSON(node: tunnelNode, tunFd: fd)
            } catch {
                self.finishStart(error: error, completionHandler: completionHandler)
                return
            }

            let result = self.bridge.startVpn(json: json)
            self.appendLog("[info] aerion_start_vpn -> \(result)")
            guard let data = result.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true,
                  let sid = (obj["session_id"] as? NSNumber)?.int64Value else {
                let message = (result.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["error"] as? String
                self.finishStart(
                    error: NSError(domain: "aerion", code: -2,
                                   userInfo: [NSLocalizedDescriptionKey: message ?? result]),
                    completionHandler: completionHandler)
                return
            }
            self.sessionId = sid
            self.setState(.connected, message: "已连接", sessionId: sid)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        appendLog("[info] stopTunnel reason=\(reason.rawValue)")
        if sessionId != 0 {
            let result = bridge.stopVpn(sessionId: sessionId)
            appendLog("[info] aerion_stop_vpn -> \(result)")
            sessionId = 0
        }
        if routeSessionId != 0 {
            let result = bridge.stopRoute(sessionId: routeSessionId)
            appendLog("[info] aerion_stop_route -> \(result)")
            routeSessionId = 0
        }
        setState(.disconnected, message: "已断开")
        completionHandler()
    }

    // App 主动拉取当前状态（设计 §6 的 pull 通道）。
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        statusQueue.async {
            completionHandler?(try? JSONEncoder().encode(self.currentStatus))
        }
    }

    // MARK: - 隧道设置

    private func makeTunnelSettings(serverIPv4s: [String]) -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let v4 = NEIPv4Settings(addresses: [Self.tunnelClientV4], subnetMasks: ["255.255.255.0"])
        v4.includedRoutes = [NEIPv4Route.default()]
        v4.excludedRoutes = serverIPv4s.map {
            NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255")
        }
        s.ipv4Settings = v4

        // dns:"virtual"：tun2proxy 本地应答 A/AAAA，无真实 DNS 外泄，最省内存也最防泄漏。
        let dns = NEDNSSettings(servers: [Self.dnsAddr])
        dns.matchDomains = [""] // 捕获全部 DNS
        s.dnsSettings = dns

        s.mtu = NSNumber(value: Self.mtu) // 必须与核心 mtu 一致
        return s
    }

    // MARK: - StartVpnRequest 组装

    private func buildStartJSON(node: Any, tunFd: Int32) throws -> String {
        // 键与 Android 路径一致，另加 iOS 内存预算相关默认值。不含 packet_information（内核强制）。
        let request: [String: Any] = [
            "node": node,
            "tun_fd": Int(tunFd),
            "mtu": Self.mtu,
            "dns": "virtual",
            "dns_addr": Self.dnsAddr,
            "virtual_dns_pool": Self.virtualDnsPool,
            "ipv6": false,
            "max_sessions": 256,
            "tcp_timeout_secs": 120,
            "udp_timeout_secs": 45,
            "exit_on_fatal_error": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "aerion", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "StartVpnRequest 序列化失败"])
        }
        return json
    }

    // 按路由模式决定隧道出口节点：
    //   rule   → 起本地 mihomo 路由 SOCKS（订阅 YAML + geoip 资产 + 选中节点），
    //            出口指向 {type: socks5, 127.0.0.1:port}；任何一步失败都回退纯节点。
    //   global → 原样返回节点；direct/block 伪节点不套规则。
    private func makeTunnelNode(from node: Any) -> Any {
        guard Persistence.routingMode == .rule, let obj = node as? [String: Any] else { return node }
        let type = ((obj["type"] as? String) ?? "").lowercased()
        if type == "direct" || type == "block" { return node }

        guard let yamlData = try? Data(contentsOf: AerionShared.routeConfigFileURL),
              let yaml = String(data: yamlData, encoding: .utf8),
              !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLog("[warn] 规则模式缺少订阅路由配置（route-config.yaml），回退全局")
            return node
        }

        var request: [String: Any] = [
            "config_yaml": yaml,
            "selected_node": obj,
        ]
        if let name = obj["name"] as? String, !name.isEmpty {
            request["selected_proxy"] = name
        }
        if let assets = routeAssetsDir() {
            request["geoip_dir"] = assets
        } else {
            appendLog("[warn] 未找到内置 geoip 资产（RouteAssets/geoip/cn.txt），GEOIP 规则可能不可用")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else {
            appendLog("[warn] 规则路由请求序列化失败，回退全局")
            return node
        }

        let result = bridge.startRoute(json: json)
        appendLog("[info] aerion_start_route -> \(result)")
        guard let rdata = result.data(using: .utf8),
              let robj = try? JSONSerialization.jsonObject(with: rdata) as? [String: Any],
              robj["ok"] as? Bool == true,
              let sid = (robj["session_id"] as? NSNumber)?.int64Value,
              let socksAddr = robj["socks_addr"] as? String,
              let colon = socksAddr.lastIndex(of: ":"),
              let port = Int(socksAddr[socksAddr.index(after: colon)...]) else {
            appendLog("[warn] 规则路由启动失败，回退全局连接")
            return node
        }
        routeSessionId = sid
        return [
            "type": "socks5",
            "name": "Clash Rules",
            "host": String(socksAddr[..<colon]),
            "port": port,
        ]
    }

    // 扩展 bundle 内的路由资产目录（RouteAssets 以文件夹引用打包，含 geoip/cn.txt）。
    private func routeAssetsDir() -> String? {
        guard let base = Bundle.main.resourcePath else { return nil }
        let dir = base + "/RouteAssets"
        return FileManager.default.fileExists(atPath: dir + "/geoip/cn.txt") ? dir : nil
    }

    // App 侧预解析好的全部订阅节点 IP（exclude-ips.json），并入 excludedRoutes。
    private func loadExcludeIPs() -> [String] {
        guard let data = try? Data(contentsOf: AerionShared.excludeIPsFileURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return list.filter { DNSResolver.isIPv4($0) }
    }

    private func loadNode() throws -> Any {
        // providerConfiguration 仅带文件名这一小键；缺省用约定名。
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let fileName = (proto?.providerConfiguration?[AerionShared.providerConfigNodeKey] as? String)
            ?? AerionShared.nodeFileName
        let url = AerionShared.containerURL().appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard obj is [String: Any] else {
            throw NSError(domain: "aerion", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "node JSON 顶层必须是对象"])
        }
        return obj
    }

    // 节点模型里 host 与 server 已被规整为同值；取任一即可（见 Android XbClientModels）。
    private func extractHost(from node: Any) -> String? {
        guard let obj = node as? [String: Any] else { return nil }
        let raw = (obj["host"] as? String) ?? (obj["server"] as? String)
        guard var host = raw?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    // 域名→IPv4 列表；已是字面量则直接返回。仅取 IPv4（本切片 ipv6=false）。
    private func resolveIPv4(_ host: String) -> [String] {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return [host] }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }

        var out: [String] = []
        var cursor = res
        while let node = cursor {
            if node.pointee.ai_family == AF_INET, let sa = node.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        out.append(String(cString: buf))
                    }
                }
            }
            cursor = node.pointee.ai_next
        }
        return out
    }

    // MARK: - utun fd 定位（wireguard-apple 式扫描，设计 §1）

    private func locateUtunFD() -> Int32? {
        // WireGuard-apple 正宗写法：不依赖 kern_control 头（iOS SDK 不公开 <sys/kern_control.h>）。
        // 逐个 fd 用 getsockopt 读 utun 接口名；level=SYSPROTO_CONTROL(2)、optname=UTUN_OPT_IFNAME(2)
        // 是稳定的内核 ABI 常量。命中以 "utun" 开头的接口名即为隧道 fd。
        let sysprotoControl: Int32 = 2
        let utunOptIfname: Int32 = 2
        for fd: Int32 in 0...1024 {
            var nameBuf = [CChar](repeating: 0, count: 128)
            var len = socklen_t(nameBuf.count)
            let ret = getsockopt(fd, sysprotoControl, utunOptIfname, &nameBuf, &len)
            if ret == 0, String(cString: nameBuf).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }

    // MARK: - 状态与事件

    private func handleEvent(_ json: String) {
        // traffic_recorded 是高频事件（千字节级粒度），不进日志、节流写盘，
        // 只把累计上下行字节记进结构化状态供 App 展示速度/用量。
        if json.contains("\"traffic_recorded\"") {
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "traffic_recorded" else { return }
            let up = (obj["upload_bytes"] as? NSNumber)?.int64Value
            let down = (obj["download_bytes"] as? NSNumber)?.int64Value
            statusQueue.async {
                if let up { self.currentStatus.uploadBytes = up }
                if let down { self.currentStatus.downloadBytes = down }
                self.writeTrafficThrottled()
            }
            return
        }
        appendLog("[event] \(json)")
        // 隧道运行时非预期退出：内核发 vpn_session_closed，反映为失败态供 App 展示。
        if json.contains("vpn_session_closed") {
            setState(.failed, message: "隧道运行时退出")
        }
    }

    // 流量状态写盘节流：最快 1 秒一次（statusQueue 上调用）。
    private var lastTrafficWriteAt: TimeInterval = 0
    private func writeTrafficThrottled() {
        let now = Date().timeIntervalSince1970
        guard now - lastTrafficWriteAt >= 1.0 else { return }
        lastTrafficWriteAt = now
        currentStatus.updatedAt = now
        StatusChannel.write(currentStatus)
    }

    private func finishStart(error: Error, completionHandler: @escaping (Error?) -> Void) {
        appendLog("[error] \(error.localizedDescription)")
        // 启动失败不会再走 stopTunnel：路由会话在此显式回收，防止残留。
        if routeSessionId != 0 {
            _ = bridge.stopRoute(sessionId: routeSessionId)
            routeSessionId = 0
        }
        setState(.failed, message: error.localizedDescription)
        completionHandler(error)
    }

    private func setState(_ state: TunnelStatus.State, message: String, sessionId: Int64? = nil) {
        statusQueue.async {
            self.currentStatus.state = state
            self.currentStatus.message = message
            if let sessionId { self.currentStatus.sessionId = sessionId }
            self.currentStatus.updatedAt = Date().timeIntervalSince1970
            StatusChannel.write(self.currentStatus)
        }
    }

    private func appendLog(_ line: String) {
        statusQueue.async {
            self.currentStatus.logs.append(line)
            // 有界环形：扩展内存预算紧，日志只留最近 300 行。
            if self.currentStatus.logs.count > 300 {
                self.currentStatus.logs.removeFirst(self.currentStatus.logs.count - 300)
            }
            self.currentStatus.updatedAt = Date().timeIntervalSince1970
            StatusChannel.write(self.currentStatus)
        }
    }
}
