use aerion_core::{set_event_callback, set_log_callback};
use anyhow::{Context, Result, anyhow, bail, ensure};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::Write;
use std::net::IpAddr;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::io::{self, AsyncBufReadExt, BufReader};

#[cfg(windows)]
mod http_bridge;
mod subscription;
mod system_proxy;

// 当前活动的本地 HTTP 代理桥（Windows 系统代理必须经它转发，见 http_bridge.rs 顶部注释）
#[cfg(windows)]
static HTTP_BRIDGE: Lazy<tokio::sync::Mutex<Option<http_bridge::HttpBridge>>> =
    Lazy::new(|| tokio::sync::Mutex::new(None));

// 系统代理是否由本进程写入：stdin EOF 的兜底清理只在真的改过系统设置时才执行
static PROXY_SET_BY_US: AtomicBool = AtomicBool::new(false);

static HTTP_CLIENT: Lazy<reqwest::Client> = Lazy::new(|| {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .timeout(Duration::from_secs(30))
        .build()
        .expect("build reqwest client")
});

static OUTPUT_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

// Electron 消亡后 stderr 管道也可能已关闭，eprintln! 写失败会 panic；
// 收尾/降级路径的日志一律走这里，写不进去就静默放弃，绝不 panic
fn log_stderr_best_effort(text: &str) {
    let _ = writeln!(std::io::stderr(), "{text}");
}

fn emit_line(value: &Value) {
    let guard = OUTPUT_LOCK.lock().expect("lock stdout writer");
    let mut out = std::io::stdout().lock();
    // stdout 断开（Electron 已死）时绝不 panic：panic 会跳过 main 尾部的
    // shutdown_cleanup，把系统代理留在指向已死端口的状态
    if writeln!(out, "{}", value).and_then(|_| out.flush()).is_err() {
        log_stderr_best_effort("[backend] write RPC line to stdout failed (peer closed?)");
    }
    drop(guard);
}

#[derive(Deserialize)]
struct RpcRequest {
    id: u64,
    method: String,
    params: Value,
}

#[derive(Serialize)]
struct RpcResponseOk {
    id: u64,
    ok: bool,
    result: Value,
}

#[derive(Serialize)]
pub struct RuntimeCapabilities {
    pub platform: &'static str,
    pub system_proxy: bool,
    pub oauth_callback: bool,
    pub autostart: bool,
    pub tray: bool,
    pub local_socks: bool,
    pub vpn: bool,
    pub payment: bool,
}

#[derive(Serialize)]
pub struct RuntimeConfig {
    pub app_name: String,
    pub default_api_url: String,
    pub user_agent: String,
    pub oauth_callback_scheme: String,
}

#[derive(Serialize)]
struct XboardResponse {
    ok: bool,
    status: u16,
    body: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Deserialize)]
struct XboardRequest {
    method: String,
    url: String,
    headers: Option<HashMap<String, String>>,
    body: Option<Value>,
}

#[derive(Deserialize)]
struct ResolveNodeHostRequest {
    #[serde(rename = "dnsUrl")]
    dns_url: String,
    host: String,
    #[serde(rename = "userAgent")]
    user_agent: Option<String>,
}

#[derive(Deserialize)]
struct RpcParamsForXboardRequest {
    request: XboardRequest,
}

fn platform_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "android") {
        "android"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "ios") {
        "ios"
    } else {
        "unknown"
    }
}

fn required_env(name: &str) -> Result<String> {
    let value =
        std::env::var(name).with_context(|| format!("{name} is required in build config"))?;
    let value = value.trim();
    if value.is_empty() {
        bail!("{name} is required in build config")
    }
    Ok(value.to_string())
}

fn runtime_capabilities() -> RuntimeCapabilities {
    // Electron 桌面端：Windows / Linux only. macOS may be added later.
    let desktop = cfg!(any(target_os = "windows", target_os = "linux"));
    let vpn = desktop;
    RuntimeCapabilities {
        platform: platform_name(),
        system_proxy: desktop,
        oauth_callback: desktop,
        autostart: desktop,
        tray: desktop,
        local_socks: true,
        vpn,
        payment: true,
    }
}

fn runtime_config() -> Result<RuntimeConfig> {
    Ok(RuntimeConfig {
        app_name: required_env("XBCLIENT_APP_NAME")?,
        default_api_url: required_env("XBCLIENT_DEFAULT_API_URL")?,
        user_agent: required_env("XBCLIENT_USER_AGENT")?,
        oauth_callback_scheme: required_env("XBCLIENT_OAUTH_CALLBACK_SCHEME")?,
    })
}

async fn resolve_node_host(params: ResolveNodeHostRequest) -> Result<String> {
    let host = params.host.trim();
    if host.parse::<IpAddr>().is_ok() {
        return Ok(host.to_string());
    }
    let resolver = params.dns_url.trim();
    if !resolver.starts_with("http://") && !resolver.starts_with("https://") {
        return Err(anyhow!("节点 DNS 必须是 DoH 地址。"));
    }

    // 部分 IPv4-only 网络解析 dns.alidns.com 会拿到 IPv6 地址导致 HTTPS 连不上，
    // 与 Android 端保持一致：先用配置的地址，连接失败时回退 AliDNS 的 IPv4 HTTP 端点
    let mut resolvers = vec![resolver.to_string()];
    if resolver.to_ascii_lowercase().contains("dns.alidns.com") {
        resolvers.push("http://223.5.5.5/resolve".to_string());
    }

    let mut last_error: Option<anyhow::Error> = None;
    for current in &resolvers {
        match doh_query(current, host, params.user_agent.as_deref()).await {
            Ok(Some(ip)) => return Ok(ip),
            // 解析服务可达但没有记录：这是权威结果，不再回退
            Ok(None) => return Err(anyhow!("节点 DNS 无可用 A/AAAA 记录。")),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow!("节点 DNS 无可用 A/AAAA 记录。")))
}

async fn doh_query(resolver: &str, host: &str, user_agent: Option<&str>) -> Result<Option<String>> {
    for record_type in ["A", "AAAA"] {
        let mut url = reqwest::Url::parse(resolver).with_context(|| "parse dns resolver URL")?;
        url.query_pairs_mut()
            .append_pair("name", host)
            .append_pair("type", record_type);

        let mut request = HTTP_CLIENT
            .get(url)
            .header("Accept", "application/dns-json, application/json");

        if let Some(value) = user_agent.map(|v| v.trim()).filter(|v| !v.is_empty()) {
            request = request.header("User-Agent", value);
        }

        let response = request
            .send()
            .await
            .map_err(|error| anyhow!("节点 DNS 请求失败：{}", error_chain_text(&error)))?;

        let status = response.status();
        if !status.is_success() {
            bail!("节点 DNS 请求失败：HTTP {}", status.as_u16());
        }

        #[derive(Deserialize)]
        struct DohResponse {
            #[serde(rename = "Answer")]
            answer: Option<Vec<DohAnswer>>,
        }
        #[derive(Deserialize)]
        struct DohAnswer {
            data: String,
        }

        let body = response
            .json::<DohResponse>()
            .await
            .map_err(|error| anyhow!("节点 DNS 响应不是 JSON：{error}"))?;

        if let Some(answer) = body.answer {
            for item in answer {
                if item.data.parse::<IpAddr>().is_ok() {
                    return Ok(Some(item.data));
                }
            }
        }
    }
    Ok(None)
}

// reqwest 错误的 Display 只有一层（如 "error sending request for url"），
// 真实原因（DNS 解析失败/连接被拒等）在 source 链里，逐层拼出来便于排查
fn error_chain_text(error: &(dyn std::error::Error + 'static)) -> String {
    let mut text = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        text.push_str(&format!("（{cause}）"));
        source = cause.source();
    }
    text
}

async fn xboard_request(params: RpcParamsForXboardRequest) -> Result<XboardResponse> {
    let method = params
        .request
        .method
        .parse::<reqwest::Method>()
        .map_err(|error| anyhow!("invalid HTTP method: {error}"))?;

    let mut builder = HTTP_CLIENT
        .request(method, &params.request.url)
        .header("Accept", "application/json");

    if let Some(headers) = params.request.headers {
        for (key, value) in headers {
            builder = builder.header(key, value);
        }
    }

    if let Some(body) = params.request.body {
        let bytes = serde_json::to_vec(&body).context("encode xboard request body")?;
        builder = builder
            .body(bytes)
            .header("Content-Type", "application/json; charset=utf-8");
    }

    let response = builder.send().await.context("xboard request")?;
    let status = response.status().as_u16();
    let text = response.text().await.context("read xboard response")?;

    ensure!(!text.is_empty(), "xboard JSON response body is empty");
    let parsed = serde_json::from_str(&text).context("parse xboard JSON response")?;

    let ok = (200..300).contains(&status);
    Ok(XboardResponse {
        ok,
        status,
        body: parsed,
        error: (!ok).then(|| format!("HTTP {status}")),
    })
}

async fn subscription_fetch(params: &Value) -> Result<Value> {
    #[derive(Deserialize)]
    struct SubscriptionReq {
        url: String,
        flag: String,
    }
    let input: SubscriptionReq =
        serde_json::from_value(params.clone()).context("parse subscription_fetch args")?;
    let v = subscription::fetch(&HTTP_CLIENT, &input.url, &input.flag).await?;
    Ok(v)
}

async fn aerion_test_node(params: &Value) -> Result<Value> {
    #[derive(Deserialize)]
    struct TestNodeParams {
        request: Value,
    }
    let input: TestNodeParams =
        serde_json::from_value(params.clone()).context("parse aerion_test_node args")?;
    let json_str = serde_json::to_string(&input.request)?;
    let output = aerion_core::test_node_from_json(&json_str)
        .await
        .context("test Aerion node")?;
    serde_json::from_str(&output).context("parse aerion_test_node response")
}

async fn spawn_aerion_value(
    fut: impl std::future::Future<Output = Result<Value>> + Send + 'static,
) -> Result<Value> {
    match tokio::spawn(fut).await {
        Ok(result) => result,
        Err(error) => Err(anyhow!("Aerion internal task failed: {error}")),
    }
}

async fn aerion_start_socks(params: &Value) -> Result<Value> {
    #[derive(Deserialize)]
    struct StartSocksParams {
        node: Value,
    }
    let input: StartSocksParams =
        serde_json::from_value(params.clone()).context("parse aerion_start_socks args")?;
    let wrapped = serde_json::json!({ "node": input.node });
    let input_str = serde_json::to_string(&wrapped)?;
    let output = aerion_core::start_socks_from_json(&input_str)
        .await
        .context("start Aerion SOCKS")?;
    serde_json::from_str(&output).context("parse aerion_start_socks response")
}

async fn aerion_start_vpn(params: &Value) -> Result<Value> {
    let input = serde_json::to_string(params)?;
    let output = aerion_core::start_vpn_from_json(&input)
        .await
        .context("start Aerion VPN")?;
    serde_json::from_str(&output).context("parse aerion_start_vpn response")
}

async fn aerion_stop_vpn(params: &Value) -> Result<Value> {
    let session_id = params
        .get("sessionId")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| anyhow!("aerion_stop_vpn missing sessionId"))?;
    let output = aerion_core::stop_vpn(session_id)
        .await
        .context("stop Aerion VPN")?;
    serde_json::from_str(&output).context("parse aerion_stop_vpn response")
}

async fn aerion_start_route(params: &Value) -> Result<Value> {
    let input = serde_json::to_string(params)?;
    let output = aerion_core::start_route_from_json(&input)
        .await
        .context("start Aerion route")?;
    serde_json::from_str(&output).context("parse aerion_start_route response")
}

async fn aerion_stop_route(params: &Value) -> Result<Value> {
    let session_id = params
        .get("sessionId")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| anyhow!("aerion_stop_route missing sessionId"))?;
    let output = aerion_core::stop_route(session_id)
        .await
        .context("stop Aerion route")?;
    serde_json::from_str(&output).context("parse aerion_stop_route response")
}

async fn aerion_stop(params: &Value) -> Result<Value> {
    let session_id = params
        .get("sessionId")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| anyhow!("aerion_stop missing sessionId"))?;
    let output = aerion_core::stop_socks(session_id).await?;
    serde_json::from_str(&output).context("parse aerion_stop response")
}

async fn system_proxy_set(params: &Value) -> Result<()> {
    #[derive(Deserialize)]
    struct SystemProxySetParams {
        host: String,
        port: u16,
    }
    let input: SystemProxySetParams =
        serde_json::from_value(params.clone()).context("parse system_proxy_set args")?;
    #[cfg(windows)]
    {
        // Windows 不能把 SOCKS5 监听直接写进注册表（WinINET/Chromium 只按 SOCKS4 握手），
        // 必须先起本地 HTTP 代理桥，再把桥地址以 HTTP 代理形式写入系统代理
        let upstream: std::net::SocketAddr = format!("{}:{}", input.host, input.port)
            .parse()
            .context("parse SOCKS upstream address")?;
        // 先起新桥并把注册表切到新桥，成功后才停旧桥；写注册表失败则撤掉新桥、
        // 旧桥原样保留——注册表要么指向新桥要么仍指向可用的旧桥，绝不指向死端口
        let bridge = http_bridge::start(upstream).await?;
        let bridge_addr = bridge.addr;
        let mut guard = HTTP_BRIDGE.lock().await;
        match system_proxy::set_http(&bridge_addr.ip().to_string(), bridge_addr.port()) {
            Ok(()) => {
                if let Some(previous) = guard.replace(bridge) {
                    previous.stop();
                }
                PROXY_SET_BY_US.store(true, Ordering::SeqCst);
            }
            Err(error) => {
                bridge.stop();
                return Err(error.context("system proxy set"));
            }
        }
    }
    #[cfg(not(windows))]
    {
        system_proxy::set_socks(&input.host, input.port).context("system proxy set")?;
        PROXY_SET_BY_US.store(true, Ordering::SeqCst);
    }
    Ok(())
}

async fn system_proxy_clear() -> Result<()> {
    #[cfg(windows)]
    {
        // 先恢复注册表再停桥：恢复失败时保留桥继续服务（浏览器不至于断网），
        // 绝不留下 ProxyEnable=1 指向已死端口的状态
        system_proxy::restore().context("system proxy restore")?;
        PROXY_SET_BY_US.store(false, Ordering::SeqCst);
        let previous = HTTP_BRIDGE.lock().await.take();
        if let Some(previous) = previous {
            previous.stop();
        }
    }
    #[cfg(not(windows))]
    {
        system_proxy::clear().context("system proxy clear")?;
        PROXY_SET_BY_US.store(false, Ordering::SeqCst);
    }
    Ok(())
}

/// 进程收尾兜底：stdin EOF/读错误（Electron 崩溃或退出）后执行。
/// 若系统代理是本进程写入的，必须恢复用户原有设置——否则注册表里
/// ProxyEnable=1 指向一个已死的临时端口，整机浏览器直接断网。
/// 此路径只尽力而为：任何失败仅写 stderr，绝不 panic。
async fn shutdown_cleanup() {
    if PROXY_SET_BY_US.swap(false, Ordering::SeqCst) {
        // 与 system_proxy_clear 保持同序：先恢复注册表，再停桥
        #[cfg(windows)]
        {
            if let Err(error) = system_proxy::restore() {
                log_stderr_best_effort(&format!(
                    "[backend] restore system proxy on shutdown failed: {error:#}"
                ));
            }
        }
        #[cfg(not(windows))]
        {
            if let Err(error) = system_proxy::clear() {
                log_stderr_best_effort(&format!(
                    "[backend] clear system proxy on shutdown failed: {error:#}"
                ));
            }
        }
    }
    #[cfg(windows)]
    {
        // 进程即将退出，桥必然随之消亡；显式停掉让监听端口立即释放
        let bridge = HTTP_BRIDGE.lock().await.take();
        if let Some(bridge) = bridge {
            bridge.stop();
        }
    }
}

fn emit_rpc_response(id: u64, out: Result<RpcResponseOk, anyhow::Error>) {
    match out {
        Ok(ok) => {
            if let Ok(value) = serde_json::to_value(ok) {
                emit_line(&value);
            } else {
                emit_line(&json!({ "id": id, "ok": false, "error": "serialize response failed" }));
            }
        }
        Err(error) => {
            emit_line(&json!({ "id": id, "ok": false, "error": format!("{error:#}") }));
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow!("rustls crypto provider is already installed"))?;
    let mut stdin = BufReader::new(io::stdin());
    let mut lines = String::new();

    set_log_callback(|level, message| {
        emit_line(&json!({ "type": "log", "level": level, "message": message }));
    });
    set_event_callback(|_, event_json| {
        emit_line(&json!({ "type": "event", "payload": event_json }));
    });

    loop {
        lines.clear();
        let read = match stdin.read_line(&mut lines).await {
            Ok(n) => n,
            Err(error) => {
                emit_line(&json!({
                    "type": "log",
                    "level": "error",
                    "message": format!("stdin read error: {error}")
                }));
                break;
            }
        };
        if read == 0 {
            break;
        }
        let text = lines.trim();
        if text.is_empty() {
            continue;
        }

        let req: RpcRequest = match serde_json::from_str(text) {
            Ok(v) => v,
            Err(error) => {
                emit_line(&json!({
                    "type": "log",
                    "level": "error",
                    "message": format!("invalid RPC request JSON: {error}")
                }));
                continue;
            }
        };

        let out: Result<RpcResponseOk, anyhow::Error> = (async {
            match req.method.as_str() {
                "runtime_capabilities" => {
                    let caps = runtime_capabilities();
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: serde_json::to_value(caps)?,
                    })
                }
                "runtime_config" => {
                    let cfg = runtime_config()?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: serde_json::to_value(cfg)?,
                    })
                }
                "resolve_node_host" => {
                    let params: ResolveNodeHostRequest = serde_json::from_value(req.params)?;
                    let resolved = resolve_node_host(params).await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: serde_json::to_value(resolved)?,
                    })
                }
                "xboard_request" => {
                    let params: RpcParamsForXboardRequest = serde_json::from_value(req.params)?;
                    let resp = xboard_request(params).await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: serde_json::to_value(resp)?,
                    })
                }
                "subscription_fetch" => {
                    let resp = subscription_fetch(&req.params).await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: resp,
                    })
                }
                "aerion_test_node" => {
                    let params = req.params.clone();
                    let resp =
                        spawn_aerion_value(async move { aerion_test_node(&params).await }).await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: resp,
                    })
                }
                "aerion_start_socks" => {
                    let params = req.params.clone();
                    let resp = spawn_aerion_value(async move { aerion_start_socks(&params).await })
                        .await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: resp,
                    })
                }
                "aerion_start_route" => {
                    let params = req.params.clone();
                    let resp = spawn_aerion_value(async move { aerion_start_route(&params).await })
                        .await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: resp,
                    })
                }
                "aerion_start_vpn" => {
                    let params = req.params.clone();
                    let resp =
                        spawn_aerion_value(async move { aerion_start_vpn(&params).await }).await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: resp,
                    })
                }
                "aerion_stop_vpn" => {
                    let params = req.params.clone();
                    let resp =
                        spawn_aerion_value(async move { aerion_stop_vpn(&params).await }).await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: resp,
                    })
                }
                "aerion_stop" => {
                    let params = req.params.clone();
                    let resp =
                        spawn_aerion_value(async move { aerion_stop(&params).await }).await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: resp,
                    })
                }
                "aerion_stop_route" => {
                    let params = req.params.clone();
                    let resp =
                        spawn_aerion_value(async move { aerion_stop_route(&params).await }).await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: resp,
                    })
                }
                "system_proxy_set" => {
                    system_proxy_set(&req.params).await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: json!(null),
                    })
                }
                "system_proxy_clear" => {
                    system_proxy_clear().await?;
                    Ok(RpcResponseOk {
                        id: req.id,
                        ok: true,
                        result: json!(null),
                    })
                }
                other => bail!("unsupported method: {other}"),
            }
        })
        .await;

        emit_rpc_response(req.id, out);
    }

    // stdin EOF/读错误意味着 Electron 已经退出或崩溃：兜底恢复系统代理并停桥，
    // 避免孤儿退出后把整机浏览器留在「代理指向已死端口」的断网状态
    shutdown_cleanup().await;

    Ok(())
}
