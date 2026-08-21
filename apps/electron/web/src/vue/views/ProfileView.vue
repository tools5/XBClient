<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { failureText, parseUserCurrencyConfig } from '../../api/helpers'
import { xboardRequest, type XboardBody } from '../../api/xboard'
import { formatMoney, numericValue, publicErrorText } from '../../format'
import { clearSession } from '../../store/persist'
import { appState, store, t } from '../state'

const router = useRouter()
const error = ref('')

async function loadProfile() {
  error.value = ''
  try {
    const [info, config] = await Promise.all([
      xboardRequest<XboardBody>('user_info', { baseUrl: appState.baseUrl, authData: appState.authData }),
      xboardRequest<XboardBody>('user_config', { baseUrl: appState.baseUrl, authData: appState.authData }),
    ])
    if (!info.ok) {
      error.value = failureText(info)
      return
    }
    if (!info.body?.data || typeof info.body.data !== 'object') throw new Error('user_info response missing data')
    const data = info.body.data as Record<string, unknown>
    store().setProfile({
      balance: numericValue(data.balance),
      commissionBalance: numericValue(data.commission_balance),
    })
    if (!config.ok) throw new Error(failureText(config))
    const currency = parseUserCurrencyConfig(config.body.data)
    store().setProfile({
      currencySymbol: currency.currencySymbol,
      currencyUnit: currency.currencyUnit,
      inviteCommissionRate: data.commission_rate === null ? 0 : numericValue(data.commission_rate),
      inviteCommissionBalance: numericValue(data.commission_balance),
    })
  } catch (err) {
    error.value = publicErrorText(err)
  }
}

async function logout() {
  store().reset()
  await clearSession()
  await router.replace('/login')
}

const giftCode = ref('')
const giftRedeeming = ref(false)
const giftMessage = ref('')

async function redeemGiftCard() {
  const code = giftCode.value.trim()
  if (!code || giftRedeeming.value) return
  giftRedeeming.value = true
  giftMessage.value = ''
  error.value = ''
  try {
    const response = await xboardRequest<{ data?: unknown; message?: string }>('gift_card_redeem', {
      baseUrl: appState.baseUrl,
      authData: appState.authData,
      params: { giftcard: code },
    })
    if (!response.ok || response.body?.data !== true) {
      error.value = failureText(response) || '礼品卡兑换失败'
      return
    }
    giftCode.value = ''
    giftMessage.value = t('gift_redeem_success')
    await loadProfile()
  } catch (err) {
    error.value = publicErrorText(err)
  } finally {
    giftRedeeming.value = false
  }
}

onMounted(loadProfile)
</script>

<template>
  <section class="liquid-page">
    <div class="page-header">
      <div class="page-header-bar" />
      <div class="page-header-content">
        <p class="muted">{{ appState.email }}</p>
        <h1>{{ t('nav_profile') }}</h1>
      </div>
      <div class="d-flex gap-2">
        <v-btn variant="outlined" size="small" @click="router.push('/settings')">
          {{ t('settings_button') }}
        </v-btn>
        <v-btn variant="outlined" color="error" size="small" @click="logout">
          {{ t('logout') }}
        </v-btn>
      </div>
    </div>

    <v-alert v-if="error" color="error" variant="tonal" class="mb-4">{{ error }}</v-alert>

    <div class="page-section">
      <p class="section-label">{{ t('section_account') }}</p>
      <v-card class="panel-card">
        <v-card-text>
          <p class="text-h6 font-weight-bold">
            {{ appState.email }}
          </p>
          <p class="muted mt-1">
            {{ t('balance') }}：{{ formatMoney(appState.balance, appState.currencySymbol, appState.currencyUnit) }}
          </p>
          <p class="muted">
            {{ t('commission_balance') }}：{{ formatMoney(appState.commissionBalance, appState.currencySymbol, appState.currencyUnit) }}
          </p>
          <p v-if="appState.subscription.summary" class="muted mt-2">
            {{ appState.subscription.summary }}
          </p>
          <v-btn variant="tonal" block class="mt-4" @click="router.push('/services')">
            {{ t('service_center') }}
          </v-btn>
          <v-btn
            v-if="appState.inviteForce || appState.inviteCommissionRate > 0"
            variant="tonal"
            block
            class="mt-2"
            @click="router.push('/promotion')"
          >
            {{ t('nav_promotion') }}
          </v-btn>
        </v-card-text>
      </v-card>
    </div>

    <div class="page-section">
      <p class="section-label">{{ t('gift_card_title') }}</p>
      <v-card class="panel-card">
        <v-card-text>
          <v-alert v-if="giftMessage" color="primary" variant="tonal" density="compact" class="mb-3">
            {{ giftMessage }}
          </v-alert>
          <v-text-field
            v-model="giftCode"
            :label="t('gift_code')"
            variant="outlined"
            density="comfortable"
          />
          <v-btn
            variant="tonal"
            block
            class="mt-2"
            :loading="giftRedeeming"
            :disabled="!giftCode.trim()"
            @click="redeemGiftCard"
          >
            {{ giftRedeeming ? t('gift_redeeming') : t('gift_redeem') }}
          </v-btn>
        </v-card-text>
      </v-card>
    </div>
  </section>
</template>
