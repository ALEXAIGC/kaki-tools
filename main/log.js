// 简单的文件日志:userData/kaki.log,方便排查打包版(无终端输出)的问题
const fs = require('fs')
const path = require('path')

let file = null

function init(dir) {
  file = path.join(dir, 'kaki.log')
  try {
    // 超过 1MB 就从头来
    if (fs.existsSync(file) && fs.statSync(file).size > 1024 * 1024) fs.unlinkSync(file)
  } catch {}
  log('===== 应用启动 =====')
}

function log(...args) {
  const line = `[${new Date().toLocaleString('zh-CN', { hour12: false })}] ${args.map(a =>
    typeof a === 'string' ? a : JSON.stringify(a)).join(' ')}\n`
  process.stderr.write('[kaki] ' + line)
  if (file) {
    try { fs.appendFileSync(file, line) } catch {}
  }
}

module.exports = { init, log }
