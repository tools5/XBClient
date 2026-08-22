import Foundation
import Darwin

// 连接前的 DNS 预解析工具：把 node.host 解析成 IPv4 字面量、sni 补回原域名，
// 与 Android XboardApi.resolveNodeHost / 桌面 aerionNodeWithResolvedHost 行为一致。
// 动机：核心在扩展进程里若拿到域名，会走系统 DNS——此时隧道路由已生效，
// 解析流量可能被自己捕获造成回环；App 侧先解析成 IP，核心直连即可。
enum DNSResolver {
    enum ResolveError: LocalizedError {
        case invalidJSON
        case missingHost
        case resolutionFailed(String)
        case serializationFailed

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "节点 JSON 无效：顶层必须是一个对象"
            case .missingHost:
                return "节点 JSON 缺少 host/server 字段"
            case .resolutionFailed(let host):
                return "域名解析失败：\(host)"
            case .serializationFailed:
                return "节点 JSON 序列化失败"
            }
        }
    }

    /// 判断字符串是否为 IPv4 字面量。
    static func isIPv4(_ host: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, host, &addr) == 1
    }

    /// 判断是否为 fake-ip 池地址（198.18.0.0/15，Clash/mihomo 默认池）。
    /// 用户手机上若装有其他 fake-ip 模式的代理客户端（如 Nextin），其 DNS 接管会让
    /// 系统 DNS 对任意域名都返回 198.18.x.x——这种结果对「直连节点服务器」毫无意义，
    /// 必须当解析失败处理。
    static func isFakeIP(_ ip: String) -> Bool {
        ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.")
    }

    // MARK: - 可信解析（绕开系统 DNS）

    /// DoH 解析器列表：阿里公共 DNS，直接用 IP 访问（证书含 IP SAN），
    /// 自身不依赖任何 DNS，且大陆可达。443 端口不会被代理客户端的 53 端口劫持影响。
    private static let dohServers = ["223.5.5.5", "223.6.6.6"]

    private static let dohSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// 通过 AliDNS DoH JSON API 解析 A 记录。兼容完整格式
    /// {"Status":0,"Answer":[{"type":1,"data":"1.2.3.4"},…]} 与 short=1 的 ["1.2.3.4"]。
    static func resolveViaDoH(_ host: String) async -> String? {
        guard let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else {
            return nil
        }
        for server in dohServers {
            guard let url = URL(string: "https://\(server)/resolve?name=\(encoded)&type=A") else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await dohSession.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            // 完整格式：Answer 数组里 type==1 的 data 即 A 记录。
            if let object = json as? [String: Any],
               let answers = object["Answer"] as? [[String: Any]] {
                for answer in answers {
                    if (answer["type"] as? Int) == 1,
                       let ip = answer["data"] as? String,
                       isIPv4(ip), !isFakeIP(ip) {
                        return ip
                    }
                }
            }
            // short 格式：字符串数组。
            if let list = json as? [Any] {
                for item in list {
                    if let ip = item as? String, isIPv4(ip), !isFakeIP(ip) {
                        return ip
                    }
                }
            }
        }
        return nil
    }

    /// 可信 IPv4 解析：字面量直接过 → DoH → 系统 DNS 兜底（拒绝 fake-ip 结果）。
    static func resolveIPv4Trusted(_ host: String) async -> String? {
        if isIPv4(host) { return host }
        if let ip = await resolveViaDoH(host) { return ip }
        // DoH 全挂时退回系统 DNS，但 fake-ip 结果宁可失败也不能用。
        let fallback = await Task.detached(priority: .userInitiated) { resolveIPv4(host) }.value
        if let ip = fallback, !isFakeIP(ip) { return ip }
        return nil
    }

    /// resolveNodeJSON 的可信版本：host 换 IP 用 resolveIPv4Trusted，其余改写逻辑一致。
    static func resolveNodeJSONTrusted(_ rawJson: String) async throws -> String {
        guard let data = rawJson.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolveError.invalidJSON
        }
        let rawHost = (obj["host"] as? String) ?? (obj["server"] as? String) ?? ""
        var host = rawHost.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { throw ResolveError.missingHost }
        if isIPv4(host) { return rawJson }

        guard let ip = await resolveIPv4Trusted(host) else {
            throw ResolveError.resolutionFailed(host)
        }
        obj["host"] = ip
        if obj["server"] != nil { obj["server"] = ip }
        let hasSni = ["sni", "server_name", "servername"].contains { key in
            if let value = obj[key] as? String {
                return !value.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return false
        }
        if !hasSni {
            obj["sni"] = host
        }
        let outData = try JSONSerialization.data(withJSONObject: obj)
        guard let out = String(data: outData, encoding: .utf8) else {
            throw ResolveError.serializationFailed
        }
        return out
    }

    /// 域名 → IPv4 字符串；已是 IPv4 字面量则原样返回。失败返回 nil。
    /// 注意：getaddrinfo 是阻塞调用，勿在主线程直接调用。
    static func resolveIPv4(_ host: String) -> String? {
        if isIPv4(host) { return host }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return nil }
        defer { freeaddrinfo(res) }

        var cursor = res
        while let node = cursor {
            if node.pointee.ai_family == AF_INET, let sa = node.pointee.ai_addr {
                var out: String?
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        out = String(cString: buf)
                    }
                }
                if let out { return out }
            }
            cursor = node.pointee.ai_next
        }
        return nil
    }

    /// 对 node JSON 做「host 换 IP、sni 补原域名」的改写并返回新 JSON：
    ///   1. host 已是 IPv4 → 原样返回（无需改写）；
    ///   2. 否则解析域名，把 host（以及 server，若存在）替换为解析出的 IP；
    ///   3. 若 sni / server_name / servername 均未设置，则把 sni 设为原始域名，
    ///      保证 TLS 握手仍带正确 SNI。
    static func resolveNodeJSON(_ rawJson: String) throws -> String {
        guard let data = rawJson.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolveError.invalidJSON
        }

        // 节点模型里 host 与 server 已被规整为同值；取任一（见 Android XbClientModels）。
        let rawHost = (obj["host"] as? String) ?? (obj["server"] as? String) ?? ""
        var host = rawHost.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { throw ResolveError.missingHost }

        // 已是 IP：不改写（也不应把 IP 塞进 sni）。
        if isIPv4(host) { return rawJson }

        guard let ip = resolveIPv4(host) else { throw ResolveError.resolutionFailed(host) }

        obj["host"] = ip
        if obj["server"] != nil { obj["server"] = ip } // 两个键保持同值

        // 仅在未显式设置任何 SNI 相关键时，才把原域名补进 sni。
        let hasSni = ["sni", "server_name", "servername"].contains { key in
            if let value = obj[key] as? String {
                return !value.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return false
        }
        if !hasSni {
            obj["sni"] = host
        }

        let outData = try JSONSerialization.data(withJSONObject: obj)
        guard let out = String(data: outData, encoding: .utf8) else {
            throw ResolveError.serializationFailed
        }
        return out
    }
}
