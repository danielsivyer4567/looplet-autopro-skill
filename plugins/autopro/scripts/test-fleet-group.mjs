// Offline unit tests for fleet isolation (no Show Time / no browser).
import assert from 'node:assert/strict'
import {
  normalizeRepoKey,
  isJunkSession,
  fleetGroupKey,
  classifyFleetRole,
  groupSessionsByFleet,
} from './fleet-group.mjs'

// normalizeRepoKey
assert.equal(
  normalizeRepoKey('C:\\repos\\looplet-producer\\.worktrees-showtime\\sess_abc'),
  normalizeRepoKey('C:/repos/looplet-producer'),
)
assert.equal(
  normalizeRepoKey('C:\\LOOPLET\\ai-sidebar'),
  'c:/looplet/ai-sidebar',
)

// junk
assert.equal(isJunkSession({ sessionId: 'sound-test-1' }), true)
assert.equal(isJunkSession({ sessionId: 'LOUD-123', ledgerTitle: 'x' }), true)
assert.equal(isJunkSession({ sessionId: 'sess_real', ledgerTitle: 'SOUND TEST alarm' }), true)
assert.equal(isJunkSession({ sessionId: 'sess_real', ledgerTitle: 'OTIS LIVE remaining' }), false)

// keys: same repo different fleetIds still same group
const a = {
  sessionId: 's1',
  fleetId: 'fleet_aaa',
  repoPath: 'C:\\repos\\looplet-producer',
  ledgerTitle: 'Looplet Producer ledger',
  counts: { done: 29, pending: 38, inProgress: 1 },
}
const b = {
  sessionId: 's2',
  fleetId: 'fleet_bbb', // different fleet id, SAME repo
  repoPath: 'C:\\repos\\looplet-producer\\.worktrees-showtime\\sess_x',
  ledgerTitle: 'Looplet Producer - autonomous creator',
  counts: { done: 1, pending: 0, inProgress: 0 },
}
const c = {
  sessionId: 's3',
  fleetId: 'fleet_ccc',
  repoPath: 'C:\\LOOPLET\\ai-sidebar',
  ledgerTitle: 'OTIS LIVE remaining (extension)',
  counts: { done: 6, pending: 4, inProgress: 0 },
}
const junk = {
  sessionId: 'BLAST-1',
  fleetId: 'fleet_junk',
  repoPath: 'C:\\LOOPLET\\ai-sidebar',
  ledgerTitle: 'BLAST SOUND NOW',
  counts: { done: 0, pending: 0, inProgress: 0 },
}

assert.equal(fleetGroupKey(a), fleetGroupKey(b), 'worktree leaf must collapse to same repo key')
assert.notEqual(fleetGroupKey(a), fleetGroupKey(c), 'producer ≠ extension')

const groups = groupSessionsByFleet([a, b, c, junk])
assert.equal(groups.length, 2, 'junk dropped; two real repos only')

const producer = groups.find((g) => /producer/i.test(g.title + g.path))
const extension = groups.find((g) => /ai-sidebar|otis/i.test(g.title + g.path))
assert.ok(producer, 'producer group exists')
assert.ok(extension, 'extension group exists')
assert.equal(producer.sessions.length, 2, 'both producer sessions in one column')
assert.equal(extension.sessions.length, 1, 'extension alone')
assert.equal(producer.role, 'primary', 'producer is MAIN')
assert.equal(extension.role, 'side', 'extension is SIDE')
assert.equal(groups[0].role, 'primary', 'MAIN column first')

// Mixed wrong fleetId must not put extension under producer
const evil = {
  sessionId: 's4',
  fleetId: a.fleetId, // pretends same fleet as producer
  repoPath: 'C:\\LOOPLET\\ai-sidebar',
  ledgerTitle: 'OTIS LIVE remaining',
  counts: { done: 0, pending: 1, inProgress: 0 },
}
const g2 = groupSessionsByFleet([a, evil])
assert.equal(g2.length, 2, 'repoPath wins over fleetId — never mix')
assert.ok(g2.every((g) => g.sessions.every((s) => {
  const key = fleetGroupKey(s)
  return g.sessions.every((t) => fleetGroupKey(t) === key)
})), 'each column is pure')

assert.equal(classifyFleetRole({ title: 'Looplet Producer', path: 'c:/repos/looplet-producer' }), 'primary')
assert.equal(classifyFleetRole({ title: 'OTIS LIVE', path: 'c:/looplet/ai-sidebar' }), 'side')

// SC-03: MAP uses same grouping — 2 same root + 1 other → 2 groups (headers)
const mapGroups = groupSessionsByFleet([a, b, c])
assert.equal(mapGroups.length, 2, 'MAP: 2 sessions same root + 1 other → 2 fleet sections')
assert.equal(mapGroups.find(g => /producer/i.test(g.title + g.path))?.sessions.length, 2,
  'MAP: both producer sessions under one header')
assert.equal(mapGroups.find(g => /ai-sidebar|otis/i.test(g.title + g.path))?.sessions.length, 1,
  'MAP: extension alone under side header')

// index.html MAP must call groupSessionsByFleet
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'theater', 'index.html'), 'utf8')
assert.match(html, /groupSessionsByFleet\s*\(\s*sessions\s*\)/, 'renderLanes uses groupSessionsByFleet')
assert.match(html, /map-fleet/, 'MAP fleet section CSS/class present')

console.log('ALL OK — test-fleet-group offline green')
