import Foundation
import NetworkExtension

// App 侧控制面：管理 NETunnelProviderManager（加载/保存/启停），把粘贴的 node JSON
// 落到 App Group 文件、只用 providerConfiguration 传文件名，并读取扩展写回的 status.json
//（Darwin 通知推 + NEVPNStatus 变更）。不做任何隧道重活。
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

    // 连接：校验并落盘 node JSON → 保存/启用 manager → startVPNTunnel。
    func connect(nodeJSON: String) async {
        lastError = ""
        let trimmed = nodeJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            lastError = "节点 JSON 无效：顶层必须是一个对象"
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

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    func refreshStatus() {
        status = StatusChannel.read()
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
