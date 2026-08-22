import Foundation
import NetworkExtension

// App 侧控制面：管理 NETunnelProviderManager（加载/保存/启停），把节点 JSON
// 落到 App Group 文件、只用 providerConfiguration 传文件名，并读取扩展写回的 status.json
//（Darwin 通知推 + NEVPNStatus 变更）。不做任何隧道重活。
//
// 连接前在 App 侧做 DNS 预解析（host→IP、sni←原域名），与 Android resolveNodeHost /
// 桌面 aerionNodeWithResolvedHost 行为一致：扩展与内核拿到的是 IP 直连节点，
// 避免核心在隧道路由生效后再走系统 DNS 造成回环。
@MainActor
final class TunnelController: ObservableObject {
    @Published var status: TunnelStatus = .empty
    @Published var connectionState: NEVPNStatus = .invalid
    @Published var lastError: String = ""

    private var manager: NETunnelProviderManager?

    init() {
        observeVPNStatus()
        observeDarwinStatus()
        refreshStatus()
        Task { await loadManager() }
    }

    // MARK: - 连接

    // 新路径：AppNode → DNS 预解析（host 换 IP、sni 补原域名）→ 落盘 → 启动隧道。
    func connect(node: AppNode) async {
        lastError = ""
        let rawJson = node.rawJson
        let resolvedJSON: String
        do {
            // 可信解析（DoH 优先）：系统 DNS 可能被其他 fake-ip 代理客户端污染，
            // 解析出 198.18.x.x 会让隧道直连一个不存在的地址。
            resolvedJSON = try await DNSResolver.resolveNodeJSONTrusted(rawJson)
        } catch {
            lastError = "节点解析失败：\(error.localizedDescription)"
            return
        }
        await startTunnel(with: resolvedJSON)
    }

    // 兼容路径：直接给 node JSON 字符串（调试/粘贴用）。校验 → 落盘 → 启动。
    func connect(nodeJSON: String) async {
        lastError = ""
        let trimmed = nodeJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            lastError = "节点 JSON 无效：顶层必须是一个对象"
            return
        }
        await startTunnel(with: trimmed)
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    func refreshStatus() {
        status = StatusChannel.read()
    }

    // MARK: - 启动尾程

    // 共用尾程：把（已解析的）node JSON 写入 App Group → 保存/启用 manager → startVPNTunnel。
    private func startTunnel(with nodeJSON: String) async {
        guard let data = nodeJSON.data(using: .utf8) else {
            lastError = "节点 JSON 编码失败"
            return
        }
        do {
            try data.write(to: AerionShared.nodeFileURL, options: .atomic)
        } catch {
            lastError = "写入节点配置失败：\(error.localizedDescription)"
            return
        }
        do {
            let m = try await ensureManager(host: extractHost(from: data))
            try m.connection.startVPNTunnel()
        } catch {
            lastError = "启动隧道失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Manager

    private func loadManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == AerionShared.tunnelBundleID
            } ?? managers.first
            if let m = manager { connectionState = m.connection.status }
        } catch {
            lastError = "加载 VPN 配置失败：\(error.localizedDescription)"
        }
    }

    private func ensureManager(host: String) async throws -> NETunnelProviderManager {
        let m = manager ?? NETunnelProviderManager()
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AerionShared.tunnelBundleID
        proto.serverAddress = host.isEmpty ? "aerion" : host
        // providerConfiguration 只带文件名这一小键；完整 node 在 App Group 文件里。
        proto.providerConfiguration = [AerionShared.providerConfigNodeKey: AerionShared.nodeFileName]
        m.protocolConfiguration = proto
        m.localizedDescription = "BBcloud"
        m.isEnabled = true
        try await m.saveToPreferences()
        // 首启：save 后必须 reload，否则 connection 可能尚未就绪。
        try await m.loadFromPreferences()
        manager = m
        connectionState = m.connection.status
        return m
    }

    private func extractHost(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let raw = (obj["host"] as? String) ?? (obj["server"] as? String) ?? ""
        var host = raw.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }

    // MARK: - 状态观察

    private func observeVPNStatus() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let conn = note.object as? NEVPNConnection { self.connectionState = conn.status }
            self.refreshStatus()
        }
    }

    // 扩展写完 status.json 后发 Darwin 通知，这里收到即重读文件。
    private func observeDarwinStatus() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<TunnelController>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in me.refreshStatus() }
            },
            AerionShared.statusChangedNotification as CFString,
            nil, .deliverImmediately
        )
    }
}
