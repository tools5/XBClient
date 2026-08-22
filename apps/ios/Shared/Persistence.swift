import Foundation

// App 与 PacketTunnel 扩展共用的轻量持久化：统一走 App Group 的 UserDefaults
//（suiteName 取 AerionShared.appGroupID），两端读到同一份数据。
// 拿不到 App Group 容器时退回 standard——仅开发期兜底，此时两端数据不共享。
enum Persistence {
    private enum Keys {
        static let session = "bbcloud.session"
        static let panelURL = "bbcloud.panelURL"
        static let lastSelectedNodeId = "bbcloud.lastSelectedNodeId"
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AerionShared.appGroupID) ?? .standard
    }

    /// 登录会话（auth_data + email），JSON 编码存储。置 nil 即清除（退出登录）。
    static var session: UserSession? {
        get {
            guard let data = defaults.data(forKey: Keys.session) else { return nil }
            return try? JSONDecoder().decode(UserSession.self, from: data)
        }
        set {
            if let value = newValue, let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: Keys.session)
            } else {
                defaults.removeObject(forKey: Keys.session)
            }
        }
    }

    /// 用户填写的面板地址（XboardAPI.baseURL）。置 nil 或空串即清除。
    static var panelURL: String? {
        get { defaults.string(forKey: Keys.panelURL) }
        set {
            if let value = newValue, !value.isEmpty {
                defaults.set(value, forKey: Keys.panelURL)
            } else {
                defaults.removeObject(forKey: Keys.panelURL)
            }
        }
    }

    /// 上次选中的节点 id（AppNode.id），用于启动后恢复选择。置 nil 或空串即清除。
    static var lastSelectedNodeId: String? {
        get { defaults.string(forKey: Keys.lastSelectedNodeId) }
        set {
            if let value = newValue, !value.isEmpty {
                defaults.set(value, forKey: Keys.lastSelectedNodeId)
            } else {
                defaults.removeObject(forKey: Keys.lastSelectedNodeId)
            }
        }
    }
}
