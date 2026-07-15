// fleet-group.mjs — pure multi-repo fleet isolation for Show Time CLAW board.
// Node-testable. index.html mirrors this algorithm (no bundler).

/**
 * Strip worktree leaves and normalize slashes for grouping.
 * @param {string} repoPath
 * @returns {string}
 */
export function normalizeRepoKey(repoPath) {
  let p = String(repoPath || '').replace(/\\/g, '/').replace(/\/+$/, '')
  p = p.replace(/\/\.worktrees-showtime\/[^/]+$/i, '')
  p = p.replace(/\/\.claude\/worktrees\/[^/]+$/i, '')
  p = p.replace(/\/\.codex-worktrees\/[^/]+$/i, '')
  // Drop trailing /src or empty
  p = p.replace(/\/+$/, '')
  return p.toLowerCase()
}

/**
 * Probe / sound-test sessions must never form a fleet column.
 * @param {object} s
 * @returns {boolean}
 */
export function isJunkSession(s) {
  const sid = String(s?.sessionId || '')
  const title = String(s?.ledgerTitle || s?.title || '')
  if (/^(sound-test|alert-test|LOUD-|HEAR-ME|BLAST-|SOUND|alarm|prove-grok)/i.test(sid)) return true
  if (/(SOUND TEST|LOUD ALARM|HEAR THIS|BLAST SOUND|TEST LOUD JOIN|alarm proof)/i.test(title)) return true
  return false
}

/**
 * Prefer git-root-ish path fields on a session.
 * @param {object} s
 * @returns {string}
 */
export function sessionRepoPath(s) {
  return String(
    s?.primaryRepoPath || s?.repoPath || s?.repoDir || '',
  ).trim()
}

/**
 * @param {object} s
 * @returns {string} stable group key
 */
export function fleetGroupKey(s) {
  const pathKey = normalizeRepoKey(sessionRepoPath(s))
  if (pathKey) return `repo:${pathKey}`
  if (s?.fleetId) return `fleet:${s.fleetId}`
  if (s?.ledgerHash) return `hash:${String(s.ledgerHash).toLowerCase()}`
  const title = String(s?.ledgerTitle || '').trim().toLowerCase()
  if (title) return `title:${title}`
  return `sess:${s?.sessionId || 'unknown'}`
}

/**
 * Classify column role for layout (MAIN vs SIDE).
 * @param {{ title?: string, path?: string, repo?: string }} g
 * @returns {'primary'|'side'}
 */
export function classifyFleetRole(g) {
  const blob = `${g.title || ''} ${g.path || ''} ${g.repo || ''}`
  if (/looplet-producer|(^|[^\w-])producer([^\w-]|$)/i.test(blob) && !/otis live|ai-sidebar/i.test(blob)) {
    return 'primary'
  }
  if (/ai-sidebar|extension|otis live/i.test(blob)) return 'side'
  return 'side'
}

/**
 * Default KPI rollup (same shape as board kpis()).
 * @param {object[]} ss
 */
export function defaultKpis(ss) {
  let done = 0
  let total = 0
  let inflight = 0
  let needs = 0
  let p0 = 0
  for (const s of ss || []) {
    const c = s.counts || {}
    const d = Number(c.done || 0)
    const p = Number(c.pending || 0)
    const ip = Number(c.inProgress || 0)
    const b = Number(c.blocked || 0)
    done += d
    total += d + p + ip + b
    inflight += ip
    needs += Number(c.blocked || 0) + (s.needsInput ? 1 : 0)
    if (s.priority === 0 || s.p0) p0 += 1
  }
  return { done, total, inflight, needs, p0, bm: 0 }
}

/**
 * Group sessions into isolated fleet columns by repo root (never mix repos).
 *
 * @param {object[]} all
 * @param {{ fleets?: object[], kpis?: (ss: object[]) => object }} [opts]
 * @returns {object[]}
 */
export function groupSessionsByFleet(all, opts = {}) {
  const fleets = Array.isArray(opts.fleets) ? opts.fleets : []
  const kfn = typeof opts.kpis === 'function' ? opts.kpis : defaultKpis
  const map = new Map()

  for (const s of all || []) {
    if (!s || isJunkSession(s)) continue
    const key = fleetGroupKey(s)
    if (!map.has(key)) {
      map.set(key, {
        key,
        fleetId: s.fleetId || key,
        sessions: [],
        meta: null,
      })
    }
    map.get(key).sessions.push(s)
  }

  for (const g of map.values()) {
    // Prefer live owner session for head title (not a twin/corpse join)
    const s0 =
      g.sessions.find((s) => s.isWorkerOwner && (s.pidAlive || s.workerAlive)) ||
      g.sessions.find((s) => s.isWorkerOwner) ||
      g.sessions.find((s) => !s.corpse) ||
      g.sessions[0]
    const pathRaw = sessionRepoPath(s0)
    g.path = pathRaw
    g.meta =
      fleets.find((f) => f.fleetId && g.sessions.some((s) => s.fleetId === f.fleetId)) ||
      fleets.find((f) => normalizeRepoKey(f.primaryRepoPath || f.repoPath || '') === normalizeRepoKey(pathRaw)) ||
      null
    g.title =
      s0?.ledgerTitle ||
      g.meta?.ledgerTitle ||
      g.meta?.label ||
      pathRaw.split(/[/\\]/).filter(Boolean).slice(-1)[0] ||
      'Fleet'
    g.repo = g.meta?.repoId || s0?.repoId || ''
    g.role = classifyFleetRole({ title: g.title, path: pathRaw, repo: g.repo })
    g.k = kfn(g.sessions)
  }

  const list = [...map.values()]
  list.sort((a, b) => {
    if (a.role !== b.role) return a.role === 'primary' ? -1 : 1
    const ap = (a.k.total || 0) - (a.k.done || 0)
    const bp = (b.k.total || 0) - (b.k.done || 0)
    if (bp !== ap) return bp - ap
    return String(a.title).localeCompare(String(b.title))
  })

  if (list.length && !list.some((g) => g.role === 'primary')) {
    // Largest remaining work becomes MAIN
    list.sort((a, b) => (b.k.total - b.k.done) - (a.k.total - a.k.done))
    list[0].role = 'primary'
    for (let i = 1; i < list.length; i++) list[i].role = 'side'
  }

  return list
}
