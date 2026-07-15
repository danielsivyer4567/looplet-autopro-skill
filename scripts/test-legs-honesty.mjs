// scripts/test-legs-honesty.mjs
// SC-R04 offline proof: legs march only when a live worker pid is coding.
// Pure source scan + pure logic mirror of theater/index.html helpers.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const html = readFileSync(join(root, 'theater', 'index.html'), 'utf8')

let failed = 0
function ok(cond, msg){
  if(cond) console.log(`  OK  ${msg}`)
  else { console.error(`  FAIL ${msg}`); failed++ }
}

// --- Pure mirror of legs helpers (keep in sync with index.html) ---
function sessionHasWorker(s){
  if(!s) return false
  if(s.workerAlive === true || s.pidAlive === true) return true
  if(s.workerAlive === false || s.pidAlive === false) return false
  if(s.workerDead === true) return false
  return false
}
function isWorkerIdle(s){
  if(!sessionHasWorker(s)) return true
  if(s.slice?.state === 'in-progress') return false
  if((s.counts?.inProgress || 0) > 0) return false
  const st = String(s.status || '')
  if(/^(running|in-progress)$/i.test(st) && s.slice?.state === 'in-progress') return false
  return true
}
function legsShouldRun(s){
  return sessionHasWorker(s) && !isWorkerIdle(s)
}

console.log('SC-R04 legs honesty')

// Source contract: orbit-agent must not hardcode running alone
ok(!/claw-icon running orbit-agent/.test(html),
  'orbit-agent no longer hardcodes class="running"')
ok(/function legsShouldRun\s*\(/.test(html),
  'legsShouldRun helper present')
ok(/perimSvgHtml\([^)]*legsRunning/.test(html) || /legsRunning\s*=\s*false/.test(html),
  'perimSvgHtml accepts legsRunning flag')
ok(/data-legs=/.test(html),
  'orbit agent exposes data-legs for stiff|run')
ok(/on board · not armed/.test(html),
  'SC card / SA copy includes "on board · not armed"')
ok(/legsShouldRun\(s\)/.test(html),
  'render path calls legsShouldRun')
// advance must freeze without worker, not invent motion
ok(/No live pid → freeze crawl|!sessionHasWorker\(s\)\) return currentPerimPct/.test(html),
  'perimeter freezes without live pid')

// Pure logic fixtures
ok(legsShouldRun(null) === false, 'null session → no legs')
ok(legsShouldRun({}) === false, 'empty session → no legs')
ok(legsShouldRun({ status: 'running', slice: { state: 'in-progress' } }) === false,
  'status=running without pidAlive → no legs')
ok(legsShouldRun({ pidAlive: false, status: 'running', slice: { state: 'in-progress' } }) === false,
  'pidAlive=false → no legs')
ok(legsShouldRun({ pidAlive: true, status: 'blocked', slice: { state: 'blocked' } }) === false,
  'live pid but idle/blocked → stiff (no legs)')
ok(legsShouldRun({ pidAlive: true, status: 'running', slice: { state: 'in-progress' } }) === true,
  'pidAlive + in-progress → legs')
ok(legsShouldRun({ workerAlive: true, counts: { inProgress: 1 } }) === true,
  'workerAlive + counts.inProgress → legs')
ok(legsShouldRun({ workerAlive: true, status: 'paused' }) === false,
  'workerAlive + paused → stiff')

if(failed){
  console.error(`\nFAILED ${failed}`)
  process.exit(1)
}
console.log('\nALL OK')
