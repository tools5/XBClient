mod aerion_config_compat;
mod aerion_core;
mod aerion_mihomo_sanitize;
mod aerion_protocol;
mod aerion_route;
#[cfg(target_os = "android")]
mod android;
// iOS 的 C-ABI FFI 层，供 Swift Network Extension 驱动；仅 iOS 编译，避免与桌面 Electron 后端冲突
#[cfg(target_os = "ios")]
mod ffi_c;

pub use aerion_core::{
    set_event_callback, set_log_callback, start_socks_from_json, start_vpn_from_json, stop_socks,
    stop_vpn, test_node_from_json,
};
pub use aerion_route::{inspect_route_config_yaml, start_route_from_json, stop_route};

// 下列 JNI 相关导入仅 Android 使用：把 jni 类型带入签名会强制 iOS 也引用只有 Android 才有的 API，
// 故整体按 target_os = "android" 门控。
#[cfg(target_os = "android")]
use anyhow::{Context, Result};
#[cfg(target_os = "android")]
use jni::errors::{Result as JniResult, ThrowRuntimeExAndDefault};
#[cfg(target_os = "android")]
use jni::objects::{JClass, JObject, JString};
#[cfg(target_os = "android")]
use jni::{Env, EnvUnowned};
#[cfg(target_os = "android")]
use serde_json::json;
// panic_message 仅在 Android(JNI) 与 iOS(ffi_c) 的边界包装里使用
#[cfg(any(target_os = "android", target_os = "ios"))]
use std::any::Any;
#[cfg(target_os = "android")]
use std::panic::{AssertUnwindSafe, catch_unwind};
// RUNTIME 仅被 Android(JNI) 与 iOS(ffi_c) 的 block_on 入口引用；桌面 Electron 后端自带运行时，
// 直接 await 本 crate 的 pub 异步函数，从不触碰此静态量，故按 android/ios 门控以免桌面出现死代码。
#[cfg(any(target_os = "android", target_os = "ios"))]
use once_cell::sync::Lazy;
#[cfg(any(target_os = "android", target_os = "ios"))]
use tokio::runtime::Runtime;

#[cfg(any(target_os = "android", target_os = "ios"))]
static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_tag("XBClient")
            .with_max_level(log::LevelFilter::Info),
    );
    if rustls::crypto::ring::default_provider()
        .install_default()
        .is_err()
    {
        panic!("rustls crypto provider is already installed");
    }
    // iOS 网络扩展内存硬上限约 50MB，默认多线程运行时（num_cpus × 2MiB 栈）光栈就 12-16MiB，
    // 会被 jetsam 直接杀；故为 iOS 裁剪成 1 worker + 512KiB 栈。仍用 multi_thread 而非
    // current_thread：核心 spawn 任务后即从 block_on 返回，需保留后台线程继续驱动已 spawn 的 I/O。
    #[cfg(target_os = "ios")]
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .max_blocking_threads(2)
        .thread_stack_size(512 * 1024)
        .enable_all()
        .build()
        .expect("create Aerion tokio runtime (ios)");
    #[cfg(not(target_os = "ios"))]
    let runtime = Runtime::new().expect("create Aerion tokio runtime");
    runtime
});

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_moe_telecom_xbclient_AerionCore_initializeAndroid<'local>(
    mut env: EnvUnowned<'local>,
    _object: JObject<'local>,
    service_class: JClass<'local>,
) {
    env.with_env(|env| -> JniResult<()> { android::initialize_android(env, &service_class) })
        .resolve::<ThrowRuntimeExAndDefault>();
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_moe_telecom_xbclient_AerionCore_startVpn<'local>(
    mut env: EnvUnowned<'local>,
    _object: JObject<'local>,
    input: JString<'local>,
) -> JString<'local> {
    env.with_env(|env| -> JniResult<_> {
        call_string(env, &input, |value| {
            RUNTIME.block_on(start_vpn_from_json(&value))
        })
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_moe_telecom_xbclient_AerionCore_testNode<'local>(
    mut env: EnvUnowned<'local>,
    _object: JObject<'local>,
    input: JString<'local>,
) -> JString<'local> {
    env.with_env(|env| -> JniResult<_> {
        call_string(env, &input, |value| {
            RUNTIME.block_on(test_node_from_json(&value))
        })
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_moe_telecom_xbclient_AerionCore_startRoute<'local>(
    mut env: EnvUnowned<'local>,
    _object: JObject<'local>,
    input: JString<'local>,
) -> JString<'local> {
    env.with_env(|env| -> JniResult<_> {
        call_string(env, &input, |value| {
            RUNTIME.block_on(start_route_from_json(&value))
        })
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_moe_telecom_xbclient_AerionCore_stopRoute<'local>(
    mut env: EnvUnowned<'local>,
    _object: JObject<'local>,
    session_id: i64,
) -> JString<'local> {
    env.with_env(|env| -> JniResult<_> {
        let output = match catch_unwind(AssertUnwindSafe(|| {
            RUNTIME.block_on(stop_route(session_id as u64))
        })) {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => json!({"ok": false, "error": format_error_chain(&error)}).to_string(),
            Err(payload) => {
                json!({"ok": false, "error": format!("Rust panic: {}", panic_message(payload))})
                    .to_string()
            }
        };
        JString::from_str(env, output)
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_moe_telecom_xbclient_AerionCore_stopVpn<'local>(
    mut env: EnvUnowned<'local>,
    _object: JObject<'local>,
    session_id: i64,
) -> JString<'local> {
    env.with_env(|env| -> JniResult<_> {
        let output = match catch_unwind(AssertUnwindSafe(|| {
            RUNTIME.block_on(stop_vpn(session_id as u64))
        })) {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => json!({"ok": false, "error": format_error_chain(&error)}).to_string(),
            Err(payload) => {
                json!({"ok": false, "error": format!("Rust panic: {}", panic_message(payload))})
                    .to_string()
            }
        };
        JString::from_str(env, output)
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_os = "android")]
fn call_string<'local>(
    env: &mut Env<'local>,
    input: &JString<'local>,
    f: impl FnOnce(String) -> Result<String>,
) -> JniResult<JString<'local>> {
    let output = match catch_unwind(AssertUnwindSafe(|| {
        input
            .try_to_string(env)
            .context("read JNI string")
            .and_then(f)
    })) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => json!({"ok": false, "error": format_error_chain(&error)}).to_string(),
        Err(payload) => {
            json!({"ok": false, "error": format!("Rust panic: {}", panic_message(payload))})
                .to_string()
        }
    };
    JString::from_str(env, output)
}

// 仅 Android(JNI) 与 iOS(ffi_c) 的边界包装会用到；桌面直接调用 pub 异步函数，无需这些
#[cfg(any(target_os = "android", target_os = "ios"))]
pub(crate) fn format_error_chain(error: &anyhow::Error) -> String {
    error
        .chain()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(": ")
}

#[cfg(any(target_os = "android", target_os = "ios"))]
pub(crate) fn panic_message(payload: Box<dyn Any + Send + 'static>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        return (*message).to_string();
    }
    if let Some(message) = payload.downcast_ref::<String>() {
        return message.clone();
    }
    "unknown panic payload".to_string()
}
