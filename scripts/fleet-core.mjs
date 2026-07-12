/**
 * fleet-core.mjs — Party handshake: one ORCH per ledger/repo fleet.
 * Board is the venue. Each guest brings ORCH + workers for ONE ledger.
 */
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

export function createFleetApi({
  fleetsDir,
  readJsonSafe,
  writeJson,
  nowIso,
  uid,
  resolveGitRoot,
  normalizeRepoRoot,
  normalizeTitle,
  listSessions,
  sessionPath,
  broadcast,
}) {
  fs.mkdirSync(fleetsDir, { recursive: true })

  function fleetPath(id) {
    const safe = String(id || '').replace(/[^a-zA-Z0-9._-]/g, '_')
    return path.join(fleetsDir, `${safe}.json`)
  }

  function listFleets() {
    if (!fs.existsSync(fleetsDir)) return []
    return fs
      .readdirSync(fleetsDir)
      .filter((f) => f.endsWith('.json'))
      .map((f) => readJsonSafe(path.join(fleetsDir, f)))
      .filter(Boolean)
      .sort((a, b) => String(a.createdAt || '').localeCompare(String(b.createdAt || '')))
  }

  function makeFleetId({ ledgerKey, ledgerHash, primaryRepoPath, repoPath, ledgerTitle }) {
    const key = String(ledgerKey || ledgerHash || '').trim().toLowerCase()
    const root = resolveGitRoot(primaryRepoPath || repoPath || '')
    const title = normalizeTitle(ledgerTitle || '')
    const raw = `${root}|${key || title}|${title}`
    return `fleet_${crypto.createHash('sha256').update(raw).digest('hex').slice(0, 12)}`
  }

  function findFleetByIdentity(body = {}) {
    const fleetId = body.fleetId ? String(body.fleetId).trim() : ''
    if (fleetId) {
      const f = readJsonSafe(fleetPath(fleetId))
      if (f) return f
    }
    const wantKey = String(body.ledgerKey || body.ledgerHash || '').trim().toLowerCase()
    const wantTitle = normalizeTitle(body.ledgerTitle || '')
    const wantRoot = resolveGitRoot(body.primaryRepoPath || body.repoPath || '').toLowerCase()
    for (const f of listFleets()) {
      if (f.status === 'left' || f.status === 'complete') continue
      if (wantKey && String(f.ledgerKey || '').toLowerCase() === wantKey) return f
      const fRoot = resolveGitRoot(f.primaryRepoPath || f.repoPath || '').toLowerCase()
      if (wantRoot && fRoot && wantRoot === fRoot && wantTitle && normalizeTitle(f.ledgerTitle) === wantTitle) {
        return f
      }
    }
    return null
  }

  function nextLocalSa(fleet) {
    const used = new Set((fleet.workers || []).map((w) => w.localNo).filter(Boolean))
    let n = 1
    while (used.has(n)) n++
    return n
  }

  /**
   * Ensure a fleet exists for this ledger. Creates ORCH session metadata on the fleet.
   * Returns { fleet, created, attached }.
   */
  function ensureFleet(body = {}) {
    const existing = findFleetByIdentity(body)
    if (existing && existing.status !== 'left' && existing.status !== 'complete') {
      return { fleet: existing, created: false, attached: true }
    }

    const ledgerKey =
      String(body.ledgerKey || body.ledgerHash || '').trim() ||
      `title:${normalizeTitle(body.ledgerTitle || 'ledger')}`
    const primaryRepoPath = body.primaryRepoPath || body.repoPath || ''
    const fleetId = body.fleetId || makeFleetId({ ...body, ledgerKey, primaryRepoPath })
    const orchSessionId = body.orchSessionId || `orch_${fleetId.replace(/^fleet_/, '')}`

    // One ledger per ORCH: refuse if another live fleet already owns this ledgerKey under different orch
    for (const f of listFleets()) {
      if (f.fleetId === fleetId) continue
      if (f.status === 'left' || f.status === 'complete') continue
      if (String(f.ledgerKey || '').toLowerCase() === String(ledgerKey).toLowerCase() && ledgerKey) {
        const err = new Error(
          `Ledger already has ORCH on fleet ${f.fleetId} (${f.repoId}). Attach there — do not invent a second orchestrator.`,
        )
        err.statusCode = 409
        err.code = 'LEDGER_HAS_ORCH'
        err.fleet = f
        throw err
      }
    }

    const fleet = {
      fleetId,
      status: 'active', // active | complete | left
      role: 'orch',
      repoId: body.repoId || path.basename(normalizeRepoRoot(primaryRepoPath) || 'repo'),
      primaryRepoPath,
      repoPath: body.repoPath || primaryRepoPath,
      ledgerKey,
      ledgerHash: body.ledgerHash || ledgerKey,
      ledgerTitle: body.ledgerTitle || null,
      ledgerPath: body.ledgerPath || null,
      branch: body.branch || null,
      orchSessionId,
      workers: [],
      createdAt: nowIso(),
      updatedAt: nowIso(),
    }
    writeJson(fleetPath(fleetId), fleet)
    broadcast('fleets', listFleets())
    return { fleet, created: true, attached: false }
  }

  function attachWorkerToFleet(fleet, workerSession) {
    const localNo = nextLocalSa(fleet)
    const entry = {
      sessionId: workerSession.sessionId,
      localNo,
      subAgentId: `SA-${localNo}`,
      chatLabel: `Chat ${localNo}`,
      joinedAt: nowIso(),
    }
    fleet.workers = (fleet.workers || []).filter((w) => w.sessionId !== workerSession.sessionId)
    fleet.workers.push(entry)
    fleet.updatedAt = nowIso()
    writeJson(fleetPath(fleet.fleetId), fleet)
    broadcast('fleets', listFleets())
    return { fleet, localNo, subAgentId: entry.subAgentId, chatLabel: entry.chatLabel }
  }

  function removeWorkerFromFleet(fleetId, sessionId) {
    const fleet = readJsonSafe(fleetPath(fleetId))
    if (!fleet) return null
    fleet.workers = (fleet.workers || []).filter((w) => w.sessionId !== sessionId)
    fleet.updatedAt = nowIso()
    if (!fleet.workers.length && fleet.status === 'active') {
      // keep fleet until explicit leave
    }
    writeJson(fleetPath(fleetId), fleet)
    broadcast('fleets', listFleets())
    return fleet
  }

  function leaveFleet(fleetId, { reason = 'left' } = {}) {
    const fleet = readJsonSafe(fleetPath(fleetId))
    if (!fleet) return null
    const workerIds = (fleet.workers || []).map((w) => w.sessionId)
    fleet.status = reason === 'complete' ? 'complete' : 'left'
    fleet.leftAt = nowIso()
    fleet.updatedAt = nowIso()
    fleet.workers = []
    writeJson(fleetPath(fleetId), fleet)
    broadcast('fleets', listFleets())
    return { fleet, workerIds, orchSessionId: fleet.orchSessionId }
  }

  /** Durable inbox under home repo scratch for Nudge/steer delivery. */
  function appendHomeInbox(primaryRepoPath, event) {
    if (!primaryRepoPath) return false
    try {
      const scratch = path.join(primaryRepoPath, '.claude', 'scratch')
      fs.mkdirSync(scratch, { recursive: true })
      const inbox = path.join(scratch, 'showtime-inbox.jsonl')
      const line = JSON.stringify({ ...event, at: event.at || nowIso() }) + '\n'
      fs.appendFileSync(inbox, line, 'utf8')
      return true
    } catch {
      return false
    }
  }

  function enrichFleetsWithSessions() {
    const sessions = listSessions()
    const byId = new Map(sessions.map((s) => [s.sessionId, s]))
    return listFleets()
      .filter((f) => f.status === 'active')
      .map((f) => {
        const workers = (f.workers || [])
          .map((w) => {
            const s = byId.get(w.sessionId)
            return s
              ? {
                  ...w,
                  status: s.status,
                  progress: s.progress,
                  counts: s.counts,
                  slice: s.slice,
                  pid: s.pid,
                }
              : w
          })
        return {
          ...f,
          workers,
          workerCount: workers.length,
          label: f.ledgerTitle || f.repoId || f.fleetId,
        }
      })
  }

  return {
    listFleets,
    makeFleetId,
    findFleetByIdentity,
    ensureFleet,
    attachWorkerToFleet,
    removeWorkerFromFleet,
    leaveFleet,
    appendHomeInbox,
    enrichFleetsWithSessions,
    fleetPath,
  }
}
