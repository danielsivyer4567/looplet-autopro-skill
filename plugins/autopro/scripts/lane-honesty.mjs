// lane-honesty.mjs — pure MAP/CLAW shared honesty decisions.
// Theater index.html mirrors laneHonesty() (no bundler). Keep in sync.
// Server flags: isWorkerOwner, pidAlive, workerAlive, corpse, ledgerProjector.

/**
 * Idle-like owner (live pid but not mid-work). Mirrors isWorkerIdle without
 * requiring sessionHasWorker first.
 * @param {object} s
 * @returns {boolean}
 */
export function isIdleLike(s) {
  if (!s) return true
  if (s.slice?.state === 'in-progress') return false
  if ((s.counts?.inProgress || 0) > 0) return false
  const st = String(s.status || '').toLowerCase()
  if (/^(blocked|stalled|paused|complete|done|needs_input|queued|idle)$/.test(st)) return true
  if (st === 'running' || st === 'in-progress') return false
  return true
}

/**
 * Shared honesty kind for MAP Pac lanes and CLAW labels.
 * @param {object|null} s - session enriched by theater-server
 * @returns {{
 *   kind: 'owner-coding'|'owner-idle'|'projector'|'corpse'|'unarmed',
 *   showPac: boolean,
 *   showGhost: boolean,
 *   coding: boolean,
 *   dim: boolean,
 *   pacCalm: boolean,
 *   label: string,
 *   metaHint: string,
 * }}
 */
export function laneHonesty(s) {
  if (!s) {
    return {
      kind: 'unarmed',
      showPac: false,
      showGhost: false,
      coding: false,
      dim: true,
      pacCalm: true,
      label: 'empty',
      metaHint: '',
    }
  }

  // True corpse (no ledger identity) — dead strip
  if (s.corpse && !s.ledgerProjector) {
    return {
      kind: 'corpse',
      showPac: false,
      showGhost: true,
      coding: false,
      dim: true,
      pacCalm: true,
      label: 'DEAD',
      metaHint: 'DEAD',
    }
  }

  // Separate ledger on shared board — visible, never "coding writer"
  if (s.ledgerProjector || s.isWorkerOwner === false) {
    return {
      kind: 'projector',
      showPac: true,
      showGhost: false,
      coding: false,
      dim: false,
      pacCalm: true,
      label: 'LEDGER',
      metaHint: 'LEDGER',
    }
  }

  const alive = s.pidAlive === true || s.workerAlive === true
  if (!alive) {
    return {
      kind: 'unarmed',
      showPac: true,
      showGhost: true,
      coding: false,
      dim: true,
      pacCalm: true,
      label: 'on board · not armed',
      metaHint: 'BOARD',
    }
  }

  if (!isIdleLike(s)) {
    return {
      kind: 'owner-coding',
      showPac: true,
      showGhost: false,
      coding: true,
      dim: false,
      pacCalm: false,
      label: 'coding',
      metaHint: 'CODING',
    }
  }

  return {
    kind: 'owner-idle',
    showPac: true,
    showGhost: false,
    coding: false,
    dim: false,
    pacCalm: true,
    label: 'armed · idle',
    metaHint: 'IDLE',
  }
}

/** True when MAP/CLAW may claim "RUNNING" / coding pac / legs. */
export function mayClaimCoding(s) {
  return laneHonesty(s).coding === true
}
