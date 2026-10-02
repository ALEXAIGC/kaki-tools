const DEFAULT_HISTORY_LIMIT = 100

function historyLimit(value) {
  const n = Number(value)
  return Number.isFinite(n) && n >= 1 ? Math.min(DEFAULT_HISTORY_LIMIT, Math.floor(n)) : DEFAULT_HISTORY_LIMIT
}

module.exports = { DEFAULT_HISTORY_LIMIT, historyLimit }
