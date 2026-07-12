# Show Time join gate (2FA-style)

**Problem solved:** chats were auto-registering / thrashing theater start-stop and hanging on “wait for board.”

## Flow

```
Chat runs skill (request-join)
        │
        ▼
  POST /api/join-requests   →  status: pending  (durable on disk)
        │
        ▼
  Operator Approves / Denies
    · Board banner at http://127.0.0.1:8770/
    · Looplet sidebar → Board (showtime.joinApprove / joinDeny)
        │
        ▼
  approved → lane Chat N appears
  denied   → chat exits cleanly
```

## Party rule (with join gate)

Join is **not** “drop a worker on the global ORCH.”  
**Approve = let this fleet (ORCH + workers for one ledger) into the party.**  
See `FLEET-HANDSHAKE.md`.

## Chat command (paste)

```powershell
$skill = Join-Path $env:USERPROFILE '.claude\skills\autopro\scripts'
$root  = '<THIS-REPO-ROOT>'
$sessionId = 'sess_' + [guid]::NewGuid().ToString('N').Substring(0,12)

# Brings YOUR orchestrator + workers for YOUR one ledger
pwsh -NoProfile -File (Join-Path $skill 'theater-register.ps1') `
  -Action request-join `
  -SessionId $sessionId `
  -RepoDir $root `
  -Root $root `
  -WaitSec 20
# WaitSec is a SHORT poll only (default 20s). If still pending:
#   JOIN_STATUS=pending  → stop. Do NOT loop for minutes.
# Later:
pwsh -NoProfile -File (Join-Path $skill 'theater-register.ps1') `
  -Action join-status -SessionId $sessionId
```

Full arm (`launch-showtime.ps1`) still uses `register`, which now **defaults to request-join**.

## Operator

1. Open **`http://127.0.0.1:8770/`** in your signed-in Chrome (or Looplet Board).
2. Yellow **JOIN REQUESTS** banner → **Approve fleet** / **Deny**.
3. Fleet (ORCH + workers) appears only after Approve.

## API

| Method | Path | Role |
|--------|------|------|
| POST | `/api/join-requests` | Chat requests in |
| GET | `/api/join-requests` | List (token) |
| GET | `/api/join-requests/:id` | Poll status |
| POST | `/api/join-requests/:id/approve` | Operator |
| POST | `/api/join-requests/:id/deny` | Operator |
| POST | `/api/sessions` | **Blocked for NEW lanes** unless already approved (or `SHOWTIME_OPEN_REGISTER=1`) |

Beacon file for extension: `%USERPROFILE%\.claude\scratch\showtime-join-pending.json`

## Transient "not found" → re-register

After a board restart (or wiped session file), heartbeats return:

```json
{ "ok": false, "code": "SESSION_NOT_FOUND", "reattach": true }
```

**Runner** (`autopro-runner.ps1`) logs:

> Register hit a transient 'not found' — re-registering the session onto the shared board

Then it:
1. `POST /api/sessions` (works if join was already **approved**)
2. else `POST /api/join-requests` — **rematerializes** without a second Approve if that sessionId was approved before
3. retries heartbeat

**CLI** (`theater-register.ps1 -Action heartbeat`) does the same via `request-join`.

If the chat was **never** approved, re-register only creates a **pending** join — operator must Approve once. No 10‑minute spin.

## Emergency open register

```powershell
$env:SHOWTIME_OPEN_REGISTER = '1'
# restart theater-server.mjs
```

Only for break-glass; normal path is Approve.
