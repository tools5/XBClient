import Foundation

// App 与 PacketTunnel 扩展共用的常量与状态通道。两端必须引用同一份，
// 任何 id/文件名/通知名不一致都会导致 IPC 或容器绑定失败。
enum AerionShared {
    // 标识符：与 project.yml / entitlements / Info.plist / CI 完全一致。
    static let appGroupID = "group.moe.telecom.xbclient"
    static let tunnelBundleID = "moe.telecom.xbclient.PacketTunnel"

    // App → 扩展：App 把粘贴的 node JSON 落到 App Group 容器文件，
    // providerConfiguration 只带文件名这一小键（providerConfiguration 有体积限制）。
    static let nodeFileName = "node.json"
    static let providerConfigNodeKey = "nodeConfigFile"

    // 扩展 → App：扩展原子写入 status.json（状态/日志），并发一个无载荷的
    // Darwin 通知让 App 立即重读文件（Darwin 通知不携带数据，数据在文件里）。
    static let statusFileName = "status.json"
    static let statusChangedNotification = "moe.telecom.xbclient.status-changed"

    // App Group 容器：拿不到即硬失败，让问题立刻暴露（勿静默回退）。
    static func containerURL() -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            fatalError("App Group 容器不可用：\(appGroupID)")
        }
        return url
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
