# Show Time — cold-agent handover

**Board:** http://127.0.0.1:8770/ (port in `%USERPROFILE%\.claude\scratch\autopro-theater\server.port`)  
**Contract:** `references/APPROVE-ARM-CONTRACT.md`  
**Offline green bar:**  
`pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\prove-approve-arm-offline.ps1"`  
Expect: `READY_CHECK=green`

## What Show Time is

- **Projector / housing only** — not git landlord, not where work is done.
- Each **repo** has its own ledger + runner. Board displays progress.
- **You talk to ORCH only.** SA workers report up. Do not DM SA-*.

## Approve → Arm (Door A → Door B)

1. Join request → loud alarm **once per new ledger** + board banner  
2. Human **Approve** = consent to arm that repo  
3. `arm-on-approve.ps1` → `launch-showtime.ps1` (or `already_armed` if runner live)  
4. Live pid + coding → **legs move** on the active SC only  

Kill switch: `SHOWTIME_AUTO_ARM=0` (approve boards, no auto-arm).  
Stop runners: `scripts/stop-autopro.ps1 -Root <repo>` or `-All`.

## CLAW board rules (do not re-invent)

1. **ORCH head** at top of each fleet — big invader under **Previous notes**.  
2. **One worker per SA column** — sits on the **active** SC; works down the list.  
3. **Done SCs:** full ring, **no** invader.  
4. **Legs moving** = coding. Stiff only for hold/clash/issue + reason.  
5. **Multi-fleet:** group by repo root (Producer MAIN vs extension SIDE). Never mix.  
6. **Single runner per repo Root** — never twin runners on same ledger.

## Shared board · separate ledgers

- **One Show Time page** — every fleet / ledger is visible together (shared projector).
- **Separate ledgers** — each SA column keeps its own ledger stack (todo progress).
- **One coding writer per repo root** — only the owner SA gets legs / live pid.
- **Other ledgers on same root** = `ledgerProjector` (full SC stack, **no legs**, badge LEDGER).
- **Corpse** = no ledger identity + dead pid → collapse / **Purge dead**.
- **Fleets** = one ORCH head per **repo root**; multi-repo = multi columns on one page.
- Offline green: `prove-approve-arm-offline.ps1`.

## Logs

| Log | Path |
|-----|------|
| Join alarm | `%USERPROFILE%\.claude\scratch\autopro-theater\join-alarm.log` |
| Arm bridge | `%USERPROFILE%\.claude\scratch\autopro-theater\arm-on-approve-bridge.log` |
| Per-repo arm | `<repo>\.claude\scratch\arm-on-approve.log` |
| Runner | `<repo>\.claude\scratch\autopro.log` |

## Arm from a repo (after ledger `Approved: yes`)

```powershell
$skill = Join-Path $env:USERPROFILE '.claude\skills\autopro\scripts'
$root  = '<YOUR-REPO-ROOT>'
& pwsh -NoProfile -File (Join-Path $skill 'launch-showtime.ps1') -Root $root -RepoDir $root
```

Or: join on the board → human Approve → auto-arm.

## Skill dual-tree note

If both `.claude\skills\autopro` and `.agents\skills\autopro` exist, keep them in sync  
(or symlink). Theater may spawn scripts from either tree.

*SC-R07 — Approve→Arm + multi-fleet housing epic.*
