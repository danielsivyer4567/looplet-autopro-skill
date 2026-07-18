// test-map-select-nudge.mjs — SC-05: MAP lane → ORCH steers/nudge target (offline)
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

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

console.log('SC-05 MAP select → ORCH nudge/steer wire')

// MAP click binds setSelectedAgent from data-id
ok(/querySelectorAll\(['"]\.lane['"]\)/.test(html), 'renderLanes binds .lane clicks')
ok(/setSelectedAgent\s*\(\s*\{\s*sessionId:/.test(html)
  || /setSelectedAgent\(\{\s*sessionId:\s*sid/.test(html)
  || /setSelectedAgent\(\{\s*sessionId:\s*el\.dataset\.id/.test(html),
  'MAP click calls setSelectedAgent with sessionId')
ok(/data-id="\$\{s\.sessionId\}"/.test(html) || /data-id="\$\{[^}]*sessionId/.test(html),
  'lanes expose data-id=sessionId')

// Desk actions target session routes
ok(/function targetSessionId\s*\(/.test(html), 'targetSessionId helper exists')
ok(/\/api\/sessions\/\$\{tid\}\/steers/.test(html) || /\/api\/sessions\/\$\{[^}]+\}\/steers/.test(html),
  'steers POST uses session path')
ok(/\/api\/sessions\/\$\{sid\}\/nudge/.test(html)
  || /\/api\/sessions\/\$\{encodeURIComponent\(sessionId\)\}\/nudge/.test(html)
  || /\/api\/sessions\/[^`]*nudge/.test(html),
  'nudge POST uses session path')
ok(/data-tell-steer/.test(html) && /data-tell-nudge/.test(html),
  'ORCH desk Tell SA + Nudge controls present')
ok(/btn-steer/.test(html) && /targetSessionId\s*\(\s*\)/.test(html),
  'Comment/Steer panel uses targetSessionId')

// SC-05: selectedId wins over stale picker
ok(/selectedId.*wins|explicit MAP\/CLAW lane click|selectedId\)\s*\{[\s\S]{0,200}bySess/i.test(html)
  || /SC-05: explicit MAP\/CLAW/.test(html),
  'ensureSelectedAgent prefers selectedId (MAP/CLAW click)')
ok(/\.lane\.sel/.test(html), 'CSS: selected MAP lane (.lane.sel)')
ok(/selectedId===s\.sessionId/.test(html) || /selectedId && selectedId===s\.sessionId/.test(html),
  'mapLaneHtml marks sel when selectedId matches')
ok(/#ledges \.ledge\[data-id=/.test(html) || /ledge\[data-id=/.test(html),
  'MAP select scrolls ORCH ledge for sessionId')

// CLAW parity: branch click also setSelectedAgent
ok(/setSelectedAgent\(\{\s*sessionId:\s*sid,\s*role:\s*['"]worker['"]/.test(html),
  'CLAW/MAP both setSelectedAgent worker key for sid')

if (failed) {
  console.error(`\nFAILED ${failed}`)
  process.exit(1)
}
console.log('\nALL OK')
