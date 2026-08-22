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
