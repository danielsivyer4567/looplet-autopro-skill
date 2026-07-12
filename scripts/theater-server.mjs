#!/usr/bin/env node
/**
 * Show Time v2 — Looplet autopro board (localhost).
 * Session bus + static UI. Port 8770+.
 *
 * Security model: localhost is NOT a browser boundary. Every /api/* call
 * except /api/health requires the boot token (X-Showtime-Token header or
 * ?t= query). No Access-Control-Allow-Origin is ever sent, so cross-origin
 * pages can neither read responses nor pass the token check. The board page
 * gets the token injected when index.html is served.
 */
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import crypto from 'node:crypto'
import { createFleetApi } from './fleet-core.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SKILL_ROOT = path.resolve(__dirname, '..')
const THEATER_DIR = path.join(SKILL_ROOT, 'theater')
const HOME = process.env.USERPROFILE || process.env.HOME || '.'
const STATE_ROOT = path.join(HOME, '.claude', 'scratch', 'autopro-theater')
const SESSIONS_DIR = path.join(STATE_ROOT, 'sessions')
const STEER_DIR = path.join(STATE_ROOT, 'steer')
const HANDOVER_DIR = path.join(STATE_ROOT, 'handovers')
const JOIN_DIR = path.join(STATE_ROOT, 'join-requests')
const FLEETS_DIR = path.join(STATE_ROOT, 'fleets')
const JOIN_BEACON = path.join(HOME, '.claude', 'scratch', 'showtime-join-pending.json')
const HANDOVER_OUTBOX = path.join(STATE_ROOT, 'handover-outbox.md')
const PORT_FILE = path.join(STATE_ROOT, 'server.port')
const PID_FILE = path.join(STATE_ROOT, 'server.pid')
const TOKEN_FILE = path.join(STATE_ROOT, 'server.token')
// Fresh token per boot; local scripts read it from TOKEN_FILE, the board page
// gets it injected into index.html. Browsers on other origins never see it.
const SERVER_TOKEN = crypto.randomBytes(24).toString('hex')
// 8766 is often taken by Electron desktop bridges in this monorepo — default 8770.
const PREFERRED_PORT = Number(process.env.SHOWTIME_PORT || 8770)
const PORT_SCAN = 20
// Keep board warm while operator may re-open the tab (2h).
const IDLE_EXIT_MS = 2 * 60 * 60 * 1000
// Wipe completed lanes off the board after this delay (handover is already written).
const COMPLETE_WIPE_MS = Number(process.env.SHOWTIME_COMPLETE_WIPE_MS || 8000)
// Stale = no live pid (or no pid) and not updated within this window.
const STALE_AFTER_MS = Number(process.env.SHOWTIME_STALE_MS || 15 * 60 * 1000)

fs.mkdirSync(SESSIONS_DIR, { recursive: true })
fs.mkdirSync(STEER_DIR, { recursive: true })
fs.mkdirSync(HANDOVER_DIR, { recursive: true })
fs.mkdirSync(JOIN_DIR, { recursive: true })
fs.mkdirSync(FLEETS_DIR, { recursive: true })

const sseClients = new Set()
const wipeTimers = new Map()
let idleTimer = null
let serverPort = PREFERRED_PORT

function nowIso() {
  return new Date().toISOString()
}
function uid(prefix = 'id') {
  return `${prefix}_${crypto.randomBytes(4).toString('hex')}`
}
function readJsonSafe(file, fallback = null) {
  try {
    if (!fs.existsSync(file)) return fallback
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return fallback
  }
}
function writeJson(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(obj, null, 2), 'utf8')
}
function sessionPath(id) {
  const safe = String(id).replace(/[^a-zA-Z0-9._-]/g, '_')
  return path.join(SESSIONS_DIR, `${safe}.json`)
}
function listSessions() {
  if (!fs.existsSync(SESSIONS_DIR)) return []
  return fs
    .readdirSync(SESSIONS_DIR)
    .filter((f) => f.endsWith('.json'))
    .map((f) => readJsonSafe(path.join(SESSIONS_DIR, f)))
    .filter(Boolean)
    .sort((a, b) => (a.lane || 0) - (b.lane || 0))
}
function nextLane() {
  const used = new Set(listSessions().map((s) => s.lane).filter(Boolean))
  let n = 1
  while (used.has(n)) n++
  return n
}
function parseLedgerTodos(ledgerPath) {
  if (!ledgerPath || !fs.existsSync(ledgerPath)) return []
  const text = fs.readFileSync(ledgerPath, 'utf8')
  const todos = []
  // SC-06: also recognize [standby] and [standby: <reason>] so a slice can be
  // marked on hold with WHY, straight from the ledger — additive, never fakes a
  // reason (the optional group is only captured when the operator writes one).
  const re = /^##\s+((?:SC-\d+)|(?:SD-[\w-]+)|(?:H\d+)|(?:P\d+[-\w]*))\s+(?:[—–-]\s+)?(.+?)\s+\[(pending|in-progress|done|blocked|standby)(?:\s*[:—–-]\s*([^\]]+))?\]/gim
  let m
  while ((m = re.exec(text)) !== null) {
    const t = { id: m[1], text: m[2].trim(), state: m[3].toLowerCase() }
    if (t.state === 'standby' && m[4]) t.standbyReason = m[4].trim()
    todos.push(t)
  }
  return todos
}
function deriveCounts(todos) {
  const counts = { pending: 0, inProgress: 0, done: 0, blocked: 0, standby: 0 }
  for (const t of todos) {
    if (t.state === 'pending') counts.pending++
    else if (t.state === 'in-progress') counts.inProgress++
    else if (t.state === 'done') counts.done++
    else if (t.state === 'blocked') counts.blocked++
    else if (t.state === 'standby') counts.standby++ // SC-06: on-hold, not done
  }
  return counts
}
function activeSlice(todos) {
  const active = todos.find((t) => t.state === 'in-progress') || todos.find((t) => t.state === 'pending')
  if (!active) return null
  const total = todos.length
  const index = todos.findIndex((t) => t.id === active.id) + 1
  return { id: active.id, title: active.text, index, total, state: active.state }
}
function emptyStats() {
  return {
    model: 'default',
    measured: false,
    tokens: {
      input: 0,
      output: 0,
      total: 0,
      monolithEst: 0,
      saved: 0,
      savePct: 0,
    },
    speed: { tokPerSec: 0, tokPerSecAvg: 0, tokPerMin: 0, lastSliceSec: 0 },
    code: {
      filesCreated: 0,
      filesTouched: 0,
      linesAdded: 0,
      linesDeleted: 0,
      linesPerTokMin: 0,
      filesPerTokMin: 0,
    },
    perSlice: [],
  }
}
function mergeStats(prev, next) {
  if (!next) return prev || emptyStats()
  const base = prev || emptyStats()
  return {
    ...base,
    ...next,
    tokens: { ...base.tokens, ...(next.tokens || {}) },
    speed: { ...base.speed, ...(next.speed || {}) },
    code: { ...base.code, ...(next.code || {}) },
    perSlice: next.perSlice || base.perSlice || [],
  }
}
function openQuestionCount(session) {
  return (session.questions || []).filter((q) => q.status === 'open').length
}
function applyStall(session) {
  if (!session || session.status === 'complete') return session
  if (openQuestionCount(session) > 0 && session.status !== 'needs_input') {
    // keep needs_input sticky when operator must answer
    if (!['blocked', 'stalled'].includes(session.status)) {
      session.status = 'needs_input'
      session.stopReason = session.stopReason || 'Open operator question'
    }
  }
  // Default 900s: a single claude -p slice often runs 5–15 min with little/no stdout
  // (JSON output is buffered until exit). 300s false-stalled almost every long slice.
  const stallAfter = session.alarms?.stallAfterSec ?? 900
  if (!session.alarms?.stallEnabled) return session
  if (['blocked', 'needs_input', 'complete', 'stalled', 'paused'].includes(session.status)) return session
  // Live runner PID = work still in flight (quiet model call is not a stall)
  if (session.pid && isPidAlive(session.pid)) return session
  const last = session.timer?.lastProgressAt || session.updatedAt
  if (!last) return session
  const age = (Date.now() - new Date(last).getTime()) / 1000
  if (age >= stallAfter && session.status === 'running') {
    session.status = 'stalled'
    const dead = session.pid && !isPidAlive(session.pid)
    session.stopReason = dead
      ? `No progress for ${Math.round(age)}s (stall threshold ${stallAfter}s) · runner pid dead`
      : `No progress for ${Math.round(age)}s (stall threshold ${stallAfter}s)`
    session.timer = { ...(session.timer || {}), running: false }
  }
  return session
}
function missionRollup(sessions) {
  let total = 0
  let done = 0
  let remaining = 0
  let userBlocked = 0
  let workers = sessions.length
  for (const s of sessions) {
    const c = s.counts || {}
    const t =
      (c.pending || 0) + (c.inProgress || 0) + (c.done || 0) + (c.blocked || 0) ||
      (s.todo || []).length
    total += t
    done += c.done || 0
    remaining += (c.pending || 0) + (c.inProgress || 0)
    userBlocked += (c.blocked || 0) + openQuestionCount(s)
  }
  const pct = total > 0 ? Math.round((done / total) * 100) : 0
  return {
    total,
    done,
    pct,
    remaining,
    userBlocked,
    workers,
    sessionsCompleted: sessions.filter((s) => s.status === 'complete').length,
  }
}
function broadcast(event, data) {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`
  for (const res of sseClients) {
    try {
      res.write(payload)
    } catch {
      sseClients.delete(res)
    }
  }
}
function touchIdleTimer() {
  if (idleTimer) clearTimeout(idleTimer)
  idleTimer = setTimeout(() => {
    if (listSessions().length === 0 && sseClients.size === 0) {
      console.log('[showtime] idle exit')
      cleanupAndExit(0)
    }
  }, IDLE_EXIT_MS)
}
function contentType(file) {
  const f = file.toLowerCase()
  if (f.endsWith('.html')) return 'text/html; charset=utf-8'
  if (f.endsWith('.json')) return 'application/json; charset=utf-8'
  if (f.endsWith('.js')) return 'text/javascript; charset=utf-8'
  if (f.endsWith('.css')) return 'text/css; charset=utf-8'
  if (f.endsWith('.wav')) return 'audio/wav'
  if (f.endsWith('.png')) return 'image/png'
  if (f.endsWith('.jpg') || f.endsWith('.jpeg')) return 'image/jpeg'
  if (f.endsWith('.gif')) return 'image/gif'
  if (f.endsWith('.svg')) return 'image/svg+xml'
  if (f.endsWith('.webp')) return 'image/webp'
  if (f.endsWith('.ico')) return 'image/x-icon'
  return 'application/octet-stream'
}
function send(res, code, body, type = 'application/json; charset=utf-8') {
  const buf = typeof body === 'string' ? body : JSON.stringify(body)
  res.writeHead(code, {
    'Content-Type': type,
    'Cache-Control': 'no-store',
  })
  res.end(buf)
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    req.on('data', (c) => chunks.push(c))
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8')
      if (!raw) return resolve({})
      try {
        resolve(JSON.parse(raw))
      } catch (e) {
        reject(e)
      }
    })
    req.on('error', reject)
  })
}
function pushSentinel(session, text, level = 'info') {
  session.sentinel = session.sentinel || []
  session.sentinel.unshift({ at: nowIso(), text, level })
  session.sentinel = session.sentinel.slice(0, 80)
}
function enrich(session) {
  session = applyStall({ ...session })
  session = applyNudgeExpiry(session)
  session.openQuestions = openQuestionCount(session)
  session.needsInput = session.openQuestions > 0 || session.status === 'needs_input'
  // Fleet model: operator talks only to ORCH; each lane is a numbered sub-agent (SA-N ≡ Chat N)
  const lane = Number(session.lane) || 0
  session.subAgentNo = lane
  session.subAgentId = lane ? `SA-${lane}` : (session.subAgentId || 'SA-?')
  session.agentRef = lane
    ? `SA-${lane} · Chat ${lane}`
    : (session.chatLabel || session.sessionId || 'agent')
  session.role = session.role || 'subagent'
  // Real folder name from repoPath (basename), falling back to repoId — NOT the sess_-derived branch
  session.repoName = repoNameOf(session)
  // Live code-worker process only — UI must not show a worker glyph on a dead pid.
  // (status can stay "running"/"blocked" in JSON long after the runner exits.)
  const alive = isPidAlive(session.pid)
  session.workerAlive = alive
  session.pidAlive = alive
  if (!alive && session.pid) {
    session.workerDead = true
  } else {
    session.workerDead = false
  }
  return session
}

// Derive a clean repo folder name from repoPath; fall back to repoId. Pure.
// Walks past showtime worktree leaves (…/.worktrees-showtime/sess_*) to the real repo folder.
function repoNameFromPath(repoPath) {
  let p = String(repoPath || '').replace(/[\\/]+$/, '')
  if (!p) return ''
  const parts = p.split(/[\\/]/).filter(Boolean)
  if (!parts.length) return ''
  // …/<repo>/.worktrees-showtime/<sess_*>  → <repo>
  const wtIdx = parts.findIndex((x) => /^\.worktrees-showtime$/i.test(x))
  if (wtIdx > 0) return parts[wtIdx - 1]
  const leaf = parts[parts.length - 1]
  // bare sess leaf without worktree marker — not a real repo name
  if (/^sess_[a-zA-Z0-9]+$/i.test(leaf)) {
    if (parts.length >= 2) return parts[parts.length - 2]
    return ''
  }
  return leaf
}

function repoNameOf(session) {
  const fromPath = repoNameFromPath(session && session.repoPath)
  if (fromPath && !/^sess_/i.test(fromPath) && fromPath !== 'repo') return fromPath
  const id = (session && session.repoId) || ''
  if (id && id !== 'repo' && !/^sess_/i.test(id)) return id
  return fromPath || id || ''
}

/** Hard join gate: board lanes need sessionId + real repo name + branch. */
function assertJoinIdentity(body, existing) {
  const sessionId = String(body.sessionId || existing?.sessionId || '').trim()
  const branch = String(body.branch || existing?.branch || '').trim()
  const repoPath = String(body.repoPath || existing?.repoPath || '').trim()
  let repoId = String(body.repoId || existing?.repoId || '').trim()
  const derived = repoNameFromPath(repoPath)
  if (!repoId || repoId === 'repo' || /^sess_/i.test(repoId)) {
    if (derived) repoId = derived
  }
  const errors = []
  if (!sessionId || sessionId.length < 4) errors.push('sessionId required')
  if (!repoId || repoId === 'repo' || /^sess_/i.test(repoId)) {
    errors.push('repo name required (real folder, not sess id)')
  }
  if (!branch || branch === 'HEAD') errors.push('branch required')
  if (errors.length) {
    const err = new Error(errors.join('; '))
    err.statusCode = 400
    err.code = 'JOIN_IDENTITY'
    throw err
  }
  return { sessionId, repoId, branch, repoPath }
}


function joinPath(id) {
  const safe = String(id || '').replace(/[^a-zA-Z0-9._-]/g, '_')
  return path.join(JOIN_DIR, `${safe}.json`)
}
function listJoinRequests(status = null) {
  if (!fs.existsSync(JOIN_DIR)) return []
  return fs
    .readdirSync(JOIN_DIR)
    .filter((f) => f.endsWith('.json'))
    .map((f) => readJsonSafe(path.join(JOIN_DIR, f)))
    .filter(Boolean)
    .filter((j) => (status ? j.status === status : true))
    .sort((a, b) => String(a.createdAt || '').localeCompare(String(b.createdAt || '')))
}
function writeJoinBeacon() {
  const pending = listJoinRequests('pending')
  const payload = {
    op: 'showtime-join-pending',
    at: nowIso(),
    count: pending.length,
    boardUrl: `http://127.0.0.1:${serverPort}/`,
    requests: pending.map((j) => ({
      id: j.id,
      sessionId: j.sessionId,
      repoId: j.repoId,
      branch: j.branch,
      ledgerTitle: j.ledgerTitle || null,
      createdAt: j.createdAt,
    })),
  }
  try {
    writeJson(JOIN_BEACON, payload)
  } catch { /* ignore */ }
  return payload
}
/**
 * Two-way join gate: chats request in; operator approves (board / extension).
 * Never hang a model for minutes — request is durable while pending.
 */

/** Canonical repo root: strip showtime/claude worktree leaves. */
function normalizeRepoRoot(repoPath) {
  let p = String(repoPath || '').replace(/\\/g, '/').replace(/\/+$/, '')
  p = p.replace(/\/\.worktrees-showtime\/[^/]+$/i, '')
  p = p.replace(/\/\.claude\/worktrees\/[^/]+$/i, '')
  p = p.replace(/\/\.codex-worktrees\/[^/]+$/i, '')
  return p
}

/** Walk parents for .git (dir or file) so monorepo packages share one project key. */
function resolveGitRoot(repoPath) {
  let cur = normalizeRepoRoot(repoPath)
  if (!cur) return ''
  // Windows path for fs
  let disk = cur.replace(/\//g, path.sep)
  for (let i = 0; i < 14; i++) {
    const gitPath = path.join(disk, '.git')
    if (fs.existsSync(gitPath)) {
      return disk.replace(/\\/g, '/')
    }
    const parent = path.dirname(disk)
    if (!parent || parent === disk) break
    disk = parent
  }
  return normalizeRepoRoot(repoPath)
}

function normalizeTitle(t) {
  return String(t || '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .replace(/[^\w\s.+#/-]/g, '')
    .trim()
}

/**
 * Stable identity for "is this the same job?":
 * - ledgerKey: immutable fingerprint from FIRST arm (hash at arm time)
 * - current ledgerHash mutates as slices complete → MUST NOT be sole dedupe key
 * - same git root + same ledger title → same epic even if hashes drifted
 * - SA-N is just lane display (Chat N); never used as identity
 */
function findSessionDuplicate(body = {}, ident = {}) {
  const hash = String(body.ledgerHash || ident.ledgerHash || body.ledgerKey || '').trim().toLowerCase()
  const ledgerKey = String(body.ledgerKey || '').trim().toLowerCase()
  const sid = String(ident.sessionId || body.sessionId || '').trim()
  const root = resolveGitRoot(body.primaryRepoPath || ident.primaryRepoPath || ident.repoPath || body.repoPath || '')
  const title = normalizeTitle(body.ledgerTitle || '')
  const sessions = listSessions().filter((s) => s && s.sessionId !== sid)
  const live = (s) => {
    const st = String(s.status || '').toLowerCase()
    return st !== 'complete' && st !== 'completed' && st !== 'done'
  }

  // 1) Immutable arm key (preferred)
  if (ledgerKey) {
    const byKey = sessions.find(
      (s) => live(s) && String(s.ledgerKey || s.ledgerHash || '').toLowerCase() === ledgerKey,
    )
    if (byKey) return { session: byKey, reason: 'same-ledger-key' }
  }

  // 2) Exact current/original hash match
  if (hash) {
    const byHash = sessions.find(
      (s) =>
        live(s) &&
        (String(s.ledgerHash || '').toLowerCase() === hash ||
          String(s.ledgerKey || '').toLowerCase() === hash),
    )
    if (byHash) return { session: byHash, reason: 'same-ledger-hash' }
  }

  // 3) Same git root + same title (survives hash drift after slice work)
  if (root && title && title !== '.' && title.length > 3) {
    const byTitle = sessions.find((s) => {
      if (!live(s)) return false
      const sRoot = resolveGitRoot(s.primaryRepoPath || s.repoPath || '')
      if (!sRoot || sRoot.toLowerCase() !== root.toLowerCase()) return false
      return normalizeTitle(s.ledgerTitle) === title
    })
    if (byTitle) return { session: byTitle, reason: 'same-git-root-title' }
  }

  // 4) Same normalized path (worktree-stripped) + title
  const bare = normalizeRepoRoot(ident.repoPath || body.repoPath || '')
  if (bare && title && title.length > 3) {
    const byPathTitle = sessions.find((s) => {
      if (!live(s)) return false
      const sBare = normalizeRepoRoot(s.repoPath || '')
      if (sBare.toLowerCase() !== bare.toLowerCase()) return false
      return normalizeTitle(s.ledgerTitle) === title
    })
    if (byPathTitle) return { session: byPathTitle, reason: 'same-path-title' }
  }

  return null
}


// --- Fleet party API (one ORCH per ledger) ---
let Fleet = null
function getFleet() {
  if (!Fleet) {
    Fleet = createFleetApi({
      fleetsDir: FLEETS_DIR,
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
    })
  }
  return Fleet
}

function createJoinRequest(body = {}) {
  const ident = assertJoinIdentity(body, null)
  const existingSess = readJsonSafe(sessionPath(ident.sessionId))
  if (existingSess) {
    return {
      ok: true,
      status: 'already_on_board',
      request: null,
      session: enrich(existingSess),
    }
  }
  // Same ledger already has a lane (different sessionId / worktree) → attach, don't twin
  const dup = findSessionDuplicate(body, ident)
  if (dup && dup.session) {
    return {
      ok: true,
      status: 'already_on_board',
      request: null,
      session: enrich(dup.session),
      deduped: true,
      dedupeReason: dup.reason,
      note: 'Another chat already owns this ledger on the board — join that lane, do not spawn a twin.',
    }
  }
  // Idempotent: same sessionId still pending → return it
  const prior = listJoinRequests().find(
    (j) => j.sessionId === ident.sessionId && (j.status === 'pending' || j.status === 'approved'),
  )
  if (prior && prior.status === 'approved' && prior.sessionId) {
    let s = readJsonSafe(sessionPath(prior.sessionId))
    if (!s) {
      // Board lost the lane file (restart race / wipe) but operator already approved —
      // re-materialize without a second Approve.
      s = registerSession({
        sessionId: prior.sessionId,
        repoId: ident.repoId || prior.repoId,
        repoPath: ident.repoPath || prior.repoPath || body.repoPath,
        branch: ident.branch || prior.branch,
        ledgerTitle: body.ledgerTitle || prior.ledgerTitle,
        ledgerPath: body.ledgerPath || prior.ledgerPath,
        ledgerHash: body.ledgerHash || prior.ledgerHash,
        logPath: body.logPath || prior.logPath,
        pid: body.pid ?? prior.pid,
        status: body.status || prior.statusDesired || 'running',
        alarms: body.alarms || prior.alarms || undefined,
        timer: body.timer || prior.timer || undefined,
      })
      prior.updatedAt = nowIso()
      prior.rematerializedAt = nowIso()
      prior.lane = s.lane
      prior.chatLabel = s.chatLabel
      writeJson(joinPath(prior.id), prior)
      writeJoinBeacon()
      broadcast('join_resolved', { id: prior.id, status: 'approved', session: s, request: prior, rematerialized: true })
    }
    return { ok: true, status: 'approved', request: prior, session: enrich(s) }
  }
  if (prior && prior.status === 'pending') {
    // Refresh identity fields on re-request
    prior.repoId = ident.repoId
    prior.repoPath = ident.repoPath || body.repoPath || prior.repoPath
    prior.branch = ident.branch
    prior.ledgerTitle = body.ledgerTitle || prior.ledgerTitle
    prior.ledgerPath = body.ledgerPath || prior.ledgerPath
    prior.ledgerHash = body.ledgerHash || prior.ledgerHash
    prior.updatedAt = nowIso()
    prior.pingCount = (prior.pingCount || 0) + 1
    writeJson(joinPath(prior.id), prior)
    writeJoinBeacon()
    broadcast('join_request', prior)
    return { ok: true, status: 'pending', request: prior, session: null }
  }

  const id = uid('join')
  const req = {
    id,
    status: 'pending', // pending | approved | denied | expired
    sessionId: ident.sessionId,
    repoId: ident.repoId,
    repoPath: ident.repoPath || body.repoPath || '',
    branch: ident.branch,
    ledgerTitle: body.ledgerTitle || null,
    ledgerPath: body.ledgerPath || null,
    ledgerHash: body.ledgerHash || null,
    logPath: body.logPath || null,
    pid: body.pid ?? null,
    statusDesired: body.status || 'running',
    alarms: body.alarms || null,
    timer: body.timer || null,
    note: body.note || body.reason || null,
    host: body.host || null,
    createdAt: nowIso(),
    updatedAt: nowIso(),
    pingCount: 1,
    resolvedAt: null,
    resolvedBy: null,
    denyReason: null,
  }
  writeJson(joinPath(id), req)
  writeJoinBeacon()
  broadcast('join_request', req)
  return { ok: true, status: 'pending', request: req, session: null }
}
function approveJoinRequest(id, { by = 'operator' } = {}) {
  const file = joinPath(id)
  const jr = readJsonSafe(file)
  if (!jr) {
    const err = new Error('join request not found')
    err.statusCode = 404
    err.code = 'NOT_FOUND'
    throw err
  }
  if (jr.status === 'approved') {
    let s = readJsonSafe(sessionPath(jr.sessionId))
    if (!s) {
      s = registerSession({
        sessionId: jr.sessionId,
        repoId: jr.repoId,
        repoPath: jr.repoPath,
        branch: jr.branch,
        ledgerTitle: jr.ledgerTitle,
        ledgerPath: jr.ledgerPath,
        ledgerHash: jr.ledgerHash,
        logPath: jr.logPath,
        pid: jr.pid,
        status: jr.statusDesired || 'running',
        alarms: jr.alarms || undefined,
        timer: jr.timer || undefined,
      })
      jr.rematerializedAt = nowIso()
      jr.lane = s.lane
      jr.chatLabel = s.chatLabel
      jr.updatedAt = nowIso()
      writeJson(file, jr)
      writeJoinBeacon()
      broadcast('join_resolved', { id: jr.id, status: 'approved', session: s, request: jr, rematerialized: true })
    }
    return { ok: true, status: 'approved', request: jr, session: enrich(s) }
  }
  if (jr.status === 'denied') {
    const err = new Error('join request was denied')
    err.statusCode = 409
    err.code = 'DENIED'
    throw err
  }
  const body = {
    sessionId: jr.sessionId,
    repoId: jr.repoId,
    repoPath: jr.repoPath,
    branch: jr.branch,
    ledgerTitle: jr.ledgerTitle,
    ledgerPath: jr.ledgerPath,
    ledgerHash: jr.ledgerHash,
    logPath: jr.logPath,
    pid: jr.pid,
    status: jr.statusDesired || 'running',
    alarms: jr.alarms || undefined,
    timer: jr.timer || undefined,
  }
  // If this ledger is already on the board under another session, attach there
  // (Approve must not create Chat 5 twin of Chat 3).
  const dup = findSessionDuplicate(body, {
    sessionId: jr.sessionId,
    repoId: jr.repoId,
    repoPath: jr.repoPath,
    branch: jr.branch,
  })
  let session
  if (dup && dup.session) {
    session = enrich(dup.session)
    jr.deduped = true
    jr.dedupeReason = dup.reason
    jr.attachedSessionId = dup.session.sessionId
  } else {
    session = registerSession(body)
  }
  jr.status = 'approved'
  jr.resolvedAt = nowIso()
  jr.resolvedBy = by
  jr.updatedAt = nowIso()
  jr.lane = session.lane
  jr.chatLabel = session.chatLabel
  writeJson(file, jr)
  writeJoinBeacon()
  broadcast('join_resolved', { id: jr.id, status: 'approved', session, request: jr })
  return { ok: true, status: 'approved', request: jr, session }
}
function denyJoinRequest(id, { by = 'operator', reason = '' } = {}) {
  const file = joinPath(id)
  const jr = readJsonSafe(file)
  if (!jr) {
    const err = new Error('join request not found')
    err.statusCode = 404
    err.code = 'NOT_FOUND'
    throw err
  }
  if (jr.status === 'approved') {
    const err = new Error('already approved — unregister the lane to remove')
    err.statusCode = 409
    err.code = 'ALREADY_APPROVED'
    throw err
  }
  jr.status = 'denied'
  jr.denyReason = reason || 'denied by operator'
  jr.resolvedAt = nowIso()
  jr.resolvedBy = by
  jr.updatedAt = nowIso()
  writeJson(file, jr)
  writeJoinBeacon()
  broadcast('join_resolved', { id: jr.id, status: 'denied', request: jr })
  return { ok: true, status: 'denied', request: jr }
}

function registerSession(body) {
  const existingPreview = body.sessionId ? readJsonSafe(sessionPath(String(body.sessionId).trim())) : null
  const ident = assertJoinIdentity(body, existingPreview)
  const sessionId = ident.sessionId
  let existing = existingPreview || readJsonSafe(sessionPath(sessionId))
  // Collapse twins: same ledger hash already live under another sessionId
  if (!existing) {
    const dup = findSessionDuplicate(body, ident)
    if (dup && dup.session) {
      // Heartbeat-style update onto the canonical lane instead of a new card
      const canon = { ...body, sessionId: dup.session.sessionId }
      return registerSession(canon)
    }
  }
  const ledgerPath = body.ledgerPath || existing?.ledgerPath || null
  let todos = body.todo
  if ((!todos || !todos.length) && ledgerPath) todos = parseLedgerTodos(ledgerPath)
  todos = todos || existing?.todo || []
  const counts = body.counts || deriveCounts(todos)
  const slice = body.slice || activeSlice(todos)
  const total = counts.pending + counts.inProgress + counts.done + counts.blocked + (counts.standby || 0)
  const done = counts.done
  const progress = total > 0 ? done / total : 0
  // Party handshake: every worker belongs to a fleet (one ORCH + one ledger).
  const primaryRepoPath =
    body.primaryRepoPath || existing?.primaryRepoPath || ident.repoPath || body.repoPath || ''
  const ledgerKey =
    existing?.ledgerKey || body.ledgerKey || body.ledgerHash || existing?.ledgerHash || null
  let fleetMeta = null
  try {
    const ens = getFleet().ensureFleet({
      ...body,
      repoId: ident.repoId,
      repoPath: ident.repoPath || body.repoPath,
      primaryRepoPath,
      ledgerKey,
      ledgerHash: body.ledgerHash || ledgerKey,
      ledgerTitle: body.ledgerTitle || existing?.ledgerTitle,
      branch: ident.branch,
    })
    fleetMeta = ens.fleet
  } catch (e) {
    if (e.code === 'LEDGER_HAS_ORCH' && e.fleet) {
      fleetMeta = e.fleet
    } else {
      throw e
    }
  }

  const lane = existing?.lane || body.lane || nextLane()
  let localNo = existing?.subAgentNo || existing?.localNo || null
  let localSa = existing?.subAgentId || null
  let localChat = existing?.chatLabel || null
  if (!existing && fleetMeta) {
    const att = getFleet().attachWorkerToFleet(fleetMeta, { sessionId })
    localNo = att.localNo
    localSa = att.subAgentId
    localChat = att.chatLabel
    fleetMeta = att.fleet
  }

  const session = {
    sessionId,
    chatLabel: localChat || existing?.chatLabel || body.chatLabel || `Chat ${lane}`,
    lane,
    // Local SA-N within fleet (party); global lane still unique for board sort
    localNo: localNo || lane,
    subAgentNo: localNo || lane,
    subAgentId: localSa || `SA-${lane}`,
    role: body.role === 'orch' ? 'orch' : 'subagent',
    fleetId: fleetMeta?.fleetId || existing?.fleetId || body.fleetId || null,
    orchSessionId: fleetMeta?.orchSessionId || existing?.orchSessionId || null,
    repoId: ident.repoId,
    repoPath: ident.repoPath || body.repoPath || existing?.repoPath || '',
    branch: ident.branch,
    pid: body.pid ?? existing?.pid ?? null,
    // ledgerKey = arm-time identity (stable). ledgerHash may drift as slices complete.
    ledgerKey,
    ledgerHash: body.ledgerHash || existing?.ledgerHash || null,
    ledgerTitle: body.ledgerTitle || existing?.ledgerTitle || null,
    primaryRepoPath,
    status: body.status || existing?.status || 'running',
    stopReason: body.stopReason ?? existing?.stopReason ?? null,
    slice,
    counts,
    todo: todos,
    progress,
    timer: {
      estimateSec: body.timer?.estimateSec ?? existing?.timer?.estimateSec ?? Math.max(600, (total - done) * 600),
      elapsedActiveSec: body.timer?.elapsedActiveSec ?? existing?.timer?.elapsedActiveSec ?? 0,
      running: body.timer?.running ?? true,
      startedAt: body.timer?.startedAt || existing?.timer?.startedAt || nowIso(),
      lastProgressAt: body.timer?.lastProgressAt || nowIso(),
      sliceStartedAt: body.timer?.sliceStartedAt || existing?.timer?.sliceStartedAt || nowIso(),
      completedSliceDurations: body.timer?.completedSliceDurations || existing?.timer?.completedSliceDurations || [],
    },
    alarms: {
      stallAfterSec: body.alarms?.stallAfterSec ?? existing?.alarms?.stallAfterSec ?? 900,
      completeEnabled: body.alarms?.completeEnabled ?? true,
      stallEnabled: body.alarms?.stallEnabled ?? true,
    },
    credit: { skill: 'autopro', product: 'Looplet', byline: 'Show Time - Looplet' },
    stats: mergeStats(existing?.stats, body.stats),
    sentinel: existing?.sentinel || [],
    questions: existing?.questions || [],
    notes: existing?.notes || [],
    steers: existing?.steers || [],
    bookmarks: existing?.bookmarks || body.bookmarks || [],
    ledgerPath,
    handoverPath: body.handoverPath || existing?.handoverPath || null,
    logPath: body.logPath || existing?.logPath || null,
    tipIndex: existing?.tipIndex ?? 0,
    updatedAt: nowIso(),
    createdAt: existing?.createdAt || nowIso(),
  }
  if (!existing) {
    session.chatLabel = `Chat ${lane}`
    session.subAgentNo = lane
    session.subAgentId = `SA-${lane}`
    pushSentinel(
      session,
      `Fleet ${session.fleetId || '—'} ·  () under ORCH for  · one ledger per ORCH`,
      'info',
    )
  }
  writeJson(sessionPath(sessionId), session)
  const all = listSessions().map(enrich)
  broadcast('sessions', all)
  touchIdleTimer()
  return enrich(session)
}

function heartbeatSession(sessionId, body = {}) {
  const file = sessionPath(sessionId)
  const existing = readJsonSafe(file)
  if (!existing) return null

  if (body.ledgerPath || existing.ledgerPath) {
    const lp = body.ledgerPath || existing.ledgerPath
    const todos = parseLedgerTodos(lp)
    if (todos.length) {
      existing.todo = todos
      existing.counts = deriveCounts(todos)
      existing.slice = activeSlice(todos)
      const total =
        existing.counts.pending +
        existing.counts.inProgress +
        existing.counts.done +
        existing.counts.blocked
      existing.progress = total > 0 ? existing.counts.done / total : 0
    }
  }

  if (body.status) existing.status = body.status
  if (body.stopReason !== undefined) existing.stopReason = body.stopReason
  if (body.pid != null) existing.pid = body.pid
  // Never wipe join identity with empty patches
  if (body.branch && String(body.branch).trim()) existing.branch = String(body.branch).trim()
  if (body.repoPath && String(body.repoPath).trim()) existing.repoPath = String(body.repoPath).trim()
  if (body.repoId && String(body.repoId).trim() && body.repoId !== 'repo' && !/^sess_/i.test(body.repoId)) {
    existing.repoId = String(body.repoId).trim()
  }
  if (body.ledgerHash) existing.ledgerHash = body.ledgerHash
  if (body.ledgerTitle) existing.ledgerTitle = body.ledgerTitle
  if (body.handoverPath) existing.handoverPath = body.handoverPath
  if (body.counts) existing.counts = body.counts
  if (body.slice) existing.slice = body.slice
  if (body.todo) existing.todo = body.todo
  if (body.stats) existing.stats = mergeStats(existing.stats, body.stats)
  if (body.bookmarks) existing.bookmarks = body.bookmarks

  if (body.sentinelEntry) {
    pushSentinel(existing, body.sentinelEntry.text || body.sentinelEntry, body.sentinelEntry.level || 'info')
  }

  const progress = body.progress === true || body.progressEvent === true
  if (progress || body.status === 'running') {
    existing.timer = existing.timer || {}
    existing.timer.lastProgressAt = nowIso()
    existing.timer.running = true
    if (['stalled', 'paused'].includes(existing.status) && body.status !== 'paused') {
      existing.status = body.status || 'running'
      if (existing.status === 'running') existing.stopReason = null
    }
    // Nudge listen window: any live progress acks reconnect
    if (existing.nudge && existing.nudge.status === 'listening') {
      existing.nudge.status = 'acked'
      existing.nudge.ackedAt = nowIso()
      existing.escalate = null
      pushSentinel(existing, 'Nudge acked — connection re-established', 'info')
    }
  }
  if (body.timer) existing.timer = { ...existing.timer, ...body.timer }

  if (body.sliceComplete === true) {
    const started = existing.timer?.sliceStartedAt
    if (started) {
      const dur = Math.max(1, Math.round((Date.now() - new Date(started).getTime()) / 1000))
      existing.timer.completedSliceDurations = [...(existing.timer.completedSliceDurations || []), dur].slice(-20)
    }
    existing.timer.sliceStartedAt = nowIso()
    existing.timer.lastProgressAt = nowIso()
    const avg =
      (existing.timer.completedSliceDurations || []).reduce((a, b) => a + b, 0) /
      Math.max(1, (existing.timer.completedSliceDurations || []).length)
    const remaining = (existing.counts?.pending || 0) + (existing.counts?.inProgress || 0)
    existing.timer.estimateSec = Math.max(60, Math.round(remaining * Math.max(60, avg || 600)))
    pushSentinel(existing, `Slice complete tick — ${existing.slice?.id || 'n/a'} progress updated`, 'info')
  }

  if (body.status === 'paused') {
    existing.timer.running = false
    existing.tipIndex = ((existing.tipIndex || 0) + 1) % 20
  }
  if (body.status === 'complete') {
    existing.status = 'complete'
    existing.timer.running = false
    existing.progress = 1
    pushSentinel(existing, 'Lane COMPLETE — final check finished', 'info')
    // Operator handover folder + auto-deliver; then wipe lane off the board
    try {
      const ho = body.handoverText
        ? createHandover({
            id: `ho_${String(sessionId).replace(/[^a-zA-Z0-9]/g, '').slice(0, 16)}_complete`,
            force: true,
            sessionId,
            lane: existing.lane,
            subAgentId: existing.subAgentId || `SA-${existing.lane}`,
            chatLabel: existing.chatLabel || `Chat ${existing.lane}`,
            repoId: existing.repoId,
            topic: existing.ledgerTitle || existing.repoId,
            text: body.handoverText,
            handoverPath: body.handoverPath || existing.handoverPath || null,
            reason: 'complete',
          })
        : createHandoverFromSession(existing, 'complete')
      if (ho) flushHandovers({ onlyIds: [ho.id] })
    } catch (e) {
      console.error('[showtime] handover on complete failed', e.message || e)
    }
    scheduleSessionWipe(sessionId, COMPLETE_WIPE_MS)
  }
  if (body.status === 'stalled' || body.status === 'blocked') {
    existing.timer.running = false
  }

  existing.updatedAt = nowIso()
  writeJson(file, existing)
  const enriched = enrich(existing)
  broadcast('sessions', listSessions().map(enrich))
  if (body.status === 'complete') broadcast('complete', enriched)
  if (enriched.status === 'stalled') broadcast('stall', enriched)
  if (enriched.needsInput) broadcast('needs_input', enriched)
  touchIdleTimer()
  return enriched
}

function unregisterSession(sessionId) {
  try {
    const prev = readJsonSafe(sessionPath(sessionId))
    if (prev?.fleetId) getFleet().removeWorkerFromFleet(prev.fleetId, sessionId)
  } catch { /* ignore */ }

  if (wipeTimers.has(sessionId)) {
    clearTimeout(wipeTimers.get(sessionId))
    wipeTimers.delete(sessionId)
  }
  const file = sessionPath(sessionId)
  if (fs.existsSync(file)) fs.unlinkSync(file)
  broadcast('sessions', listSessions().map(enrich))
  touchIdleTimer()
  return { ok: true }
}

function isPidAlive(pid) {
  const n = Number(pid)
  if (!n || n <= 0) return false
  try {
    process.kill(n, 0)
    return true
  } catch {
    return false
  }
}

function handoverPath(id) {
  const safe = String(id).replace(/[^a-zA-Z0-9._-]/g, '_')
  return path.join(HANDOVER_DIR, `${safe}.json`)
}

function listHandovers() {
  if (!fs.existsSync(HANDOVER_DIR)) return []
  return fs
    .readdirSync(HANDOVER_DIR)
    .filter((f) => f.endsWith('.json'))
    .map((f) => readJsonSafe(path.join(HANDOVER_DIR, f)))
    .filter(Boolean)
    .sort((a, b) => String(b.at || '').localeCompare(String(a.at || '')))
}

function sessionHandoverText(s, reason = 'update') {
  const lane = s.lane || '?'
  const sa = s.subAgentId || `SA-${lane}`
  const c = s.counts || {}
  const done = c.done || 0
  const pend = (c.pending || 0) + (c.inProgress || 0)
  const slice = s.slice ? `${s.slice.id} ${s.slice.title || ''}`.trim() : '—'
  const lines = [
    `Handover · ${sa} · Chat ${lane}`,
    `Repo: ${s.repoId || '—'} · branch: ${s.branch || '—'}`,
    `Ledger: ${s.ledgerTitle || '—'} · hash: ${s.ledgerHash || '—'}`,
    s.handoverPath ? `Repo handover: ${s.handoverPath}` : null,
    `Status: ${s.status || '—'} · reason: ${reason}`,
    `Progress: ${done} done · ${pend} remaining · open Q: ${openQuestionCount(s)}`,
    `Slice: ${slice}`,
    s.stopReason ? `Stop: ${s.stopReason}` : null,
    `Session: ${s.sessionId}`,
    `At: ${nowIso()}`,
  ].filter(Boolean)
  return lines.join('\n')
}

function createHandover(body = {}) {
  const id = body.id || uid('ho')
  const existing = readJsonSafe(handoverPath(id))
  if (existing && existing.status === 'pending' && !body.force) return existing
  const note = {
    id,
    sessionId: body.sessionId || existing?.sessionId || null,
    lane: body.lane ?? existing?.lane ?? null,
    subAgentId: body.subAgentId || existing?.subAgentId || (body.lane ? `SA-${body.lane}` : null),
    chatLabel: body.chatLabel || existing?.chatLabel || (body.lane ? `Chat ${body.lane}` : null),
    repoId: body.repoId || existing?.repoId || null,
    topic: body.topic || existing?.topic || null,
    text: String(body.text || existing?.text || '').trim(),
    reason: body.reason || existing?.reason || 'handover',
    handoverPath: body.handoverPath || existing?.handoverPath || null,
    status: 'pending', // pending → delivered (shown to operator / outbox)
    at: body.at || existing?.at || nowIso(),
    deliveredAt: null,
    deliveredHow: null,
  }
  if (!note.text) return null
  writeJson(handoverPath(id), note)
  broadcast('handover', note)
  return note
}

function createHandoverFromSession(s, reason = 'complete') {
  if (!s) return null
  // One pending note per session+reason window (overwrite pending for same session)
  const existing = listHandovers().find(
    (h) => h.sessionId === s.sessionId && h.status === 'pending' && h.reason === reason,
  )
  const id = existing?.id || `ho_${String(s.sessionId).replace(/[^a-zA-Z0-9]/g, '').slice(0, 16)}_${reason}`
  return createHandover({
    id,
    force: true,
    sessionId: s.sessionId,
    lane: s.lane,
    subAgentId: s.subAgentId || `SA-${s.lane}`,
    chatLabel: s.chatLabel || `Chat ${s.lane}`,
    repoId: s.repoId,
    topic: s.slice ? `${s.slice.id} ${s.slice.title || ''}`.trim() : s.repoId,
    text: sessionHandoverText(s, reason),
    reason,
  })
}

function appendOutbox(note) {
  const block = [
    '',
    `## ${note.at || nowIso()} · ${note.subAgentId || 'SA-?'} · ${note.chatLabel || ''} · ${note.repoId || ''}`,
    `status: delivered · reason: ${note.reason || 'handover'} · id: ${note.id}`,
    note.handoverPath ? `repo handover: ${note.handoverPath}` : null,
    '',
    note.text || '',
    '',
    '---',
    '',
  ].filter((line) => line !== null).join('\n')
  try {
    if (!fs.existsSync(HANDOVER_OUTBOX)) {
      fs.writeFileSync(
        HANDOVER_OUTBOX,
        '# Show Time · Handover outbox\n\nOperator-facing notes from ORCH / sub-agents. Auto-appended on deliver.\n',
        'utf8',
      )
    }
    fs.appendFileSync(HANDOVER_OUTBOX, block, 'utf8')
  } catch (e) {
    console.error('[showtime] outbox write failed', e.message || e)
  }
}

/** Mark pending handovers delivered (outbox + board). Returns newly delivered notes. */
function flushHandovers({ onlyIds = null } = {}) {
  const delivered = []
  for (const h of listHandovers()) {
    if (h.status !== 'pending') continue
    if (onlyIds && !onlyIds.includes(h.id)) continue
    h.status = 'delivered'
    h.deliveredAt = nowIso()
    h.deliveredHow = 'flush'
    writeJson(handoverPath(h.id), h)
    appendOutbox(h)
    delivered.push(h)
    broadcast('handover', h)
  }
  if (delivered.length) broadcast('handovers', listHandovers())
  return delivered
}

function scheduleSessionWipe(sessionId, ms = COMPLETE_WIPE_MS) {
  if (wipeTimers.has(sessionId)) clearTimeout(wipeTimers.get(sessionId))
  const t = setTimeout(() => {
    wipeTimers.delete(sessionId)
    try {
      unregisterSession(sessionId)
      broadcast('wiped', { sessionId, at: nowIso() })
    } catch {}
  }, Math.max(500, ms))
  wipeTimers.set(sessionId, t)
}

/**
 * Production boot sweep:
 * 1) complete / dead-stale sessions → handover (if missing) → wipe from board
 * 2) flush any pending handovers to operator outbox
 */
function preflightSweep(opts = {}) {
  const staleAfterMs = Number(opts.staleAfterMs || STALE_AFTER_MS)
  const currentLedgerHash = opts.ledgerHash ? String(opts.ledgerHash) : ''
  const wipeComplete = opts.wipeComplete !== false
  const now = Date.now()
  const wiped = []
  const kept = []
  const handovers = []

  for (const raw of listSessions()) {
    const s = enrich(raw)
    const age = s.updatedAt ? now - new Date(s.updatedAt).getTime() : Infinity
    const alive = isPidAlive(s.pid)
    const isComplete = s.status === 'complete'
    const differentLedger = currentLedgerHash && s.ledgerHash && s.ledgerHash !== currentLedgerHash
    const isStaleDead = !alive && age >= staleAfterMs
    const isZombie = !alive && ['running', 'in-progress', 'queued', 'stalled', 'blocked', 'paused', 'needs_input'].includes(s.status) && age >= staleAfterMs

    if (isComplete && wipeComplete) {
      const ho = createHandoverFromSession(s, 'complete')
      if (ho) handovers.push(ho)
      unregisterSession(s.sessionId)
      wiped.push({ sessionId: s.sessionId, why: 'complete' })
      continue
    }
    if (isStaleDead || isZombie || (differentLedger && age >= staleAfterMs)) {
      const reason = differentLedger ? 'stale-different-ledger' : 'stale'
      const ho = createHandoverFromSession(s, reason)
      if (ho) handovers.push(ho)
      unregisterSession(s.sessionId)
      wiped.push({ sessionId: s.sessionId, why: reason, ageSec: Math.round(age / 1000), pidAlive: alive, ledgerHash: s.ledgerHash || null })
      continue
    }
    if (differentLedger) {
      kept.push({ sessionId: s.sessionId, why: 'different-ledger-active', ageSec: Math.round(age / 1000), pidAlive: alive, ledgerHash: s.ledgerHash || null })
    }
  }

  const flushed = flushHandovers()
  return {
    ok: true,
    wiped,
    kept,
    handoversCreated: handovers.length,
    handoversFlushed: flushed.length,
    handovers: listHandovers().slice(0, 40),
    outbox: HANDOVER_OUTBOX,
    at: nowIso(),
  }
}

function addNote(sessionId, body) {
  const s = readJsonSafe(sessionPath(sessionId))
  if (!s) return null
  const note = {
    id: uid('n'),
    text: String(body.text || '').trim(),
    from: body.from || 'operator',
    at: nowIso(),
    sliceId: body.sliceId || s.slice?.id || null,
  }
  if (!note.text) return s
  s.notes = s.notes || []
  s.notes.unshift(note)
  s.notes = s.notes.slice(0, 100)
  s.updatedAt = nowIso()
  writeJson(sessionPath(sessionId), s)
  broadcast('sessions', listSessions().map(enrich))
  return enrich(s)
}

function addQuestion(sessionId, body) {
  const s = readJsonSafe(sessionPath(sessionId))
  if (!s) return null
  const q = {
    id: uid('q'),
    sliceId: body.sliceId || s.slice?.id || null,
    text: String(body.text || '').trim(),
    status: 'open',
    chips: body.chips || [],
    at: nowIso(),
  }
  if (!q.text) return s
  s.questions = s.questions || []
  s.questions.unshift(q)
  s.status = 'needs_input'
  s.stopReason = `Question: ${q.text.slice(0, 80)}`
  s.updatedAt = nowIso()
  pushSentinel(s, `Operator question opened on ${q.sliceId || 'lane'}: ${q.text.slice(0, 100)}`, 'warn')
  writeJson(sessionPath(sessionId), s)
  const e = enrich(s)
  broadcast('sessions', listSessions().map(enrich))
  broadcast('needs_input', e)
  return e
}

function answerQuestion(sessionId, qid, body) {
  const s = readJsonSafe(sessionPath(sessionId))
  if (!s) return null
  const q = (s.questions || []).find((x) => x.id === qid)
  if (!q) return enrich(s)
  q.status = 'answered'
  q.answer = String(body.answer || body.text || '').trim()
  q.answeredAt = nowIso()
  s.notes = s.notes || []
  s.notes.unshift({
    id: uid('n'),
    text: `Answered ${qid}: ${q.answer}`,
    from: 'operator',
    at: nowIso(),
    sliceId: q.sliceId,
  })
  const stillOpen = (s.questions || []).some((x) => x.status === 'open')
  if (!stillOpen && s.status === 'needs_input') {
    s.status = 'running'
    s.stopReason = null
  }
  s.updatedAt = nowIso()
  pushSentinel(s, `Question ${qid} answered`, 'info')
  writeJson(sessionPath(sessionId), s)
  broadcast('sessions', listSessions().map(enrich))
  return enrich(s)
}

function addSteer(sessionId, body) {
  const s = readJsonSafe(sessionPath(sessionId))
  if (!s) return null
  const steer = {
    id: uid('s'),
    target: body.target || body.sliceId || s.slice?.id || null,
    text: String(body.text || '').trim(),
    kind: body.kind || null,
    at: nowIso(),
    consumed: false,
  }
  if (!steer.text) return s
  s.steers = s.steers || []
  s.steers.unshift(steer)
  s.notes = s.notes || []
  s.notes.unshift({
    id: uid('n'),
    text: `STEER → ${steer.target || 'next'}: ${steer.text}`,
    from: 'operator',
    at: nowIso(),
    sliceId: steer.target,
  })
  s.updatedAt = nowIso()
  // durable file for runner
  const steerFile = path.join(STEER_DIR, `${sessionId}.jsonl`)
  fs.appendFileSync(steerFile, JSON.stringify(steer) + '\n', 'utf8')
  pushSentinel(s, `Steer queued for ${steer.target || 'next slice'}`, 'info')
  writeJson(sessionPath(sessionId), s)
  broadcast('sessions', listSessions().map(enrich))
  return enrich(s)
}

/** Operator reconnect ping: 30s listen window + durable steer for runner. */
function addNudge(sessionId, body = {}) {
  const s = readJsonSafe(sessionPath(sessionId))
  if (!s) return null
  const listenSec = Math.max(5, Math.min(120, Number(body.listenSec) || 30))
  const at = nowIso()
  const listenUntil = new Date(Date.now() + listenSec * 1000).toISOString()
  const alive = isPidAlive(s.pid)
  const canNudge = alive

  s.nudge = {
    id: uid('nudge'),
    at,
    listenUntil,
    status: 'listening',
    reason: 'reconnect',
    canNudge,
    listenSec,
  }

  // Durable signal for runner (same consume-steers path)
  const steer = {
    id: uid('s'),
    target: s.slice?.id || 'reconnect',
    text:
      'ORCH NUDGE: operator requested reconnect / re-establish. Heartbeat now, clear stall if working, resume slice loop.',
    kind: 'nudge',
    at,
    consumed: false,
  }
  s.steers = s.steers || []
  s.steers.unshift(steer)
  const steerFile = path.join(STEER_DIR, `${sessionId}.jsonl`)
  fs.appendFileSync(steerFile, JSON.stringify(steer) + '\n', 'utf8')

  s.notes = s.notes || []
  s.notes.unshift({
    id: uid('n'),
    text: `NUDGE · reconnect requested (${listenSec}s listen)`,
    from: 'operator',
    at,
  })

  if (s.status === 'stalled' && alive) {
    s.status = 'running'
    s.stopReason = null
    s.timer = { ...(s.timer || {}), running: true, lastProgressAt: at }
  }

  if (!canNudge) {
    s.escalate = {
      reason: 'cant_nudge',
      sessionId,
      subAgentId: s.subAgentId || `SA-${s.lane}`,
      lane: s.lane,
      at,
      detail: s.pid ? 'runner pid dead' : 'no runner pid',
    }
    pushSentinel(
      s,
      `NUDGE · cannot reconnect ${s.subAgentId || 'SA'} (${s.escalate.detail}) — ORCH CLICK HERE`,
      'warn',
    )
  } else {
    s.escalate = null
    pushSentinel(s, `NUDGE · reconnect requested (${listenSec}s listen)`, 'info')
  }

  s.updatedAt = at
  writeJson(sessionPath(sessionId), s)
  const enriched = enrich(s)
  broadcast('sessions', listSessions().map(enrich))
  try {
    getFleet().appendHomeInbox(s.primaryRepoPath || s.repoPath, {
      op: 'nudge',
      fleetId: s.fleetId || null,
      sessionId,
      subAgentId: s.subAgentId,
      text: steer.text,
      kind: 'nudge',
    })
  } catch { /* ignore inbox failures */ }
  broadcast('nudge', enriched)
  return enriched
}

/** Expire listen windows; escalate when reconnect never acked. */
function applyNudgeExpiry(session) {
  if (!session?.nudge || session.nudge.status !== 'listening') return session
  const until = session.nudge.listenUntil
  if (!until) return session
  if (Date.now() < new Date(until).getTime()) return session
  session.nudge.status = 'expired'
  const stagnant =
    session.status === 'stalled' ||
    session.status === 'blocked' ||
    !isPidAlive(session.pid)
  if (stagnant || session.nudge.canNudge === false) {
    session.escalate = {
      reason: 'cant_nudge',
      sessionId: session.sessionId,
      subAgentId: session.subAgentId || `SA-${session.lane}`,
      lane: session.lane,
      at: nowIso(),
      detail: 'nudge listen expired without ack',
    }
  }
  return session
}

function consumeSteers(sessionId) {
  const s = readJsonSafe(sessionPath(sessionId))
  if (!s) return { steers: [] }
  const open = (s.steers || []).filter((x) => !x.consumed)
  for (const st of open) st.consumed = true
  s.updatedAt = nowIso()
  writeJson(sessionPath(sessionId), s)
  const steerFile = path.join(STEER_DIR, `${sessionId}.jsonl`)
  if (fs.existsSync(steerFile)) {
    try {
      fs.renameSync(steerFile, steerFile + '.consumed.' + Date.now())
    } catch {}
  }
  return { steers: open }
}

async function handleApi(req, res, url) {
  if (req.method === 'OPTIONS') {
    // Deliberately no ACAO: cross-origin preflights must fail.
    res.writeHead(204)
    return res.end()
  }

  if (url.pathname === '/api/health') {
    // Same-origin token refresh: the board page holds window.__SHOWTIME_TOKEN__
    // from the boot it was SERVED on. If the server restarts (new token) the
    // open page's token goes stale and every /api/ call 401s → OFFLINE with no
    // recovery but a manual hard-reload. So health returns the CURRENT token —
    // but ONLY to a same-origin request (the board page itself), never to a
    // cross-site fetch, so the token's CSRF value is preserved. A cross-origin
    // page sends Sec-Fetch-Site: cross-site (or an Origin that isn't ours);
    // the board page's own fetch is same-origin (or no Origin on a nav-load).
    const sfs = String(req.headers['sec-fetch-site'] || '').toLowerCase()
    const origin = req.headers['origin']
    const selfOrigins = [`http://127.0.0.1:${serverPort}`, `http://localhost:${serverPort}`]
    const sameOrigin = (!sfs || sfs === 'same-origin' || sfs === 'none')
      && (!origin || selfOrigins.includes(origin))
    const payload = {
      ok: true,
      name: 'Show Time',
      product: 'Looplet',
      version: 2,
      sessions: listSessions().length,
      port: serverPort,
    }
    if (sameOrigin) payload.token = SERVER_TOKEN
    return send(res, 200, payload)
  }

  // Token gate for everything else under /api/.
  const presented = req.headers['x-showtime-token'] || url.searchParams.get('t') || ''
  if (presented !== SERVER_TOKEN) {
    return send(res, 401, { ok: false, error: 'missing or bad token' })
  }
  // Bodied requests must be JSON — a text/plain body is the no-preflight
  // cross-origin shape; nothing legitimate sends it.
  if (['POST', 'PUT', 'DELETE'].includes(req.method)) {
    const ct = String(req.headers['content-type'] || '')
    if (ct && !ct.toLowerCase().includes('application/json')) {
      return send(res, 415, { ok: false, error: 'content-type must be application/json' })
    }
  }

  if (url.pathname === '/api/mission' && req.method === 'GET') {
    const sessions = listSessions().map(enrich)
    return send(res, 200, { mission: missionRollup(sessions), sessions })
  }

  if (url.pathname === '/api/sessions' && req.method === 'GET') {
    const sessions = listSessions().map(enrich)
    let fleets = []
    try { fleets = getFleet().enrichFleetsWithSessions() } catch { fleets = [] }
    return send(res, 200, {
      sessions,
      fleets,
      mission: missionRollup(sessions),
      partyRule: 'one-orch-per-ledger',
    })
  }

  // Party fleets: one ORCH + workers per guest ledger
  if (url.pathname === '/api/fleets' && req.method === 'GET') {
    return send(res, 200, {
      ok: true,
      fleets: getFleet().enrichFleetsWithSessions(),
      partyRule: 'one-orch-per-ledger',
    })
  }

  if (url.pathname === '/api/fleets' && req.method === 'POST') {
    try {
      const body = await readBody(req)
      const ens = getFleet().ensureFleet(body)
      return send(res, 200, {
        ok: true,
        created: ens.created,
        attached: ens.attached,
        fleet: ens.fleet,
      })
    } catch (e) {
      return send(res, e.statusCode || 400, {
        ok: false,
        code: e.code || 'FLEET_ERROR',
        error: String(e.message || e),
        fleet: e.fleet || null,
      })
    }
  }

  const fleetLeave = url.pathname.match(/^\/api\/fleets\/([^/]+)\/leave$/)
  if (fleetLeave && req.method === 'POST') {
    try {
      const fid = decodeURIComponent(fleetLeave[1])
      const body = await readBody(req).catch(() => ({}))
      const left = getFleet().leaveFleet(fid, { reason: body.reason || 'left' })
      if (!left) return send(res, 404, { ok: false, error: 'fleet not found' })
      // Unregister worker sessions on the board
      for (const wid of left.workerIds || []) {
        try { unregisterSession(wid) } catch { /* ignore */ }
      }
      return send(res, 200, { ok: true, fleet: left.fleet, clearedWorkers: left.workerIds })
    } catch (e) {
      return send(res, 400, { ok: false, error: String(e.message || e) })
    }
  }

  // Two-way join gate: NEW lanes must be approved (POST /api/join-requests → approve).
  // Existing sessionId may re-register/update. Opt out: SHOWTIME_OPEN_REGISTER=1
  if (url.pathname === '/api/sessions' && req.method === 'POST') {
    try {
      const body = await readBody(req)
      const sid = String(body.sessionId || '').trim()
      const existing = sid ? readJsonSafe(sessionPath(sid)) : null
      const openReg = String(process.env.SHOWTIME_OPEN_REGISTER || '') === '1'
      if (!existing && !openReg) {
        // Allow only if this session already has an approved join request
        const approved = listJoinRequests().find(
          (j) => j.sessionId === sid && j.status === 'approved',
        )
        if (!approved) {
          return send(res, 403, {
            ok: false,
            code: 'JOIN_REQUIRES_APPROVAL',
            error: 'New lanes need operator approval. POST /api/join-requests then wait for approve (board or extension).',
          })
        }
      }
      return send(res, 200, { ok: true, session: registerSession(body) })
    } catch (e) {
      const code = e.code || (e.statusCode === 400 ? 'JOIN_IDENTITY' : 'ERROR')
      return send(res, e.statusCode || 400, {
        ok: false,
        code,
        error: String(e.message || e),
      })
    }
  }

  // --- Join requests (2FA-style operator gate) ---
  if (url.pathname === '/api/join-requests' && req.method === 'GET') {
    const status = url.searchParams.get('status') || null
    const requests = listJoinRequests(status)
    return send(res, 200, {
      ok: true,
      pending: requests.filter((r) => r.status === 'pending').length,
      requests,
    })
  }

  if (url.pathname === '/api/join-requests' && req.method === 'POST') {
    try {
      const body = await readBody(req)
      const result = createJoinRequest(body)
      return send(res, 200, result)
    } catch (e) {
      return send(res, e.statusCode || 400, {
        ok: false,
        code: e.code || 'JOIN_IDENTITY',
        error: String(e.message || e),
      })
    }
  }

  const joinM = url.pathname.match(/^\/api\/join-requests\/([^/]+)(?:\/(approve|deny))?$/)
  if (joinM) {
    const jid = decodeURIComponent(joinM[1])
    const jop = joinM[2] || ''
    if (req.method === 'GET' && !jop) {
      const jr = readJsonSafe(joinPath(jid))
      if (!jr) return send(res, 404, { ok: false, error: 'not found' })
      let session = null
      if (jr.status === 'approved' || jr.status === 'already_on_board') {
        const s = readJsonSafe(sessionPath(jr.sessionId))
        if (s) session = enrich(s)
      }
      // Also: if session exists under sessionId even without request status
      if (!session && jr.sessionId) {
        const s = readJsonSafe(sessionPath(jr.sessionId))
        if (s) session = enrich(s)
      }
      return send(res, 200, { ok: true, request: jr, session, status: jr.status })
    }
    if (req.method === 'POST' && jop === 'approve') {
      try {
        const body = await readBody(req).catch(() => ({}))
        const result = approveJoinRequest(jid, { by: body.by || 'operator' })
        return send(res, 200, result)
      } catch (e) {
        return send(res, e.statusCode || 400, {
          ok: false,
          code: e.code || 'ERROR',
          error: String(e.message || e),
        })
      }
    }
    if (req.method === 'POST' && jop === 'deny') {
      try {
        const body = await readBody(req).catch(() => ({}))
        const result = denyJoinRequest(jid, {
          by: body.by || 'operator',
          reason: body.reason || '',
        })
        return send(res, 200, result)
      } catch (e) {
        return send(res, e.statusCode || 400, {
          ok: false,
          code: e.code || 'ERROR',
          error: String(e.message || e),
        })
      }
    }
  }

  // /api/sessions/:id/...
  const m = url.pathname.match(
    /^\/api\/sessions\/([^/]+)(?:\/(heartbeat|notes|questions|steers|consume-steers|nudge|unregister))?$/,
  )
  if (m) {
    const id = decodeURIComponent(m[1])
    const op = m[2] || ''

    if (req.method === 'DELETE' || op === 'unregister') {
      return send(res, 200, unregisterSession(id))
    }

    if (req.method === 'POST' && (op === 'heartbeat' || op === '')) {
      try {
        const body = await readBody(req)
        if (body.unregister) return send(res, 200, unregisterSession(id))
        if (op === 'notes' || body.note) {
          const session = addNote(id, body.note || body)
          if (!session) return send(res, 404, { ok: false, error: 'not found' })
          return send(res, 200, { ok: true, session })
        }
        if (op === 'questions' || body.question) {
          if (body.answer && body.questionId) {
            const session = answerQuestion(id, body.questionId, body)
            if (!session) return send(res, 404, { ok: false, error: 'not found' })
            return send(res, 200, { ok: true, session })
          }
          const session = addQuestion(id, body.question || body)
          if (!session) return send(res, 404, { ok: false, error: 'not found' })
          return send(res, 200, { ok: true, session })
        }
        if (op === 'steers' || body.steer) {
          const session = addSteer(id, body.steer || body)
          if (!session) return send(res, 404, { ok: false, error: 'not found' })
          return send(res, 200, { ok: true, session })
        }
        if (op === 'consume-steers') {
          return send(res, 200, { ok: true, ...consumeSteers(id) })
        }
        const session = heartbeatSession(id, body)
        if (!session) return send(res, 404, { ok: false, code: 'SESSION_NOT_FOUND', error: 'session not found', reattach: true })
        return send(res, 200, { ok: true, session })
      } catch (e) {
        return send(res, 400, { ok: false, error: String(e.message || e) })
      }
    }

    if (req.method === 'POST' && op === 'notes') {
      const body = await readBody(req)
      const session = addNote(id, body)
      if (!session) return send(res, 404, { ok: false, error: 'not found' })
      return send(res, 200, { ok: true, session })
    }
    if (req.method === 'POST' && op === 'questions') {
      const body = await readBody(req)
      if (body.questionId && (body.answer || body.text)) {
        const session = answerQuestion(id, body.questionId, body)
        if (!session) return send(res, 404, { ok: false, error: 'not found' })
        return send(res, 200, { ok: true, session })
      }
      const session = addQuestion(id, body)
      if (!session) return send(res, 404, { ok: false, error: 'not found' })
      return send(res, 200, { ok: true, session })
    }
    if (req.method === 'POST' && op === 'steers') {
      const body = await readBody(req)
      const session = addSteer(id, body)
      if (!session) return send(res, 404, { ok: false, error: 'not found' })
      return send(res, 200, { ok: true, session })
    }
    if (req.method === 'POST' && op === 'consume-steers') {
      return send(res, 200, { ok: true, ...consumeSteers(id) })
    }
    if (req.method === 'POST' && op === 'nudge') {
      try {
        const body = await readBody(req)
        const session = addNudge(id, body)
        if (!session) return send(res, 404, { ok: false, error: 'not found' })
        return send(res, 200, { ok: true, session, nudge: session.nudge })
      } catch (e) {
        return send(res, 400, { ok: false, error: String(e.message || e) })
      }
    }
  }

  if (url.pathname === '/api/tips' && req.method === 'GET') {
    const tips = readJsonSafe(path.join(THEATER_DIR, 'tips.json'), [])
    return send(res, 200, { tips })
  }

  // Handover folders (operator desk) — auto-deliver + resume undelivered on boot
  if (url.pathname === '/api/handovers' && req.method === 'GET') {
    return send(res, 200, {
      handovers: listHandovers().slice(0, 60),
      pending: listHandovers().filter((h) => h.status === 'pending').length,
      outbox: HANDOVER_OUTBOX,
    })
  }
  if (url.pathname === '/api/handovers' && req.method === 'POST') {
    try {
      const body = await readBody(req)
      const note = createHandover(body)
      if (!note) return send(res, 400, { ok: false, error: 'text required' })
      if (body.deliver !== false) flushHandovers({ onlyIds: [note.id] })
      return send(res, 200, { ok: true, handover: readJsonSafe(handoverPath(note.id)), handovers: listHandovers().slice(0, 40) })
    } catch (e) {
      return send(res, 400, { ok: false, error: String(e.message || e) })
    }
  }
  if (url.pathname === '/api/handovers/flush' && req.method === 'POST') {
    const flushed = flushHandovers()
    return send(res, 200, {
      ok: true,
      flushed: flushed.length,
      handovers: listHandovers().slice(0, 40),
      outbox: HANDOVER_OUTBOX,
    })
  }
  if (url.pathname === '/api/preflight' && req.method === 'POST') {
    let body = {}
    try {
      body = await readBody(req)
    } catch {
      body = {}
    }
    const result = preflightSweep(body)
    return send(res, 200, result)
  }

  if (url.pathname === '/api/events' && req.method === 'GET') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
    })
    const sessions = listSessions().map(enrich)
    res.write(`event: sessions\ndata: ${JSON.stringify(sessions)}\n\n`)
    res.write(`event: mission\ndata: ${JSON.stringify(missionRollup(sessions))}\n\n`)
    res.write(`event: handovers\ndata: ${JSON.stringify(listHandovers().slice(0, 40))}\n\n`)
    sseClients.add(res)
    touchIdleTimer()
    req.on('close', () => {
      sseClients.delete(res)
      touchIdleTimer()
    })
    return
  }

  return send(res, 404, { ok: false, error: 'not found' })
}

function serveStatic(req, res, url) {
  // Windows: path.join(base, '/assets/x.png') drops base (absolute-looking segment).
  // Always strip leading slashes so assets resolve under THEATER_DIR.
  let rel = url.pathname === '/' ? 'index.html' : url.pathname
  rel = rel.replace(/^\/+/, '').replace(/\.\./g, '')
  const root = path.resolve(THEATER_DIR)
  const file = path.resolve(root, rel)
  if (!file.startsWith(root + path.sep) && file !== root) {
    return send(res, 404, 'Not found', 'text/plain')
  }
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    return send(res, 404, 'Not found', 'text/plain')
  }
  let data = fs.readFileSync(file)
  if (path.basename(file).toLowerCase() === 'index.html') {
    const inject = `<head><script>window.__SHOWTIME_TOKEN__=${JSON.stringify(SERVER_TOKEN)}</script>`
    data = Buffer.from(data.toString('utf8').replace('<head>', inject))
  }
  res.writeHead(200, {
    'Content-Type': contentType(file),
    'Cache-Control': 'no-store',
  })
  res.end(data)
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || '/', `http://127.0.0.1:${serverPort}`)
    if (url.pathname.startsWith('/api/')) return await handleApi(req, res, url)
    return serveStatic(req, res, url)
  } catch (e) {
    console.error(e)
    send(res, 500, { ok: false, error: String(e.message || e) })
  }
})

function cleanupAndExit(code) {
  // Drop BOTH files: a surviving server.port with no server behind it points
  // every runner heartbeat at a dead socket and defeats the boot dedupe below.
  try {
    if (fs.existsSync(PID_FILE)) fs.unlinkSync(PID_FILE)
  } catch {}
  try {
    if (fs.existsSync(PORT_FILE)) fs.unlinkSync(PORT_FILE)
  } catch {}
  try {
    if (fs.existsSync(TOKEN_FILE)) fs.unlinkSync(TOKEN_FILE)
  } catch {}
  process.exit(code)
}

function tryListen(port) {
  return new Promise((resolve, reject) => {
    const onError = (err) => {
      server.off('listening', onListen)
      reject(err)
    }
    const onListen = () => {
      server.off('error', onError)
      resolve(port)
    }
    server.once('error', onError)
    server.once('listening', onListen)
    server.listen(port, '127.0.0.1')
  })
}

async function main() {
  // Dedupe on the port file alone — requiring PID_FILE too meant a crash that
  // left only server.port skipped this check and double-started the board.
  // Health probe is the truth; stale files get cleaned before we bind.
  if (fs.existsSync(PORT_FILE)) {
    const oldPort = Number(fs.readFileSync(PORT_FILE, 'utf8').trim())
    const ok = await fetch(`http://127.0.0.1:${oldPort}/api/health`)
      .then((r) => r.ok)
      .catch(() => false)
    if (ok) {
      console.log(`[showtime] already running port=${oldPort}`)
      console.log(`SHOWTIME_URL=http://127.0.0.1:${oldPort}/`)
      process.exit(0)
    }
    try {
      fs.unlinkSync(PORT_FILE)
    } catch {}
    try {
      if (fs.existsSync(PID_FILE)) fs.unlinkSync(PID_FILE)
    } catch {}
  }

  let bound = null
  for (let i = 0; i < PORT_SCAN; i++) {
    const p = PREFERRED_PORT + i
    try {
      bound = await tryListen(p)
      break
    } catch (e) {
      if (e.code !== 'EADDRINUSE') throw e
    }
  }
  if (bound == null) {
    console.error('[showtime] no free port')
    process.exit(1)
  }
  serverPort = bound
  fs.mkdirSync(STATE_ROOT, { recursive: true })
  fs.writeFileSync(PORT_FILE, String(serverPort), 'utf8')
  fs.writeFileSync(PID_FILE, String(process.pid), 'utf8')
  fs.writeFileSync(TOKEN_FILE, SERVER_TOKEN, 'utf8')
  console.log(`[showtime] Show Time - Looplet v2 on http://127.0.0.1:${serverPort}/`)
  console.log(`SHOWTIME_URL=http://127.0.0.1:${serverPort}/`)
  touchIdleTimer()

  setInterval(() => {
    let changed = false
    for (const s of listSessions()) {
      const before = s.status
      const beforeNudge = s.nudge?.status
      const beforeEsc = s.escalate?.at
      let after = applyStall({ ...s })
      after = applyNudgeExpiry(after)
      if (
        after.status !== before ||
        after.stopReason !== s.stopReason ||
        after.nudge?.status !== beforeNudge ||
        after.escalate?.at !== beforeEsc
      ) {
        writeJson(sessionPath(s.sessionId), after)
        changed = true
        if (after.status === 'stalled' && before !== 'stalled') broadcast('stall', enrich(after))
      }
    }
    if (changed) broadcast('sessions', listSessions().map(enrich))
  }, 5000)
}

process.on('SIGINT', () => cleanupAndExit(0))
process.on('SIGTERM', () => cleanupAndExit(0))
main().catch((e) => {
  console.error(e)
  process.exit(1)
})
