import Foundation
import AerionCore

// 节点延迟测速：调用 aerion_test_node（Rust FFI），在 App 进程内起临时 SOCKS
// 监听 → 走节点的代理协议握手 → 通过代理向测速 URL 发 HTTP 探测，返回全程耗时。
// 因为走的是代理协议本身，被墙节点/GFW 干扰不影响测速结果的真实性；
// 未连接 VPN 也能测（纯出站 TCP，无需 NE 权限）。
//
// Rust 侧有 TEST_NODE_GUARD 互斥锁，多个测速请求会内部串行；Swift 侧再加一层
// 并发上限没有意义，直接顺序 await 即可。aerion_test_node 是阻塞调用
// （RUNTIME.block_on），必须在后台线程执行，绝不能在主线程调。
enum NodeLatencyTester {

    /// 单个节点的测速结果。
    enum Outcome: Equatable {
        case ok(latencyMs: Int)
        case failed(String)
        case testing
        case idle
    }

    /// 默认测速目标：与 Nextin / Clash 生态一致的 generate_204。
    static let defaultTestURL = "http://www.gstatic.com/generate_204"
    static let defaultTargetHost = "www.gstatic.com"
    static let defaultTargetPort = 80
    static let defaultTimeoutMs = 2000

    /// UserDefaults 键：设置页可改测速 URL 与超时。
    static let testURLDefaultsKey = "bbcloud.latencyTestURL"
    static let timeoutDefaultsKey = "bbcloud.latencyTimeoutMs"

    /// 按设置页配置测一个节点（URL 解析失败时回退默认目标）。
    static func testWithSettings(node: AppNode) async -> Outcome {
        let defaults = UserDefaults.standard
        let urlString = defaults.string(forKey: testURLDefaultsKey) ?? defaultTestURL
        let timeout = defaults.integer(forKey: timeoutDefaultsKey)
        let timeoutMs = timeout > 0 ? timeout : defaultTimeoutMs
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return await test(node: node, timeoutMs: timeoutMs)
        }
        let tls = url.scheme?.lowercased() == "https"
        let port = url.port ?? (tls ? 443 : 80)
        return await test(node: node, targetHost: host, targetPort: port, targetTLS: tls, timeoutMs: timeoutMs)
    }

    /// 测一个节点。node.rawJson 原样作为 TestNodeRequest.node 传给内核。
    static func test(
        node: AppNode,
        targetHost: String = defaultTargetHost,
        targetPort: Int = defaultTargetPort,
        targetTLS: Bool = false,
        timeoutMs: Int = defaultTimeoutMs
    ) async -> Outcome {
        // rawJson 是字符串，转回 JSON 对象内嵌到请求里（不能作为字符串字段传）。
        guard
            let nodeData = node.rawJson.data(using: .utf8),
            let nodeObject = try? JSONSerialization.jsonObject(with: nodeData)
        else {
            return .failed("节点配置解析失败")
        }
        let request: [String: Any] = [
            "node": nodeObject,
            "target_host": targetHost,
            "target_port": targetPort,
            "target_tls": targetTLS,
            "timeout_ms": timeoutMs,
        ]
        guard
            let requestData = try? JSONSerialization.data(withJSONObject: request),
            let requestJSON = String(data: requestData, encoding: .utf8)
        else {
            return .failed("测速请求编码失败")
        }

        // 阻塞 FFI 调用挪到后台线程；withCheckedContinuation 桥回 async。
        let responseJSON: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let out = aerion_test_node(requestJSON) else {
                    continuation.resume(returning: #"{"ok":false,"error":"aerion_test_node returned null"}"#)
                    return
                }
                defer { aerion_free_string(out) }
                continuation.resume(returning: String(cString: out))
            }
        }

        guard
            let data = responseJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failed("测速结果解析失败")
        }
        if (object["ok"] as? Bool) == true, let latency = object["latency_ms"] as? Int {
            return .ok(latencyMs: latency)
        }
        let error = (object["error"] as? String) ?? "未知错误"
        return .failed(error)
    }
}
