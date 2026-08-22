import Foundation
import AerionCore

// Swift ⇄ Rust C-ABI 桥。回调按头文件约定为 ctx-first：
//   aerion_set_log_callback(void* ctx, void(*cb)(void* ctx, const char* level, const char* message))
//   aerion_set_event_callback(void* ctx, void(*cb)(void* ctx, const char* event_json))
// trampoline 必须是全局 @convention(c) 闭包，除 ctx 外不能捕获任何 Swift 状态；
// 回调在 tokio 工作线程触发，故在此仅做字符串拷贝并转交给串行队列，绝不在回调里碰 NE 状态。
final class AerionBridge {
    // 日志与事件的下游消费者（由 PacketTunnelProvider 安装），已在串行队列上被调用。
    var onLog: ((_ level: String, _ message: String) -> Void)?
    var onEvent: ((_ json: String) -> Void)?

    // 回调可能来自任意 tokio 线程，统一 marshal 到该串行队列再触达 provider。
    private let queue = DispatchQueue(label: "moe.telecom.xbclient.aerion-bridge")

    private static let logTrampoline: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Void = { ctx, level, message in
        guard let ctx else { return }
        let me = Unmanaged<AerionBridge>.fromOpaque(ctx).takeUnretainedValue()
        // 指针仅在本次调用期间有效，立即拷贝成 Swift String。
        let l = level.map { String(cString: $0) } ?? ""
        let m = message.map { String(cString: $0) } ?? ""
        me.queue.async { me.onLog?(l, m) }
    }

    private static let eventTrampoline: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> Void = { ctx, json in
        guard let ctx else { return }
        let me = Unmanaged<AerionBridge>.fromOpaque(ctx).takeUnretainedValue()
        let j = json.map { String(cString: $0) } ?? ""
        me.queue.async { me.onEvent?(j) }
    }

    // 注册回调。passRetained 故意泄漏一个 retain 供进程存续期持有：
    // 扩展是短生命周期进程，随进程整体销毁，无需在意这次泄漏（见设计 §5）。
    func install() {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        aerion_set_log_callback(ctx, AerionBridge.logTrampoline)
        aerion_set_event_callback(ctx, AerionBridge.eventTrampoline)
    }

    // 启动：入参为完整 StartVpnRequest JSON（含 tun_fd），返回 {"ok",...,"session_id"} JSON。
    func startVpn(json: String) -> String {
        guard let out = aerion_start_vpn(json) else {
            return #"{"ok":false,"error":"aerion_start_vpn returned null"}"#
        }
        defer { aerion_free_string(out) }
        return String(cString: out)
    }

    // 停止：幂等。
    func stopVpn(sessionId: Int64) -> String {
        guard let out = aerion_stop_vpn(sessionId) else {
            return #"{"ok":false,"error":"aerion_stop_vpn returned null"}"#
        }
        defer { aerion_free_string(out) }
        return String(cString: out)
    }
}
