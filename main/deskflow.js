'use strict'

// Deskflow core manager.
//
// This module drives Deskflow's `deskflow-core` binary (the proven
// mouse/keyboard sharing core) as a native helper child process. It owns three
// things the old hand-rolled desklink.js could never get right:
//
//   1. generating Deskflow's text server config and INI settings file,
//   2. generating/reusing the TLS identity and the trusted-fingerprint store,
//   3. spawning/stopping `deskflow-core server|client` and surfacing its state.
//
// Raw input capture, forwarding, injection, and the screen-switching state
// machine all live inside deskflow-core itself, so Kaki Tools never has to
// install an event tap (the source of the previous "input interception" bug).

const { EventEmitter } = require('events')
const crypto = require('crypto')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { execFileSync, spawn } = require('child_process')

const DEFAULT_PORT = 24800

// Mirror Deskflow's Settings::cleanComputerName so the `core/computerName`
// value always matches the name Deskflow derives from the host, and therefore
// always satisfies the server config's `isValidScreenName`.
function cleanComputerName(name) {
  let s = String(name || os.hostname()).replace(/\s+/g, ' ').trim()
  s = s.replace(/ /g, '_').replace(/[^\w\-.]/g, '')
  while (/^[-_.]/.test(s)) s = s.slice(1)
  while (/[-_.]$/.test(s)) s = s.slice(0, -1)
  return s.slice(0, 255)
}

function clampPort(port) {
  const n = Number(port)
  return Number.isFinite(n) ? Math.max(1024, Math.min(65535, Math.trunc(n))) : DEFAULT_PORT
}

// LAN addresses, "recommended" first. Same heuristic as the previous desklink.
function localAddresses() {
  const blocked = /^(awdl|llw|utun|bridge|docker|vmenet|vmnet)/i
  return Object.entries(os.networkInterfaces())
    .flatMap(([name, entries]) => (entries || []).map(entry => ({ name, entry })))
    .filter(({ entry }) => entry && entry.family === 'IPv4' && !entry.internal)
    .map(({ name, entry }) => ({ name, address: entry.address, preferred: /^en\d+$/i.test(name) }))
    .filter(item => !blocked.test(item.name))
    .sort((a, b) => Number(b.preferred) - Number(a.preferred) || a.name.localeCompare(b.name))
}

// SHA-256 of a DER certificate, returned both as raw hex and as the
// colon-separated uppercase form used for display.
function fingerprintFromDer(der) {
  const digest = crypto.createHash('sha256').update(der).digest('hex')
  return {
    hex: digest.toLowerCase(),
    display: digest.toUpperCase().match(/.{1,2}/g).join(':'),
  }
}

class DeskflowCore extends EventEmitter {
  constructor({ userData, deviceName, binaryPath }) {
    super()
    this.userData = userData
    this.deviceName = cleanComputerName(deviceName)
    this.binaryPath = binaryPath
    this.child = null
    this.role = 'idle'
    this.port = DEFAULT_PORT
    this.host = null
    this.peer = null
    this.lastError = null
    this._stdoutBuffer = ''
    this._stderrBuffer = ''
    this._acceptedClients = []
    this._restarting = false
  }

  _dir() { return path.join(this.userData, 'deskflow') }
  _tlsDir() { return path.join(this._dir(), 'tls') }
  _settingsFile() { return path.join(this._dir(), 'deskflow.conf') }
  _serverConfigFile() { return path.join(this._dir(), 'server.conf') }
  _certFile() { return path.join(this._tlsDir(), 'deskflow.pem') }

  // A single PEM file containing the certificate followed by the private key
  // (Deskflow reads both blocks from one path). Generated once and reused so
  // the fingerprint stays stable across restarts, just like the GUI does.
  identity() {
    fs.mkdirSync(this._tlsDir(), { recursive: true, mode: 0o700 })
    if (!fs.existsSync(this._certFile())) {
      const tmp = path.join(this._tlsDir(), `tmp-${process.pid}-${Date.now()}`)
      fs.mkdirSync(tmp, { recursive: true })
      const key = path.join(tmp, 'key.pem')
      const cert = path.join(tmp, 'cert.pem')
      const openssl = fs.existsSync('/usr/bin/openssl') ? '/usr/bin/openssl' : '/opt/homebrew/bin/openssl'
      try {
        execFileSync(openssl, [
          'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
          '-keyout', key, '-out', cert, '-days', '3650',
          '-subj', `/CN=Kaki-Tools-${crypto.randomUUID()}`,
        ], { stdio: 'ignore' })
        const combined = `${fs.readFileSync(cert)}${fs.readFileSync(key)}`
        fs.writeFileSync(this._certFile(), combined, { mode: 0o600 })
      } finally {
        fs.rmSync(tmp, { recursive: true, force: true })
      }
    }
    // The certificate block sits first in the combined file; X509Certificate
    // ignores the trailing private-key block.
    const der = new crypto.X509Certificate(fs.readFileSync(this._certFile())).raw
    return { certPath: this._certFile(), ...fingerprintFromDer(der) }
  }

  status() {
    return {
      role: this.role,
      port: this.port,
      host: this.host,
      deviceName: this.deviceName,
      fingerprint: this.identity().display,
      addresses: localAddresses(),
      peer: this.peer,
      running: !!this.child,
      error: this.lastError,
    }
  }

  _emitStatus() { this.emit('status', this.status()) }

  _writeSettings(text) {
    fs.mkdirSync(this._dir(), { recursive: true })
    fs.writeFileSync(this._settingsFile(), text, 'utf8')
  }

  _writeServerConfig(text) {
    fs.mkdirSync(this._dir(), { recursive: true })
    fs.writeFileSync(this._serverConfigFile(), text, 'utf8')
  }

  // Build the text server config for the host plus any accepted clients, all
  // placed to the right of this Mac. Regenerating the whole file (rather than
  // editing in place) keeps the parser happy and makes layout changes trivial.
  _serverConfigFor(clients) {
    const lines = [
      '# Kaki Tools generated Deskflow server config',
      'section: screens',
      `\t${this.deviceName}:`,
    ]
    for (const client of clients) lines.push(`\t${client}:`)
    lines.push('end', 'section: links', `\t${this.deviceName}:`)
    for (const client of clients) lines.push(`\t\tright = ${client}`)
    for (const client of clients) {
      lines.push(`\t${client}:`, `\t\tleft = ${this.deviceName}`)
    }
    lines.push('end', '')
    return lines.join('\n')
  }

  startHost({ port = DEFAULT_PORT } = {}) {
    this.stop()
    this.role = 'host'
    this.port = clampPort(port)
    this.host = null
    this.lastError = null
    this._acceptedClients = []
    const ident = this.identity()

    // Start with only this Mac in the config. Clients are accepted on demand:
    // when an unknown client tries to join we append it below and SIGHUP the
    // core to hot-reload, so the user never has to type the peer's name.
    this._writeServerConfig(this._serverConfigFor([]))

    // Server settings. `checkPeerFingerprints=false` keeps the wire encrypted
    // (TLS) but does not reject unknown clients headlessly; the client side
    // still pins the server fingerprint. Mutual pinning is a follow-up.
    const settings = [
      '[core]',
      `computerName=${this.deviceName}`,
      `port=${this.port}`,
      'coreMode=2',
      '[server]',
      'externalConfig=true',
      `externalConfigFile=${this._serverConfigFile()}`,
      'enableClipboard=true',
      '[security]',
      'tlsEnabled=true',
      'checkPeerFingerprints=false',
      `certificate=${ident.certPath}`,
      '[log]',
      'level=debug',
      '',
    ].join('\n')
    this._writeSettings(settings)

    this._spawn('server')
    this._emitStatus()
    return this.status()
  }

  // A client announced a name the server config does not know yet. Append it
  // as a right-hand neighbour and restart the core so it picks up the new
  // config. (Deskflow's SIGHUP reload is unreliable in headless mode: its
  // signal thread blocks SIGHUP on the worker thread but not the main thread,
  // so the process tends to die instead of reloading. A graceful restart is
  // harmless here because the unknown client is already retrying its connect.)
  _addClientToConfig(clientName) {
    const clean = cleanComputerName(clientName)
    if (!clean || this._acceptedClients.includes(clean)) return
    this._acceptedClients.push(clean)
    this._writeServerConfig(this._serverConfigFor(this._acceptedClients))
    this.lastError = null

    this._restarting = true
    if (this.child && !this.child.killed) {
      try { this.child.kill('SIGTERM') } catch {}
    } else {
      this._restarting = false
      this._spawn('server')
    }
    this._emitStatus()
  }

  connect({ host, port = DEFAULT_PORT, fingerprint = '' } = {}) {
    this.stop()
    const addr = String(host || '').trim()
    if (!addr) {
      this.lastError = '请填写主机地址。'
      this.role = 'idle'
      this._emitStatus()
      return this.status()
    }

    this.role = 'client'
    this.port = clampPort(port)
    this.host = addr
    this.lastError = null
    const ident = this.identity()

    // The client runs PeerAuth: it must pin the server's cert fingerprint.
    // Deskflow reads trusted fingerprints from tls/trusted-servers as
    // "v2:sha256:<64 lowercase hex>" lines.
    const hex = String(fingerprint || '').replace(/[^0-9a-fA-F]/g, '').toLowerCase()
    if (hex.length === 64) {
      fs.mkdirSync(this._tlsDir(), { recursive: true, mode: 0o700 })
      fs.writeFileSync(path.join(this._tlsDir(), 'trusted-servers'), `v2:sha256:${hex}\n`, 'utf8')
    } else {
      this.lastError = '主机指纹格式不正确（需要 64 位十六进制）。'
      this.role = 'idle'
      this._emitStatus()
      return this.status()
    }

    const settings = [
      '[core]',
      `computerName=${this.deviceName}`,
      `port=${this.port}`,
      'coreMode=1',
      '[client]',
      `remoteHost=${this.host}`,
      'languageSync=true',
      '[security]',
      'tlsEnabled=true',
      'checkPeerFingerprints=true',
      `certificate=${ident.certPath}`,
      '[log]',
      'level=debug',
      '',
    ].join('\n')
    this._writeSettings(settings)

    this._spawn('client')
    this._emitStatus()
    return this.status()
  }

  // Parse one deskflow-core log line (from either stdout or stderr) and update
  // the exposed status. This is deliberately tolerant: it reads human log text
  // rather than a machine protocol, so every branch is a best-effort hint.
  _handleLogLine(line) {
    this.emit('log', line)
    if (line.includes('does not trust this process') || line.includes('assistive devices')) {
      this.lastError = '未获得辅助功能权限：请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 Kaki Tools。'
      this._emitStatus()
    } else if (line.includes('has connected') || line.includes('connected to secure socket')) {
      const match = line.match(/"([^"]+)" has connected/)
      this.peer = { name: match ? match[1] : '已连接' }
      this.lastError = null
      this._emitStatus()
    } else if (line.includes('unrecognised client name')) {
      const match = line.match(/unrecognised client name "([^"]+)"/i)
      if (this.role === 'host' && match) this._addClientToConfig(match[1])
    } else if (line.includes('disconnected') || line.includes('failed to connect') || line.includes('Connection refused')) {
      this.peer = null
      this._emitStatus()
    }
  }

  _spawn(mode) {
    if (!this.binaryPath || !fs.existsSync(this.binaryPath)) {
      this.lastError = `未找到 Deskflow 核心程序：${this.binaryPath || '(未设置)'}`
      this.role = 'idle'
      this.child = null
      this._emitStatus()
      return
    }

    const args = [mode, '-s', this._settingsFile()]
    this._stdoutBuffer = ''
    let child
    try {
      child = spawn(this.binaryPath, args, { stdio: ['ignore', 'pipe', 'pipe'] })
    } catch (error) {
      this.lastError = `无法启动 Deskflow 核心：${error.message}`
      this.role = 'idle'
      this._emitStatus()
      return
    }
    this.child = child

    // Deskflow writes its log to BOTH streams depending on severity, so route
    // stdout and stderr through the same line parser.
    this._stdoutBuffer = ''
    this._stderrBuffer = ''
    const attachStream = (stream, bufferKey) => {
      stream.setEncoding('utf8')
      stream.on('data', chunk => {
        this[bufferKey] += chunk
        const lines = this[bufferKey].split(/\r?\n/)
        this[bufferKey] = lines.pop() || ''
        for (const raw of lines) {
          const line = raw.trim()
          if (line) this._handleLogLine(line)
        }
      })
    }
    attachStream(child.stdout, '_stdoutBuffer')
    attachStream(child.stderr, '_stderrBuffer')
    child.on('error', error => {
      if (this.child !== child) return
      this.child = null
      this.lastError = `Deskflow 核心错误：${error.message}`
      this.role = 'idle'
      this._emitStatus()
    })
    child.on('exit', (code, signal) => {
      if (this.child !== child) return
      this.child = null
      this.peer = null
      // A requested restart (new client added to config) respawns the server
      // with the updated config; it is not an error.
      if (this._restarting) {
        this._restarting = false
        this._spawn('server')
        return
      }
      // 若日志已给出更具体的错误(如辅助功能未授权),不要用通用的退出码覆盖。
      if (!this.lastError) {
        this.lastError = `Deskflow 核心已退出（code ${code ?? ''} ${signal || ''}）`.trim()
      }
      this.role = 'idle'
      this._emitStatus()
    })
  }

  stop() {
    const child = this.child
    this.child = null
    this.role = 'idle'
    this.host = null
    this.peer = null
    this.lastError = null
    this._acceptedClients = []
    this._restarting = false
    if (child && !child.killed) {
      try { child.kill('SIGTERM') } catch {}
      // Deskflow core installs a SIGINT/SIGTERM handler; give it a moment
      // before forcing, so it can release the event tap cleanly.
      const pending = child
      setTimeout(() => { try { if (!pending.killed) pending.kill('SIGKILL') } catch {} }, 1500).unref()
    }
  }
}

module.exports = { DeskflowCore, DEFAULT_PORT, cleanComputerName, localAddresses }
