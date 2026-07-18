#!/usr/bin/env node
/**
 * test-selectable-agent.mjs — prove steers hit only the selected agent/fleet.
 * Requires theater on 127.0.0.1:8770.
 */
import fs from 'node:fs'
import path from 'node:path'
import http from 'node:http'
import os from 'node:os'

const BASE = process.env.SHOWTIME_BASE || 'http://127.0.0.1:8770'
const HOME = process.env.USERPROFILE || process.env.HOME || os.homedir()
const TOKEN_FILE = path.join(HOME, '.claude', 'scratch', 'autopro-theater', 'server.token')

function token() {
  try {
    return fs.readFileSync(TOKEN_FILE, 'utf8').trim()
  } catch {
    return ''
  }
}

function req(method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlPath, BASE)
    const t = token()
    const payload = body != null ? JSON.stringify(body) : null
    const r = http.request(
      {
        hostname: u.hostname,
        port: u.port,
        path: u.pathname + u.search,
        method,
        headers: {
          'Content-Type': 'application/json',
          ...(t ? { 'X-Showtime-Token': t } : {}),
          ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
        },
      },
      (res) => {
        let data = ''
        res.on('data', (c) => (data += c))
        res.on('end', () => {
          let json = null
          try {
            json = JSON.parse(data)
          } catch {
            json = data
          }
          resolve({ status: res.statusCode, json })
        })
      },
    )
    r.on('error', reject)
    if (payload) r.write(payload)
    r.end()
  })
}

async function joinAndApprove(body) {
  const j = await req('POST', '/api/join-requests', body)
  if (j.json?.status === 'already_on_board' && j.json.session) return j.json.session
  if (j.json?.request?.id) {
    const ap = await req('POST', `/api/join-requests/${j.json.request.id}/approve`, { by: 'test-selectable' })
    if (!ap.json?.session) throw new Error('approve failed: ' + JSON.stringify(ap.json))
    return ap.json.session
  }
  // try direct
  const reg = await req('POST', '/api/sessions', body)
  if (reg.json?.session) return reg.json.session
  throw new Error('join failed: ' + JSON.stringify(j.json))
}

function assert(cond, msg) {
  if (!cond) {
    console.error('FAIL:', msg)
    process.exit(1)
  }
  console.log('OK:', msg)
}

async function main() {
  const health = await req('GET', '/api/health')
  assert(health.status === 200 && health.json?.ok, 'theater health')

  const aBody = {
    sessionId: 'sess_sel_a_' + Date.now().toString(36),
    repoId: 'SelA',
    repoPath: path.join(HOME, '.claude', 'scratch', 'sel-a-repo'),
    primaryRepoPath: path.join(HOME, '.claude', 'scratch', 'sel-a-repo'),
    branch: 'main',
    ledgerTitle: 'Selectable Agent Test A',
    ledgerHash: 'a'.repeat(64),
    ledgerKey: 'a'.repeat(64),
    status: 'running',
  }
  const bBody = {
    sessionId: 'sess_sel_b_' + Date.now().toString(36),
    repoId: 'SelB',
    repoPath: path.join(HOME, '.claude', 'scratch', 'sel-b-repo'),
    primaryRepoPath: path.join(HOME, '.claude', 'scratch', 'sel-b-repo'),
    branch: 'main',
    ledgerTitle: 'Selectable Agent Test B',
    ledgerHash: 'b'.repeat(64),
    ledgerKey: 'b'.repeat(64),
    status: 'running',
  }

  // Ensure scratch roots exist for inbox
  fs.mkdirSync(path.join(aBody.primaryRepoPath, '.claude', 'scratch'), { recursive: true })
  fs.mkdirSync(path.join(bBody.primaryRepoPath, '.claude', 'scratch'), { recursive: true })

  const sessA = await joinAndApprove(aBody)
  const sessB = await joinAndApprove(bBody)
  assert(sessA.sessionId && sessB.sessionId, 'two sessions registered')
  assert(sessA.fleetId && sessB.fleetId, 'both have fleetId')
  assert(sessA.fleetId !== sessB.fleetId, 'different fleets')

  const mark = 'SELECTABLE_PROOF_' + Date.now()
  const steer = await req('POST', `/api/sessions/${sessA.sessionId}/steers`, {
    text: mark,
    target: 'proof',
  })
  assert(steer.status === 200, 'steer to A ok')

  const list = await req('GET', '/api/sessions')
  const a = (list.json.sessions || []).find((s) => s.sessionId === sessA.sessionId)
  const b = (list.json.sessions || []).find((s) => s.sessionId === sessB.sessionId)
  const aHas = (a?.steers || []).some((s) => String(s.text || '').includes(mark))
  const bHas = (b?.steers || []).some((s) => String(s.text || '').includes(mark))
  assert(aHas, 'steer present on A only (selected agent)')
  assert(!bHas, 'steer NOT on B')

  const fleets = await req('GET', '/api/fleets')
  assert(fleets.json?.partyRule === 'one-orch-per-ledger', 'partyRule present')
  assert((fleets.json?.fleets || []).length >= 2, 'at least two fleets listed')

  // Nudge A → inbox
  await req('POST', `/api/sessions/${sessA.sessionId}/nudge`, { listenSec: 10 })
  const inboxPath = path.join(aBody.primaryRepoPath, '.claude', 'scratch', 'showtime-inbox.jsonl')
  let inboxOk = false
  try {
    const raw = fs.readFileSync(inboxPath, 'utf8')
    inboxOk = raw.includes('nudge') && raw.includes(sessA.sessionId)
  } catch {
    inboxOk = false
  }
  assert(inboxOk, 'nudge wrote home showtime-inbox.jsonl for A')

  // Cleanup
  if (sessA.fleetId) await req('POST', `/api/fleets/${sessA.fleetId}/leave`, { reason: 'test' })
  if (sessB.fleetId) await req('POST', `/api/fleets/${sessB.fleetId}/leave`, { reason: 'test' })

  console.log('\nPASS selectable-agent isolation')
  process.exit(0)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
