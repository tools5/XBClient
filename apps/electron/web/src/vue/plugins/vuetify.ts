import 'vuetify/styles'
import { createVuetify } from 'vuetify'
import * as components from 'vuetify/components'
import * as directives from 'vuetify/directives'

// 方案 D · 极简高对比：黑白灰 + 唯一状态绿。
// primary 语义 = 「主操作/强调」：暗色反白（#ededed 底 / #0a0a0a 字）、亮色反黑（#171717 底 / #ffffff 字）。
export const vuetify = createVuetify({
  components,
  directives,
  theme: {
    defaultTheme: 'light',
    themes: {
      light: {
        dark: false,
        colors: {
          primary: '#171717',
          'on-primary': '#ffffff',
          'primary-container': '#f5f5f5',
          'on-primary-container': '#0a0a0a',
          secondary: '#525252',
          'on-secondary': '#ffffff',
          'secondary-container': '#f5f5f5',
          'on-secondary-container': '#0a0a0a',
          tertiary: '#525252',
          success: '#16a34a',
          warning: '#b45309',
          background: '#fafafa',
          'on-background': '#0a0a0a',
          surface: '#ffffff',
          'on-surface': '#0a0a0a',
          'surface-container-low': '#fafafa',
          'surface-container': '#ffffff',
          'surface-container-high': '#f5f5f5',
          'surface-variant': '#f5f5f5',
          'on-surface-variant': '#525252',
          outline: '#d4d4d4',
          'outline-variant': '#e5e5e5',
          error: '#dc2626',
        },
      },
      dark: {
        dark: true,
        colors: {
          primary: '#ededed',
          'on-primary': '#0a0a0a',
          'primary-container': '#171717',
          'on-primary-container': '#fafafa',
          secondary: '#8f8f8f',
          'on-secondary': '#0a0a0a',
          'secondary-container': '#171717',
          'on-secondary-container': '#ededed',
          tertiary: '#8f8f8f',
          success: '#4ade80',
          warning: '#fbbf24',
          background: '#0a0a0a',
          'on-background': '#ededed',
          surface: '#0d0d0d',
          'on-surface': '#ededed',
          'surface-container-low': '#0a0a0a',
          'surface-container': '#0d0d0d',
          'surface-container-high': '#171717',
          'surface-variant': '#171717',
          'on-surface-variant': '#8f8f8f',
          outline: '#2e2e2e',
          'outline-variant': '#262626',
          error: '#f87171',
        },
      },
    },
  },
  defaults: {
    VBtn: {
      rounded: 'lg',
      elevation: 0,
    },
    VCard: {
      rounded: 'lg',
      elevation: 0,
    },
    VAlert: {
      rounded: 'lg',
    },
    VChip: {
      label: true,
    },
    VTextField: {
      variant: 'outlined',
      density: 'comfortable',
      hideDetails: 'auto',
      rounded: 'lg',
    },
    VSelect: {
      variant: 'outlined',
      density: 'comfortable',
      hideDetails: 'auto',
      rounded: 'lg',
    },
    VTextarea: {
      variant: 'outlined',
      rounded: 'lg',
    },
  },
})
