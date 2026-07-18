// worker-ownership.mjs — pure single-writer + corpse honesty for Show Time.
// Used by theater-server.mjs; unit-tested offline. No Node fs here.

/**
 * @param {string} repoPath
 * @returns {string}
 */
export function normalizeRootKey(repoPath) {
  let p = String(repoPath || '').replace(/\\/g, '/').replace(/\/+$/, '')
  p = p.replace(/\/\.worktrees-showtime\/[^/]+$/i, '')
  p = p.replace(/\/\.claude\/worktrees\/[^/]+$/i, '')
  p = p.replace(/\/\.codex-worktrees\/[^/]+$/i, '')
  p = p.replace(/\/+$/, '')
  return p.toLowerCase()
}

/**
 * Session fields that may hold a claimed pid (own claim only — never invent).
 * @param {object} s
 * @returns {number}
 */
export function ownPidClaim(s) {
  for (const c of [s?.pid, s?.runnerPid, s?.armPid]) {
    const n = Number(c)
    if (n > 0) return n
  }
  return 0
}

/**
 * Pick the single owner session for a repo root.
 * Priority: autopro-on.<sessionId> flag match → session whose own pid == disk worker pid
 * → most recently updated session with a live own pid → first with any own pid claim.
 *
 * @param {object[]} sessionsInRoot
 * @param {{ flagOwnerId?: string, diskPid?: number, isPidAlive?: (n:number)=>boolean }} opts
 * @returns {string} owner sessionId or ''
 */
export function pickOwnerSessionId(sessionsInRoot, opts = {}) {
  const list = (sessionsInRoot || []).filter((s) => s && s.sessionId)
  if (!list.length) return ''
  const isAlive = typeof opts.isPidAlive === 'function' ? opts.isPidAlive : () => false
  const flagOwner = String(opts.flagOwnerId || '').trim()
  const diskPid = Number(opts.diskPid || 0)

  if (flagOwner && list.some((s) => s.sessionId === flagOwner)) return flagOwner

  if (diskPid > 0 && isAlive(diskPid)) {
    const byPid = list.find((s) => ownPidClaim(s) === diskPid)
    if (byPid) return byPid.sessionId
  }

  const liveOwn = list
    .filter((s) => {
      const p = ownPidClaim(s)
      return p > 0 && isAlive(p)
    })
    .sort((a, b) => String(b.updatedAt || '').localeCompare(String(a.updatedAt || '')))
  if (liveOwn.length) return liveOwn[0].sessionId

  const anyClaim = list
    .filter((s) => ownPidClaim(s) > 0)
    .sort((a, b) => String(b.updatedAt || '').localeCompare(String(a.updatedAt || '')))
  if (anyClaim.length) return anyClaim[0].sessionId

  // Prefer session matching armRunner / most recently heartbeated
  const sorted = [...list].sort((a, b) =>
    String(b.updatedAt || b.createdAt || '').localeCompare(String(a.updatedAt || a.createdAt || '')),
  )
  return sorted[0]?.sessionId || ''
}

/**
 * Apply single-writer + corpse flags onto session objects (mutates copies).
 * @param {object[]} sessions - raw or pre-enriched
 * @param {{
 *   rootKeyOf: (s:object)=>string,
 *   isPidAlive: (n:number)=>boolean,
 *   readDiskPid: (rootKey:string)=>number,
 *   readFlagOwner: (rootKey:string)=>string,
 * }} io
 * @returns {object[]}
 */
export function applyOwnership(sessions, io) {
  const list = (sessions || []).map((s) => ({ ...s }))
  const byRoot = new Map()
  for (const s of list) {
    const key = io.rootKeyOf(s) || `sess:${s.sessionId}`
    if (!byRoot.has(key)) byRoot.set(key, [])
    byRoot.get(key).push(s)
  }

  for (const [rootKey, group] of byRoot) {
    const diskPid = rootKey.startsWith('sess:') ? 0 : Number(io.readDiskPid(rootKey) || 0)
    const flagOwner = rootKey.startsWith('sess:') ? '' : String(io.readFlagOwner(rootKey) || '')
    const ownerId = pickOwnerSessionId(group, {
      flagOwnerId: flagOwner,
      diskPid,
      isPidAlive: io.isPidAlive,
    })

    for (const s of group) {
      const own = ownPidClaim(s)
      const isOwner = s.sessionId === ownerId
      s.isWorkerOwner = isOwner
      s.workerOwnerSessionId = ownerId || null
      s.repoRootKey = rootKey

      let effectivePid = 0
      if (isOwner) {
        // Owner may inherit disk worker pid when their own claim is empty/stale
        if (own > 0 && io.isPidAlive(own)) effectivePid = own
        else if (diskPid > 0 && io.isPidAlive(diskPid)) effectivePid = diskPid
        else if (own > 0) effectivePid = own // dead own claim — still stamp for corpse
      } else {
        // Twins: only their OWN distinct live pid counts (should be rare / never for single-writer)
        if (own > 0 && io.isPidAlive(own) && own !== diskPid) effectivePid = own
        else effectivePid = 0
        if (own > 0 && own === diskPid) s.twinOf = ownerId
        else if (!isOwner && ownerId) s.twinOf = ownerId
      }

      if (effectivePid > 0) s.pid = effectivePid
      const alive = effectivePid > 0 && io.isPidAlive(effectivePid)
      s.workerAlive = alive
      s.pidAlive = alive
      s.workerDead = !alive && (effectivePid > 0 || own > 0 || Number(s.pid) > 0)

      const st = String(s.status || '').toLowerCase()
      const looksActive = /^(running|in-progress|stalled|blocked|paused|needs_input|queued)$/.test(st)
      const hasLedger = !!(
        s.ledgerPath ||
        s.ledgerTitle ||
        s.ledgerHash ||
        (Array.isArray(s.todo) && s.todo.length) ||
        s.slice
      )

      s.ledgerProjector = false
      s.corpse = false
      s.twinOf = s.twinOf || null

      if (isOwner) {
        // Dead owner still "running" → corpse (no fake coding)
        if (!alive && looksActive) s.corpse = true
      } else if (!alive) {
        // SHARED BOARD: other ledgers stay visible as projectors (separate ledger, same page).
        // Corpse only when there is nothing useful to project (no ledger + not a real lane).
        if (hasLedger || looksActive) {
          s.ledgerProjector = true
          s.armDisplay = 'projector'
          if (ownerId) s.twinOf = ownerId // same root — not the coding writer
        } else {
          s.corpse = true
          s.armDisplay = 'corpse'
        }
      }
    }
  }
  return list
}

/**
 * True when session may show coding legs (owner + live pid + not idle).
 * Pure helper for tests; UI still uses server flags.
 */
export function mayShowLegs(s, isIdleFn) {
  if (!s?.isWorkerOwner) return false
  if (!s.pidAlive && !s.workerAlive) return false
  if (s.corpse) return false
  if (typeof isIdleFn === 'function' && isIdleFn(s)) return false
  return true
}
