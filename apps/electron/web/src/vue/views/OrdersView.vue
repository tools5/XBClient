<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { dataRows, failureText, field, type Row } from '../../api/helpers'
import { openInAppBrowser } from '../../api/system'
import { xboardRequest, type XboardBody } from '../../api/xboard'
import { formatMoney, formatUnixDateTime, numericValue, publicErrorText } from '../../format'
import { appState, t } from '../state'
import type { TranslationKey } from '../../i18n'

// v2board 订单 status：0 待支付 / 1 开通中 / 2 已取消 / 3 已完成 / 4 已折抵
const ORDER_STATUS_PENDING = 0

interface OrderItem {
  tradeNo: string
  status: number
  period: string
  planName: string
  /** 金额单位均为分 */
  totalAmount: number
  balanceAmount: number
  handlingAmount: number
  createdAt: number
  /**
   * xiao/v2board：首次 checkout 后订单被锁定到该支付方式（换方式或取消都会被面板 500 拒绝）；
   * Xboard 响应无此字段，恒为 null
   */
  paymentId: number | null
}

interface PaymentMethodOption {
  id: number
  name: string
}

const orders = ref<OrderItem[]>([])
const loading = ref(false)
const payingTradeNo = ref('')
const cancelTarget = ref<OrderItem | null>(null)
/** 非空时展示支付方式选择弹窗（仅在订单未绑定支付方式且有多个可选方式时） */
const methodPicker = ref<{ order: OrderItem; methods: PaymentMethodOption[] } | null>(null)
const error = ref('')
const message = ref('')

const cancelDialog = computed({
  get: () => cancelTarget.value !== null,
  set: (value: boolean) => {
    if (!value) cancelTarget.value = null
  },
})

const methodDialog = computed({
  get: () => methodPicker.value !== null,
  set: (value: boolean) => {
    if (!value) methodPicker.value = null
  },
})

function numericOrZero(value: unknown): number {
  return value === undefined || value === null ? 0 : numericValue(value)
}

// 订单字段容错：trade_no/status 是核心语义必填；金额、时间与 plan 映射
// 双面板可能缺失或为 null，一律判空回退（金额按 0 分、套餐名按空串处理）
function parseOrder(row: Row): OrderItem {
  const plan = row.plan && typeof row.plan === 'object' ? (row.plan as Row) : null
  return {
    tradeNo: field(row, 'trade_no'),
    status: Math.round(numericValue(row.status)),
    period: typeof row.period === 'string' ? row.period : '',
    planName: plan && typeof plan.name === 'string' ? plan.name : '',
    totalAmount: Math.round(numericOrZero(row.total_amount)),
    balanceAmount: Math.round(numericOrZero(row.balance_amount)),
    handlingAmount: Math.round(numericOrZero(row.handling_amount)),
    createdAt: Math.round(numericOrZero(row.created_at)),
    paymentId: row.payment_id === undefined || row.payment_id === null ? null : Math.round(numericValue(row.payment_id)),
  }
}

const PERIOD_KEYS: Record<string, TranslationKey> = {
  month_price: 'price_month',
  quarter_price: 'price_quarter',
  half_year_price: 'price_half_year',
  year_price: 'price_year',
  two_year_price: 'price_two_year',
  three_year_price: 'price_three_year',
  onetime_price: 'price_onetime',
  reset_price: 'price_reset',
}

function orderPeriodText(period: string): string {
  if (period === 'deposit') return t('order_period_deposit')
  const key = PERIOD_KEYS[period]
  return key ? t(key) : period || '-'
}

// plan 名可为空（充值订单 / 套餐已删除）：充值按 period 回退，其余显示 “-”
function orderTitle(order: OrderItem): string {
  if (order.planName) return order.planName
  return order.period === 'deposit' ? t('order_period_deposit') : '-'
}

function orderStatusText(status: number): string {
  switch (status) {
    case 0: return t('order_status_pending')
    case 1: return t('order_status_processing')
    case 2: return t('order_status_cancelled')
    case 3: return t('order_status_completed')
    case 4: return t('order_status_discounted')
    default: return `#${status}`
  }
}

// 待支付=描边黄 / 已完成=绿 tag / 其余描边灰（取消行整体弱化）
function statusChipColor(status: number): string | undefined {
  if (status === 0) return 'warning'
  if (status === 3) return 'success'
  return undefined
}

function orderMeta(order: OrderItem): string {
  return [orderPeriodText(order.period), order.tradeNo, formatUnixDateTime(order.createdAt)]
    .filter((item) => item)
    .join(' · ')
}

async function loadOrders() {
  loading.value = true
  error.value = ''
  try {
    const response = await xboardRequest<XboardBody>('order_fetch', {
      baseUrl: appState.baseUrl,
      authData: appState.authData,
      params: { current: 1, pageSize: 100 },
    })
    const text = failureText(response)
    if (text) {
      error.value = text
      return
    }
    orders.value = dataRows(response.body?.data).map(parseOrder)
  } catch (err) {
    error.value = publicErrorText(err)
  } finally {
    loading.value = false
  }
}

// checkout 语义与 PlansView buy() 一致：-1/2 视为已支付、1 打开支付页、0 提示扫码；
// methodId 为 null 时不带 method 发起（面板对 total_amount<=0 的订单会先行标记已支付）
async function checkoutOrder(order: OrderItem, methodId: number | null) {
  const checkout = await xboardRequest<{ type?: number; data?: unknown; message?: string }>('order_checkout', {
    baseUrl: appState.baseUrl,
    authData: appState.authData,
    params: methodId !== null ? { trade_no: order.tradeNo, method: methodId } : { trade_no: order.tradeNo },
  })
  // -1=余额足额抵扣，2=网关即时扣款成功（如 Stripe），都视为已支付
  if (checkout.ok && (checkout.body?.type === -1 || checkout.body?.type === 2)) {
    message.value = t('order_pay_success')
    await loadOrders()
    return
  }
  if (checkout.ok && checkout.body?.type === 1 && typeof checkout.body.data === 'string') {
    await openInAppBrowser(checkout.body.data, order.tradeNo)
    // xiao 面板在 checkout 后把订单锁定到该支付方式，刷新以同步取消按钮状态
    await loadOrders()
    return
  }
  if (checkout.ok && checkout.body?.type === 0) {
    message.value = t('order_pay_scan_hint')
    await loadOrders()
    return
  }
  error.value = !checkout.ok ? failureText(checkout) : t('order_pay_unsupported')
}

// 继续支付：xiao 面板会把订单锁定在首次 checkout 使用的支付方式上（payment_id），
// 换方式会被面板 500 拒绝，因此绑定方式直接续付；未绑定且有多个方式时让用户选择
async function continuePay(order: OrderItem) {
  if (payingTradeNo.value) return
  error.value = ''
  message.value = ''
  payingTradeNo.value = order.tradeNo
  try {
    // 面板 checkout 对 total_amount<=0 的订单在校验支付方式前就标记已支付，无需 method
    if (order.totalAmount <= 0) {
      await checkoutOrder(order, null)
      return
    }
    const methods = await xboardRequest<XboardBody>('payment_methods', { baseUrl: appState.baseUrl, authData: appState.authData })
    const methodsError = failureText(methods)
    if (methodsError) {
      error.value = methodsError
      return
    }
    // StripeCredit 需要客户端先取 stripe_token，桌面端没有实现，过滤掉（与 PlansView 一致）
    const options: PaymentMethodOption[] = (Array.isArray(methods.body?.data) ? (methods.body.data as Row[]) : [])
      .filter((row) => String(row.payment ?? '') !== 'StripeCredit')
      .map((row) => ({
        id: Math.round(numericValue(row.id)),
        name: typeof row.name === 'string' && row.name ? row.name : String(row.payment ?? ''),
      }))
      .filter((option) => option.id > 0)
    if (order.paymentId !== null) {
      const bound = options.find((option) => option.id === order.paymentId)
      if (!bound) {
        // 绑定方式已停用（或为桌面端不支持的 StripeCredit）：换方式会被面板拒绝，引导去网站支付
        error.value = t('order_pay_method_unavailable')
        return
      }
      await checkoutOrder(order, bound.id)
      return
    }
    if (!options.length) {
      // 无可用支付方式：保持原行为不带 method 发起（余额全额抵扣的订单可直接完成）
      await checkoutOrder(order, null)
      return
    }
    if (options.length === 1) {
      await checkoutOrder(order, options[0].id)
      return
    }
    // 多个支付方式：弹窗让用户选择（xiao 面板会把订单锁定到所选方式）
    methodPicker.value = { order, methods: options }
  } catch (err) {
    error.value = publicErrorText(err)
  } finally {
    payingTradeNo.value = ''
  }
}

async function payWithMethod(option: PaymentMethodOption) {
  const picker = methodPicker.value
  methodPicker.value = null
  if (!picker || payingTradeNo.value) return
  error.value = ''
  message.value = ''
  payingTradeNo.value = picker.order.tradeNo
  try {
    await checkoutOrder(picker.order, option.id)
  } catch (err) {
    error.value = publicErrorText(err)
  } finally {
    payingTradeNo.value = ''
  }
}

async function confirmCancel() {
  const order = cancelTarget.value
  cancelTarget.value = null
  if (!order) return
  error.value = ''
  message.value = ''
  try {
    const response = await xboardRequest<XboardBody>('order_cancel', {
      baseUrl: appState.baseUrl,
      authData: appState.authData,
      params: { trade_no: order.tradeNo },
    })
    const text = failureText(response)
    if (text) {
      error.value = text
      return
    }
    message.value = t('order_cancelled_success')
    await loadOrders()
  } catch (err) {
    error.value = publicErrorText(err)
  }
}

onMounted(loadOrders)
</script>

<template>
  <section class="liquid-page">
    <div class="page-header">
      <div class="page-header-bar subtitle" />
      <div class="page-header-content">
        <h1>{{ t('nav_orders') }}</h1>
        <p>{{ appState.email || t('service_orders_desc') }}</p>
      </div>
      <v-btn variant="outlined" :loading="loading" @click="loadOrders">
        {{ loading ? t('refreshing') : t('refresh') }}
      </v-btn>
    </div>

    <v-alert v-if="error" color="error" variant="tonal" class="mb-4">{{ error }}</v-alert>
    <v-alert v-if="message" color="primary" variant="tonal" class="mb-4">{{ message }}</v-alert>

    <div class="stack">
      <v-card
        v-for="order in orders"
        :key="order.tradeNo"
        class="panel-card"
        :class="{ 'order-cancelled': order.status === 2 }"
      >
        <v-card-text>
          <div class="d-flex align-center justify-space-between ga-2">
            <div>
              <p class="text-h6 font-weight-bold mb-0">{{ orderTitle(order) }}</p>
              <p class="muted mt-1 mb-0">{{ orderMeta(order) }}</p>
            </div>
            <v-chip
              :color="statusChipColor(order.status)"
              :variant="order.status === 3 ? 'tonal' : 'outlined'"
            >
              {{ orderStatusText(order.status) }}
            </v-chip>
          </div>
          <div class="d-flex align-center justify-space-between ga-2 mt-3">
            <div>
              <p class="mb-0 order-amount">
                {{ formatMoney(order.totalAmount + order.handlingAmount, appState.currencySymbol, appState.currencyUnit) }}
              </p>
              <p v-if="order.balanceAmount > 0" class="muted text-caption mb-0 order-amount">
                {{ t('order_balance_deduct') }} {{ formatMoney(order.balanceAmount, appState.currencySymbol, appState.currencyUnit) }}
              </p>
            </div>
            <div v-if="order.status === ORDER_STATUS_PENDING" class="d-flex flex-column align-end ga-1">
              <div class="d-flex ga-2">
                <v-btn
                  color="primary"
                  variant="tonal"
                  :loading="payingTradeNo === order.tradeNo"
                  :disabled="Boolean(payingTradeNo) && payingTradeNo !== order.tradeNo"
                  @click="continuePay(order)"
                >
                  {{ t('order_continue_pay') }}
                </v-btn>
                <!-- xiao 面板对已绑定支付方式（payment_id 非空）的订单会拒绝取消，直接隐藏按钮 -->
                <v-btn
                  v-if="order.paymentId === null"
                  variant="outlined"
                  :disabled="Boolean(payingTradeNo)"
                  @click="cancelTarget = order"
                >
                  {{ t('order_cancel') }}
                </v-btn>
              </div>
              <p v-if="order.paymentId !== null" class="muted text-caption mb-0 text-right">
                {{ t('order_cancel_locked_hint') }}
              </p>
            </div>
          </div>
        </v-card-text>
      </v-card>
      <v-card v-if="!loading && !orders.length" class="panel-card">
        <v-card-text>
          <p class="muted">{{ t('orders_empty') }}</p>
        </v-card-text>
      </v-card>
    </div>

    <v-dialog v-model="methodDialog" max-width="420">
      <v-card class="panel-card">
        <v-card-text>
          <p class="text-h6 font-weight-bold mb-2">{{ t('order_pay_method_title') }}</p>
          <p class="muted">{{ t('order_pay_method_hint') }}</p>
          <div class="stack mt-4">
            <v-btn
              v-for="option in methodPicker?.methods ?? []"
              :key="option.id"
              variant="tonal"
              block
              @click="payWithMethod(option)"
            >
              {{ option.name }}
            </v-btn>
          </div>
          <div class="d-flex justify-end mt-4">
            <v-btn variant="outlined" @click="methodPicker = null">{{ t('order_pay_method_cancel') }}</v-btn>
          </div>
        </v-card-text>
      </v-card>
    </v-dialog>

    <v-dialog v-model="cancelDialog" max-width="420">
      <v-card class="panel-card">
        <v-card-text>
          <p class="text-h6 font-weight-bold mb-2">{{ t('order_cancel') }}</p>
          <p class="muted">{{ t('order_cancel_confirm') }}</p>
          <p v-if="cancelTarget" class="order-amount">{{ cancelTarget.tradeNo }}</p>
          <div class="d-flex justify-end ga-2 mt-4">
            <v-btn variant="outlined" @click="cancelTarget = null">{{ t('order_cancel_keep') }}</v-btn>
            <v-btn color="primary" variant="tonal" @click="confirmCancel">{{ t('order_cancel') }}</v-btn>
          </div>
        </v-card-text>
      </v-card>
    </v-dialog>
  </section>
</template>

<style scoped>
.order-amount {
  font-family: ui-monospace, 'Cascadia Mono', 'JetBrains Mono', Consolas, monospace;
}

.order-cancelled {
  opacity: 0.55;
}
</style>
