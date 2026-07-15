// test-lane-honesty.mjs — MAP/CLAW shared honesty (offline) + SC-04 paint contracts
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { laneHonesty, mayClaimCoding, isIdleLike } from './lane-honesty.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const html = readFileSync(join(root, 'theater', 'index.html'), 'utf8')

let failed = 0
function ok(cond, msg) {
  if (cond) console.log(`  OK  ${msg}`)
  else {
    console.error(`  FAIL ${msg}`)
    failed++
  }
}

console.log('lane-honesty (MAP/CLAW shared)')

// Pure logic
ok(laneHonesty(null).kind === 'unarmed', 'null → unarmed')
ok(laneHonesty({ corpse: true }).kind === 'corpse', 'corpse → DEAD')
ok(laneHonesty({ corpse: true }).showPac === false, 'corpse → no pac')
ok(laneHonesty({ corpse: true }).metaHint === 'DEAD', 'corpse meta DEAD')

ok(laneHonesty({ ledgerProjector: true, status: 'running' }).kind === 'projector', 'projector flag')
ok(laneHonesty({ isWorkerOwner: false, status: 'running' }).kind === 'projector', 'non-owner → projector')
ok(mayClaimCoding({ ledgerProjector: true, status: 'running', pidAlive: true }) === false,
  'projector never claims coding')
ok(laneHonesty({ ledgerProjector: true }).showPac === true, 'projector still shows calm pac')
ok(laneHonesty({ ledgerProjector: true }).pacCalm === true, 'projector pac is calm')
ok(laneHonesty({ ledgerProjector: true }).metaHint === 'LEDGER', 'projector meta LEDGER')

ok(laneHonesty({ isWorkerOwner: true, pidAlive: false }).kind === 'unarmed', 'owner dead pid → unarmed')
ok(mayClaimCoding({ isWorkerOwner: true, pidAlive: false, status: 'running' }) === false,
  'dead owner never coding')

const coding = laneHonesty({
  isWorkerOwner: true,
  pidAlive: true,
  status: 'running',
  slice: { state: 'in-progress' },
})
ok(coding.kind === 'owner-coding', 'owner + running + in-progress → owner-coding')
ok(coding.coding === true && coding.showPac === true, 'owner-coding shows active pac')
ok(coding.pacCalm === false, 'owner-coding pac is not calm (marches)')
ok(coding.metaHint === 'CODING', 'owner-coding meta')
ok(mayClaimCoding({ isWorkerOwner: true, pidAlive: true, status: 'running' }) === true,
  'owner running claims coding even if slice pending (ledger lag)')

const idle = laneHonesty({
  isWorkerOwner: true,
  pidAlive: true,
  status: 'paused',
})
ok(idle.kind === 'owner-idle' || isIdleLike({ status: 'paused' }), 'paused owner idle-like')
ok(mayClaimCoding({ isWorkerOwner: true, pidAlive: true, status: 'blocked' }) === false,
  'blocked owner not coding')

// SC-04: unarmed board-only is never RUNNING/coding
const board = laneHonesty({ isWorkerOwner: true, pidAlive: false, status: 'running' })
ok(board.kind === 'unarmed', 'unarmed kind')
ok(board.coding === false && board.pacCalm === true, 'unarmed stiff pac, not coding')
ok(board.metaHint === 'BOARD', 'unarmed meta BOARD')
ok(board.showGhost === true, 'unarmed may show ghost')

// index.html must define/use laneHonesty for MAP
ok(/function laneHonesty\s*\(/.test(html), 'index.html defines laneHonesty')
ok(/laneHonesty\s*\(\s*s\s*\)/.test(html) || /const h\s*=\s*laneHonesty/.test(html),
  'renderLanes (or map path) calls laneHonesty')
ok(/metaHint|CODING|LEDGER|DEAD/.test(html), 'MAP paint uses honesty meta hints')

// SC-04 paint contracts in mapLaneHtml
ok(/corpse-strip/.test(html), 'MAP has corpse-strip collapsed DEAD path')
ok(/DEAD · no writer/.test(html), 'corpse strip label present')
ok(/function pacSpriteHtml\s*\([^)]*calm/.test(html) || /pacSpriteHtml\(pacPct,\s*h\.pacCalm/.test(html),
  'pacSpriteHtml accepts calm flag')
ok(/\.h-pac\.calm/.test(html), 'CSS: calm pac (no chomp look)')
ok(/h-pac\.calm\s+\.mouth\s*\{[^}]*animation:\s*none/.test(html.replace(/\s+/g, ' '))
  || /\.h-pac\.calm\s+\.mouth\{animation:none\}/.test(html),
  'CSS: calm pac mouth animation none')
ok(/if\s*\(\s*h\.coding\s*\)\s*statusBits\.push\(\s*['"]RUNNING['"]\s*\)/.test(html)
  || /if\(h\.coding\)\s*statusBits\.push\(['"]RUNNING['"]\)/.test(html),
  'RUNNING only pushed when h.coding')
// Ensure we don't have a bare status===running → RUNNING path for MAP
ok(!/statusBits\.push\(['"]RUNNING['"]\).*status\s*===\s*['"]running['"]/.test(html)
  && !/st\s*===\s*['"]running['"][\s\S]{0,40}statusBits\.push\(['"]RUNNING['"]\)/.test(html),
  'no status-alone RUNNING claim near statusBits')
ok(/kind===['"]projector['"][\s\S]{0,80}LEDGER/.test(html)
  || /h\.kind==='projector'/.test(html),
  'projector kind gates LEDGER paint')
ok(/data-honesty=/.test(html), 'lanes expose data-honesty kind')

if (failed) {
  console.error(`\nFAILED ${failed}`)
  process.exit(1)
}
console.log('\nALL OK')
