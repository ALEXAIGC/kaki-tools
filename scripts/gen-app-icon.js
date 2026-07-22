// 生成 build/icon.icns(macOS 应用图标)。用法:node scripts/gen-app-icon.js
const fs = require('fs')
const path = require('path')
const { execSync } = require('child_process')
const { makeAppIconPng } = require('../main/genIcon')

const buildDir = path.join(__dirname, '..', 'build')
const iconset = path.join(buildDir, 'icon.iconset')
fs.mkdirSync(iconset, { recursive: true })

const specs = [
  ['icon_16x16.png', 16], ['icon_16x16@2x.png', 32],
  ['icon_32x32.png', 32], ['icon_32x32@2x.png', 64],
  ['icon_128x128.png', 128], ['icon_128x128@2x.png', 256],
  ['icon_256x256.png', 256], ['icon_256x256@2x.png', 512],
  ['icon_512x512.png', 512], ['icon_512x512@2x.png', 1024],
]
for (const [name, size] of specs) {
  fs.writeFileSync(path.join(iconset, name), makeAppIconPng(size))
}

if (process.platform === 'darwin') {
  execSync(`iconutil -c icns "${iconset}" -o "${path.join(buildDir, 'icon.icns')}"`)
  console.log('已生成', path.join(buildDir, 'icon.icns'))
} else {
  console.log('已生成 iconset(icns 需在 macOS 上用 iconutil 转换)')
}
