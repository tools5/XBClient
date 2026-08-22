// Windows 构建后校验：wintun.dll 必须已被 tun2proxy 的 build.rs 复制到
// backend/target/release，随后由 electron-builder extraResources 打进 resources/bin。
// 缺失时立刻让构建失败——否则打包出的客户端 TUN 模式会在创建虚拟网卡时
// 静默失败（LoadLibrary 找不到 wintun.dll，会话秒死且无用户可见报错）。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

if (process.platform === 'win32') {
  const dir = path.dirname(fileURLToPath(import.meta.url))
  const dll = path.resolve(dir, '../backend/target/release/wintun.dll')
  if (!fs.existsSync(dll)) {
    console.error(
      `wintun.dll 缺失：${dll}\n` +
        'tun2proxy 的 build.rs 未能把 wintun.dll 复制到 cargo target 目录，' +
        '排查 backend/target/release/build.log（build.rs 会把复制结果写在里面）。',
    )
    process.exit(1)
  }
  console.log(`wintun.dll ok: ${dll}`)
}
