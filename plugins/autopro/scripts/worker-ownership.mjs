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
 * Prefers structured runnerPid when pid is absent; workerPid is coding-only.
 * @param {object} s
 * @returns {number}
 */
export function ownPidClaim(s) {
  for (const c of [s?.pid, s?.runnerPid, s?.armPid, s?.workerPid]) {
    const n = Number(c)
    if (n > 0) return n
  }
  return 0
}

/**
 * All positive pids claimed by a session (for live-any checks).
 * @param {object} s
 * @returns {number[]}
 */
export function allOwnPids(s) {
  const out = []
  for (const c of [s?.workerPid, s?.pid, s?.runnerPid, s?.armPid]) {
    const n = Number(c)
    if (n > 0 && !out.includes(n)) out.push(n)
  }
  return out
}

/**
 * True when any claimed pid is live.
 * @param {object} s
 * @param {(n:number)=>boolean} isPidAlive
 */
export function hasLiveOwnPid(s, isPidAlive) {
  const isAlive = typeof isPidAlive === 'function' ? isPidAlive : () => false
  return allOwnPids(s).some((n) => isAlive(n))
}

/**
 * Pick the single owner session for a repo root.
 * Priority: autopro-on.<sessionId> flag match → live own pid → disk worker match
 * → most recently updated session with any own pid claim.
 *
 * Flag wins over a twin's live pid so the armed lane owns the column (and then
 * inherits disk worker.pid for legs). Live-first used to let ghosts steal ownership.
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

  // 1) Flag owner is the armed lane identity (single-writer contract)
  if (flagOwner && list.some((s) => s.sessionId === flagOwner)) return flagOwner

  // 2) LIVE own-pid (any of worker/runner/pid) — beats corpses without a flag
  const liveOwn = list
    .filter((s) => hasLiveOwnPid(s, isAlive))
    .sort((a, b) => String(b.updatedAt || '').localeCompare(String(a.updatedAt || '')))
  if (liveOwn.length) return liveOwn[0].sessionId

  // 3) Disk worker.pid match on a session's own claim
  if (diskPid > 0 && isAlive(diskPid)) {
    const byPid = list.find((s) => allOwnPids(s).includes(diskPid) || ownPidClaim(s) === diskPid)
    if (byPid) return byPid.sessionId
  }

  // 4) Any pid claim (dead) — prefer most recently updated
  const anyClaim = list
    .filter((s) => ownPidClaim(s) > 0 || allOwnPids(s).length > 0)
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
 * Owner inherits disk worker.pid for coding legs; runnerPid keeps the lane "armed"
 * between slices when the worker process is gone.
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
      const workerClaim = Number(s.workerPid || 0)
      // Only trust explicit runnerPid — never promote a twin's worker pid to "runner"
      const runnerClaim = Number(s.runnerPid || 0)
      const isOwner = s.sessionId === ownerId
      s.isWorkerOwner = isOwner
      s.workerOwnerSessionId = ownerId || null
      s.repoRootKey = rootKey

      let codingPid = 0
      let armedPid = 0
      if (isOwner) {
        // Coding process: explicit worker → disk file → live own when it is not the runner
        if (workerClaim > 0 && io.isPidAlive(workerClaim)) codingPid = workerClaim
        else if (diskPid > 0 && io.isPidAlive(diskPid)) codingPid = diskPid
        else if (own > 0 && io.isPidAlive(own) && own !== runnerClaim) {
          // legacy heartbeats: pid alone was the worker
          codingPid = own
        }

        // Armed (conductor still up): runner → live own → coding → dead stamp
        if (runnerClaim > 0 && io.isPidAlive(runnerClaim)) armedPid = runnerClaim
        else if (own > 0 && io.isPidAlive(own)) armedPid = own
        else if (codingPid > 0) armedPid = codingPid
        else if (own > 0) armedPid = own // dead claim for corpse stamp
        else if (runnerClaim > 0) armedPid = runnerClaim
        else if (diskPid > 0) armedPid = diskPid
      } else {
        // Twins: NEVER inherit disk/shared worker pid. Only a distinct live own pid counts.
        if (workerClaim > 0 && io.isPidAlive(workerClaim) && workerClaim !== diskPid) {
          codingPid = workerClaim
          armedPid = workerClaim
        } else if (
          own > 0 &&
          io.isPidAlive(own) &&
          own !== diskPid &&
          (runnerClaim === 0 || own === runnerClaim)
        ) {
          // Distinct live process that is not the shared disk worker
          codingPid = own
          armedPid = own
        } else {
          codingPid = 0
          armedPid = 0
        }
        if ((own > 0 && own === diskPid) || (workerClaim > 0 && workerClaim === diskPid)) {
          s.twinOf = ownerId
        } else if (ownerId) {
          s.twinOf = ownerId
        }
      }

      const codingAlive = codingPid > 0 && io.isPidAlive(codingPid)
      // Display pid: coding when live, else armed. Twins with no distinct pid stay at 0.
      let effectivePid = 0
      if (codingAlive) effectivePid = codingPid
      else if (armedPid > 0) effectivePid = armedPid
      else if (isOwner && own > 0) effectivePid = own
      if (effectivePid > 0) s.pid = effectivePid
      // workerAlive = coding process; pidAlive = this lane is armed/coding (owner) or has distinct live pid (rare twin)
      s.workerAlive = codingAlive
      s.pidAlive =
        codingAlive ||
        (armedPid > 0 && io.isPidAlive(armedPid)) ||
        (isOwner && effectivePid > 0 && io.isPidAlive(effectivePid))
      s.runnerAlive = !!(runnerClaim > 0 && io.isPidAlive(runnerClaim))

      const st = String(s.status || '').toLowerCase()
      // idle/complete are honest resting states — never "corpse"
      const looksActive = /^(running|in-progress|stalled|blocked|paused|needs_input|queued)$/.test(st)
      s.workerDead =
        !codingAlive &&
        (workerClaim > 0 ||
          (isOwner && diskPid > 0 && !io.isPidAlive(diskPid)) ||
          (isOwner && !s.pidAlive && looksActive))
      const hasLedger = !!(
        s.ledgerPath ||
        s.ledgerTitle ||
        s.ledgerHash ||
        (Array.isArray(s.todo) && s.todo.length) ||
        s.slice
      )
      const isOrch = /^(orch|orchestrator)$/i.test(String(s.role || ''))

      s.ledgerProjector = false
      s.corpse = false
      s.twinOf = s.twinOf || null

      if (isOrch) {
        // ORCH desk never collapses to Corpse/DEAD (even with pid 0)
        s.corpse = false
        s.armDisplay = s.pidAlive ? 'armed' : 'desk'
      } else if (isOwner) {
        // Dead owner mid-run: keep SC stack if we have ledger/todos (ultra bands).
        // True corpse only when there is nothing useful to show.
        if (!s.pidAlive && looksActive) {
          if (hasLedger) {
            s.corpse = false
            s.armDisplay = 'disarmed'
            s.workerDead = true
          } else {
            s.corpse = true
            s.armDisplay = 'corpse'
          }
        } else if (s.pidAlive) {
          s.armDisplay = codingAlive ? 'coding' : 'armed'
        }
      } else if (!s.pidAlive) {
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
 * True when session may show coding legs (owner + live coding pid + not idle).
 * Pure helper for tests; UI still uses server flags.
 * workerAlive=false means armed-but-not-coding (between slices) → no legs.
 */
export function mayShowLegs(s, isIdleFn) {
  if (!s?.isWorkerOwner) return false
  if (s.corpse) return false
  if (s.workerAlive === false) return false
  if (!(s.workerAlive === true || s.pidAlive === true)) return false
  if (typeof isIdleFn === 'function' && isIdleFn(s)) return false
  return true
}
