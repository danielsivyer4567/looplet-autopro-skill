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
import { spawn } from 'node:child_process'
import { createFleetApi } from './fleet-core.mjs'
import { applyOwnership, normalizeRootKey, ownPidClaim } from './worker-ownership.mjs'

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
/**
 * Own pid claim only (never share disk worker.pid across twin join sessions).
 * Disk pid is applied later in listSessionsEnriched() for the single root OWNER.
 */
function resolveOwnLivePid(session) {
  const n = ownPidClaim(session)
  if (n > 0 && isPidAlive(n)) return n
  return 0
}

function sessionRootKey(session) {
  const raw = session?.primaryRepoPath || session?.repoPath || session?.armRepoDir || session?.repoDir || ''
  let root = String(raw || '')
  try {
    root = normalizeRepoRoot(root) || root
  } catch { /* ignore */ }
  const key = normalizeRootKey(root)
  return key || ''
}

function readDiskWorkerPidForRoot(rootKey) {
  if (!rootKey || rootKey.startsWith('sess:')) return 0
  // rootKey is lowercased path — recover a real path from any session later; try common casing via readdir
  try {
    // Windows paths in keys are lowercase; fs is usually case-insensitive
    const pf = path.join(rootKey, '.claude', 'scratch', 'autopro-worker.pid')
    if (!fs.existsSync(pf)) return 0
    const n = Number(String(fs.readFileSync(pf, 'utf8')).trim())
    return n > 0 ? n : 0
  } catch {
    return 0
  }
}

function readFlagOwnerForRoot(rootKey) {
  if (!rootKey || rootKey.startsWith('sess:')) return ''
  try {
    const scratch = path.join(rootKey, '.claude', 'scratch')
    if (!fs.existsSync(scratch)) return ''
    const flags = fs.readdirSync(scratch).filter((f) => f.startsWith('autopro-on'))
    // Prefer autopro-on.sess_*
    for (const f of flags) {
      const m = f.match(/^autopro-on\.(sess_.+)$/i) || f.match(/^autopro-on\.(.+)$/i)
      if (m) return String(m[1]).trim()
    }
    // autopro-session.json
    const sj = path.join(scratch, 'autopro-session.json')
    if (fs.existsSync(sj)) {
      const j = JSON.parse(fs.readFileSync(sj, 'utf8'))
      if (j?.sessionId) return String(j.sessionId).trim()
    }
  } catch { /* ignore */ }
  return ''
}

/** Per-session enrich WITHOUT cross-session disk pid sharing. */
function enrichBase(session) {
  session = applyStall({ ...session })
  session = applyNudgeExpiry(session)
  session.openQuestions = openQuestionCount(session)
  session.needsInput = session.openQuestions > 0 || session.status === 'needs_input'
  const lane = Number(session.lane) || 0
  session.subAgentNo = lane
  session.subAgentId = lane ? `SA-${lane}` : (session.subAgentId || 'SA-?')
  session.agentRef = lane
    ? `SA-${lane} · Chat ${lane}`
    : (session.chatLabel || session.sessionId || 'agent')
  session.role = session.role || 'subagent'
  session.repoName = repoNameOf(session)
  // Tentative own-pid only; listSessionsEnriched overwrites with ownership rules
  const ownLive = resolveOwnLivePid(session)
  if (ownLive > 0) session.pid = ownLive
  const alive = ownLive > 0
  session.workerAlive = alive
  session.pidAlive = alive
  session.workerDead = !alive && !!ownPidClaim(session)
  session.isWorkerOwner = false
  session.corpse = false
  session.twinOf = null
  return session
}

/**
 * Single-writer honesty: one owner per repo root inherits disk worker.pid;
 * twins never get legs; corpses flagged for UI collapse / purge.
 */
function listSessionsEnriched() {
  const base = listSessions().map((s) => enrichBase(s))
  // Map rootKey -> real path for disk reads (keys are lowercased)
  const rootPathByKey = new Map()
  for (const s of base) {
    const raw = s.primaryRepoPath || s.repoPath || s.armRepoDir || ''
    let root = String(raw || '')
    try { root = normalizeRepoRoot(root) || root } catch { /* ignore */ }
    const key = normalizeRootKey(root)
    if (key && root) rootPathByKey.set(key, root)
  }
  return applyOwnership(base, {
    rootKeyOf: (s) => sessionRootKey(s) || `sess:${s.sessionId}`,
    isPidAlive,
    readDiskPid: (rootKey) => {
      const real = rootPathByKey.get(rootKey) || rootKey
      return readDiskWorkerPidForRoot(real)
    },
    readFlagOwner: (rootKey) => {
      const real = rootPathByKey.get(rootKey) || rootKey
      return readFlagOwnerForRoot(real)
    },
  })
}

/** enrich one session in context of full board (ownership-correct). */
function enrich(session) {
  if (!session) return session
  const sid = session.sessionId
  const all = listSessionsEnriched()
  const hit = all.find((s) => s.sessionId === sid)
  if (hit) return hit
  return enrichBase(session)
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
/**
 * Join alarm policy (product):
 *   ONE short sound per NEW ledger (not per re-ping, not while pending sits).
 * Never re-fire for the same ledger key. Never launch triple processes.
 * Never play multi-round WAV marathons.
 */
const JOIN_ALERT_PS1 = path.join(STATE_ROOT, 'join-alarm-loud.ps1')
const JOIN_ALERT_LOG = path.join(STATE_ROOT, 'join-alarm.log')
const JOIN_ALERT_PAYLOAD = path.join(STATE_ROOT, 'join-alarm-payload.json')
const JOIN_ALERTED_LEDGERS = path.join(STATE_ROOT, 'join-alarm-ledgers.json')
/** In-memory: ledger keys already alerted this process lifetime (disk is durable too). */
const joinAlertedLedgers = new Set()

function loadJoinAlertedLedgers() {
  try {
    const j = readJsonSafe(JOIN_ALERTED_LEDGERS)
    const keys = Array.isArray(j?.keys) ? j.keys : []
    for (const k of keys) {
      if (k) joinAlertedLedgers.add(String(k))
    }
  } catch { /* ignore */ }
}

function persistJoinAlertedLedgers() {
  try {
    writeJson(JOIN_ALERTED_LEDGERS, {
      keys: [...joinAlertedLedgers].slice(-200),
      updatedAt: nowIso(),
    })
  } catch { /* ignore */ }
}

/** Stable key for "this ledger already got its one ding". */
function joinLedgerAlarmKey(jr = {}) {
  const hash = String(jr.ledgerHash || '').trim()
  if (hash) return `hash:${hash}`
  const lp = String(jr.ledgerPath || '').trim().toLowerCase().replace(/\\/g, '/')
  if (lp) return `path:${lp}`
  const root = normalizeRepoRoot(jr.repoPath || jr.primaryRepoPath || '')
  const title = String(jr.ledgerTitle || '').trim().toLowerCase()
  if (root && title) return `repo-title:${root.toLowerCase()}|${title}`
  if (root) return `repo:${root.toLowerCase()}`
  const sid = String(jr.sessionId || '').trim()
  return sid ? `sess:${sid}` : ''
}

/**
 * Durable alarm script: ONE short WAV + bottom-right Approve/Deny popup.
 * Source of truth: scripts/join-alarm-loud.ps1 (copied into STATE_ROOT for launch).
 */
function ensureJoinAlarmScript() {
  const src = path.join(SKILL_ROOT, 'scripts', 'join-alarm-loud.ps1')
  try {
    fs.mkdirSync(STATE_ROOT, { recursive: true })
    if (fs.existsSync(src)) {
      fs.copyFileSync(src, JOIN_ALERT_PS1)
      return
    }
  } catch { /* fall through to minimal stub */ }
  // Minimal fallback if skill script missing — still copy so launch has a file
  try {
    fs.writeFileSync(
      JOIN_ALERT_PS1,
      `# fallback join alarm — install scripts/join-alarm-loud.ps1\nWrite-Host 'join-alarm stub'\n`,
      'utf8',
    )
  } catch { /* ignore */ }
}

/**
 * Launch alarm outside the parent Job Object — SINGLE process only.
 * (Old code spawned cmd+direct+WMI = triple simultaneous marathons.)
 */
function launchAlarmProcess() {
  try {
    fs.appendFileSync(
      JOIN_ALERT_LOG,
      `${new Date().toISOString()} launchAlarmProcess once ps1=${JOIN_ALERT_PS1}\n`,
      'utf8',
    )
  } catch { /* ignore */ }

  // Do NOT use /MIN — the join popup is a WinForms dialog (Approve/Deny) that
  // must paint on screen. WindowStyle Hidden suppresses the console only.
  try {
    const c = spawn(
      'cmd.exe',
      [
        '/c',
        'start',
        '',
        'pwsh.exe',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        JOIN_ALERT_PS1,
      ],
      { detached: true, stdio: 'ignore', windowsHide: true },
    )
    c.unref()
    return true
  } catch (e) {
    try {
      fs.appendFileSync(JOIN_ALERT_LOG, `${new Date().toISOString()} cmd-start fail ${e?.message || e}\n`, 'utf8')
    } catch { /* ignore */ }
  }

  // Fallback only if cmd start failed
  try {
    const c2 = spawn(
      'pwsh.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', JOIN_ALERT_PS1],
      { detached: true, stdio: 'ignore', windowsHide: true },
    )
    c2.unref()
    return true
  } catch { /* ignore */ }

  return false
}

/**
 * Fire OS join alert at most ONCE per ledger key.
 * @param {object} jr - the new join request (or payload with ledger fields)
 */
function fireJoinOsAlertForLedger(jr) {
  if (process.platform !== 'win32') return { fired: false, reason: 'not_win32' }
  if (!jr) return { fired: false, reason: 'no_request' }
  loadJoinAlertedLedgers()
  const ledgerKey = joinLedgerAlarmKey(jr)
  if (!ledgerKey) return { fired: false, reason: 'no_ledger_key' }
  if (joinAlertedLedgers.has(ledgerKey)) {
    try {
      fs.appendFileSync(
        JOIN_ALERT_LOG,
        `${new Date().toISOString()} skip already-alerted ledger=${ledgerKey}\n`,
        'utf8',
      )
    } catch { /* ignore */ }
    return { fired: false, reason: 'already_alerted', ledgerKey }
  }
  joinAlertedLedgers.add(ledgerKey)
  persistJoinAlertedLedgers()

  const title = 'SHOW TIME — JOIN REQUEST'
  const repoBit = jr.repoId || path.basename(String(jr.repoPath || '').replace(/\\/g, '/')) || 'repo'
  const body = [
    repoBit,
    jr.branch || '',
    jr.ledgerTitle || jr.sessionId || '',
    'APPROVE or DENY on the popup',
  ].filter(Boolean).join(' · ')

  ensureJoinAlarmScript()
  try {
    fs.writeFileSync(
      JOIN_ALERT_PAYLOAD,
      JSON.stringify({
        title: title.slice(0, 80),
        body: body.slice(0, 240),
        at: new Date().toISOString(),
        ledgerKey,
        joinId: jr.id || null,
        sessionId: jr.sessionId || null,
        repoId: jr.repoId || repoBit || null,
        repoPath: jr.repoPath || jr.primaryRepoPath || null,
        branch: jr.branch || null,
        ledgerTitle: jr.ledgerTitle || null,
        port: String(serverPort),
        boardUrl: `http://127.0.0.1:${serverPort}/`,
      }),
      'utf8',
    )
  } catch { /* ignore */ }
  try {
    fs.appendFileSync(
      JOIN_ALERT_LOG,
      `${new Date().toISOString()} fireJoinOsAlert ONCE ledger=${ledgerKey} join=${jr.id || ''}\n`,
      'utf8',
    )
  } catch { /* ignore */ }

  launchAlarmProcess()
  return { fired: true, ledgerKey }
}

/**
 * Update join beacon file. Sound is NOT fired here (re-pings / approve / deny
 * used to re-trigger the marathon). Sound only via maybeAlertNewJoinLedger.
 */
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

/** Call only when a brand-new pending join is created for a ledger. */
function maybeAlertNewJoinLedger(jr) {
  try {
    return fireJoinOsAlertForLedger(jr)
  } catch (e) {
    try {
      fs.appendFileSync(
        JOIN_ALERT_LOG,
        `${new Date().toISOString()} maybeAlert fail ${e?.message || e}\n`,
        'utf8',
      )
    } catch { /* ignore */ }
    return { fired: false, reason: 'error' }
  }
}

// Load durable "already dinged" ledger set on boot
try { loadJoinAlertedLedgers() } catch { /* ignore */ }
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
  // Dedupe only against truly live lanes. Dead-pid stalled/running zombies must
  // NOT block re-arm of the same ledger (operator re-attach / OpenRegister).
  const live = (s) => {
    const st = String(s.status || '').toLowerCase()
    if (st === 'complete' || st === 'completed' || st === 'done') return false
    const pid = s.pid != null ? Number(s.pid) : 0
    const alive = pid > 0 && isPidAlive(pid)
    if (!alive && ['stalled', 'blocked', 'paused', 'error', 'running', 'in-progress', 'queued', 'needs_input'].includes(st)) {
      return false
    }
    return true
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
  // Sound ONCE per new ledger — never on re-ping / beacon refresh / approve path
  maybeAlertNewJoinLedger(req)
  broadcast('join_request', req)
  return { ok: true, status: 'pending', request: req, session: null }
}
// ---------------------------------------------------------------------------
// Approve → Arm bridge (Door A opens Door B)
// Board Approve is operator consent to unattended autopro in that repo.
// ---------------------------------------------------------------------------
const ARM_ON_APPROVE_PS1 = path.join(SKILL_ROOT, 'scripts', 'arm-on-approve.ps1')
const ARM_BRIDGE_LOG = path.join(STATE_ROOT, 'arm-on-approve-bridge.log')
const JUNK_SESSION_RE = /^(sound-test|alert-test|LOUD-|HEAR-ME|BLAST-|SOUND|alarm|prove-grok)/i
const JUNK_TITLE_RE = /(SOUND TEST|LOUD ALARM|HEAR THIS|BLAST SOUND|TEST LOUD JOIN|alarm proof)/i
/** repoPath → last arm attempt ms (debounce double-approve) */
const armDebounce = new Map()

function armBridgeLog(line) {
  try {
    fs.mkdirSync(STATE_ROOT, { recursive: true })
    fs.appendFileSync(ARM_BRIDGE_LOG, `${new Date().toISOString()} ${line}\n`, 'utf8')
  } catch { /* ignore */ }
}

function resolveRepoDirForArm(jr) {
  const candidates = [
    jr.repoPath,
    jr.primaryRepoPath,
    jr.ledgerPath ? path.dirname(path.dirname(jr.ledgerPath)) : '', // …/.claude/scratch/ledger.md → repo
  ].filter(Boolean)
  for (const c of candidates) {
    try {
      const abs = path.resolve(String(c))
      if (fs.existsSync(abs) && fs.statSync(abs).isDirectory()) {
        // Prefer git root if we landed in a package subfolder
        const gitRoot = resolveGitRoot(abs)
        if (gitRoot && fs.existsSync(gitRoot)) return path.resolve(gitRoot)
        return abs
      }
    } catch { /* next */ }
  }
  return ''
}

function ledgerIsApproved(repoDir, ledgerPathHint) {
  const paths = [
    ledgerPathHint,
    path.join(repoDir, '.claude', 'scratch', 'ledger.md'),
  ].filter(Boolean)
  for (const p of paths) {
    try {
      if (!fs.existsSync(p)) continue
      const raw = fs.readFileSync(p, 'utf8')
      if (/^Approved:\s*yes/im.test(raw)) return { ok: true, path: p }
    } catch { /* next */ }
  }
  return { ok: false, path: paths[0] || '' }
}

function isJunkJoin(jr) {
  const sid = String(jr.sessionId || '')
  const title = String(jr.ledgerTitle || '')
  if (JUNK_SESSION_RE.test(sid)) return true
  if (JUNK_TITLE_RE.test(title)) return true
  return false
}

/**
 * After Approve: spawn arm-on-approve.ps1 for the repo (async).
 * Updates session.arm* fields when the child exits (best-effort poll file).
 */
function tryAutoArmAfterApprove(jr, session) {
  const result = {
    attempted: false,
    status: 'skipped',
    reason: '',
    pid: 0,
    repoDir: '',
  }
  if (process.env.SHOWTIME_AUTO_ARM === '0' || process.env.SHOWTIME_AUTO_ARM === 'false') {
    result.reason = 'SHOWTIME_AUTO_ARM disabled'
    return result
  }
  if (isJunkJoin(jr)) {
    result.reason = 'junk_session'
    armBridgeLog(`skip junk sessionId=${jr.sessionId}`)
    return result
  }
  const repoDir = resolveRepoDirForArm(jr)
  result.repoDir = repoDir
  if (!repoDir) {
    result.reason = 'no_repo_path'
    armBridgeLog(`skip no repoPath for ${jr.sessionId}`)
    return result
  }
  const now = Date.now()
  const last = armDebounce.get(repoDir) || 0
  if (now - last < 20_000) {
    result.reason = 'debounce'
    armBridgeLog(`skip debounce repo=${repoDir}`)
    return result
  }
  armDebounce.set(repoDir, now)

  const ledgerCheck = ledgerIsApproved(repoDir, jr.ledgerPath)
  if (!ledgerCheck.ok) {
    result.reason = 'ledger_not_approved'
    armBridgeLog(`skip ledger not approved repo=${repoDir}`)
    patchSessionArm(jr.sessionId, {
      armStatus: 'skipped',
      armReason: 'ledger_not_approved',
      armAt: nowIso(),
      armRepoDir: repoDir,
    })
    return result
  }

  if (!fs.existsSync(ARM_ON_APPROVE_PS1)) {
    result.reason = 'arm_script_missing'
    armBridgeLog(`FAIL missing ${ARM_ON_APPROVE_PS1}`)
    patchSessionArm(jr.sessionId, {
      armStatus: 'failed',
      armReason: 'arm_script_missing',
      armAt: nowIso(),
      armRepoDir: repoDir,
    })
    return result
  }

  result.attempted = true
  result.status = 'arming'
  patchSessionArm(jr.sessionId, {
    armStatus: 'arming',
    armReason: 'board_approve',
    armAt: nowIso(),
    armRepoDir: repoDir,
    armLedgerPath: ledgerCheck.path,
  })
  pushSentinelOnSession(jr.sessionId, `Board Approve → arming autopro in ${path.basename(repoDir)}…`, 'info')
  broadcast('sessions', listSessionsEnriched())
  broadcast('arm_started', { sessionId: jr.sessionId, repoDir, joinId: jr.id })

  // Escape job objects: cmd /c start + direct spawn (same pattern as loud alarm)
  const psArgs = [
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', ARM_ON_APPROVE_PS1,
    '-RepoDir', repoDir,
    '-Root', repoDir,
    '-SessionId', String(jr.sessionId || ''),
    '-Engine', 'auto',
    '-IAcceptBoardApproveAsArmConsent',
    '-NoBrowser',
  ]
  const cmdLine = `pwsh.exe ${psArgs.map((a) => (/\s/.test(a) ? `"${a}"` : a)).join(' ')}`
  armBridgeLog(`spawn arm: ${cmdLine}`)

  try {
    const c1 = spawn(
      'cmd.exe',
      ['/c', 'start', '', '/MIN', 'pwsh.exe', ...psArgs],
      { detached: true, stdio: 'ignore', windowsHide: true },
    )
    c1.unref()
  } catch (e) {
    armBridgeLog(`cmd-start fail ${e?.message || e}`)
  }
  try {
    const c2 = spawn('pwsh.exe', psArgs, {
      detached: true,
      stdio: 'ignore',
      windowsHide: true,
      cwd: repoDir,
    })
    c2.unref()
  } catch (e) {
    armBridgeLog(`spawn fail ${e?.message || e}`)
  }

  // Poll arm log + flags for ~90s and patch session when runner appears
  scheduleArmResultPoll(jr.sessionId, repoDir, 0)

  return result
}

function patchSessionArm(sessionId, fields) {
  try {
    const s = readJsonSafe(sessionPath(sessionId))
    if (!s) return
    Object.assign(s, fields)
    s.updatedAt = nowIso()
    writeJson(sessionPath(sessionId), s)
  } catch { /* ignore */ }
}

function pushSentinelOnSession(sessionId, text, level = 'info') {
  try {
    const s = readJsonSafe(sessionPath(sessionId))
    if (!s) return
    pushSentinel(s, text, level)
    writeJson(sessionPath(sessionId), s)
  } catch { /* ignore */ }
}

function scheduleArmResultPoll(sessionId, repoDir, attempt) {
  if (attempt > 30) {
    patchSessionArm(sessionId, {
      armStatus: 'failed',
      armReason: 'timeout_waiting_for_runner',
      armAt: nowIso(),
    })
    pushSentinelOnSession(sessionId, 'Arm timeout — no runner pid after Approve. Check arm-on-approve.log', 'warn')
    broadcast('sessions', listSessionsEnriched())
    broadcast('arm_failed', { sessionId, repoDir, reason: 'timeout' })
    return
  }
  setTimeout(() => {
    try {
      const scratch = path.join(repoDir, '.claude', 'scratch')
      const logPath = path.join(scratch, 'arm-on-approve.log')
      let status = ''
      let pid = 0
      let runnerSessionId = ''
      if (fs.existsSync(logPath)) {
        // Scan last lines bottom-up so a later SUCCESS wins over an earlier ARM_STATUS=failed
        // (same log file accumulates many arm attempts).
        const lines = fs.readFileSync(logPath, 'utf8').split(/\r?\n/).slice(-120)
        for (let i = lines.length - 1; i >= 0; i--) {
          const line = lines[i]
          if (!status) {
            if (/SUCCESS armed|ARM_STATUS=armed\b/i.test(line)) status = 'armed'
            else if (/ARM_STATUS=already_armed/i.test(line)) status = 'already_armed'
            else if (/ARM_STATUS=armed_flag_only/i.test(line)) status = 'armed_flag_only'
            else if (/ARM_STATUS=skipped/i.test(line)) status = 'skipped'
            else if (/ARM_STATUS=failed/i.test(line)) status = 'failed'
            else if (/ARM_STATUS=whatif_ok/i.test(line)) status = 'whatif_ok'
          }
          if (!pid) {
            const m =
              line.match(/SUCCESS armed pid=(\d+)/i) ||
              line.match(/ARM_PID=(\d+)/) ||
              line.match(/RUNNER_PID=(\d+)/)
            if (m) pid = Number(m[1]) || 0
          }
          if (!runnerSessionId) {
            const sm =
              line.match(/SUCCESS armed pid=\d+ session=(\S+)/i) ||
              line.match(/ARM_RUNNER_SESSION=(\S+)/) ||
              line.match(/ARM_SESSION=(\S+)/) ||
              line.match(/SHOWTIME_SESSION=(\S+)/)
            if (sm) runnerSessionId = String(sm[1] || '').trim()
          }
          if (status && pid && runnerSessionId) break
        }
      }
      // Also detect live runner / flags without log parse
      try {
        const flags = fs.existsSync(scratch)
          ? fs.readdirSync(scratch).filter((f) => f.startsWith('autopro-on'))
          : []
        if (flags.length && !status) status = 'armed_flag_only'
      } catch { /* ignore */ }

      if (status === 'armed' || status === 'already_armed' || status === 'armed_flag_only') {
        const patch = {
          armStatus: status === 'already_armed' ? 'already_armed' : 'armed',
          armReason: 'board_approve',
          armAt: nowIso(),
          armRepoDir: repoDir,
        }
        if (pid > 0) {
          patch.pid = pid
          patch.workerAlive = true
          patch.pidAlive = true
          patch.workerDead = false
        }
        // launch-showtime often mints sess_* different from the join sessionId —
        // keep the join lane linked to the runner session for the board.
        if (runnerSessionId && runnerSessionId !== sessionId) {
          patch.armRunnerSessionId = runnerSessionId
        }
        patchSessionArm(sessionId, patch)
        // Best-effort: stamp pid onto runner session if it exists on the board
        if (runnerSessionId && runnerSessionId !== sessionId && pid > 0) {
          patchSessionArm(runnerSessionId, {
            pid,
            workerAlive: true,
            pidAlive: true,
            workerDead: false,
            armStatus: 'armed',
            armJoinSessionId: sessionId,
            armAt: nowIso(),
          })
        }
        pushSentinelOnSession(
          sessionId,
          pid > 0
            ? `ARMED — runner pid ${pid}${runnerSessionId && runnerSessionId !== sessionId ? ` · runner session ${runnerSessionId}` : ''} · legs should move on active SC`
            : `ARMED — autopro flag set · runner starting`,
          'info',
        )
        broadcast('sessions', listSessionsEnriched())
        broadcast('arm_ok', {
          sessionId,
          repoDir,
          pid,
          status: patch.armStatus,
          armRunnerSessionId: runnerSessionId || null,
        })
        armBridgeLog(
          `arm ok session=${sessionId} pid=${pid} status=${patch.armStatus} runnerSession=${runnerSessionId || ''}`,
        )
        return
      }
      if (status === 'skipped' || status === 'failed') {
        patchSessionArm(sessionId, {
          armStatus: status,
          armReason: status,
          armAt: nowIso(),
          armRepoDir: repoDir,
        })
        pushSentinelOnSession(sessionId, `Arm ${status} after Approve — see arm-on-approve.log`, 'warn')
        broadcast('sessions', listSessionsEnriched())
        broadcast('arm_failed', { sessionId, repoDir, status })
        return
      }
    } catch (e) {
      armBridgeLog(`poll err ${e?.message || e}`)
    }
    scheduleArmResultPoll(sessionId, repoDir, attempt + 1)
  }, 3000)
}

/** Drop noise fleets/sessions from sound tests so multi-repo board stays clean. */
function purgeJunkSessions() {
  let n = 0
  for (const s of listSessions()) {
    if (isJunkJoin(s) || JUNK_TITLE_RE.test(String(s.ledgerTitle || ''))) {
      try {
        unregisterSession(s.sessionId)
        n++
      } catch { /* ignore */ }
    }
  }
  // Empty fleets
  try {
    if (fs.existsSync(FLEETS_DIR)) {
      for (const f of fs.readdirSync(FLEETS_DIR).filter((x) => x.endsWith('.json'))) {
        const fp = path.join(FLEETS_DIR, f)
        const fl = readJsonSafe(fp)
        if (!fl) continue
        const workers = Array.isArray(fl.workers) ? fl.workers.length : 0
        if (workers === 0 || JUNK_TITLE_RE.test(String(fl.ledgerTitle || ''))) {
          try { fs.unlinkSync(fp) } catch { /* ignore */ }
          n++
        }
      }
    }
  } catch { /* ignore */ }
  if (n) {
    armBridgeLog(`purged ${n} junk sessions/fleets`)
    broadcast('sessions', listSessionsEnriched())
  }
  return n
}

/**
 * Drop true corpses only (no ledger identity). Does NOT remove ledger projectors —
 * those are separate ledgers that must stay visible on the shared board.
 * Never kills live owner runners.
 */
function purgeDeadSessions({ force = true } = {}) {
  let n = 0
  const enriched = listSessionsEnriched()
  for (const s of enriched) {
    if (!s?.sessionId) continue
    if (s.isWorkerOwner && s.pidAlive) continue
    // Keep separate ledgers on the shared page
    if (s.ledgerProjector) continue
    if (s.corpse || (force && s.workerDead && !s.pidAlive && !s.workerAlive && !s.ledgerPath && !s.ledgerTitle)) {
      try {
        unregisterSession(s.sessionId)
        n++
        armBridgeLog(`purge-dead session=${s.sessionId} corpse=${!!s.corpse}`)
      } catch { /* ignore */ }
    }
  }
  // Collapse empty fleets after session wipe
  try {
    if (fs.existsSync(FLEETS_DIR)) {
      for (const f of fs.readdirSync(FLEETS_DIR).filter((x) => x.endsWith('.json'))) {
        const fp = path.join(FLEETS_DIR, f)
        const fl = readJsonSafe(fp)
        if (!fl) continue
        const workers = Array.isArray(fl.workers) ? fl.workers : []
        const liveWorkers = workers.filter((w) => {
          const sid = w.sessionId || w
          return !!readJsonSafe(sessionPath(sid))
        })
        if (liveWorkers.length === 0) {
          try { fs.unlinkSync(fp) } catch { /* ignore */ }
          n++
        } else if (liveWorkers.length !== workers.length) {
          fl.workers = liveWorkers
          fl.workerCount = liveWorkers.length
          fl.updatedAt = nowIso()
          writeJson(fp, fl)
        }
      }
    }
  } catch { /* ignore */ }
  if (n) broadcast('sessions', listSessionsEnriched())
  return n
}

/** One virtual fleet per repo root (board truth — not per ledger title). */
function fleetsByRepoRoot() {
  const sessions = listSessionsEnriched()
  const map = new Map()
  for (const s of sessions) {
    if (isJunkJoin(s)) continue
    const key = sessionRootKey(s) || `sess:${s.sessionId}`
    if (!map.has(key)) {
      map.set(key, {
        fleetId: `root_${key.replace(/[^a-zA-Z0-9]+/g, '_').slice(-24)}`,
        status: 'active',
        role: 'orch',
        primaryRepoPath: s.primaryRepoPath || s.repoPath || '',
        repoPath: s.repoPath || s.primaryRepoPath || '',
        repoId: s.repoId || s.repoName || '',
        ledgerTitle: null,
        workers: [],
        partyRule: 'one-orch-per-repo-root',
      })
    }
    const g = map.get(key)
    g.workers.push({
      sessionId: s.sessionId,
      localNo: s.lane || g.workers.length + 1,
      subAgentId: s.subAgentId,
      chatLabel: s.chatLabel,
      status: s.status,
      progress: s.progress,
      counts: s.counts,
      slice: s.slice,
      pid: s.pid || 0,
      pidAlive: !!s.pidAlive,
      isWorkerOwner: !!s.isWorkerOwner,
      corpse: !!s.corpse,
      twinOf: s.twinOf || null,
    })
    // Prefer owner's ledger title for the head label
    if (s.isWorkerOwner || !g.ledgerTitle) {
      g.ledgerTitle = s.ledgerTitle || g.ledgerTitle
      g.ledgerPath = s.ledgerPath || g.ledgerPath
      g.branch = s.branch || g.branch
    }
  }
  return [...map.values()].map((f) => ({
    ...f,
    workerCount: f.workers.length,
    label: f.ledgerTitle || f.repoId || f.fleetId,
  }))
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
    // Re-approve still tries arm if not already armed
    const arm = tryAutoArmAfterApprove(jr, s)
    return { ok: true, status: 'approved', request: jr, session: enrich(readJsonSafe(sessionPath(jr.sessionId)) || s), arm }
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

  // THE BRIDGE: Approve (Door A) → Arm autopro (Door B)
  const arm = tryAutoArmAfterApprove(jr, session)
  jr.arm = arm
  writeJson(file, jr)

  const live = enrich(readJsonSafe(sessionPath(session.sessionId)) || session)
  broadcast('join_resolved', { id: jr.id, status: 'approved', session: live, request: jr, arm })
  return { ok: true, status: 'approved', request: jr, session: live, arm }
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
  const all = listSessionsEnriched()
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
  broadcast('sessions', listSessionsEnriched())
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
  broadcast('sessions', listSessionsEnriched())
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
/**
 * Deliver pending handovers to operator outbox AND absorb into the session's
 * repo scratch (showtime-inbox.jsonl + SHOWTIME-HANDOVER-INBOX.md) so the other
 * end can read them without the board. Show Time still does zero git push.
 */
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
    // Absorb into target repo scratch (cross-fleet / cold agent path)
    try {
      const s = h.sessionId ? readJsonSafe(sessionPath(h.sessionId)) : null
      const root = s?.primaryRepoPath || s?.repoPath || null
      if (root) {
        getFleet().appendHomeInbox(root, {
          op: 'handover',
          sessionId: h.sessionId,
          subAgentId: h.subAgentId,
          reason: h.reason,
          text: h.text,
          handoverId: h.id,
        })
        const scratch = path.join(root, '.claude', 'scratch')
        fs.mkdirSync(scratch, { recursive: true })
        const absorb = path.join(scratch, 'SHOWTIME-HANDOVER-INBOX.md')
        const block = [
          '',
          `## ${h.deliveredAt || nowIso()} · ${h.subAgentId || 'SA'} · ${h.reason || 'handover'} · ${h.id}`,
          h.text || '',
          '',
          '---',
          '',
        ].join('\n')
        if (!fs.existsSync(absorb)) {
          fs.writeFileSync(
            absorb,
            '# Show Time · Handover inbox (absorbed from board)\n\n'
              + 'Delivered notes land here so this repo can read them offline.\n',
            'utf8',
          )
        }
        fs.appendFileSync(absorb, block, 'utf8')
        h.deliveredHow = 'flush+repo-inbox'
        writeJson(handoverPath(h.id), h)
      }
    } catch { /* ignore absorb failures */ }
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
      const s = readJsonSafe(sessionPath(sessionId))
      // Never blank the board while a runner pid is still alive
      if (s && (isPidAlive(s.pid) || isPidAlive(s.runnerPid))) {
        armBridgeLog(`skip wipe live session=${sessionId} pid=${s.pid || s.runnerPid}`)
        return
      }
      unregisterSession(sessionId)
      broadcast('wiped', { sessionId, at: nowIso() })
    } catch {}
  }, Math.max(500, ms))
  wipeTimers.set(sessionId, t)
}

/**
 * Re-materialize approved join lanes whose session files were wiped (restart race,
 * preflight, complete wipe). Keeps the board from going blank while a runner still
 * heartbeats / holds an approved join. Idempotent.
 */
function rematerializeApprovedJoins() {
  const restored = []
  for (const jr of listJoinRequests('approved')) {
    if (!jr?.sessionId) continue
    if (isJunkJoin(jr)) continue
    // Skip pure test session ids from test-showtime / soak noise
    if (/^(v2a_|v2b_|v2d_|v2old_|v2done_|sess_armproof_|sess_codex|producer-main|ext-side|sess_demo_|sess_absorb_)/i.test(String(jr.sessionId))) {
      continue
    }
    const existing = readJsonSafe(sessionPath(jr.sessionId))
    if (existing) continue
    const pid = Number(jr.pid || jr.runnerPid || 0) || 0
    const live = isPidAlive(pid)
    // Flag on disk for this session under repo root (armed runner still working)
    let flagged = false
    try {
      const root = jr.repoPath || jr.primaryRepoPath || ''
      if (root) {
        const scratch = path.join(root, '.claude', 'scratch')
        if (fs.existsSync(scratch)) {
          const sid = String(jr.sessionId)
          flagged = fs.readdirSync(scratch).some(
            (f) => f.startsWith('autopro-on') && (f.includes(sid) || f.includes(sid.slice(0, 16))),
          )
        }
      }
    } catch { /* ignore */ }
    // STRICT: only restore if runner pid is alive OR autopro-on flag still present.
    // Never resurrect historical approved joins by timestamp alone (blank→junk flood).
    if (!live && !flagged) continue
    try {
      const s = registerSession({
        sessionId: jr.sessionId,
        repoId: jr.repoId,
        repoPath: jr.repoPath,
        branch: jr.branch,
        ledgerTitle: jr.ledgerTitle,
        ledgerPath: jr.ledgerPath,
        ledgerHash: jr.ledgerHash,
        logPath: jr.logPath,
        pid: pid || 0,
        status: jr.statusDesired || 'running',
        alarms: jr.alarms || undefined,
        timer: jr.timer || undefined,
      })
      jr.rematerializedAt = nowIso()
      jr.lane = s.lane
      jr.chatLabel = s.chatLabel
      jr.updatedAt = nowIso()
      try { writeJson(joinPath(jr.id), jr) } catch { /* ignore */ }
      restored.push(jr.sessionId)
      armBridgeLog(`rematerialize approved join session=${jr.sessionId} join=${jr.id} live=${live} flagged=${flagged}`)
    } catch (e) {
      armBridgeLog(`rematerialize fail session=${jr.sessionId} ${e?.message || e}`)
    }
  }
  if (restored.length) {
    writeJoinBeacon()
    broadcast('sessions', listSessionsEnriched())
  }
  return restored
}

function preflightSweep(opts = {}) {
  const staleAfterMs = Number(opts.staleAfterMs || STALE_AFTER_MS)
  const currentLedgerHash = opts.ledgerHash ? String(opts.ledgerHash) : ''
  const wipeComplete = opts.wipeComplete !== false
  // Default OFF — shared multi-ledger board must not erase a live foreign fleet.
  const killForeignLedgers = opts.killForeignLedgers === true || opts.forceKillActiveForeign === true
  const now = Date.now()
  const wiped = []
  const kept = []
  const handovers = []

  for (const raw of listSessions()) {
    const s = enrich(raw)
    const age = s.updatedAt ? now - new Date(s.updatedAt).getTime() : Infinity
    // Prefer ownership-enriched live flags; fall back to raw pid probe
    const alive = !!(s.pidAlive || s.workerAlive || isPidAlive(s.pid) || isPidAlive(s.runnerPid))
    const isComplete = s.status === 'complete'
    const differentLedger = currentLedgerHash && s.ledgerHash && s.ledgerHash !== currentLedgerHash
    const isStaleDead = !alive && age >= staleAfterMs
    const isZombie = !alive && ['running', 'in-progress', 'queued', 'stalled', 'blocked', 'paused', 'needs_input'].includes(s.status) && age >= staleAfterMs

    // HARD RULE: never wipe a live runner — empty board is worse than a twin card
    if (alive && !isComplete) {
      kept.push({
        sessionId: s.sessionId,
        why: differentLedger ? 'live-different-ledger' : 'live-pid',
        ageSec: Math.round(age / 1000),
        pidAlive: true,
        ledgerHash: s.ledgerHash || null,
      })
      continue
    }

    if (isComplete && wipeComplete && !alive) {
      const ho = createHandoverFromSession(s, 'complete')
      if (ho) handovers.push(ho)
      unregisterSession(s.sessionId)
      wiped.push({ sessionId: s.sessionId, why: 'complete' })
      continue
    }
    // Foreign ledger wipe only when explicitly requested AND dead/stale
    if (differentLedger && age >= staleAfterMs && killForeignLedgers && !alive) {
      const ho = createHandoverFromSession(s, 'stale-different-ledger')
      if (ho) handovers.push(ho)
      unregisterSession(s.sessionId)
      wiped.push({ sessionId: s.sessionId, why: 'stale-different-ledger', ageSec: Math.round(age / 1000), pidAlive: false, ledgerHash: s.ledgerHash || null })
      continue
    }
    if (isStaleDead || isZombie) {
      const reason = 'stale'
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
  broadcast('sessions', listSessionsEnriched())
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
  // Questions are SA → operator holds only. Operator commands use /steers or /nudge.
  s.questions = s.questions || []
  s.questions.unshift(q)
  s.status = 'needs_input'
  s.stopReason = `SA needs input: ${q.text.slice(0, 80)}`
  s.updatedAt = nowIso()
  pushSentinel(s, `SA hold opened on ${q.sliceId || 'lane'}: ${q.text.slice(0, 100)}`, 'warn')
  writeJson(sessionPath(sessionId), s)
  const e = enrich(s)
  broadcast('sessions', listSessionsEnriched())
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
  broadcast('sessions', listSessionsEnriched())
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
  // Cross-repo / home absorb: durable inbox in the target repo scratch
  try {
    getFleet().appendHomeInbox(s.primaryRepoPath || s.repoPath, {
      op: 'steer',
      fleetId: s.fleetId || null,
      sessionId,
      subAgentId: s.subAgentId,
      text: steer.text,
      target: steer.target,
      kind: 'steer',
    })
  } catch { /* ignore */ }
  pushSentinel(s, `Steer queued for ${steer.target || 'next slice'}`, 'info')
  writeJson(sessionPath(sessionId), s)
  broadcast('sessions', listSessionsEnriched())
  return enrich(s)
}

/** Operator reconnect ping: 30s listen window + durable steer for runner. */
function addNudge(sessionId, body = {}) {
  const s = readJsonSafe(sessionPath(sessionId))
  if (!s) return null
  const listenSec = Math.max(5, Math.min(120, Number(body.listenSec) || 30))
  const at = nowIso()
  const listenUntil = new Date(Date.now() + listenSec * 1000).toISOString()
  // Ownership-aware: owner may inherit live disk pid
  const owned = listSessionsEnriched().find((x) => x.sessionId === sessionId)
  const alive = !!(owned?.pidAlive || isPidAlive(s.pid) || isPidAlive(owned?.pid))
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
  broadcast('sessions', listSessionsEnriched())
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

// --- SC-04: the projector (READ-ONLY) -------------------------------------
// Show Time projects; it does not act. This block is the ONLY place the board
// learns what a repo is doing, and it can do exactly one thing: GET
// /projector/status from that repo's companion. There is no git here, no spawn,
// no write of any kind — the board physically cannot strand work (SC-02).
// The one inbound path stays the nudge, which appends to the repo's
// showtime-inbox.jsonl for the runner to accept or IGNORE. A request, not a
// command.
const COMPANION_BASE = process.env.LOOPLET_COMPANION_BASE || 'http://127.0.0.1:4321'
// Cards refresh on every poll; a git fork per card per poll would be silly.
const PROJECTOR_TTL_MS = Number(process.env.SHOWTIME_PROJECTOR_TTL_MS || 4000)
const PROJECTOR_TIMEOUT_MS = 2500
const projectorCache = new Map() // repoPath -> { at, data }

/** Fetch one repo's live state. NEVER throws — a dead companion is a card. */
async function projectOne(repoPath) {
  const key = String(repoPath || '')
  const hit = projectorCache.get(key)
  if (hit && Date.now() - hit.at < PROJECTOR_TTL_MS) return hit.data
  let data
  try {
    const ac = new AbortController()
    const t = setTimeout(() => ac.abort(), PROJECTOR_TIMEOUT_MS)
    const r = await fetch(
      `${COMPANION_BASE}/projector/status?cwd=${encodeURIComponent(key)}`,
      { signal: ac.signal },
    ).finally(() => clearTimeout(t))
    const j = await r.json()
    data = j && j.ok
      ? { online: true, repoPath: key, ...j }
      // Companion answered but git didn't (not a repo / outside LOOPLET_ROOTS).
      // That is NOT "offline" — the companion is plainly up. Saying offline here
      // would send the operator hunting a dead server that is actually running.
      : { online: true, repoPath: key, ok: false, error: (j && j.error) || 'unavailable' }
  } catch (e) {
    // Companion down / unreachable / timed out → degrade, don't throw.
    data = {
      online: false,
      repoPath: key,
      ok: false,
      error: e?.name === 'AbortError' ? 'companion timeout' : 'companion offline',
    }
  }
  projectorCache.set(key, { at: Date.now(), data })
  return data
}

/**
 * One card per distinct repo behind the live lanes.
 * Emits only what the board actually renders — repoPath (the join key),
 * repoName, and the live projection. The lanes' own session data already
 * arrives via /api/sessions; re-shipping it here would be dead payload on
 * every poll.
 */
async function projectRepos() {
  const roots = new Map() // repoPath -> { repoName, sessionIds[] }
  for (const raw of listSessions()) {
    const s = enrich(raw)
    const repoPath = normalizeRepoRoot(s.primaryRepoPath || s.repoPath || '')
    if (!repoPath) continue
    if (!roots.has(repoPath)) {
      // Name the card after the path we ACTUALLY projected, not repoNameOf(s):
      // that reads s.repoPath, which on a legacy lane is a dead
      // .worktrees-showtime/sess_* leaf. repoNameFromPath then walks up past the
      // worktree dir and yields the PARENT of the repo (e.g. "LOOPLET" instead
      // of "ai-sidebar") — a card labelled with the wrong repo. repoPath here is
      // already normalizeRepoRoot()'d, so it is the real root.
      roots.set(repoPath, { repoName: repoNameFromPath(repoPath) || s.repoId || '', sessionIds: [] })
    }
    // Publish which lanes map to this repo. The CLIENT must not re-derive the
    // key: that would mean a second copy of the worktree-stripping regexes in
    // the browser, and two copies of a normalizer drift.
    roots.get(repoPath).sessionIds.push(s.sessionId)
  }
  const list = [...roots.entries()].map(([repoPath, v]) => ({ repoPath, ...v }))
  const live = await Promise.all(list.map((r) => projectOne(r.repoPath)))
  // Evict cache entries for repos no longer on the board — sessions come and go,
  // and an unevicted Map keyed by repoPath would grow for the server's lifetime.
  for (const key of projectorCache.keys()) {
    if (!roots.has(key)) projectorCache.delete(key)
  }
  return list.map((r, i) => ({ ...r, live: live[i] }))
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
    const sessions = listSessionsEnriched()
    return send(res, 200, { mission: missionRollup(sessions), sessions })
  }

  if (url.pathname === '/api/sessions' && req.method === 'GET') {
    // Heal blank board: restore approved joins whose session files vanished
    try { rematerializeApprovedJoins() } catch { /* ignore */ }
    const sessions = listSessionsEnriched()
    let fleets = []
    try { fleets = getFleet().enrichFleetsWithSessions() } catch { fleets = [] }
    return send(res, 200, {
      sessions,
      fleets,
      mission: missionRollup(sessions),
      partyRule: 'one-orch-per-repo-root',
      fleetsByRoot: fleetsByRepoRoot(),
      restored: true,
    })
  }

  // Party fleets: one ORCH per REPO ROOT (never split same root by ledger title)
  if (url.pathname === '/api/fleets' && req.method === 'GET') {
    return send(res, 200, {
      ok: true,
      fleets: fleetsByRepoRoot(),
      partyRule: 'one-orch-per-repo-root',
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

  // Operator tools: purge junk fleets; purge dead/twin corpses; re-arm by hand
  if (url.pathname === '/api/purge-junk' && req.method === 'POST') {
    const n = purgeJunkSessions()
    return send(res, 200, { ok: true, purged: n, sessions: listSessionsEnriched() })
  }
  if (url.pathname === '/api/purge-dead' && req.method === 'POST') {
    const n = purgeDeadSessions({ force: true })
    return send(res, 200, {
      ok: true,
      purged: n,
      sessions: listSessionsEnriched(),
      fleets: fleetsByRepoRoot(),
    })
  }
  if (url.pathname === '/api/arm' && req.method === 'POST') {
    try {
      const body = await readBody(req)
      const sid = String(body.sessionId || '').trim()
      const s = sid ? readJsonSafe(sessionPath(sid)) : null
      if (!s) return send(res, 404, { ok: false, error: 'session not found' })
      const arm = tryAutoArmAfterApprove({
        sessionId: s.sessionId,
        repoPath: s.repoPath || s.primaryRepoPath,
        ledgerPath: s.ledgerPath,
        ledgerTitle: s.ledgerTitle,
        repoId: s.repoId,
      }, s)
      return send(res, 200, { ok: true, arm, session: enrich(readJsonSafe(sessionPath(sid)) || s) })
    } catch (e) {
      return send(res, 400, { ok: false, error: String(e.message || e) })
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

  // SC-04 — the projection. Live repo truth, straight from each repo's own
  // companion. Read-only by construction: see projectRepos().
  if (url.pathname === '/api/projector' && req.method === 'GET') {
    const repos = await projectRepos()
    return send(res, 200, { ok: true, repos, at: nowIso() })
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
    try { rematerializeApprovedJoins() } catch { /* ignore */ }
    const sessions = listSessionsEnriched()
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
  console.log('[showtime] AUTO_ARM on Approve: enabled (set SHOWTIME_AUTO_ARM=0 to disable)')
  try {
    const n = purgeJunkSessions()
    if (n) console.log(`[showtime] purged ${n} junk session/fleet files on boot`)
  } catch (e) {
    console.warn('[showtime] purgeJunk failed', e?.message || e)
  }
  try {
    const r = rematerializeApprovedJoins()
    if (r.length) console.log(`[showtime] rematerialized ${r.length} approved join(s) on boot`)
  } catch (e) {
    console.warn('[showtime] rematerialize on boot failed', e?.message || e)
  }
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
    if (changed) broadcast('sessions', listSessionsEnriched())
  }, 5000)
}

process.on('SIGINT', () => cleanupAndExit(0))
process.on('SIGTERM', () => cleanupAndExit(0))
main().catch((e) => {
  console.error(e)
  process.exit(1)
})
