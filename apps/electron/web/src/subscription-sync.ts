import { failureText } from './api/helpers'
import { subscriptionFetch, xboardRequest, type XboardBody } from './api/xboard'
import { formatTrafficBytes, formatUnixDate, numericValue } from './format'
import { translate, type TranslationKey } from './i18n'
import { resolveConnectableNodeIndex, toAppNode, type RawNode } from './nodes'
import { useAppStore, type AppNode, type NoticeItem, type SubscriptionState } from './store'
import { saveSubscriptionCache } from './store/persist'

interface NoticeFetchBody {
  data?: Array<{ id?: unknown; title?: unknown; content?: unknown; created_at?: unknown }>
}

function t(key: TranslationKey, language: string): string {
  return translate(key, language)
}

function parseNotices(body: NoticeFetchBody | undefined): NoticeItem[] {
  if (!Array.isArray(body?.data)) throw new Error('公告响应 data 必须是数组。')
  return body.data
    .map((row) => {
      if (typeof row.title !== 'string' || typeof row.content !== 'string') throw new Error('公告缺少 title 或 content。')
      const id = Number(row.id)
      const createdAt = Number(row.created_at)
      if (!Number.isFinite(id) || !Number.isFinite(createdAt)) throw new Error('公告 id 或 created_at 无效。')
      return {
        id,
        title: row.title,
        content: row.content,
        createdAt,
      }
    })
}

function subscriptionState(data: Record<string, unknown>, language: string): SubscriptionState {
  for (const key of ['u', 'd', 'transfer_enable', 'expired_at', 'plan_id']) {
    if (!(key in data)) throw new Error(`订阅同步响应缺少 ${key}。`)
  }
  // 面板对无套餐/一次性/长期订阅返回 null（plan_id、expired_at 等），按 0 处理
  const field = (key: string): number => (data[key] === null ? 0 : numericValue(data[key]))
  const used = field('u') + field('d')
  const total = field('transfer_enable')
  const plan = data.plan && typeof data.plan === 'object' ? (data.plan as Record<string, unknown>) : null
  if (plan && typeof plan.name !== 'string') throw new Error('订阅套餐缺少 name。')
  const planName = plan ? (plan.name as string) : ''
  const expiredAt = field('expired_at')
  const planId = field('plan_id')
  return {
    summary: [
      planName,
      total > 0 ? `${t('used_traffic', language)} ${formatTrafficBytes(used)} / ${formatTrafficBytes(total)}` : '',
      expiredAt > 0 ? `${t('expires_prefix', language)} ${formatUnixDate(expiredAt)}` : '',
    ].filter(Boolean).join(' · '),
    blockReason: (planId <= 0 && !plan
      ? 'no_plan'
      : expiredAt > 0 && expiredAt <= Date.now() / 1000
        ? 'expired'
        : total <= 0 || used >= total
          ? 'traffic_exceeded'
          : '') as SubscriptionState['blockReason'],
    trafficUsedBytes: used,
    trafficTotalBytes: total,
    planName,
    expiredAt,
  }
}

export async function syncSubscription(): Promise<string | null> {
  const state = useAppStore.getState()
  const language = state.settings.appLanguage
  const sub = await xboardRequest<XboardBody>('user_subscribe', { baseUrl: state.baseUrl, authData: state.authData })
  if (!sub.ok) return failureText(sub)

  if (!sub.body?.data || typeof sub.body.data !== 'object') throw new Error('订阅同步响应缺少 data。')
  const data = sub.body.data as Record<string, unknown>
  const url = typeof data.subscribe_url === 'string' ? data.subscribe_url : ''
  const nextSubscription = subscriptionState(data, language)
  let list: AppNode[] = []
  let metaSubscription: Awaited<ReturnType<typeof subscriptionFetch>> | null = null
  // 被封禁/过期/无套餐用户的订阅地址会返回空内容，先判定 blockReason 再抓订阅
  if (url && !nextSubscription.blockReason) {
    metaSubscription = await subscriptionFetch(url, 'meta')
    if (!metaSubscription.ok) {
      if (!metaSubscription.error) throw new Error('订阅规则同步失败但缺少 error 字段。')
      return metaSubscription.error
    }
    const routing = metaSubscription.routing
    if (!routing) throw new Error('订阅规则响应缺少 routing。')
    state.setRouting({
      hasRules: Boolean(routing.has_rules),
      ruleCount: Number(routing.rule_count),
      proxyGroupCount: Number(routing.proxy_group_count),
      ruleProviderCount: Number(routing.rule_provider_count),
      rulesPreview: routing.rules_preview,
      routeConfigYaml: typeof routing.route_config_yaml === 'string' ? routing.route_config_yaml : null,
    })
    // 节点来自订阅 YAML 的 proxies（面板没有 XBoard 的 admob 节点接口）
    if (!Array.isArray(metaSubscription.nodes)) throw new Error('订阅响应缺少 nodes 数组。')
    list = (metaSubscription.nodes as RawNode[]).map(toAppNode)
  }

  state.setSubscribe({ subscribeUrl: url, nodes: list })
  // 持久化/旧的选中索引可能指向订阅里的信息条目，同步后校正为第一个可连接节点
  const correctedIndex = resolveConnectableNodeIndex(list, state.preferredNodeIndex)
  if (correctedIndex >= 0 && correctedIndex !== state.preferredNodeIndex) {
    state.setPreferredNodeIndex(correctedIndex)
  }
  state.setSubscriptionState(nextSubscription)
  await saveSubscriptionCache({
    authData: state.authData,
    subscribeUrl: url,
    nodes: list,
    subscription: nextSubscription,
    routing: useAppStore.getState().routing,
  })

  // 面板公告默认分页 5 条，显式取到上限
  const noticeResponse = await xboardRequest<NoticeFetchBody>('notices', { baseUrl: state.baseUrl, authData: state.authData, params: { pageSize: 100 } })
  if (!noticeResponse.ok) return failureText(noticeResponse)
  state.setNotices(parseNotices(noticeResponse.body))
  return null
}
