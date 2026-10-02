// Transport only: action owners decide whether a failed request may be retried.
// A timeout/disconnection is ambiguous, so it must never cause a second paste or resize.
class NativeClient {
  constructor() {
    this.child = null
    this.capabilities = new Set()
    this.sequence = 0
    this.requests = new Map()
  }

  connect(child, capabilities = []) {
    this.disconnect()
    this.child = child
    this.capabilities = new Set(capabilities)
  }

  disconnect() {
    this.child = null
    this.capabilities.clear()
    for (const id of this.requests.keys()) this.settle(id, { status: 'disconnected' })
  }

  settle(id, result) {
    const request = this.requests.get(id)
    if (!request) return false
    clearTimeout(request.timer)
    this.requests.delete(id)
    request.resolve(result)
    return true
  }

  handleLine(line) {
    const match = /^result (\d+) (.+)$/.exec(line)
    if (match) {
      try {
        const result = JSON.parse(match[2])
        if (!result || typeof result.status !== 'string') return false
        return this.settle(match[1], result)
      } catch { return false }
    }
    const legacy = /^(ok|not-trusted|error) (\d+)$/.exec(line)
    return !!legacy && this.settle(legacy[2], { status: legacy[1] })
  }

  request(command, payload = {}, timeoutMs = 1500) {
    const child = this.child
    const capability = command.startsWith('window-') ? 'windows' : command
    if (!child?.stdin?.writable || (command !== 'paste' && (!this.capabilities.has('requests') || !this.capabilities.has(capability)))) {
      return Promise.resolve({ status: 'unavailable' })
    }
    const id = String(++this.sequence)
    let line
    try {
      line = this.capabilities.has('requests')
        ? `request ${id} ${JSON.stringify({ command, payload, deadline: Date.now() + timeoutMs })}\n`
        : `paste ${id}\n`
    } catch { return Promise.resolve({ status: 'error', message: '无法序列化原生请求' }) }
    return new Promise(resolve => {
      const timer = setTimeout(() => this.settle(id, { status: 'timeout' }), timeoutMs)
      this.requests.set(id, { resolve, timer })
      try {
        child.stdin.write(line, error => {
          if (error) this.settle(id, { status: 'disconnected' })
        })
      } catch { this.settle(id, { status: 'disconnected' }) }
    })
  }
}

module.exports = NativeClient
