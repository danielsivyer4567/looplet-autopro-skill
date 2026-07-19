#!/usr/bin/env node
/**
 * npx @looplet/autopro — install AutoPro skill into ~/.claude/skills/autopro
 *
 *   npx @looplet/autopro
 *   npx @looplet/autopro --dry-run
 *   npx @looplet/autopro --version
 *
 * Preferred short install. No pipe-to-shell. Pin with:
 *   npx @looplet/autopro@1.2.0
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const pkgRoot = path.resolve(__dirname, '..');
const skillSrc = path.join(pkgRoot, 'plugins', 'autopro');
const home = os.homedir();
const dest = path.join(home, '.claude', 'skills', 'autopro');
const backupsRoot = path.join(home, '.claude', 'autopro-backups');

const args = new Set(process.argv.slice(2));
const dryRun = args.has('--dry-run') || args.has('-DryRun') || args.has('-n');
const showVersion = args.has('--version') || args.has('-v') || args.has('-Version');
const help = args.has('--help') || args.has('-h');

function readVersion() {
  try {
    return fs.readFileSync(path.join(pkgRoot, 'VERSION'), 'utf8').trim();
  } catch {
    try {
      return JSON.parse(fs.readFileSync(path.join(pkgRoot, 'package.json'), 'utf8')).version;
    } catch {
      return 'unknown';
    }
  }
}

function log(msg) {
  process.stdout.write(String(msg) + '\n');
}

function die(msg, code = 1) {
  process.stderr.write(String(msg) + '\n');
  process.exit(code);
}

function copyRecursive(src, dst) {
  const st = fs.statSync(src);
  if (st.isDirectory()) {
    fs.mkdirSync(dst, { recursive: true });
    for (const name of fs.readdirSync(src)) {
      if (name === 'node_modules' || name === '.git') continue;
      copyRecursive(path.join(src, name), path.join(dst, name));
    }
    return;
  }
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
}

function rmRecursive(p) {
  fs.rmSync(p, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
}

function rewriteSkillMd(text, installDest) {
  // Match install.ps1: expand plugin placeholder for non-plugin installs
  return text.split('${CLAUDE_PLUGIN_ROOT}').join(installDest.replace(/\\/g, '/'));
}

function main() {
  const version = readVersion();

  if (help) {
    log(`@looplet/autopro v${version}

Install AutoPro (Claude Code skill) → ~/.claude/skills/autopro

  npx @looplet/autopro
  npx @looplet/autopro --dry-run
  npx @looplet/autopro --version
  npx @looplet/autopro@${version}     # pin

After install: approve a ledger, type /autopro in Claude Code.
Trust: https://github.com/danielsivyer4567/looplet-autopro-skill/blob/master/TRUST.md
`);
    process.exit(0);
  }

  if (showVersion) {
    log(`AUTOPRO_VERSION=${version}`);
    log(`PACKAGE_ROOT=${pkgRoot}`);
    process.exit(0);
  }

  const skillMd = path.join(skillSrc, 'SKILL.md');
  if (!fs.existsSync(skillMd)) {
    die(`install: missing ${skillMd} — broken package (expected plugins/autopro/SKILL.md)`);
  }

  log(`AUTOPRO_VERSION=${version}`);
  log(`INSTALL_SRC=${skillSrc}`);
  log(`INSTALL_DEST=${dest}`);
  log(`INSTALL_VIA=npx @looplet/autopro`);

  if (dryRun) {
    const exists = fs.existsSync(dest);
    log('DRY_RUN=1');
    log(`DRY_RUN_DEST_EXISTS=${exists ? '1' : '0'}`);
    if (exists) {
      const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
      log(`DRY_RUN_BACKUP_WOULD=${path.join(backupsRoot, `autopro.bak-${stamp}`)}`);
    }
    log('DRY_RUN_ACTION=would copy plugins/autopro → ~/.claude/skills/autopro');
    log('DRY_RUN_NO_NETWORK=1');
    process.exit(0);
  }

  const stamp = new Date()
    .toISOString()
    .replace(/[-:TZ.]/g, '')
    .slice(0, 14);

  if (fs.existsSync(dest)) {
    const bak = path.join(backupsRoot, `autopro.bak-${stamp}`);
    fs.mkdirSync(backupsRoot, { recursive: true });
    try {
      copyRecursive(dest, bak);
      log(`backed up existing skill -> ${bak}`);
    } catch (e) {
      log(`WARN: backup copy failed: ${e.message}`);
    }
    try {
      rmRecursive(dest);
    } catch (e) {
      log(`WARN: remove dest failed (overlaying): ${e.message}`);
    }
  }

  fs.mkdirSync(dest, { recursive: true });

  // SKILL.md with placeholder rewrite
  const rawSkill = fs.readFileSync(skillMd, 'utf8');
  fs.writeFileSync(path.join(dest, 'SKILL.md'), rewriteSkillMd(rawSkill, dest), 'utf8');

  for (const d of ['scripts', 'references', 'theater']) {
    const p = path.join(skillSrc, d);
    if (fs.existsSync(p)) {
      copyRecursive(p, path.join(dest, d));
    }
  }

  // Trust surface next to installed skill
  for (const f of ['VERSION', 'CHANGELOG.md', 'TRUST.md', 'SHA256SUMS.txt', 'LICENSE']) {
    const p = path.join(pkgRoot, f);
    if (fs.existsSync(p)) {
      fs.copyFileSync(p, path.join(dest, f));
    }
  }

  // executable bits on .sh (best-effort; no-op on Windows)
  const scriptsDir = path.join(dest, 'scripts');
  if (fs.existsSync(scriptsDir) && process.platform !== 'win32') {
    for (const name of fs.readdirSync(scriptsDir)) {
      if (name.endsWith('.sh')) {
        try {
          fs.chmodSync(path.join(scriptsDir, name), 0o755);
        } catch {
          /* ignore */
        }
      }
    }
  }

  log(`AutoPro skill installed -> ${dest} (v${version})`);
  log('');
  log('Done. Next:');
  log('  1) Open Claude Code in a repo');
  log('  2) Create + approve a ledger');
  log('  3) Type  /autopro');
  log('');
  log(`Dry-run arm:  npx --yes --package=@looplet/autopro autopro --version`);
  log(
    `  or: pwsh -NoProfile -File "${path.join(dest, 'scripts', 'launch-autopro.ps1')}" -Root <repo> -RepoDir <repo> -DryRun`,
  );
  log(`Stop:         pwsh -NoProfile -File "${path.join(dest, 'scripts', 'stop-autopro.ps1')}" -All`);
  log('Trust:        see TRUST.md in the package / installed skill dir');
}

main();
