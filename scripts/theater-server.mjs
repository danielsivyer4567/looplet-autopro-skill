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

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SKILL_ROOT = path.resolve(__dirname, '..')
const THEATER_DIR = path.join(SKILL_ROOT, 'theater')
const HOME = process.env.USERPROFILE || process.env.HOME || '.'
const STATE_ROOT = path.join(HOME, '.claude', 'scratch', 'autopro-theater')
const SESSIONS_DIR = path.join(STATE_ROOT, 'sessions')
const STEER_DIR = path.join(STATE_ROOT, 'steer')
const HANDOVER_DIR = path.join(STATE_ROOT, 'handovers')
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
  const re = /^##\s+((?:SC-\d+)|(?:SD-[\w-]+)|(?:H\d+)|(?:P\d+[-\w]*))\s+(?:[—–-]\s+)?(.+?)\s+\[(pending|in-progress|done|blocked)\]/gim
  let m
  while ((m = re.exec(text)) !== null) {
    todos.push({ id: m[1], text: m[2].trim(), state: m[3].toLowerCase() })
  }
  return todos
}
function deriveCounts(todos) {
  const counts = { pending: 0, inProgress: 0, done: 0, blocked: 0 }
  for (const t of todos) {
    if (t.state === 'pending') counts.pending++
    else if (t.state === 'in-progress') counts.inProgress++
    else if (t.state === 'done') counts.done++
    else if (t.state === 'blocked') counts.blocked++
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
  const stallAfter = session.alarms?.stallAfterSec ?? 300
  if (!session.alarms?.stallEnabled) return session
  if (['blocked', 'needs_input', 'complete'].includes(session.status)) return session
  const last = session.timer?.lastProgressAt || session.updatedAt
  if (!last) return session
  const age = (Date.now() - new Date(last).getTime()) / 1000
  if (age >= stallAfter && session.status === 'running') {
    session.status = 'stalled'
    session.stopReason = `No progress for ${Math.round(age)}s (stall threshold ${stallAfter}s)`
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
  return session
}

// Derive a clean repo folder name from repoPath; fall back to repoId. Pure.
function repoNameOf(session) {
  const p = (session && session.repoPath || '').replace(/[\\/]+$/, '')
  if (p) {
    const base = p.split(/[\\/]/).pop()
    if (base) return base
  }
  return (session && session.repoId) || ''
}

function registerSession(body) {
  const sessionId = body.sessionId || uid('sess')
  const existing = readJsonSafe(sessionPath(sessionId))
  const ledgerPath = body.ledgerPath || existing?.ledgerPath || null
  let todos = body.todo
  if ((!todos || !todos.length) && ledgerPath) todos = parseLedgerTodos(ledgerPath)
  todos = todos || existing?.todo || []
  const counts = body.counts || deriveCounts(todos)
  const slice = body.slice || activeSlice(todos)
  const total = counts.pending + counts.inProgress + counts.done + counts.blocked
  const done = counts.done
  const progress = total > 0 ? done / total : 0
  const lane = existing?.lane || body.lane || nextLane()

  const session = {
    sessionId,
    chatLabel: existing?.chatLabel || body.chatLabel || `Chat ${lane}`,
    lane,
    // SA-N always matches Chat N / lane N — operator never addresses these directly
    subAgentNo: lane,
    subAgentId: `SA-${lane}`,
    role: 'subagent',
    repoId: body.repoId || existing?.repoId || 'repo',
    repoPath: body.repoPath || existing?.repoPath || '',
    branch: body.branch || existing?.branch || '',
    pid: body.pid ?? existing?.pid ?? null,
    ledgerHash: body.ledgerHash || existing?.ledgerHash || null,
    ledgerTitle: body.ledgerTitle || existing?.ledgerTitle || null,
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
      stallAfterSec: body.alarms?.stallAfterSec ?? existing?.alarms?.stallAfterSec ?? 300,
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
      `Sub-agent SA-${lane} (Chat ${lane}) registered under ORCH for ${session.repoId}`,
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
  if (body.branch) existing.branch = body.branch
  if (body.repoPath) existing.repoPath = body.repoPath
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
    return send(res, 200, { sessions, mission: missionRollup(sessions) })
  }

  if (url.pathname === '/api/sessions' && req.method === 'POST') {
    try {
      const body = await readBody(req)
      return send(res, 200, { ok: true, session: registerSession(body) })
    } catch (e) {
      return send(res, 400, { ok: false, error: String(e.message || e) })
    }
  }

  // /api/sessions/:id/...
  const m = url.pathname.match(/^\/api\/sessions\/([^/]+)(?:\/(heartbeat|notes|questions|steers|consume-steers|unregister))?$/)
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
        if (!session) return send(res, 404, { ok: false, error: 'session not found' })
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
      const after = applyStall({ ...s })
      if (after.status !== before || after.stopReason !== s.stopReason) {
        writeJson(sessionPath(s.sessionId), after)
        changed = true
        if (after.status === 'stalled') broadcast('stall', enrich(after))
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
