#[cfg(windows)]
use anyhow::{Context, Result};

#[cfg(windows)]
const REGISTRY_PATH: &str = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

/// 接管系统代理前用户原有配置的快照；None 表示该注册表值当时不存在。
#[cfg(windows)]
#[derive(serde::Serialize, serde::Deserialize)]
struct ProxySnapshot {
    proxy_enable: Option<u32>,
    proxy_server: Option<String>,
    proxy_override: Option<String>,
    auto_config_url: Option<String>,
}

/// 快照备份文件路径：%APPDATA% 缺失时退回临时目录，保证总有处可写。
#[cfg(windows)]
fn backup_file_path() -> std::path::PathBuf {
    match std::env::var("APPDATA") {
        Ok(dir) if !dir.trim().is_empty() => {
            std::path::PathBuf::from(dir).join("xbclient-proxy-backup.json")
        }
        _ => std::env::temp_dir().join("xbclient-proxy-backup.json"),
    }
}

/// 读取注册表值；值不存在时返回 None 而非错误。
#[cfg(windows)]
fn read_optional<T: winreg::types::FromRegValue>(
    key: &winreg::RegKey,
    name: &str,
) -> Result<Option<T>> {
    match key.get_value::<T, _>(name) {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("read {name}")),
    }
}

/// 删除注册表值；值本就不存在视为成功。
#[cfg(windows)]
fn delete_value_if_exists(key: &winreg::RegKey, name: &str) -> Result<()> {
    match key.delete_value(name) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("delete {name}")),
    }
}

/// 恢复字符串型注册表值：快照里不存在的值必须删掉，不能留下我们写入的残余。
#[cfg(windows)]
fn restore_string(key: &winreg::RegKey, name: &str, value: Option<&String>) -> Result<()> {
    match value {
        Some(text) => key
            .set_value(name, text)
            .with_context(|| format!("restore {name}")),
        None => delete_value_if_exists(key, name),
    }
}

/// 首次接管前把用户原有代理配置写入备份文件。备份文件已存在时绝不覆盖：
/// 那说明上一次会话在恢复前崩溃了——文件里才是用户的真实配置，
/// 而当前注册表里是我们写入的值，拿它重做快照会把用户配置永久顶掉。
#[cfg(windows)]
fn snapshot_user_proxy(key: &winreg::RegKey) -> Result<()> {
    let path = backup_file_path();
    if path.exists() {
        return Ok(());
    }
    let snapshot = ProxySnapshot {
        proxy_enable: read_optional::<u32>(key, "ProxyEnable")?,
        proxy_server: read_optional::<String>(key, "ProxyServer")?,
        proxy_override: read_optional::<String>(key, "ProxyOverride")?,
        auto_config_url: read_optional::<String>(key, "AutoConfigURL")?,
    };
    let json = serde_json::to_vec_pretty(&snapshot).context("encode proxy snapshot")?;
    std::fs::write(&path, json)
        .with_context(|| format!("write proxy snapshot {}", path.display()))?;
    Ok(())
}

/// 通知 WinINET（及跟随系统代理的浏览器）代理设置已变更并立即生效。
#[cfg(windows)]
fn refresh_wininet() {
    use std::ptr;
    use windows_sys::Win32::Networking::WinInet::{
        INTERNET_OPTION_REFRESH, INTERNET_OPTION_SETTINGS_CHANGED, InternetSetOptionW,
    };
    unsafe {
        InternetSetOptionW(
            ptr::null_mut(),
            INTERNET_OPTION_SETTINGS_CHANGED,
            ptr::null(),
            0,
        );
        InternetSetOptionW(ptr::null_mut(), INTERNET_OPTION_REFRESH, ptr::null(), 0);
    }
}

/// 把本地 HTTP 代理（http_bridge）写入 Windows 系统代理。
///
/// 注意：这里绝不能写 `socks=host:port` —— WinINET 与 Chromium 系浏览器
/// （Edge/Chrome）会按 SOCKS4 协议对该地址握手，而本地监听只支持 SOCKS5，
/// 结果是「系统代理开启但完全无法上网」。纯 `host:port` 形式表示对所有协议
/// 使用 HTTP 代理，与 v2rayN/Clash 等主流客户端一致。
#[cfg(windows)]
pub fn set_http(host: &str, port: u16) -> Result<()> {
    use winreg::RegKey;
    use winreg::enums::{HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE};

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = hkcu
        .open_subkey_with_flags(REGISTRY_PATH, KEY_QUERY_VALUE | KEY_SET_VALUE)
        .context("open Internet Settings registry key")?;

    // 覆盖前先快照用户原值（含企业代理/PAC），restore() 据此原样恢复
    snapshot_user_proxy(&key)?;

    let server = format!("{host}:{port}");
    key.set_value("ProxyServer", &server)
        .context("write ProxyServer")?;
    key.set_value("ProxyEnable", &1u32)
        .context("write ProxyEnable")?;
    // 回环地址必须绕过系统代理，否则本机组件之间的请求也会被绕进代理链；
    // [::1] 覆盖 IPv6 回环，127.* 只匹配 IPv4
    key.set_value(
        "ProxyOverride",
        &"localhost;127.*;[::1];<local>".to_string(),
    )
    .context("write ProxyOverride")?;
    // 残留的 PAC（AutoConfigURL）优先级高于手动代理，会静默架空上面的设置，
    // 必须删掉；其原值已随快照保存，恢复时会原样写回
    delete_value_if_exists(&key, "AutoConfigURL")?;

    refresh_wininet();
    Ok(())
}

/// 恢复接管系统代理前的用户配置：按备份文件原样写回四个值并删除备份；
/// 没有备份文件时退化为仅关闭代理开关（ProxyEnable=0）。
#[cfg(windows)]
pub fn restore() -> Result<()> {
    use winreg::RegKey;
    use winreg::enums::{HKEY_CURRENT_USER, KEY_SET_VALUE};

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = hkcu
        .open_subkey_with_flags(REGISTRY_PATH, KEY_SET_VALUE)
        .context("open Internet Settings registry key")?;

    let backup = backup_file_path();
    match std::fs::read(&backup) {
        Ok(bytes) => match serde_json::from_slice::<ProxySnapshot>(&bytes) {
            Ok(snapshot) => {
                restore_string(&key, "ProxyServer", snapshot.proxy_server.as_ref())?;
                restore_string(&key, "ProxyOverride", snapshot.proxy_override.as_ref())?;
                restore_string(&key, "AutoConfigURL", snapshot.auto_config_url.as_ref())?;
                match snapshot.proxy_enable {
                    Some(value) => key
                        .set_value("ProxyEnable", &value)
                        .context("restore ProxyEnable")?,
                    None => delete_value_if_exists(&key, "ProxyEnable")?,
                }
                std::fs::remove_file(&backup)
                    .with_context(|| format!("remove proxy snapshot {}", backup.display()))?;
            }
            Err(error) => {
                // 快照损坏无从恢复原值：退化为关闭代理，并删掉坏文件——
                // 否则每次恢复都失败，系统代理会被永久卡在指向本进程的状态。
                // 本函数也在进程收尾路径上运行，stderr 可能已消亡，写日志绝不 panic
                {
                    use std::io::Write as _;
                    let _ = writeln!(
                        std::io::stderr(),
                        "[system-proxy] proxy snapshot {} is corrupt: {error}",
                        backup.display()
                    );
                }
                key.set_value("ProxyEnable", &0u32)
                    .context("write ProxyEnable")?;
                let _ = std::fs::remove_file(&backup);
            }
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // 无快照（从未经过 set_http，或备份已被上一次恢复消费）：仅关闭代理开关
            key.set_value("ProxyEnable", &0u32)
                .context("write ProxyEnable")?;
        }
        Err(error) => {
            return Err(error).with_context(|| format!("read proxy snapshot {}", backup.display()));
        }
    }

    refresh_wininet();
    Ok(())
}

#[cfg(target_os = "linux")]
use anyhow::{Context, Result, bail};

#[cfg(target_os = "linux")]
fn gsettings_set(schema: &str, key: &str, value: &str) -> Result<()> {
    let status = std::process::Command::new("gsettings")
        .args(["set", schema, key, value])
        .status()
        .with_context(|| format!("gsettings set {schema} {key}"))?;
    if !status.success() {
        bail!("gsettings set {schema} {key} failed (exit {status})");
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn set_socks(host: &str, port: u16) -> Result<()> {
    gsettings_set("org.gnome.system.proxy", "mode", "manual")?;
    gsettings_set("org.gnome.system.proxy.socks", "host", host)?;
    gsettings_set("org.gnome.system.proxy.socks", "port", &port.to_string())?;
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn clear() -> Result<()> {
    gsettings_set("org.gnome.system.proxy", "mode", "none")?;
    Ok(())
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn set_socks(_host: &str, _port: u16) -> anyhow::Result<()> {
    anyhow::bail!("system proxy not supported on this platform")
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn clear() -> anyhow::Result<()> {
    anyhow::bail!("system proxy not supported on this platform")
}
