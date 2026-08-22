import Foundation

// App 与 PacketTunnel 扩展共用的常量与状态通道。两端必须引用同一份，
// 任何 id/文件名/通知名不一致都会导致 IPC 或容器绑定失败。
enum AerionShared {
    // 基础标识符（CI/entitlements 原始值）。ReSign 重签会追加 TeamID 后缀，
    // 下面用 Bundle.main 动态适配，避免硬编码与实际签名不一致导致崩溃。
    private static let baseAppGroupID = "group.moe.telecom.xbclient"
    private static let baseBundleID = "moe.telecom.xbclient"

    // 动态 App Group ID：先尝试与运行时 bundle ID 匹配的 group，再回退基础值。
    static var appGroupID: String {
        let mainID = Bundle.main.bundleIdentifier ?? baseBundleID
        // ReSign 把 bundle ID 改为 <base>.TeamID，App Group 也变成 group.<base>.TeamID
        let candidates = ["group.\(mainID)", baseAppGroupID]
        for gid in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: gid) != nil {
                return gid
            }
        }
        return baseAppGroupID
    }

    // 动态 tunnel bundle ID：主 App 的 bundleID + ".PacketTunnel"
    static var tunnelBundleID: String {
        let mainID = Bundle.main.bundleIdentifier ?? baseBundleID
        return "\(mainID).PacketTunnel"
    }

    // App → 扩展：App 把粘贴的 node JSON 落到 App Group 容器文件，
    // providerConfiguration 只带文件名这一小键（providerConfiguration 有体积限制）。
    static let nodeFileName = "node.json"
    static let providerConfigNodeKey = "nodeConfigFile"

    // 扩展 → App：扩展原子写入 status.json（状态/日志），并发一个无载荷的
    // Darwin 通知让 App 立即重读文件（Darwin 通知不携带数据，数据在文件里）。
    static let statusFileName = "status.json"
    static let statusChangedNotification = "moe.telecom.xbclient.status-changed"

    // App Group 容器：先尝试动态 group，拿不到则降级到本地 Documents（初期测试可用，
    // 但 App↔扩展 IPC 将不通——两者看不到同一个容器）。
    static func containerURL() -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return url
        }
        // 降级：至少让 App 不崩溃。扩展侧也会走到这里，只是两者路径不同、文件不共享。
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    static var nodeFileURL: URL { containerURL().appendingPathComponent(nodeFileName) }
    static var statusFileURL: URL { containerURL().appendingPathComponent(statusFileName) }
}

// 隧道状态：扩展写、App 读。logs 为有界环形缓冲（扩展内存预算紧，见设计 §4）。
struct TunnelStatus: Codable {
    enum State: String, Codable {
        case disconnected
        case connecting
        case connected
        case failed
    }

    var state: State
    var message: String
    var sessionId: Int64
    var logs: [String]
    var updatedAt: Double
    // 本次隧道会话累计流量（字节），扩展从内核 traffic_recorded 事件更新。
    // 可选类型：兼容旧版扩展写出的、不含这两个键的 status.json。
    var uploadBytes: Int64? = nil
    var downloadBytes: Int64? = nil

    static let empty = TunnelStatus(state: .disconnected, message: "", sessionId: 0, logs: [], updatedAt: 0)
}

// 状态文件读写 + Darwin 推送。两端共用编解码，避免格式漂移。
enum StatusChannel {
    static func read() -> TunnelStatus {
        guard let data = try? Data(contentsOf: AerionShared.statusFileURL),
              let status = try? JSONDecoder().decode(TunnelStatus.self, from: data) else {
            return .empty
        }
        return status
    }

    // 扩展侧调用：原子写文件后发 Darwin 通知。
    static func write(_ status: TunnelStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: AerionShared.statusFileURL, options: .atomic)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AerionShared.statusChangedNotification as CFString),
            nil, nil, true
        )
    }
}
