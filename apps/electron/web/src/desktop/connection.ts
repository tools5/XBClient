import {
  aerionStartRoute,
  aerionStartSocks,
  aerionStartVpn,
  aerionStop,
  aerionStopRoute,
  aerionStopVpn,
} from '../api/xboard'
import {
  parseSocksAddr,
  resolveAppNode,
  systemProxyClear,
  systemProxySet,
} from '../api/system'
import {
  dnsAddressForVpn,
  resolveConnectableNodeIndex,
} from '../nodes'
import { publicErrorText } from '../format'
import { reportVpnSession } from '../platform/electron'
import { isDesktopShell } from '../platform/shell'
import { ref } from 'vue'
import { useAppStore, type AppNode } from '../store'

// 用响应式 ref 而非普通变量：DesktopConnectionPanel 的 computed 依赖它，
// 普通变量无法触发重新求值，会把开关永久卡在首次渲染时的禁用状态
const syncing = ref(false)
// 会话意外消亡（TUN 运行时崩溃/秒死）的原因：null=无事故；''=消亡但后端未附原因。
// 自愈只会把 UI 归零，若不把原因留在这里，用户只看到「连了又断」毫无线索。
const sessionLostDetail = ref<string | null>(null)
// 串行化队列：applyDesktopConnection 可能被并发触发（bootstrap 自动连接、
// HomeView 刷新、节点点击、开关切换），并发执行会产生两个 TUN 会话并泄漏其一。
// 每次排队的执行都会重读最新 state，所以「最后一次操作」自然生效。
let applyChain: Promise<unknown> = Promise.resolve()
let pendingApplies = 0

export function isDesktopConnectionShell(): boolean {
  return isDesktopShell() && Boolean(useAppStore.getState().capabilities?.vpn)
}

async function resolvedNode(node: AppNode): Promise<unknown> {
  const state = useAppStore.getState()
  if (!state.buildConfig?.user_agent) throw new Error('XBCLIENT_USER_AGENT is required in build config')
  return resolveAppNode(node, state.settings.nodeDns, state.buildConfig.user_agent)
}

async function connectionNode(index: number): Promise<unknown> {
  const state = useAppStore.getState()
  if (state.settings.routingMode === 'direct') return { type: 'direct', name: 'DIRECT' }
  const node = state.nodes[index]
  if (!node?.connectSupported || node.isInfo) throw new Error('unsupported_protocol')
  return resolvedNode(node)
}

async function applySessionSystemProxy(): Promise<void> {
  const state = useAppStore.getState()
  const session = state.vpn
  const socksAddr = session?.socksAddr || session?.tunSocksAddr || ''
  if (state.settings.systemProxyEnabled) {
    if (!socksAddr) throw new Error('session SOCKS address is required for system proxy')
    const parsed = parseSocksAddr(socksAddr)
    await systemProxySet(parsed.host, parsed.port)
    state.setSystemProxyActive(true)
  } else if (state.systemProxyActive) {
    await systemProxyClear()
    state.setSystemProxyActive(false)
  }
}

async function disconnectSession(): Promise<void> {
  const state = useAppStore.getState()
  const session = state.vpn
  if (!session) return
  const useTun = !session.routeMode && !session.socksAddr
  try {
    if (session.routeMode) await aerionStopRoute(session.sessionId)
    else if (useTun) await aerionStopVpn(session.sessionId)
    else await aerionStop(session.sessionId)
  } catch (err) {
    // 停止失败（含会话已不存在）视为会话已消亡：清空本地状态并继续后续流程，
    // 避免残留会话卡死节点切换/重连
    console.warn('stop VPN session failed; treating session as already stopped', err)
  }
  if (state.systemProxyActive) {
    try {
      await systemProxyClear()
      state.setSystemProxyActive(false)
    } catch (err) {
      // 清理系统代理失败不能中断后续拆除：否则 setVpn(null)/reportVpnSession(null)
      // 被跳过，UI 会对着一个已死会话永远显示「已连接」。保留 systemProxyActive
      // 标记，后续断开/开关操作仍会再次尝试清理。
      console.warn('clear system proxy during disconnect failed; continuing teardown', err)
    }
  }
  state.setVpn(null)
  await reportVpnSession(null)
}

/**
 * 后端会话在未被显式停止的情况下消亡（TUN 运行时崩溃/自然退出）时的自愈：
 * 收到 vpn_session_closed 事件后清空本地连接状态，避免 UI 显示“已连接”但 0 流量。
 */
export function handleAerionBackendEvent(payload: string): void {
  let data: { type?: string; wrapper_session_id?: number; error?: string | null }
  try {
    data = JSON.parse(payload) as { type?: string; wrapper_session_id?: number; error?: string | null }
  } catch {
    return
  }
  if (data.type !== 'vpn_session_closed') return
  const state = useAppStore.getState()
  const session = state.vpn
  if (!session || typeof data.wrapper_session_id !== 'number' || session.sessionId !== data.wrapper_session_id) return
  // vpn_session_closed 只描述 TUN 会话；SOCKS/route 会话的编号在各自独立计数序列里，
  // 数值可能与 TUN 会话撞号，绝不能据此清掉非 TUN 的活动会话
  if (session.routeMode || session.socksAddr) return
  sessionLostDetail.value = typeof data.error === 'string' && data.error.trim() ? publicErrorText(data.error) : ''
  state.setVpn(null)
  if (state.systemProxyActive) {
    void systemProxyClear()
      .then(() => useAppStore.getState().setSystemProxyActive(false))
      .catch((err) => console.warn('clear system proxy after session loss failed', err))
  }
  void reportVpnSession(null).catch(() => {})
}

async function startTun(index: number): Promise<void> {
  const state = useAppStore.getState()
  const resolved = await connectionNode(index)
  const dnsMode = state.settings.vpnDnsMode
  const dns_addr = dnsAddressForVpn(
    dnsMode === 'direct' ? state.settings.directDns : state.settings.overseasDns,
  )
  const handle = await aerionStartVpn({
    node: resolved,
    mtu: 1500,
    dns: dnsMode,
    dns_addr,
    virtual_dns_pool: state.settings.virtualDnsPool,
    ipv6: state.settings.vpnIpv6Enabled,
  })
  state.setPreferredNodeIndex(index)
  state.setVpn({
    sessionId: handle.session_id,
    socksAddr: '',
    tunSocksAddr: handle.socks_addr,
    nodeIndex: index,
    uploadBytes: 0,
    downloadBytes: 0,
    routeMode: false,
    routingMode: state.settings.routingMode,
  })
  await reportVpnSession(handle.session_id)
  await applySessionSystemProxy()
}

async function startSocks(index: number): Promise<void> {
  const state = useAppStore.getState()
  const resolved = await connectionNode(index)
  const handle = await aerionStartSocks(resolved)
  state.setPreferredNodeIndex(index)
  state.setVpn({
    sessionId: handle.session_id,
    socksAddr: handle.socks_addr,
    nodeIndex: index,
    uploadBytes: 0,
    downloadBytes: 0,
    routeMode: false,
    routingMode: state.settings.routingMode,
  })
  await applySessionSystemProxy()
}

async function startRoute(index: number): Promise<void> {
  const state = useAppStore.getState()
  const node = state.nodes[index]
  if (!node?.connectSupported || node.isInfo) throw new Error('unsupported_protocol')
  const resolved = await resolvedNode(node)
  const configYaml = state.settings.routeConfigYaml.trim() || state.routing.routeConfigYaml
  if (!configYaml?.trim()) throw new Error('routing_rules_missing')
  const request = {
    config_yaml: configYaml,
    geoip_dir: state.settings.geoipDir.trim() || undefined,
    global_proxy: state.settings.routingMode === 'global' ? node.name : undefined,
    selected_proxy: state.settings.routingMode === 'rule' ? node.name : undefined,
    selected_node: state.settings.routingMode === 'rule' ? resolved : undefined,
  }
  const handle = await aerionStartRoute(request)
  const parsed = parseSocksAddr(handle.socks_addr)
  state.setPreferredNodeIndex(index)
  state.setVpn({
    sessionId: handle.session_id,
    socksAddr: handle.socks_addr,
    nodeIndex: index,
    uploadBytes: 0,
    downloadBytes: 0,
    routeMode: true,
    routingMode: state.settings.routingMode,
  })
  if (state.settings.systemProxyEnabled) {
    await systemProxySet(parsed.host, parsed.port)
    state.setSystemProxyActive(true)
  }
}

export function applyDesktopConnection(): Promise<string | null> {
  // 用户发起了新的连接操作：清掉上一次会话意外消亡的提示
  sessionLostDetail.value = null
  // 同步置忙：开关/按钮在第一次点击的同一帧就禁用，堵住二次点击窗口
  pendingApplies += 1
  syncing.value = true
  const run = applyChain.then(() => runDesktopConnectionSync()).finally(() => {
    pendingApplies -= 1
    if (pendingApplies === 0) syncing.value = false
  })
  // 队列自身永不 reject（runDesktopConnectionSync 内部已兜底捕获），保险起见再消化一次
  applyChain = run.catch(() => null)
  return run
}

async function runDesktopConnectionSync(): Promise<string | null> {
  if (!isDesktopConnectionShell()) return null
  const state = useAppStore.getState()
  if (state.subscription.blockReason) return null
  // 目标节点从「用户偏好」解析而非沿用会话当前节点：沿用会话节点会让
  // 「已连接时切换节点」的重启分支永远不可达（点击节点毫无反应）。
  // 首选索引可能指向订阅里的信息条目（公告伪节点），先校正为第一个可连接节点；
  // 解析不出可连接节点时才回退到会话当前节点。
  const preferredIndex = resolveConnectableNodeIndex(state.nodes, state.preferredNodeIndex)
  const nodeIndex = preferredIndex >= 0 ? preferredIndex : (state.vpn?.nodeIndex ?? -1)
  const node = state.nodes[nodeIndex]
  if (state.settings.routingMode !== 'direct' && (!node?.connectSupported || node.isInfo)) return null

  try {
    const routeConfigYaml = state.settings.routeConfigYaml.trim() || state.routing.routeConfigYaml || ''
    const useRuleRouting =
      !state.settings.tunEnabled
      && state.settings.systemProxyEnabled
      && state.settings.routingMode === 'rule'
      && Boolean(routeConfigYaml.trim())
    const wantTun = state.settings.tunEnabled
    const wantSocks = !wantTun && state.settings.systemProxyEnabled && !useRuleRouting
    const session = state.vpn
    const tunSession = session && !session.socksAddr && !session.routeMode
    const routeSession = session?.routeMode === true
    const socksSession = session && Boolean(session.socksAddr) && !session.routeMode
    const modeChanged = session?.routingMode !== state.settings.routingMode

    if (useRuleRouting) {
      if (tunSession || socksSession) await disconnectSession()
      if (!routeSession || session?.nodeIndex !== nodeIndex || modeChanged) {
        if (session) await disconnectSession()
        await startRoute(nodeIndex)
      } else if (!state.systemProxyActive && session.socksAddr) {
        const parsed = parseSocksAddr(session.socksAddr)
        await systemProxySet(parsed.host, parsed.port)
        state.setSystemProxyActive(true)
      }
      return null
    }

    if (routeSession) await disconnectSession()

    if (wantTun) {
      if (socksSession || routeSession) await disconnectSession()
      if (!tunSession || session?.nodeIndex !== nodeIndex || modeChanged) {
        if (session) await disconnectSession()
        await startTun(nodeIndex)
      } else {
        await applySessionSystemProxy()
      }
      return null
    }

    if (tunSession || routeSession) await disconnectSession()
    if (wantSocks) {
      if (!socksSession || session?.nodeIndex !== nodeIndex || modeChanged) {
        if (session) await disconnectSession()
        await startSocks(nodeIndex)
      } else if (!state.systemProxyActive && session.socksAddr) {
        const parsed = parseSocksAddr(session.socksAddr)
        await systemProxySet(parsed.host, parsed.port)
        state.setSystemProxyActive(true)
      }
    } else if (session) {
      await disconnectSession()
    } else if (state.systemProxyActive) {
      await systemProxyClear()
      state.setSystemProxyActive(false)
    }
    return null
  } catch (err) {
    return publicErrorText(err)
  }
}

export async function setRoutingMode(mode: 'rule' | 'global' | 'direct'): Promise<string | null> {
  const state = useAppStore.getState()
  state.setSettings({ routingMode: mode })
  return applyDesktopConnection()
}

export async function setTunEnabled(enabled: boolean): Promise<string | null> {
  const state = useAppStore.getState()
  state.setSettings({ tunEnabled: enabled })
  return applyDesktopConnection()
}

export async function setSystemProxyEnabled(enabled: boolean): Promise<string | null> {
  const state = useAppStore.getState()
  state.setSettings({ systemProxyEnabled: enabled })
  return applyDesktopConnection()
}

export function desktopConnectionBusy(): boolean {
  return syncing.value
}

/** 会话意外消亡的原因；null 表示没有待展示的事故（''=消亡但后端未附原因）。 */
export function desktopSessionLostDetail(): string | null {
  return sessionLostDetail.value
}
