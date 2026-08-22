import path from 'node:path'
import fs from 'node:fs'
import { app, dialog } from 'electron'
import electronUpdater from 'electron-updater'

const { autoUpdater } = electronUpdater

// electron-builder 打包时按 publish 配置写入 app-update.yml（github provider）。
// 解析它作为面板镜像不可用时的后备更新源，避免在代码里硬编码仓库。
function packagedGithubFeed() {
  const file = path.join(process.resourcesPath, 'app-update.yml')
  if (!fs.existsSync(file)) return null
  const text = fs.readFileSync(file, 'utf8')
  const pick = (key) => {
    const match = text.match(new RegExp(`^${key}:\\s*(.+)$`, 'm'))
    return match ? match[1].trim().replace(/^['"]|['"]$/g, '') : ''
  }
  if (pick('provider') !== 'github') return null
  const owner = pick('owner')
  const repo = pick('repo')
  if (!owner || !repo) return null
  return { provider: 'github', owner, repo, vPrefixedTagName: pick('vPrefixedTagName') !== 'false' }
}

export function setupAutoUpdater(defaultApiUrl) {
  if (!app.isPackaged || process.platform !== 'win32') return

  autoUpdater.autoDownload = true
  autoUpdater.autoInstallOnAppQuit = true

  let restartDialogShown = false

  autoUpdater.on('error', (err) => {
    console.error('[updater]', err)
  })

  autoUpdater.on('update-downloaded', () => {
    if (restartDialogShown) return
    restartDialogShown = true
    dialog
      .showMessageBox({
        type: 'info',
        title: '发现新版本',
        message: '新版本已下载，重启后即可完成安装。',
        buttons: ['立即重启', '稍后'],
        defaultId: 0,
        cancelId: 1,
      })
      .then(({ response }) => {
        if (response === 0) autoUpdater.quitAndInstall()
      })
  })

  // 国内用户直连不了 GitHub：优先走面板镜像（面板每小时把 Release 同步到
  // public/clients/，nginx 静态服务），镜像不可用再退回 GitHub Releases。
  const base = String(defaultApiUrl ?? '').trim().replace(/\/+$/, '')
  const feeds = []
  if (base) feeds.push({ provider: 'generic', url: `${base}/clients` })
  const github = packagedGithubFeed()
  if (github) feeds.push(github)

  // 注意不能用 checkForUpdatesAndNotify：autoDownload 下它拿到 latest.yml 就
  // resolve，安装包下载挂在 result.downloadPromise 上异步进行，失败只走 error
  // 事件。镜像 cron 同步不是原子的，最常见的故障恰恰是 latest.yml 已更新而改名
  // 后的安装包缺失/截断——必须 await 下载结果，失败才能切到下一个源。
  async function checkForUpdatesWithFallback() {
    for (const feed of feeds) {
      try {
        autoUpdater.setFeedURL(feed)
        const result = await autoUpdater.checkForUpdates()
        // null 表示 updater 未启用；已是最新版本时也无需再试其它源
        if (!result || !result.isUpdateAvailable) return
        // autoDownload 为 true 时 downloadPromise 必然存在；下载失败会 reject
        // （electron-updater 会在 finally 里清掉内部下载状态，可安全重试），
        // 下载成功则由 update-downloaded 事件弹出重启对话框
        if (result.downloadPromise) await result.downloadPromise
        return
      } catch (err) {
        console.error(
          `[updater] ${feed.provider} 更新源检查/下载失败，尝试下一个源`,
          err instanceof Error ? err.message : String(err),
        )
      }
    }
  }

  setTimeout(() => {
    void checkForUpdatesWithFallback()
  }, 5000)
}
