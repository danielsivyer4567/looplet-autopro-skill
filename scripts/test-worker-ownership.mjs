// test-worker-ownership.mjs — single-writer + corpse honesty (offline)
import assert from 'node:assert/strict'
import {
  normalizeRootKey,
  ownPidClaim,
  pickOwnerSessionId,
  applyOwnership,
  mayShowLegs,
} from './worker-ownership.mjs'

let failed = 0
function ok(cond, msg) {
  if (cond) console.log(`  OK  ${msg}`)
  else {
    console.error(`  FAIL ${msg}`)
    failed++
  }
}

console.log('worker-ownership (single-writer honesty)')

ok(normalizeRootKey('C:\\repos\\looplet-producer\\.worktrees-showtime\\sess_x') ===
  normalizeRootKey('C:\\repos\\looplet-producer'), 'worktree stripped for root key')
ok(ownPidClaim({ pid: 12 }) === 12, 'ownPidClaim reads pid')
ok(ownPidClaim({ runnerPid: 9 }) === 9, 'ownPidClaim reads runnerPid')

const alive = (n) => n === 77080 || n === 51784
const owner = pickOwnerSessionId(
  [
    { sessionId: 'sess_a', pid: 0, updatedAt: '2026-01-01' },
    { sessionId: 'sess_b', pid: 77080, updatedAt: '2026-01-02' },
  ],
  { flagOwnerId: 'sess_a', diskPid: 77080, isPidAlive: alive },
)
ok(owner === 'sess_a', 'autopro-on flag wins owner over other pid claim')

const owner2 = pickOwnerSessionId(
  [
    { sessionId: 'sess_a', pid: 0 },
    { sessionId: 'sess_b', pid: 77080 },
  ],
  { diskPid: 77080, isPidAlive: alive },
)
ok(owner2 === 'sess_b', 'disk pid match picks owner when no flag')

const sessions = applyOwnership(
  [
    {
      sessionId: 'sess_owner',
      repoPath: 'C:\\repos\\looplet-producer',
      pid: 0,
      status: 'running',
      updatedAt: '2026-07-15T01:00:00Z',
    },
    {
      sessionId: 'sess_twin',
      repoPath: 'C:\\repos\\looplet-producer',
      pid: 77080,
      status: 'running',
      updatedAt: '2026-07-15T00:00:00Z',
    },
    {
      sessionId: 'sess_dead',
      repoPath: 'C:\\LOOPLET\\ai-sidebar',
      pid: 58608,
      status: 'stalled',
      updatedAt: '2026-07-15T00:00:00Z',
    },
  ],
  {
    rootKeyOf: (s) => normalizeRootKey(s.repoPath),
    isPidAlive: (n) => n === 77080,
    readDiskPid: (k) => (k.includes('looplet-producer') ? 77080 : 0),
    readFlagOwner: (k) => (k.includes('looplet-producer') ? 'sess_owner' : ''),
  },
)

const o = sessions.find((s) => s.sessionId === 'sess_owner')
const t = sessions.find((s) => s.sessionId === 'sess_twin')
const d = sessions.find((s) => s.sessionId === 'sess_dead')

ok(o.isWorkerOwner === true, 'flag session is owner')
ok(o.pidAlive === true && o.pid === 77080, 'owner inherits disk worker pid')
ok(t.isWorkerOwner === false, 'other same-root session is not owner')
ok(t.pidAlive === false, 'twin does NOT get legs via shared disk pid')
ok(t.ledgerProjector === true, 'same-root other session with ledger stays as projector')
ok(t.corpse !== true, 'ledger projector is not a corpse')
ok(d.pidAlive === false, 'dead sidebar not alive')
// sess_dead has no ledger fields → corpse
ok(d.corpse === true || d.ledgerProjector === true, 'dead sidebar is corpse or projector')
ok(mayShowLegs(o, () => false) === true, 'owner may show legs when not idle')
ok(mayShowLegs(t, () => false) === false, 'projector may not show legs')
ok(mayShowLegs(d, () => false) === false, 'corpse may not show legs')

// Two titles same root → same ownership pool
const sameRoot = applyOwnership(
  [
    { sessionId: 'a', repoPath: 'C:/repos/looplet-producer', ledgerTitle: 'Title A', status: 'running', pid: 1 },
    { sessionId: 'b', repoPath: 'C:/repos/looplet-producer', ledgerTitle: 'Title B', status: 'running', pid: 1 },
  ],
  {
    rootKeyOf: (s) => normalizeRootKey(s.repoPath),
    isPidAlive: (n) => n === 1,
    readDiskPid: () => 1,
    readFlagOwner: () => 'a',
  },
)
ok(sameRoot.filter((s) => s.isWorkerOwner).length === 1, 'exactly one owner per root')
ok(sameRoot.filter((s) => s.pidAlive).length === 1, 'exactly one pidAlive per root when single disk pid')

if (failed) {
  console.error(`\nFAILED ${failed}`)
  process.exit(1)
}
console.log('\nALL OK')
