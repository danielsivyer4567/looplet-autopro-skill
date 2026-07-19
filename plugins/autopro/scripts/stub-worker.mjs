#!/usr/bin/env node
/**
 * stub-worker.mjs — AutoPro soak / offline worker.
 *
 * Completes ONE ledger slice per invocation (serial AutoPro contract):
 *   1. Read .claude/scratch/ledger.md
 *   2. Mark first [pending]|[in-progress] → [done]
 *   3. Write soak-out/<SC-id>.txt + git commit
 *   4. Print a tiny JSON usage line for board stats
 *
 * Never used by -Engine auto. Pin with -Engine stub.
 */
import fs from 'node:fs'
import path from 'node:path'
import { execSync } from 'node:child_process'

function parseArgs(argv) {
  let prompt = ''
  let cwd = process.cwd()
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '-p' || a === '--prompt') {
      prompt = String(argv[++i] || '')
      continue
    }
    if (a === '--cwd' || a === '-C') {
      cwd = String(argv[++i] || cwd)
      continue
    }
  }
  // Fallback: last bare arg as prompt (some harnesses)
  if (!prompt) {
    for (let i = argv.length - 1; i >= 0; i--) {
      if (!argv[i].startsWith('-')) {
        prompt = argv[i]
        break
      }
    }
  }
  return { prompt, cwd }
}

function git(cwd, cmd) {
  return execSync(cmd, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
}

const { prompt, cwd } = parseArgs(process.argv.slice(2))
const ledgerPath = path.join(cwd, '.claude', 'scratch', 'ledger.md')

if (!fs.existsSync(ledgerPath)) {
  console.error(`STUB_WORKER_FAIL no ledger at ${ledgerPath}`)
  process.exit(2)
}

let text = fs.readFileSync(ledgerPath, 'utf8')
const re = /^##\s+(SC-\d+)\s+[—–-]\s+(.+?)\s+\[(pending|in-progress)\]\s*$/m
const m = text.match(re)

if (!m) {
  // Finalizer path: runner spawns worker for "ledger is 100% complete · check skill".
  // Must emit the marker Test-FinalCheckGreen looks for.
  console.log('STUB_WORKER all-done (no pending slices)')
  console.log('FINAL_CHECK_STATUS=green')
  console.log('FINAL_CHECK_NOTE=stub soak finalizer — all slices already [done]')
  console.log(
    JSON.stringify({
      type: 'result',
      model: 'stub-soak',
      usage: { input_tokens: 1, output_tokens: 1 },
    }),
  )
  process.exit(0)
}

const id = m[1]
const title = m[2].trim()
const line = m[0]
const doneLine = line.replace(/\[(pending|in-progress)\]/, '[done]')
text = text.replace(line, doneLine)
fs.writeFileSync(ledgerPath, text, 'utf8')

const outDir = path.join(cwd, 'soak-out')
fs.mkdirSync(outDir, { recursive: true })
const artifact = path.join(outDir, `${id}.txt`)
fs.writeFileSync(
  artifact,
  `stub completed ${id} — ${title}\nat ${new Date().toISOString()}\npromptChars=${prompt.length}\n`,
  'utf8',
)

try {
  git(cwd, 'git add -A')
  git(cwd, `git commit -m "soak: ${id} done (${title.replace(/"/g, "'")})"`)
} catch (e) {
  console.error(`STUB_WORKER_GIT_WARN ${e.message || e}`)
  // Still exit 0 if ledger moved — runner cares about ledger progress
}

console.log(`STUB_WORKER done ${id} — ${title}`)
console.log(
  JSON.stringify({
    type: 'result',
    model: 'stub-soak',
    usage: { input_tokens: 12, output_tokens: 24, cache_read_input_tokens: 0 },
  }),
)
process.exit(0)
