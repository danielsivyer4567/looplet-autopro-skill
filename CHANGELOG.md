# Changelog

## [1.2.3] — 2026-07-19

### Install
- **Live:** `npx looplet-autopro` (npm package `looplet-autopro@1.2.3`)
- Scoped `@looplet/autopro` was published but registry packument 404s; unscoped name is the supported short install until scope is fixed on npm org
All notable changes to the AutoPro skill package are documented here.

## [1.2.0] — 2026-07-19

### Install
- **`npx looplet-autopro`** — short install via npm (`package.json` + `bin/install.mjs`)
- `preferGlobal: true`; `--dry-run` / `--version` on the installer
- Until the package is on the registry, use: `npx github:danielsivyer4567/looplet-autopro-skill`

## [1.1.2] — 2026-07-19

### Discoverability
- **Root `SKILL.md`** — package-level skill card so GitHub / skill indexes see a skill at repo root; points at canonical `plugins/autopro/SKILL.md` (marketplace layout)

## [1.1.1] — 2026-07-19

### Trust / public review response
- **Preferred install path** documented first: `git clone` + `install.ps1` / `install.sh` (inspect before run)
- **`get.ps1` / `get.sh`** warn as remote code execution; support `AUTOPRO_REF` pin (tag/SHA)
- **`-DryRun` on `launch-autopro.ps1`** — real implementation: resolve serial/ultra, print dispatch, exit 0 (no arm)
- **`install.ps1` / `install.sh`**: `-DryRun` / `--dry-run`, `-Version` / `--version`; copy VERSION/TRUST/CHANGELOG/SHA256SUMS into skill dir
- **`README.md`**, **`TRUST.md`**, **`README-INSTALL.md`** — safeguards, serial vs ultra, rollback, proof scripts
- **`SHA256SUMS.txt`** + `write-checksums.ps1` for release pins
- Explicit: no cosign/SLSA yet — honest ceiling below signed-release 8/10

## [1.1.0] — 2026-07-19

### Added
- **`launch-autopro.ps1`** — single front door; `-Mode auto|serial|ultra`
- **Auto size heuristic** — open slices &lt; 12 → serial, ≥ 12 → ultra (`-SerialMaxSlices`)
- Supervisor v1 (kickstart, needs-you, chat inbox, watch)
- Sticky join approve (bottom-right, no auto-timeout; board + MessageBox fallbacks)
- ORCH speech bubble + desk transcript; `test-orch-comms.ps1`
- Independent final gate invoke (`Invoke-IndependentFinalGate`)
- Stub engine + `soak-serial-n.ps1` offline soak
- MAP: one Pac-Man track per SC slice
- Shake-and-bake join chime (full PlaySync)
- Ultra band scripts (`launch-ultra`, `autopro-ultra`, …)

### Fixed
- Purge-dead rematerialize zombie loop (stale `autopro-on` flags)
- Chrome board open double-window / `Profile 5` split junk tab
- Join popup auto-close at 10 minutes
- Missing independent gate function hung finalizer

## [1.0.0] — 2026-07

- Plugin packaging (`plugins/autopro`), marketplace metadata
- Cross-OS install (`get.ps1` / `get.sh`, `ensure-pwsh.sh`)
- Multi-engine workers, Show Time board, zero-git projector contract

