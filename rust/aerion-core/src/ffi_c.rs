//! iOS 专用的 C-ABI FFI 层。Swift Network Extension 通过它驱动共享 VPN 内核。
//! 约定：入参为 UTF-8 JSON 的 *const c_char（inspect 例外，见下），返回堆分配的
//! *mut c_char JSON，调用方必须用 `aerion_free_string` 释放。所有入口都在边界
//! catch_unwind，绝不让 panic 跨越 C ABI 展开；错误/panic 统一返回
//! `{"ok":false,"error":...}`，与 JNI 层保持一致。

use crate::{
    RUNTIME, format_error_chain, inspect_route_config_yaml, panic_message, set_event_callback,
    set_log_callback, start_route_from_json, start_socks_from_json, start_vpn_from_json,
    stop_route, stop_socks, stop_vpn, test_node_from_json,
};
use anyhow::Result;
use serde_json::json;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// 读取入参 C 字符串：空指针或非 UTF-8 都以错误信息返回，绝不解引用空指针。
fn read_input(ptr: *const c_char) -> std::result::Result<String, String> {
    if ptr.is_null() {
        return Err("input pointer is null".to_string());
    }
    // SAFETY: 调用方保证 ptr 指向以 NUL 结尾的合法 C 字符串
    let raw = unsafe { CStr::from_ptr(ptr) };
    raw.to_str()
        .map(str::to_string)
        .map_err(|error| format!("input is not valid UTF-8: {error}"))
}

/// 构造回传 C 侧的字符串。JSON 输出本不含 NUL，但日志/事件文本可能带控制字符，
/// 故对 interior NUL 做无损剔除而非 panic。
fn to_c_string(value: &str) -> CString {
    match CString::new(value) {
        Ok(cstring) => cstring,
        Err(_) => {
            let cleaned: String = value.chars().filter(|&ch| ch != '\0').collect();
            CString::new(cleaned).unwrap_or_default()
        }
    }
}

fn error_json(message: &str) -> String {
    json!({ "ok": false, "error": message }).to_string()
}

/// 接收 JSON 入参、返回 JSON 的入口统一包装：读参 → 执行 → catch_unwind → 堆分配 C 字符串。
fn json_call<F>(input: *const c_char, f: F) -> *mut c_char
where
    F: FnOnce(String) -> Result<String>,
{
    let output = match catch_unwind(AssertUnwindSafe(|| match read_input(input) {
        Ok(value) => match f(value) {
            Ok(value) => value,
            Err(error) => error_json(&format_error_chain(&error)),
        },
        Err(message) => error_json(&message),
    })) {
        Ok(value) => value,
        Err(payload) => error_json(&format!("Rust panic: {}", panic_message(payload))),
    };
    to_c_string(&output).into_raw()
}

/// 仅凭 session_id 的入口统一包装（stop 系列）。
fn id_call<F>(f: F) -> *mut c_char
where
    F: FnOnce() -> Result<String>,
{
    let output = match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => error_json(&format_error_chain(&error)),
        Err(payload) => error_json(&format!("Rust panic: {}", panic_message(payload))),
    };
    to_c_string(&output).into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn aerion_start_vpn(input: *const c_char) -> *mut c_char {
    json_call(input, |value| RUNTIME.block_on(start_vpn_from_json(&value)))
}

#[unsafe(no_mangle)]
pub extern "C" fn aerion_stop_vpn(session_id: i64) -> *mut c_char {
    id_call(|| RUNTIME.block_on(stop_vpn(session_id as u64)))
}

#[unsafe(no_mangle)]
pub extern "C" fn aerion_start_socks(input: *const c_char) -> *mut c_char {
    json_call(input, |value| {
        RUNTIME.block_on(start_socks_from_json(&value))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn aerion_stop_socks(session_id: i64) -> *mut c_char {
    id_call(|| RUNTIME.block_on(stop_socks(session_id as u64)))
}

#[unsafe(no_mangle)]
pub extern "C" fn aerion_test_node(input: *const c_char) -> *mut c_char {
    json_call(input, |value| RUNTIME.block_on(test_node_from_json(&value)))
}

#[unsafe(no_mangle)]
pub extern "C" fn aerion_start_route(input: *const c_char) -> *mut c_char {
    json_call(input, |value| {
        RUNTIME.block_on(start_route_from_json(&value))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn aerion_stop_route(session_id: i64) -> *mut c_char {
    id_call(|| RUNTIME.block_on(stop_route(session_id as u64)))
}

/// 入参为 mihomo 路由配置 YAML 文本（非 JSON），底层为同步函数，无需进 tokio 运行时。
#[unsafe(no_mangle)]
pub extern "C" fn aerion_inspect_route(input: *const c_char) -> *mut c_char {
    json_call(input, |value| inspect_route_config_yaml(&value))
}

#[unsafe(no_mangle)]
pub extern "C" fn aerion_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: ptr 必须来自本模块的 into_raw 且尚未释放
        unsafe { drop(CString::from_raw(ptr)) };
    }));
}

// Swift 对象指针跨 FFI 边界后被闭包长期持有：裸指针默认非 Send/Sync，回调又可能在
// 任意 tokio 线程触发，故显式声明可跨线程传递，使闭包满足 set_log_callback/
// set_event_callback 要求的 Fn + Send + Sync + 'static。
struct CtxPtr(*mut c_void);
unsafe impl Send for CtxPtr {}
unsafe impl Sync for CtxPtr {}

type LogCallback = extern "C" fn(ctx: *mut c_void, level: *const c_char, message: *const c_char);
type EventCallback = extern "C" fn(ctx: *mut c_void, event_json: *const c_char);

#[unsafe(no_mangle)]
pub extern "C" fn aerion_set_log_callback(ctx: *mut c_void, cb: Option<LogCallback>) {
    let _ = catch_unwind(AssertUnwindSafe(|| match cb {
        Some(cb) => {
            let ctx = CtxPtr(ctx);
            set_log_callback(move |level, message| {
                let level = to_c_string(&level);
                let message = to_c_string(&message);
                // 指针仅在本次调用期间有效，Swift 侧须在回调内立即复制
                cb(ctx.0, level.as_ptr(), message.as_ptr());
            });
        }
        // 传入空回调即注销：替换为吞日志的空闭包
        None => set_log_callback(|_level, _message| {}),
    }));
}

#[unsafe(no_mangle)]
pub extern "C" fn aerion_set_event_callback(ctx: *mut c_void, cb: Option<EventCallback>) {
    let _ = catch_unwind(AssertUnwindSafe(|| match cb {
        Some(cb) => {
            let ctx = CtxPtr(ctx);
            // set_event_callback 闭包签名为 (kind, payload)，事件路径 kind 恒为 "event"，此处仅透传 JSON
            set_event_callback(move |_kind, event_json| {
                let event_json = to_c_string(&event_json);
                cb(ctx.0, event_json.as_ptr());
            });
        }
        None => set_event_callback(|_kind, _event_json| {}),
    }));
}
