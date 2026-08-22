import Foundation

// MARK: - 错误

enum XboardAPIError: LocalizedError {
    case invalidBaseURL(String)
    case invalidURL(String)
    case notLoggedIn
    case notHTTPResponse
    case http(status: Int, message: String)
    case api(message: String)
    case emptyData(endpoint: String)
    case emptySubscription
    case invalidProxy(index: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "面板地址无效：\(url)"
        case .invalidURL(let url):
            return "URL 无效：\(url)"
        case .notLoggedIn:
            return "尚未登录：缺少 auth_data。"
        case .notHTTPResponse:
            return "服务器响应不是 HTTP 响应。"
        case .http(let status, let message):
            return message.isEmpty ? "请求失败：HTTP \(status)" : "请求失败：HTTP \(status)（\(message)）"
        case .api(let message):
            return message
        case .emptyData(let endpoint):
            return "\(endpoint)失败：响应缺少 data 字段。"
        case .emptySubscription:
            return "订阅为空：未解析到任何节点。"
        case .invalidProxy(let index, let reason):
            return "订阅第 \(index + 1) 个节点无效：\(reason)"
        }
    }
}

// MARK: - API 客户端

/// v2board 系面板（Xboard / xiao 自用面板）的 HTTP 客户端。
/// 鉴权：Authorization 头直接放 auth_data 原文（没有 "Bearer " 前缀）。
final class XboardAPI {
    /// 面板 API 请求的 User-Agent。
    static let appUserAgent = "BBcloud/0.1.0"
    /// 订阅拉取伪装成 mihomo，面板据此返回 Clash Meta YAML。
    static let subscriptionUserAgent = "mihomo"
    /// 订阅协议过滤参数。
    static let subscriptionNodeTypes = "anytls,hysteria,hysteria2,trojan,vless,vmess,shadowsocks,ss,tuic"

    /// 识别订阅模板下发的信息伪节点（展示流量/到期/官网等，非真实可选节点）。
    static func isInfoPseudoNode(name: String) -> Bool {
        let prefixes = ["剩余流量", "套餐到期", "距离下次重置", "官网", "过期时间", "最新网址"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// 用户面板地址，如 "https://panel.example.com"（可不带 scheme，默认补 https）。
    var baseURL: String
    /// 登录后获得的 auth_data；login 成功会自动写入。
    var authData: String?

    private let session: URLSession

    init(baseURL: String = "", authData: String? = nil) {
        self.baseURL = baseURL
        self.authData = authData
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: 面板 API

    /// POST /api/v1/passport/auth/login。成功后自动保存 authData。
    func login(email: String, password: String) async throws -> LoginData {
        let data: LoginData = try await request(
            method: "POST",
            path: "/api/v1/passport/auth/login",
            body: ["email": email, "password": password],
            authorized: false,
            endpoint: "登录"
        )
        authData = data.auth_data
        return data
    }

    /// GET /api/v1/user/info
    func getUserInfo() async throws -> UserInfo {
        try await request(
            method: "GET",
            path: "/api/v1/user/info",
            authorized: true,
            endpoint: "获取用户信息"
        )
    }

    /// GET /api/v1/user/getSubscribe
    func getSubscription() async throws -> SubscribeData {
        try await request(
            method: "GET",
            path: "/api/v1/user/getSubscribe",
            authorized: true,
            endpoint: "获取订阅信息"
        )
    }

    // MARK: 订阅节点拉取

    /// GET subscribeUrl?types=...&flag=meta，UA 伪装 mihomo，解析 Clash Meta YAML
    /// 的 proxies 数组。每个节点的 rawJson 是完整原始 JSON（host 缺失时从 server 补齐，
    /// 连字符键补一份下划线别名），与桌面/安卓端喂给 aerion-core 的格式一致。
    func fetchProxyNodes(subscribeUrl: String) async throws -> [AppNode] {
        var target = subscribeUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw XboardAPIError.invalidURL(subscribeUrl) }
        if !target.lowercased().hasPrefix("http://") && !target.lowercased().hasPrefix("https://") {
            target = "https://" + target
        }
        guard var components = URLComponents(string: target) else {
            throw XboardAPIError.invalidURL(subscribeUrl)
        }
        // 保留原有 query（token 等），去重后追加 types 与 flag。
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "types" || $0.name == "flag" }
        query.append(URLQueryItem(name: "types", value: Self.subscriptionNodeTypes))
        query.append(URLQueryItem(name: "flag", value: "meta"))
        components.queryItems = query
        guard let url = components.url else { throw XboardAPIError.invalidURL(subscribeUrl) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.subscriptionUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/yaml, text/plain, */*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XboardAPIError.notHTTPResponse }
        guard (200...299).contains(http.statusCode) else {
            throw XboardAPIError.http(status: http.statusCode, message: Self.bodySnippet(data))
        }

        let yaml = String(decoding: data, as: UTF8.self)
        let proxies = try ClashYAMLParser.parseProxies(fromYAML: yaml)

        // 订阅原始 YAML 落盘（App Group）：规则分流模式下扩展将其交给
        // aerion_start_route（内部有 sanitize），失败不阻塞节点解析。
        try? yaml.data(using: .utf8)?.write(to: AerionShared.routeConfigFileURL, options: .atomic)

        var nodes: [AppNode] = []
        nodes.reserveCapacity(proxies.count)
        for (index, proxy) in proxies.enumerated() {
            // 连字符键补下划线别名（ws-opts → ws_opts 等），与安卓端一致；
            // aerion-core 只认下划线键。
            var node = Self.normalizeKeys(proxy)
            if node["host"] == nil, let server = node["server"] {
                node["host"] = server
            }
            guard let type = Self.stringValue(node["type"])?.lowercased(), !type.isEmpty else {
                throw XboardAPIError.invalidProxy(index: index, reason: "缺少 type 字段")
            }
            // direct/block 是面板下发的伪节点，不是可连接的代理，跳过。
            if type == "direct" || type == "block" { continue }
            guard let name = Self.stringValue(node["name"]), !name.isEmpty else {
                throw XboardAPIError.invalidProxy(index: index, reason: "缺少 name 字段")
            }
            // 面板订阅模板会塞“剩余流量：/套餐到期：”等信息伪节点（指向真实服务器但
            // 仅作展示用），不进节点列表——流量/到期信息由订阅页专门展示。
            if Self.isInfoPseudoNode(name: name) { continue }
            guard let host = Self.stringValue(node["host"]), !host.isEmpty else {
                throw XboardAPIError.invalidProxy(index: index, reason: "缺少 host/server 字段")
            }
            guard let port = Self.intValue(node["port"]), (1...65535).contains(port) else {
                throw XboardAPIError.invalidProxy(index: index, reason: "port 字段缺失或非法")
            }
            guard JSONSerialization.isValidJSONObject(node) else {
                throw XboardAPIError.invalidProxy(index: index, reason: "字段无法编码为 JSON")
            }
            // sortedKeys 保证同一节点两次拉取的 rawJson 字节级一致（id/去重稳定）。
            let jsonData = try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])
            let rawJson = String(decoding: jsonData, as: UTF8.self)
            nodes.append(AppNode(type: type, name: name, host: host, port: port, rawJson: rawJson))
        }
        guard !nodes.isEmpty else { throw XboardAPIError.emptySubscription }
        return nodes
    }

    // MARK: - 内部：面板请求管道

    private func request<T: Codable>(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        authorized: Bool,
        endpoint: String
    ) async throws -> T {
        let base = Self.normalizeBaseURL(baseURL)
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw XboardAPIError.invalidBaseURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.appUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized {
            guard let auth = authData, !auth.isEmpty else { throw XboardAPIError.notLoggedIn }
            // 注意：v2board 系面板的 Authorization 就是 auth_data 原文，没有 "Bearer " 前缀。
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XboardAPIError.notHTTPResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = Self.serverMessage(from: data) ?? Self.bodySnippet(data)
            throw XboardAPIError.http(status: http.statusCode, message: message)
        }

        let decoded: APIResponse<T>
        do {
            decoded = try JSONDecoder().decode(APIResponse<T>.self, from: data)
        } catch {
            throw XboardAPIError.api(message: "\(endpoint)失败：响应格式异常（\(error.localizedDescription)）")
        }
        guard let payload = decoded.data else {
            if let message = decoded.message, !message.isEmpty {
                throw XboardAPIError.api(message: message)
            }
            throw XboardAPIError.emptyData(endpoint: endpoint)
        }
        return payload
    }

    static func normalizeBaseURL(_ value: String) -> String {
        var base = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return "" }
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "https://" + base
        }
        return base
    }

    /// 从失败响应体里尽力挖 message（{"message": "..."} 或 {"errors": {字段: [提示]}}）。
    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        if let errors = object["errors"] as? [String: Any] {
            for value in errors.values {
                if let texts = value as? [String], let first = texts.first, !first.isEmpty {
                    return first
                }
                if let text = value as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func bodySnippet(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(200))
    }

    // MARK: - 内部：节点 JSON 规整

    /// 连字符键补一份下划线别名（不覆盖已有键），递归处理嵌套结构。
    static func normalizeKeys(_ dict: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        result.reserveCapacity(dict.count * 2)
        for (key, rawValue) in dict {
            let value = normalizeValue(rawValue)
            result[key] = value
            let underscored = key.replacingOccurrences(of: "-", with: "_")
            if underscored != key, dict[underscored] == nil {
                result[underscored] = value
            }
        }
        return result
    }

    private static func normalizeValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return normalizeKeys(dict)
        }
        if let array = value as? [Any] {
            return array.map(normalizeValue)
        }
        return value
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case is NSNull, nil:
            return nil
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        case let text as String:
            return Int(text.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }
}
