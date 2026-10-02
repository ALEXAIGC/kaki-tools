const { test } = require('node:test')
const assert = require('node:assert/strict')
const NativeClient = require('../main/native-client')

function setup() {
  const writes = []
  const child = { stdin: { writable: true, write(line, cb) { writes.push(line); cb?.() } } }
  const client = new NativeClient()
  client.connect(child, ['requests', 'windows', 'clipboard-write'])
  return { client, child, writes }
}

test('native JSON requests round trip text with newlines and resolve only the matching response', async () => {
  const { client, writes } = setup()
  const pending = client.request('clipboard-write', { text: '中文\nnext' })
  const [, id, json] = writes[0].match(/^request (\d+) (.+)\n$/)
  const request = JSON.parse(json)
  assert.equal(request.payload.text, '中文\nnext')
  assert.ok(request.deadline > Date.now())
  assert.equal(client.handleLine('result 999 {"status":"ok"}'), false)
  assert.equal(client.handleLine(`result ${id} {"status":"ok"}`), true)
  assert.deepEqual(await pending, { status: 'ok' })
})

test('disconnection resolves pending operations as ambiguous and never replays a command', async () => {
  const { client, writes } = setup()
  const pending = client.request('window-apply', { token: '1' })
  client.disconnect()
  assert.equal((await pending).status, 'disconnected')
  assert.equal((await client.request('paste')).status, 'unavailable')
  assert.equal(writes.length, 1)
})

test('a timeout is distinguished from unavailability and late replies are ignored', async () => {
  const { client, writes } = setup()
  const pending = client.request('paste', {}, 5)
  const id = writes[0].split(' ')[1]
  assert.equal((await pending).status, 'timeout')
  assert.equal(client.handleLine(`result ${id} {"status":"ok"}`), false)
  assert.equal(writes.length, 1)
})

test('older helpers support legacy paste but do not receive unsupported window requests', async () => {
  const { client, child, writes } = setup()
  client.connect(child, [])
  assert.equal((await client.request('window-snapshot')).status, 'unavailable')
  const pending = client.request('paste')
  const id = writes[0].trim().split(' ')[1]
  assert.equal(writes[0], `paste ${id}\n`)
  client.handleLine(`ok ${id}`)
  assert.equal((await pending).status, 'ok')
})

test('partial capabilities never turn a window or copy request into a paste command', async () => {
  const { client, child, writes } = setup()
  client.connect(child, ['windows', 'clipboard-write'])
  assert.equal((await client.request('window-snapshot')).status, 'unavailable')
  assert.equal((await client.request('clipboard-write')).status, 'unavailable')
  assert.equal(writes.length, 0)
})
