// test-join-popup.mjs — OS join popup has APPROVE/DENY + payload fields (offline)
import { readFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const ps1 = join(root, 'scripts', 'join-alarm-loud.ps1')
const server = readFileSync(join(root, 'scripts', 'theater-server.mjs'), 'utf8')
const html = readFileSync(join(root, 'theater', 'index.html'), 'utf8')

let failed = 0
function ok(cond, msg) {
  if (cond) console.log(`  OK  ${msg}`)
  else {
    console.error(`  FAIL ${msg}`)
    failed++
  }
}

console.log('join-alarm Approve/Deny popup')

ok(existsSync(ps1), 'scripts/join-alarm-loud.ps1 exists')
const src = existsSync(ps1) ? readFileSync(ps1, 'utf8') : ''
ok(/APPROVE/.test(src) && /DENY/.test(src), 'popup has APPROVE and DENY labels')
ok(/Invoke-JoinAct|join-requests/.test(src), 'popup posts to join-requests API')
ok(/X-Showtime-Token/.test(src), 'popup sends board token')
ok(/join-requests\/.*\$act|Invoke-JoinAct\s+['"]approve['"]|Invoke-JoinAct\s+['"]deny['"]/.test(src)
  && /Invoke-JoinAct\s*['"]approve['"]/.test(src)
  && /Invoke-JoinAct\s*['"]deny['"]/.test(src),
  'approve and deny actions call API')
ok(/TopMost\s*=\s*\$true/.test(src), 'popup is topmost (visible over other apps)')
ok(/os-toast/.test(src), 'marks by=os-toast')

ok(/ensureJoinAlarmScript/.test(server), 'server ensureJoinAlarmScript present')
ok(/join-alarm-loud\.ps1/.test(server), 'server copies skill join-alarm-loud.ps1')
ok(/joinId:\s*jr\.id/.test(server), 'payload includes joinId')
ok(/repoId:\s*jr\.repoId/.test(server), 'payload includes repoId')
ok(/boardUrl:/.test(server), 'payload includes boardUrl')
ok(/APPROVE or DENY on the popup/.test(server), 'body tells operator about popup buttons')
ok(/isSilentJoin|silent_test_join|showtime-test-repos/.test(server), 'server silences test-showtime join alarms')
ok(/JOIN_OS_ALERT_COOLDOWN|lastJoinOsAlertAt|cooldown/.test(server), 'server rate-limits OS join alarms')

ok(/data-act="approve"/.test(html) && /data-act="deny"/.test(html), 'board join-gate has approve/deny')
ok(/APPROVE<\/button>/.test(html) && /DENY<\/button>/.test(html), 'board buttons are big APPROVE/DENY labels')

if (failed) {
  console.error(`\nFAILED ${failed}`)
  process.exit(1)
}
console.log('\nALL OK')
