import Foundation

// MARK: - 节点模型

/// 订阅解析出的代理节点。rawJson 保存完整原始 JSON（含协议专有字段与
/// 下划线兼容键），直接落到 App Group 文件传给 aerion-core，绝不能丢字段。
struct AppNode: Codable, Identifiable, Hashable {
    var id: String { "\(host):\(port):\(name)" }

    let type: String        // "shadowsocks" / "vmess" / "vless" / "trojan" / "hysteria2" ...
    let name: String        // 展示名
    let host: String        // 服务器主机名或 IP
    let port: Int           // 服务器端口
    let rawJson: String     // 完整原始 JSON 字符串（含 type/name/host/port 及协议字段）

    // 可选展示字段
    var group: String? = nil
    var tags: [String]? = nil
}

// MARK: - 会话

/// 登录态：authData 原样放进 Authorization 头（注意：没有 "Bearer " 前缀）。
struct UserSession: Codable {
    let authData: String
    let email: String
}

// MARK: - 订阅信息（App 内部展示用的规整形态）

struct SubscriptionInfo: Codable {
    let subscribeUrl: String
    let upload: Int64         // 已用上行字节（u）
    let download: Int64       // 已用下行字节（d）
    let transferEnable: Int64 // 总可用字节
    let expiredAt: Int64?     // Unix 秒；nil = 永不过期
    let planName: String?
}

// MARK: - 用户信息（GET /api/v1/user/info 的 data）

/// 除 email 外全部宽松解码：Xboard 与 xiao/v2board 字段类型略有出入
/// （如 banned 可能是 0/1 或 bool），单个字段异常不应拖垮整个接口。
struct UserInfo: Codable {
    let email: String
    let uuid: String?
    let planId: Int?
    let expiredAt: Int64?     // Unix 秒；nil = 永不过期或无套餐
    let createdAt: Int64?
    let balance: Int64?       // 面板以“分”为单位
    let transferEnable: Int64?
    let banned: Int?          // 0/1
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case email
        case uuid
        case planId = "plan_id"
        case expiredAt = "expired_at"
        case createdAt = "created_at"
        case balance
        case transferEnable = "transfer_enable"
        case banned
        case avatarUrl = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        uuid = (try? container.decodeIfPresent(String.self, forKey: .uuid)) ?? nil
        planId = lenientInt(container, .planId)
        expiredAt = lenientInt64(container, .expiredAt)
        createdAt = lenientInt64(container, .createdAt)
        balance = lenientInt64(container, .balance)
        transferEnable = lenientInt64(container, .transferEnable)
        if let intValue = lenientInt(container, .banned) {
            banned = intValue
        } else if let boolValue = try? container.decodeIfPresent(Bool.self, forKey: .banned) {
            banned = boolValue ? 1 : 0
        } else {
            banned = nil
        }
        avatarUrl = (try? container.decodeIfPresent(String.self, forKey: .avatarUrl)) ?? nil
    }
}

// MARK: - API 响应外壳

/// v2board 系面板统一返回 {"data": T, "message": "..."}，失败时 data 缺失/为 null。
struct APIResponse<T: Codable>: Codable {
    let data: T?
    let message: String?
}

// MARK: - 登录响应（POST /api/v1/passport/auth/login 的 data）

struct LoginData: Codable {
    let auth_data: String
    // 双面板兼容：xiao/v2board 的登录响应额外携带 token 与 subscribe_url，
    // Xboard 没有这两个键，保持可空即可两边都能解码。
    let token: String?
    let subscribe_url: String?
}

// MARK: - 订阅响应（GET /api/v1/user/getSubscribe 的 data）

struct SubscribeData: Codable {
    let subscribe_url: String
    let u: Int64
    let d: Int64
    let transfer_enable: Int64
    let expired_at: Int64?
    let plan: PlanRef?

    struct PlanRef: Codable {
        let name: String?
    }

    enum CodingKeys: String, CodingKey {
        case subscribe_url, u, d, transfer_enable, expired_at, plan
    }

    /// 宽松解码：无套餐/被封禁账号的 u/d/transfer_enable 可能为 null，按 0 处理；
    /// subscribe_url 是硬前提，缺了整个流程都走不下去，保持必填。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscribe_url = try container.decode(String.self, forKey: .subscribe_url)
        u = lenientInt64(container, .u) ?? 0
        d = lenientInt64(container, .d) ?? 0
        transfer_enable = lenientInt64(container, .transfer_enable) ?? 0
        expired_at = lenientInt64(container, .expired_at)
        plan = (try? container.decodeIfPresent(PlanRef.self, forKey: .plan)) ?? nil
    }

    /// 转成 App 内部展示用的规整形态。
    var info: SubscriptionInfo {
        SubscriptionInfo(
            subscribeUrl: subscribe_url,
            upload: u,
            download: d,
            transferEnable: transfer_enable,
            expiredAt: expired_at,
            planName: plan?.name
        )
    }
}

// MARK: - 宽松数值解码

/// 面板字段类型不稳定（整数/浮点/数字字符串混用），统一走宽松路径。
private func lenientInt64<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
    if let value = try? container.decodeIfPresent(Int64.self, forKey: key) { return value }
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
    if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int64(text) }
    return nil
}

private func lenientInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
    lenientInt64(container, key).flatMap { Int(exactly: $0) }
}
