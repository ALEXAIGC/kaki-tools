// Search original history in the main process; the renderer keeps short previews.
// Yield between batches so a large collection of saved items cannot monopolize IPC.
async function searchHistory(items, query) {
  const needle = String(query || '').trim().toLowerCase()
  if (!needle) return []
  const matches = []
  const snapshot = items.slice()
  for (let n = 0; n < snapshot.length; n++) {
    const item = snapshot[n]
    const values = [item.type === 'text' ? item.text : '', ...(item.tags || []), item.note]
    if (values.some(value => typeof value === 'string' && value.toLowerCase().includes(needle))) matches.push(item.id)
    if (n % 16 === 15) await new Promise(resolve => setImmediate(resolve))
  }
  return matches
}
module.exports = searchHistory
