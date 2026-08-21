import { enabled } from '../reward'
import { useAppStore } from '../store'
import { parseOAuthProviders } from './helpers'
import { xboardRequest } from './xboard'

interface GuestConfigData {
  oauth_providers?: unknown
  is_invite_force?: number | boolean | string
  is_email_verify?: number | boolean | string
  is_captcha?: number | boolean | string
  captcha_type?: unknown
  is_recaptcha?: number | boolean | string
  is_cap?: number | boolean | string
  register_email_mode?: unknown
}

interface GuestConfigBody {
  data?: GuestConfigData
  message?: string
}

export async function syncGuestAuthConfig(baseUrl: string): Promise<void> {
  const response = await xboardRequest<GuestConfigBody>('guest_config', { baseUrl })
  if (!response.ok) {
    if (response.body?.message) throw new Error(response.body.message)
    if (response.error) throw new Error(response.error)
    throw new Error('guest config failed response missing message or error')
  }
  if (!response.body?.data) throw new Error('guest config response missing data')

  const data = response.body.data
  useAppStore.getState().setAuthConfig({
    oauthProviders: parseOAuthProviders(data.oauth_providers),
    inviteForce: enabled(data.is_invite_force),
    registerEmailVerifyEnabled: enabled(data.is_email_verify),
    // xiao/v2board 独有：link 模式下注册/找回密码只能通过邮件链接（网页端）完成
    registerEmailMode: data.register_email_mode === 'link' ? 'link' : 'code',
    ...parseCaptchaConfig(data),
  })
}

// xiao/v2board exposes two independent captcha switches (is_recaptcha for Google
// reCAPTCHA, is_cap for the self-hosted Cap widget), while the older
// XBoard-compatible API uses is_captcha + captcha_type.
function parseCaptchaConfig(data: GuestConfigData): { registerCaptchaEnabled: boolean; registerCaptchaType: string } {
  if (data.is_captcha !== undefined) {
    if (typeof data.captcha_type !== 'string') throw new Error('guest config captcha_type is required')
    return { registerCaptchaEnabled: enabled(data.is_captcha), registerCaptchaType: data.captcha_type }
  }
  if (data.is_recaptcha === undefined && data.is_cap === undefined) {
    throw new Error('guest config missing is_captcha, is_recaptcha and is_cap')
  }
  const recaptcha = data.is_recaptcha !== undefined && enabled(data.is_recaptcha)
  const cap = data.is_cap !== undefined && enabled(data.is_cap)
  return {
    registerCaptchaEnabled: recaptcha || cap,
    registerCaptchaType: recaptcha ? 'recaptcha' : cap ? 'cap' : '',
  }
}
