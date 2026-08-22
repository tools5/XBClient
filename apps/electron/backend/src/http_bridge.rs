//! 本地 HTTP 代理桥：接收浏览器的 HTTP 代理请求（CONNECT 隧道 + http:// 绝对路径明文请求），
//! 通过当前会话的本地 SOCKS5 监听转发出去。
//!
//! 为什么必须存在：Windows 注册表 ProxyServer 写 `socks=host:port` 时，WinINET 与
//! Chromium 系浏览器（Edge/Chrome，即 Windows 上绝大多数浏览器）只会按 **SOCKS4**
//! 协议对该地址握手（历史兼容行为），而 Aerion 本地监听只支持 SOCKS5，首字节 0x04
//! 直接被拒——表现为「系统代理已开启但完全无法上网」。且 SOCKS4 由浏览器本地解析
//! DNS，即使握手成功也会因 DNS 污染失效。主流客户端（v2rayN/Clash 等）一律以本地
//! HTTP 代理接管系统代理（CONNECT 携带主机名 → 远端解析），此处同理。

use anyhow::{Context, Result, bail, ensure};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

pub struct HttpBridge {
    pub addr: SocketAddr,
    task: JoinHandle<()>,
}

impl HttpBridge {
    pub fn stop(self) {
        // 中止 accept 循环并释放监听端口；既有连接由两端关闭自然结束
        self.task.abort();
    }
}

pub async fn start(upstream_socks: SocketAddr) -> Result<HttpBridge> {
    let listener = TcpListener::bind(SocketAddr::new(
        IpAddr::V4(Ipv4Addr::LOCALHOST),
        0,
    ))
    .await
    .context("bind local HTTP proxy bridge")?;
    let addr = listener
        .local_addr()
        .context("read HTTP proxy bridge address")?;
    let task = tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    tokio::spawn(async move {
                        if let Err(error) = handle_client(stream, upstream_socks).await {
                            eprintln!("[http-bridge] client failed: {error:#}");
                        }
                    });
                }
                Err(error) => {
                    eprintln!("[http-bridge] accept failed: {error}");
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
            }
        }
    });
    Ok(HttpBridge { addr, task })
}

async fn handle_client(mut local: TcpStream, upstream_socks: SocketAddr) -> Result<()> {
    let (head, leftover) = read_head(&mut local).await?;
    let head_text = String::from_utf8_lossy(&head).into_owned();
    let mut lines = head_text.split("\r\n");
    let request_line = lines.next().unwrap_or_default().to_string();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_string();
    let target = parts.next().unwrap_or_default().to_string();
    let version = parts.next().unwrap_or_default().to_string();
    if method.is_empty() || target.is_empty() || !version.starts_with("HTTP/1.") {
        let _ = local.write_all(b"HTTP/1.1 400 Bad Request\r\n\r\n").await;
        bail!("invalid HTTP proxy request line: {request_line}");
    }

    if method.eq_ignore_ascii_case("CONNECT") {
        let (host, port) = split_host_port(&target, 443)?;
        let mut upstream = match socks5_connect(upstream_socks, &host, port).await {
            Ok(upstream) => upstream,
            Err(error) => {
                let _ = local.write_all(b"HTTP/1.1 502 Bad Gateway\r\n\r\n").await;
                return Err(error);
            }
        };
        local
            .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            .await
            .context("write CONNECT response")?;
        if !leftover.is_empty() {
            upstream
                .write_all(&leftover)
                .await
                .context("forward buffered CONNECT bytes")?;
        }
        let _ = tokio::io::copy_bidirectional(&mut local, &mut upstream).await;
        return Ok(());
    }

    // 明文 http:// 绝对路径请求（浏览器访问 80 端口站点时经代理走这里）
    let Some(rest) = target.strip_prefix("http://") else {
        let _ = local.write_all(b"HTTP/1.1 400 Bad Request\r\n\r\n").await;
        bail!("unsupported HTTP proxy target: {target}");
    };
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    let (host, port) = split_host_port(authority, 80)?;
    let mut upstream = match socks5_connect(upstream_socks, &host, port).await {
        Ok(upstream) => upstream,
        Err(error) => {
            let _ = local.write_all(b"HTTP/1.1 502 Bad Gateway\r\n\r\n").await;
            return Err(error);
        }
    };

    // 重写为 origin-form 并强制短连接，避免实现代理侧 keep-alive 语义
    let mut request = format!("{method} {path} HTTP/1.1\r\n");
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("proxy-connection:")
            || lower.starts_with("connection:")
            || lower.starts_with("keep-alive:")
        {
            continue;
        }
        request.push_str(line);
        request.push_str("\r\n");
    }
    request.push_str("Connection: close\r\n\r\n");
    upstream
        .write_all(request.as_bytes())
        .await
        .context("forward HTTP proxy request head")?;
    if !leftover.is_empty() {
        upstream
            .write_all(&leftover)
            .await
            .context("forward HTTP proxy request body")?;
    }
    let _ = tokio::io::copy_bidirectional(&mut local, &mut upstream).await;
    Ok(())
}

async fn read_head(stream: &mut TcpStream) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut buffer: Vec<u8> = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    loop {
        let read = stream
            .read(&mut chunk)
            .await
            .context("read HTTP proxy request head")?;
        ensure!(read > 0, "HTTP proxy client closed before request head");
        buffer.extend_from_slice(&chunk[..read]);
        if let Some(end) = buffer
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .map(|index| index + 4)
        {
            let leftover = buffer.split_off(end);
            return Ok((buffer, leftover));
        }
        ensure!(
            buffer.len() <= 32 * 1024,
            "HTTP proxy request head is too large"
        );
    }
}

fn split_host_port(authority: &str, default_port: u16) -> Result<(String, u16)> {
    let authority = authority.trim();
    ensure!(!authority.is_empty(), "HTTP proxy target authority is empty");
    if let Some(rest) = authority.strip_prefix('[') {
        let (host, tail) = rest
            .split_once(']')
            .with_context(|| format!("invalid IPv6 proxy authority: {authority}"))?;
        let port = match tail.strip_prefix(':') {
            Some(port) => port
                .parse::<u16>()
                .with_context(|| format!("parse proxy authority port: {authority}"))?,
            None => default_port,
        };
        return Ok((host.to_string(), port));
    }
    match authority.rsplit_once(':') {
        Some((host, port)) if !host.contains(':') => {
            let port = port
                .parse::<u16>()
                .with_context(|| format!("parse proxy authority port: {authority}"))?;
            Ok((host.to_string(), port))
        }
        Some(_) => bail!("IPv6 proxy authority must use [addr]:port form: {authority}"),
        None => Ok((authority.to_string(), default_port)),
    }
}

async fn socks5_connect(upstream: SocketAddr, host: &str, port: u16) -> Result<TcpStream> {
    let mut stream = TcpStream::connect(upstream)
        .await
        .with_context(|| format!("connect local SOCKS listener {upstream}"))?;
    stream
        .write_all(&[0x05, 0x01, 0x00])
        .await
        .context("write SOCKS greeting")?;
    let mut greeting = [0u8; 2];
    stream
        .read_exact(&mut greeting)
        .await
        .context("read SOCKS greeting response")?;
    ensure!(
        greeting == [0x05, 0x00],
        "SOCKS greeting rejected: {greeting:02x?}"
    );
    let mut request: Vec<u8> = vec![0x05, 0x01, 0x00];
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            request.push(0x01);
            request.extend_from_slice(&ip.octets());
        }
        Ok(IpAddr::V6(ip)) => {
            request.push(0x04);
            request.extend_from_slice(&ip.octets());
        }
        // 主机名原样透传给 SOCKS5（域名 ATYP），由代理链条远端解析，规避本地 DNS 污染
        Err(_) => {
            ensure!(
                host.len() <= u8::MAX as usize,
                "proxy target host is too long: {host}"
            );
            request.push(0x03);
            request.push(host.len() as u8);
            request.extend_from_slice(host.as_bytes());
        }
    }
    request.extend_from_slice(&port.to_be_bytes());
    stream
        .write_all(&request)
        .await
        .context("write SOCKS connect request")?;
    let mut header = [0u8; 4];
    stream
        .read_exact(&mut header)
        .await
        .context("read SOCKS connect response")?;
    ensure!(
        header[0] == 0x05 && header[1] == 0x00,
        "SOCKS connect failed (reply 0x{:02x})",
        header[1]
    );
    match header[3] {
        0x01 => {
            let mut skip = [0u8; 6];
            stream
                .read_exact(&mut skip)
                .await
                .context("read SOCKS bind address")?;
        }
        0x03 => {
            let mut len = [0u8; 1];
            stream
                .read_exact(&mut len)
                .await
                .context("read SOCKS bind address length")?;
            let mut skip = vec![0u8; len[0] as usize + 2];
            stream
                .read_exact(&mut skip)
                .await
                .context("read SOCKS bind address")?;
        }
        0x04 => {
            let mut skip = [0u8; 18];
            stream
                .read_exact(&mut skip)
                .await
                .context("read SOCKS bind address")?;
        }
        atyp => bail!("unsupported SOCKS bind address type: {atyp}"),
    }
    Ok(stream)
}
