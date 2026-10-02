const { test } = require('node:test')
const assert = require('node:assert/strict')
const searchHistory = require('../main/history-search')

test('full history search finds text beyond the preview and includes tags and notes', async () => {
  const items = [
    { id: 'long', type: 'text', text: 'x'.repeat(900) + 'TailNeedle', tags: [] },
    { id: 'tag', type: 'image', tags: ['TailNeedle'] },
    { id: 'note', type: 'text', text: 'short', note: 'tailneedle' },
    { id: 'other', type: 'text', text: 'something else' },
  ]
  assert.deepEqual(await searchHistory(items, ' tailNEEDLE '), ['long', 'tag', 'note'])
  assert.deepEqual(await searchHistory(items, 'missing'), [])
  assert.deepEqual(await searchHistory(items, ''), [])
})

test('search yields during long collections and does not mutate history', async () => {
  const items = Array.from({ length: 100 }, (_, n) => ({ id: String(n), type: 'text', text: 'match' }))
  let finished = false
  const pending = searchHistory(items, 'match').then(result => { finished = true; return result })
  assert.equal(finished, false)
  assert.equal((await pending).length, 100)
  assert.equal(items[0].text, 'match')
})
