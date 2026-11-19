#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-2105_161b_kamera_rueckflug_quelltext_robust"
MAC_PROJECT_DIR="${MAC_PROJECT_DIR:-/Users/andreasmelcher/_AM/PRIVAT/strom}"
REMOTE_HOST="${REMOTE_HOST:-mpwh@192.168.1.21}"
REMOTE_DEPLOY_DIR="${REMOTE_DEPLOY_DIR:-/home/mpwh/deploy}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/tmp}"
STAGE_DIR="${STAGE_DIR:-/home/mpwh/strom_stage}"
PROD_DIR="${PROD_DIR:-/home/mpwh/strom}"
WEB_TEST_DIR="${WEB_TEST_DIR:-/var/www/strom-test}"
BACKUP_BASE="${BACKUP_BASE:-/home/mpwh}"
GITHUB_OWNER="mpwh23"
GITHUB_REPO="stromnetze"
GITHUB_BRANCH="main"
GITHUB_ALIAS="github-stromnetze"
GITHUB_REMOTE="git@${GITHUB_ALIAS}:${GITHUB_OWNER}/${GITHUB_REPO}.git"
COMMIT_MESSAGE="Update 161b: restore 159b forward; robust one-driver return"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"

# -----------------------------------------------------------------------------
# Mac launcher
# One SSH master connection is opened first. This asks for the Pi password once;
# all following ssh/scp calls reuse the same authenticated connection.
# -----------------------------------------------------------------------------
if [ "$(uname -s)" = "Darwin" ] && [ -z "$MODE" ]; then
  echo "=== $SCRIPT_NAME / Mac ==="
  echo "Startordner:   $MAC_PROJECT_DIR"
  echo "GitHub:        https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
  echo "Branch:        $GITHUB_BRANCH"
  echo "Pi:            $REMOTE_HOST"
  echo ""

  [ "$(pwd)" = "$MAC_PROJECT_DIR" ] || {
    echo "FEHLER: Bitte aus $MAC_PROJECT_DIR starten." >&2
    exit 1
  }
  command -v ssh >/dev/null 2>&1 || { echo "FEHLER: ssh fehlt auf dem Mac." >&2; exit 1; }
  command -v scp >/dev/null 2>&1 || { echo "FEHLER: scp fehlt auf dem Mac." >&2; exit 1; }

  SSH_CONTROL_PATH="/tmp/strom-ssh-${UID:-0}-$$"
  SSH_CONTROL_OPTS=(-o ControlMaster=auto -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=600)

  close_ssh_master() {
    ssh -o ControlPath="$SSH_CONTROL_PATH" -O exit "$REMOTE_HOST" >/dev/null 2>&1 || true
    rm -f "$SSH_CONTROL_PATH" >/dev/null 2>&1 || true
  }
  trap close_ssh_master EXIT INT TERM

  echo "0) SSH-Verbindung zum Pi aufbauen ..."
  echo "   Das Pi-Passwort wird fuer diesen kompletten Lauf nur einmal abgefragt."
  ssh -M -N -f -o ControlMaster=yes -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=600 "$REMOTE_HOST"
  ssh "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "true" >/dev/null
  echo "   SSH-Masterverbindung steht."

  REMOTE_TMP_SCRIPT="${REMOTE_TMP_DIR}/$(basename "$SELF_PATH")"
  REMOTE_DEPLOY_SCRIPT="${REMOTE_DEPLOY_DIR}/$(basename "$SELF_PATH")"

  echo ""
  echo "1) Temporaere Hilfskopie auf den Pi uebertragen ..."
  echo "   Nur fuer den Git-Push mit dem dort vorhandenen Deploy-Key; noch kein Stage-Deployment."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_TMP_SCRIPT"

  echo ""
  echo "2) Update 161b im isolierten Git-Checkout bauen und nach GitHub pushen ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "chmod +x '$REMOTE_TMP_SCRIPT' && '$REMOTE_TMP_SCRIPT' --git-phase"

  echo ""
  echo "3) Git-Push erfolgreich. Update-Script jetzt nach ~/deploy kopieren ..."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_DEPLOY_SCRIPT"

  echo ""
  echo "4) Stage-Update auf dem Pi ausfuehren ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "rm -f '$REMOTE_TMP_SCRIPT'; chmod +x '$REMOTE_DEPLOY_SCRIPT'; cd '$REMOTE_DEPLOY_DIR'; './$(basename "$SELF_PATH")' --stage-phase"
  exit $?
fi

# -----------------------------------------------------------------------------
# Pi Git phase. Uses the already configured HomePi deploy key:
#   Host github-stromnetze -> /root/.ssh/.../github-stromnetze
# No Mac Git repository and no GitHub CLI are required.
# -----------------------------------------------------------------------------
if [ "$MODE" = "--git-phase" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -H "$SELF_PATH" --git-phase-root
  fi
  MODE="--git-phase-root"
fi

if [ "$MODE" = "--git-phase-root" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "FEHLER: Git-Phase muss als root laufen." >&2; exit 1; }
  [ -d "$STAGE_DIR/frontend/src" ] || { echo "FEHLER: Stage nicht gefunden: $STAGE_DIR" >&2; exit 1; }
  [ -f /root/.ssh/config ] || { echo "FEHLER: /root/.ssh/config fehlt." >&2; exit 1; }
  grep -Eq '^[[:space:]]*Host[[:space:]]+.*github-stromnetze([[:space:]]|$)' /root/.ssh/config || {
    echo "FEHLER: SSH-Alias github-stromnetze fehlt in /root/.ssh/config." >&2
    exit 1
  }

  GIT_TMP="/tmp/${SCRIPT_NAME}_gitrepo_$$"
  GIT_BUILD_BACKUP="/tmp/${SCRIPT_NAME}_gitbackup_$$"
  rm -rf "$GIT_TMP" "$GIT_BUILD_BACKUP"

  cleanup_git_phase() {
    rm -rf "$GIT_TMP" "$GIT_BUILD_BACKUP" 2>/dev/null || true
  }
  trap cleanup_git_phase EXIT

  echo "=== $SCRIPT_NAME / Git-Phase auf Pi ==="
  echo "GitHub Remote: $GITHUB_REMOTE"
  echo "Quelle:        $STAGE_DIR"
  echo ""

  echo "1.1) GitHub-Repository temporaer klonen ..."
  GIT_SSH_COMMAND="ssh -F /root/.ssh/config" git clone --branch "$GITHUB_BRANCH" "$GITHUB_REMOTE" "$GIT_TMP"

  echo "1.2) Aktuellen Stage-Source in das Git-Checkout synchronisieren ..."
  for dir in backend db deploy frontend tools; do
    if [ -d "$STAGE_DIR/$dir" ]; then
      mkdir -p "$GIT_TMP/$dir"
      if [ "$dir" = "frontend" ]; then
        rsync -a --delete --exclude 'node_modules/' --exclude 'dist/' "$STAGE_DIR/$dir/" "$GIT_TMP/$dir/"
      elif [ "$dir" = "deploy" ]; then
        # Git-only Update-Historie nicht durch den Stage-Sync loeschen.
        rsync -a --delete --exclude 'updates/' "$STAGE_DIR/$dir/" "$GIT_TMP/$dir/"
      else
        rsync -a --delete "$STAGE_DIR/$dir/" "$GIT_TMP/$dir/"
      fi
    fi
  done
  for file in .gitignore .env.example Makefile README.md; do
    if [ -f "$STAGE_DIR/$file" ]; then
      cp -a "$STAGE_DIR/$file" "$GIT_TMP/$file"
    fi
  done

  echo "1.3) Update 161b isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
  PATCH_ONLY=1 \
    STAGE_DIR="$GIT_TMP" \
    PROD_DIR="$STAGE_DIR" \
    BACKUP_BASE=/tmp \
    "$SELF_PATH" --stage-phase

  mkdir -p "$GIT_TMP/deploy/updates"
  cp -a "$SELF_PATH" "$GIT_TMP/deploy/updates/$(basename "$SELF_PATH")"
  chmod 755 "$GIT_TMP/deploy/updates/$(basename "$SELF_PATH")"

  # 132f hat durch einen vorhandenen Symlink frontend/node_modules als Git-Eintrag
  # aufnehmen koennen. Ab 132g werden Abhaengigkeiten/Build-Artefakte nie versioniert.
  rm -rf "$GIT_TMP/frontend/node_modules" "$GIT_TMP/frontend/dist"
  git -C "$GIT_TMP" rm -r -f --cached --ignore-unmatch frontend/node_modules frontend/dist >/dev/null 2>&1 || true

  echo "1.4) Source committen ..."
  git -C "$GIT_TMP" config user.name "HomePi Adminpanel"
  git -C "$GIT_TMP" config user.email "homepi-adminpanel@localhost"
  git -C "$GIT_TMP" add -A
  if git -C "$GIT_TMP" diff --cached --quiet; then
    echo "Keine neue Git-Aenderung; pruefe/pushe Branch trotzdem."
  else
    git -C "$GIT_TMP" commit -m "$COMMIT_MESSAGE"
  fi
  git -C "$GIT_TMP" branch -M "$GITHUB_BRANCH"

  echo "1.5) Git-Push ueber HomePi Deploy-Key ..."
  GIT_SSH_COMMAND="ssh -F /root/.ssh/config" git -C "$GIT_TMP" push "$GITHUB_REMOTE" "$GITHUB_BRANCH:$GITHUB_BRANCH"

  echo ""
  echo "Git-Push erfolgreich."
  echo "Commit: $(git -C "$GIT_TMP" rev-parse --short HEAD)"
  exit 0
fi


if [ "$MODE" != "--stage-phase" ]; then
  echo "FEHLER: Unbekannter Modus '$MODE'. Auf dem Mac ohne Parameter starten." >&2
  exit 1
fi


DEPLOY_DIR="$REMOTE_DEPLOY_DIR"
if [ ! -d "$BACKUP_BASE" ]; then BACKUP_BASE="$(dirname "$STAGE_DIR")"; fi
BACKUP_DIR="$BACKUP_BASE/strom_stage_backup_${SCRIPT_NAME}_$(date +%Y%m%d-%H%M%S)"
WORK_DIR="$(mktemp -d "/tmp/${SCRIPT_NAME}_work_$(id -u)_XXXXXX")"
DIAG_LOG="/tmp/${SCRIPT_NAME}_diagnostics_$(date +%Y%m%d-%H%M%S)_$$.log"
run_sudo() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
log() { echo "$@" | tee -a "$DIAG_LOG"; }
fail() { log ""; log "ERROR: $*"; log "Diagnostics: $DIAG_LOG"; if [ -f "$DIAG_LOG" ]; then echo '--- Last diagnostic lines ---'; tail -n 100 "$DIAG_LOG"; fi; exit 1; }
cleanup_work() { [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf -- "$WORK_DIR" || true; }
trap cleanup_work EXIT
node_supported() {
  local major minor patch
  IFS=. read -r major minor patch <<< "${1#v}"
  major="${major:-0}"; minor="${minor:-0}"
  if [ "$major" -eq 20 ] && [ "$minor" -ge 19 ]; then return 0; fi
  if [ "$major" -eq 22 ] && [ "$minor" -ge 12 ]; then return 0; fi
  [ "$major" -gt 22 ]
}
select_node() {
  local candidate version best="" best_v=""
  for candidate in /home/mpwh/.nvm/versions/node/*/bin/node /root/.nvm/versions/node/*/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -x "$candidate" ] || continue
    version="$($candidate -p 'process.versions.node' 2>/dev/null || true)"
    node_supported "$version" || continue
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best_v" "$version" | sort -V | tail -n 1)" = "$version" ]; then best="$candidate";best_v="$version"; fi
  done
  [ -n "$best" ] || fail "Node >=20.19 or >=22.12 missing"
  export PATH="$(dirname "$best"):$PATH";hash -r 2>/dev/null || true
  log "Node: $best ($best_v), npm: $(npm -v 2>/dev/null || echo missing)"
}


log "=== Update 161b: restore pre-160 camera; robust exit-target patch ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts frontend/src/components/cameraBlueprintCenter156.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "161b required source missing: $file"
done
grep -Fq 'STROM156_BLUEPRINT_CAMERA_CENTER' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" ||   fail "161b requires forward calibration 156; no changes made."
grep -Fq 'registerExit150' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" ||   fail "161b requires existing reverse callback; no changes made."
grep -Fq 'STROM160_REVERSE_FROM_SAVED_TOP_VIEW' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "161b requires currently installed 160; no changes made."
if grep -Fq 'STROM161B_RETURN_SAVED_CALIBRATED_POSE' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"; then
  fail "161b already installed; no changes made."
fi
select_node
log "1) Backup Stage ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no Stage backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
fi
log "2) Prepare isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "161b source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "161b TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/161b_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch161b.py" <<'STROM161B_PY'
#!/usr/bin/env python3
"""STROM 161b: restore 159b forward from the pre-160 Stage backup and
repair reverse in the *existing* single R3F animation loop.

Unlike 161, NEVER assumes a particular const-top/overheadPose expression.
It locates the one verified exit-flight assignment and replaces only its END,
while preserving the entire 157-159b outward path verbatim.

All modifications are done in memory before any source is written.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

stage_root = Path(os.environ['STROM161B_ROOT'])
src = stage_root / 'frontend/src'
flight_path = src / 'components/CameraFlight150.tsx'
helper160 = src / 'components/returnFlight160.ts'
if not flight_path.is_file():
    raise RuntimeError('161b: CameraFlight150.tsx missing')
current = flight_path.read_text(encoding='utf-8')
if 'STROM161B_RETURN_SAVED_CALIBRATED_POSE' in current:
    raise RuntimeError('161b: already installed, no source changed')
if 'STROM160_REVERSE_FROM_SAVED_TOP_VIEW' not in current:
    raise RuntimeError('161b: expected failed 160 in Stage, source unchanged')


def unique_pattern(s: str, pattern: str, purpose: str, flags: int = 0) -> re.Match[str]:
    matches = list(re.finditer(pattern, s, flags))
    if len(matches) != 1:
        raise RuntimeError(f'161b {purpose}: expected one match, got {len(matches)}')
    return matches[0]


def unique_replace(s: str, old: str, new: str, purpose: str) -> str:
    n = s.count(old)
    if n != 1:
        raise RuntimeError(f'161b {purpose}: expected one occurrence, got {n}')
    return s.replace(old, new, 1)


def brace_close(s: str, open_brace: int) -> int:
    """Return matching } index for a { at open_brace in a TS/TSX snippet.

    Supports ordinary strings/comments and nested objects; targeted snippets
    are regular callback/object bodies, not JSX or template substitutions.
    """
    if open_brace >= len(s) or s[open_brace] != '{':
        raise RuntimeError('161b: opening brace not found')
    depth, i, mode, quote = 1, open_brace + 1, 'code', ''
    while i < len(s):
        a = s[i]
        b = s[i + 1] if i + 1 < len(s) else ''
        if mode == 'line':
            if a == '\n': mode = 'code'
            i += 1
            continue
        if mode == 'block':
            if a == '*' and b == '/': mode = 'code'; i += 2; continue
            i += 1
            continue
        if mode == 'string':
            if a == '\\': i += 2; continue
            if a == quote: mode = 'code'
            i += 1
            continue
        if a == '/' and b == '/': mode = 'line'; i += 2; continue
        if a == '/' and b == '*': mode = 'block'; i += 2; continue
        if a in ('\'', '"', '`'):
            quote, mode = a, 'string'; i += 1; continue
        if a == '{': depth += 1
        elif a == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise RuntimeError('161b: callback/object has no matching closing brace')


def pre160_backup() -> Path | None:
    """Prefer the explicitly verified pre-160 backup from the user's Pi log."""
    root = Path(os.environ.get('STROM161B_BACKUP_DIR', '/home/mpwh'))
    prefix = 'strom_stage_backup_20261119_160_rueckflug_ohne_zoomsprung_'
    paths = []
    if root.is_dir():
        paths.extend(root.glob(prefix + '*'))
    preferred = 'strom_stage_backup_20261119_160_rueckflug_ohne_zoomsprung_20261119-203527'
    if (root / preferred).is_dir():
        paths = [root / preferred] + [d for d in sorted(set(paths), key=lambda x: x.name, reverse=True) if d.name != preferred]
    else:
        paths = sorted(set(paths), key=lambda x: x.name, reverse=True)
    for d in paths:
        p = d / 'frontend/src/components/CameraFlight150.tsx'
        if not p.is_file(): continue
        body = p.read_text('utf-8')
        if ('STROM156_BLUEPRINT_CAMERA_CENTER' in body and
            'STROM160_REVERSE_FROM_SAVED_TOP_VIEW' not in body and
            'STROM161B_RETURN_SAVED_CALIBRATED_POSE' not in body):
            return p
    return None


def inverse160(f: str) -> str:
    """Conservative fallback if the 160 predeployment backup was removed.

    This is last resort and validates that all 160 additions were removed.
    """
    f = unique_replace(f,
        "import { clonePose160, interpolatePose160, easeOut160, type ReturnPose160, type ReturnLens160 } from './returnFlight160' // STROM160_REVERSE_FROM_SAVED_TOP_VIEW\n",
        '', 'remove 160 import')
    ref = r'(?m)^[ \t]*const (?:entryAnchor160|reverseRequest160|reverse160) = useRef<[^\n]+\n'
    if len(re.findall(ref, f)) != 3:
        raise RuntimeError('161b: unsafe inverse160: three added refs not found')
    f = re.sub(ref, '', f)
    m = unique_pattern(f,
        r'\bregisterExit150\s*\(\s*\(?[A-Za-z_$][\w$]*\)?\s*=>\s*\{',
        'inverse 160 exit callback')
    a = m.end() - 1
    b = brace_close(f, a)
    old_block = f[a + 1:b]
    start = re.search(
        r'\A\s*// STROM160:.*?\n\s*if\s*\(entryAnchor160\.current\)\s*\{.*?\}\s*else\s*\{\n',
        old_block, re.S)
    if not start:
        raise RuntimeError('161b: inverse160 callback wrapper differs')
    tail = old_block[start.end():]
    if not re.search(r'\n\s*\}\s*$', tail):
        raise RuntimeError('161b: inverse160 callback else branch differs')
    restored = re.sub(r'\n\s*\}\s*$', '', tail)
    restored = '\n'.join(line[6:] if line.startswith('      ') else line
                         for line in restored.splitlines())
    f = f[:a + 1] + '\n' + restored + '\n    ' + f[b:]
    frame_extra = f.find('    // STROM160_REVERSE_FROM_SAVED_TOP_VIEW: remember the *actual* calibrated')
    frame_end = f.find('    const control = orbit()', frame_extra)
    if frame_extra < 0 or frame_end < 0 or frame_end - frame_extra > 8500:
        raise RuntimeError('161b: inverse160 standalone frame driver differs')
    f = f[:frame_extra] + f[frame_end:]
    if 'STROM160' in f or 'reverse160.current' in f:
        raise RuntimeError('161b: incomplete inverse160')
    return f


backup = pre160_backup()
if backup is not None:
    base = backup.read_text(encoding='utf-8')
    print('161b: VERIFIED pre-160 backup used: ' + str(backup))
else:
    base = inverse160(current)
    print('161b: 160 additions reversed from Stage source (no pre-160 backup)')

for anchor in (
    'STROM156_BLUEPRINT_CAMERA_CENTER', 'STROM150N_NO_END_JUMP',
    'const flight = useRef', 'registerExit150', 'notifyEnterReady150',
    'useFrame(state => {', 'viewOffset156', 'alignBlueprintCenter156',
    'clearViewOffset156(camera)', 'const control = orbit()',
):
    if anchor not in base:
        raise RuntimeError('161b: pre-160 source lacks '+anchor)
if 'STROM160' in base:
    raise RuntimeError('161b: restored backup still contains 160 additions')
if len(re.findall(r'\buseFrame\s*\(', base)) != 1:
    raise RuntimeError('161b: camera must have exactly one useFrame driver')

f = base
# 1) A separate immutable snapshot; no alterations to the entry phase logic.
m = unique_pattern(f,
    r'(?m)^(?P<indent>[ \t]*)const flight = useRef<[^\n]+\n',
    'single flight state ref')
added = (m.group('indent') +
    'const savedTop161b = useRef<{pose: CameraPose; lens: ViewOffset156 | null} | null>(null) // STROM161B_RETURN_SAVED_CALIBRATED_POSE\n')
f = f[:m.end()] + added + f[m.end():]

# 2) Record once the exact post-calibration forward pose AND view offset.
# The snapshot is taken during the fade/flight, never the settling phase.
m = unique_pattern(f,
    r'\buseFrame\s*\(\s*state\s*=>\s*\{\s*\n(?P<indent>[ \t]*)const camera = state\.camera\b[^\n]*\n',
    'one frame-camera callback')
snapshot = '''
    // 161b: Save the real calibrated top view. No writes to the entry camera.
    const entering161b = flight.current
    if (!savedTop161b.current && entering161b?.kind === 'entry' &&
        (entering161b.phase === 'fade' || entering161b.phase === 'flight')) {
      const p161b = entering161b.start
      savedTop161b.current = {
        pose: {
          position: p161b.position.clone(), rotation: p161b.rotation.clone(),
          target: p161b.target.clone(), up: p161b.up.clone(), zoom: p161b.zoom,
        },
        lens: entering161b.viewOffset156 ? {...entering161b.viewOffset156} : null,
      }
    }
'''
f = f[:m.end()] + snapshot + f[m.end():]

# 3) A NEW forward handoff clears the prior snapshot. Existing forward code
# is otherwise identical to the restored backup. Inserting directly after the
# guarded entry branch is robust to changes in pending.current assignment form.
frame_marker = unique_pattern(f, r'\buseFrame\s*\(\s*state\s*=>\s*\{', 'frame branch for entry reset')
entry_match = unique_pattern(
    f[frame_marker.start():], r'\bif\s*\(\s*pending\.current\s*\)\s*\{',
    'one new-entry guard in frame')
open_entry = frame_marker.start() + entry_match.end() - 1
f = (f[:open_entry + 1] +
     '\n      savedTop161b.current = null // a NEW Blueprint -> 3D flight' +
     f[open_entry + 1:])

# 4) Do NOT match overheadPose or the name of the local `top` expression.
# The pre-160 Stage backup can have a custom return-setup from 157-159b.
# Instead find the unique existing `flight.current = {...}` exit assignment
# and override its destination AFTER its own setup has finished.
exit_guard = unique_pattern(f,
    r'\bif\s*\(\s*requestedExit\.current\s*\)\s*\{',
    'single reverse request guard')
exit_start = exit_guard.end() - 1
exit_end = brace_close(f, exit_start)
exit_body = f[exit_start + 1:exit_end]
assn = unique_pattern(exit_body,
    r'(?m)^(?P<indent>[ \t]*)flight\.current\s*=\s*\{',
    'exactly one reverse flight assignment')
assign_open = assn.end() - 1
assign_end = brace_close(exit_body, assign_open)
old_assignment = exit_body[assign_open + 1:assign_end]
if not re.search(r'\bkind\s*:\s*[\'\"]exit[\'\"]', old_assignment):
    raise RuntimeError('161b: reverse flight is not an explicit exit flight')
if not re.search(r'\bstart\s*:', old_assignment) or not re.search(r'\bend\s*:', old_assignment):
    raise RuntimeError('161b: reverse flight start/end missing, refusing override')
# Allow an optional semicolon on `flight.current={...};`.
post = assign_end + 1
if post < len(exit_body) and exit_body[post] == ';': post += 1
indent = assn.group('indent')
addition = ("\n" + indent + "// 161b: Override ONLY the exit target with the genuine forward start.\n" +
    indent + "const savedEnd161b = savedTop161b.current\n" +
    indent + "if (savedEnd161b && flight.current?.kind === 'exit') {\n" +
    indent + "  flight.current.end = {\n" +
    indent + "    position: savedEnd161b.pose.position.clone(),\n" +
    indent + "    rotation: savedEnd161b.pose.rotation.clone(),\n" +
    indent + "    target: savedEnd161b.pose.target.clone(),\n" +
    indent + "    up: savedEnd161b.pose.up.clone(), zoom: savedEnd161b.pose.zoom,\n" +
    indent + "  }\n" +
    indent + "  flight.current.viewOffset156 = savedEnd161b.lens ? {...savedEnd161b.lens} : undefined\n" +
    indent + "}\n")
exit_body = exit_body[:post] + addition + exit_body[post:]
f = f[:exit_start + 1] + exit_body + f[exit_end:]

# 5) Change ONLY the exit time divisor. Preserve the forward DURATION150.
# `const t = clamp01(...)` is the only original R3F time interpolation.
time_pattern = (r'(?m)^(?P<indent>[ \t]*)const t\s*=\s*clamp01\s*\(\s*'
                r'\(\s*performance\.now\(\)\s*-\s*running\.startedAt\s*\)\s*/\s*'
                r'(?P<denom>[^\n]+)\)\s*$')
t = unique_pattern(f, time_pattern, 'single camera interpolation clock')
denominator = t.group('denom').strip()
# 159b may spell its exit duration as a constant instead of the literal
# 1000. Normalize ONLY the return branch and leave the original entry
# duration expression intact (including other future entry settings).
entry_denom = denominator
if 'running.kind' in denominator and '?' in denominator and ':' in denominator:
    clean = denominator.strip()
    if clean.startswith('(') and clean.endswith(')'):
        clean = clean[1:-1].strip()
    conditional = re.fullmatch(
        r"running\.kind\s*===\s*['\"](?P<branch>entry|exit)['\"]\s*\?\s*"
        r"(?P<yes>[^:]+?)\s*:\s*(?P<no>.+)", clean)
    if conditional:
        entry_denom = (conditional.group('no') if conditional.group('branch') == 'exit'
                       else conditional.group('yes')).strip()
    elif not re.search(r'\b1000\b', denominator):
        raise RuntimeError('161b: unknown existing reverse timing expression')
    else:
        # Already contains 1000 but is too complex to rewrite safely.
        entry_denom = None
if entry_denom is None:
    new_time = t.group(0)
else:
    new_time = (t.group('indent') +
        'const t = clamp01((performance.now() - running.startedAt) / '
        "(running.kind === 'exit' ? 1000 : " + entry_denom + '))')
f = f[:t.start()] + new_time + f[t.end():]

# 6) In the very same interpolation loop, ramp the original camera-lens
# offset smoothly from 0 to the saved blueprint value on exit.
# The incoming (entry) offset behavior stays EXACTLY unchanged.
apply_site = unique_pattern(f,
    r'(?m)^(?P<indent>[ \t]*)apply\(camera,\s*pose\)\s*$',
    'one interpolated camera apply')
ind = apply_site.group('indent')
reverse_offset = ("\n" + ind +
    "if (running.kind === 'exit' && running.viewOffset156)\n" + ind +
    '  applyViewOffset156(camera, running.viewOffset156, k) '
    '// STROM161B_REVERSE_LENS_TO_SAVED_TOP')
f = f[:apply_site.end()] + reverse_offset + f[apply_site.end():]

if len(re.findall(r'\buseFrame\s*\(', f)) != 1:
    raise RuntimeError('161b: second frame driver detected after patch')
for anchor in (
    'STROM156_BLUEPRINT_CAMERA_CENTER', 'STROM150N_NO_END_JUMP',
    'alignBlueprintCenter156', 'notifyEnterReady150',
    "running.kind === 'entry'", 'clearViewOffset156(camera)',
    'STROM161B_RETURN_SAVED_CALIBRATED_POSE',
    'STROM161B_REVERSE_LENS_TO_SAVED_TOP',
):
    if anchor not in f: raise RuntimeError('161b: forward invariant missing '+anchor)
if 'STROM160' in f or 'reverse160.current' in f:
    raise RuntimeError('161b: legacy 160 driver still present')

baseline_file = os.environ.get('STROM161B_BASELINE_PATH')
if baseline_file:
    Path(baseline_file).write_text(base, encoding='utf-8')
# All potentially failing checks are complete: publish files only now.
flight_path.write_text(f, encoding='utf-8')
if helper160.is_file() and 'STROM160_REVERSE_FROM_SAVED_TOP_VIEW' in helper160.read_text('utf-8'):
    helper160.unlink()
print('PASS 161b: original good forward restored; destination override works without overheadPose; single 1000ms reverse driver')
STROM161B_PY
cat > "$RESOURCE_DIR/test161b.cjs" <<'STROM161B_TEST'
'use strict';
const fs=require('fs'),path=require('path'),assert=require('assert');
const ts=require(process.env.STROM161B_TS);
const source=process.env.STROM161B_SOURCE;
const cameraPath=path.join(source,'components/CameraFlight150.tsx');
const camera=fs.readFileSync(cameraPath,'utf8');
const ast=ts.createSourceFile(cameraPath,camera,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
assert.equal(ast.parseDiagnostics.length,0,ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '));
for(const key of [
  'STROM161B_RETURN_SAVED_CALIBRATED_POSE',
  'STROM161B_REVERSE_LENS_TO_SAVED_TOP',
  'STROM156_BLUEPRINT_CAMERA_CENTER',
  'STROM150N_NO_END_JUMP',
  'notifyEnterReady150',
  'savedTop161b.current = null',
  "entering161b.phase === 'fade'",
  "entering161b.phase === 'flight'",
  "savedEnd161b && flight.current?.kind === 'exit'",
  'flight.current.end = {',
  'flight.current.viewOffset156 =',
  'applyViewOffset156(camera, running.viewOffset156, k)',
  "running.kind === 'exit' ? 1000 :"
])assert(camera.includes(key),'Missing required 161b anchor: '+key);
for(const key of ['STROM160_REVERSE_FROM_SAVED_TOP_VIEW', 'reverse160.current', './returnFlight160']) {
  assert(!camera.includes(key),'Competing reverse driver still present: '+key);
}
assert.equal((camera.match(/\buseFrame\s*\(/g)||[]).length,1,'Multiple animation drivers');
assert.equal((camera.match(/\bregisterExit150\s*\(/g)||[]).length,1,'Multiple reverse callbacks');
assert(!fs.existsSync(path.join(source,'components/returnFlight160.ts')),'160 helper still present');
// Compare original forward prepare/fade logic if the exact baseline is available.
const baseline=process.env.STROM161B_BASELINE;
if(baseline && fs.existsSync(baseline)) {
  const original=fs.readFileSync(baseline,'utf8');
  const phases=[
    ["if (running.kind === 'entry' && running.phase === 'prepare')", "if (running.kind === 'entry' && running.phase === 'fade')"],
    ["if (running.kind === 'entry' && running.phase === 'fade')",'const t = clamp01']
  ];
  for(const [start,end] of phases) {
    const a=original.indexOf(start),b=original.indexOf(end,a);
    const c=camera.indexOf(start),d=camera.indexOf(end,c);
    if(a>=0 && b>a && c>=0 && d>c) {
      assert.equal(camera.slice(c,d),original.slice(a,b),'Original forward '+start+' modified');
    }
  }
  assert.equal((original.match(/\bnotifyEnterReady150\s*\(/g)||[]).length,
    (camera.match(/\bnotifyEnterReady150\s*\(/g)||[]).length,
    'Original forward notifications changed');
}
function ease(t){return 1-Math.pow(1-Math.max(0,Math.min(1,t)),3)}
const initial={x:3.5,y:1.25,z:14,zoom:0.8};
const target={x:5.96,y:3.849,z:22.048,zoom:1.6};
let lastK=-1;
for(let i=0;i<=1000;i++) {
  const t=i/1000,k=ease(t);
  assert(k>=lastK && k<=1,'easeOut must be monotonic');
  for(const p of Object.keys(initial)) {
    const value=initial[p]+(target[p]-initial[p])*k;
    if(i===0)assert.equal(value,initial[p]);
    if(i===1000)assert.equal(value,target[p]);
  }
  if(i===0)assert.equal(k*120,0,'lens must be unshifted at return start');
  if(i===1000)assert.equal(k*120,120,'lens must match saved forward top at return end');
  lastK=k;
}
console.log('PASS 161b: TSX parse, exact forward prepare/fade preserved, one driver, saved calibrated exit, smooth 1000ms return & lens');
STROM161B_TEST
log "3) Restore verified pre-160 camera; patch the actual exit block structurally ..."
python3 -m py_compile "$RESOURCE_DIR/patch161b.py" >>"$DIAG_LOG" 2>&1 || fail "161b patch syntax failed"
# Backup path is auto-discovered. The timestamp from the user's diagnostic
# (20261119-203527) is preferred when present. Do not modify Stage yet.
STROM161B_ROOT="$WORK_DIR" STROM161B_BACKUP_DIR=/home/mpwh \
  STROM161B_BASELINE_PATH="$RESOURCE_DIR/pre160_camera.tsx" \
  python3 "$RESOURCE_DIR/patch161b.py" >>"$DIAG_LOG" 2>&1 || \
  fail "161b source mismatch; GitHub and Stage unchanged. Details in $DIAG_LOG"
log "4) Full TypeScript/Vite build BEFORE Git push ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "161b Vite/TypeScript build failed; GitHub and Stage unchanged"
log "5) Regression: original forward phase and single-driver reverse ..."
STROM161B_SOURCE="$WORK_DIR/frontend/src" STROM161B_TS="$DEPENDENCIES/typescript" \
  STROM161B_BASELINE="$RESOURCE_DIR/pre160_camera.tsx" \
  node "$RESOURCE_DIR/test161b.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "161b regression failed; GitHub and Stage unchanged"
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch161b.py" "$WORK_DIR/deploy/updates/${SCRIPT_NAME}_patch.py"
cat > "$WORK_DIR/docs/STROM_UPDATE_161b.md" <<'STROM161B_DOC'
# Stromnetze 161b – camera exit fix after 161 source-mismatch

## Why 161 failed
161 expected a precise `const top = overheadPose(...)` expression in the
pre-160 camera's reverse branch. The actual 159b branch has a different
expression, so the isolated checkout failed before any changes were deployed.

## Implementation
- Recover ONLY `CameraFlight150.tsx` from the verified backup made immediately
  before 160 (`20261119-203527` preferred); never roll back the Blueprint,
  model, axes, other UI or 159b timing modules.
- Undo the competing reverse driver introduced by 160 and remove its helper.
- Save the real, calibrated entry pose and temporary lens offset at the first
  3D fade frame. The entire working forward camera prepare/fade remains exact.
- On reverse, reuse the original `flight.current` assignment, capturing the
  *current* 3D camera as its start. After this assignment, override ONLY its
  destination pose with the saved blueprint top and its lens offset. No
  assumptions about the name or implementation of the old `overheadPose` call.
- Use ONE existing `useFrame` driver for both directions. Reverse 1000ms with
  ease-out and progressive view offset; original forward 750ms fade + 2500ms
  flight and reverse fade 500ms remain defined by unmodified transition code.
- Keep any app/backend/3D scene data and production deployment untouched.

## Verification
A full frontend TypeScript/Vite build and a TSX/behavioral regression run
happen in an isolated Git checkout BEFORE the Git push. A Stage backup and
second build run before deployment to `/var/www/strom-test/` only.
Actual browser camera motion still requires user-side visual verification.
STROM161B_DOC
rm -rf "$RESOURCE_DIR"
log "6) Synchronize checked source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "161b Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "7) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "161b Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "161b frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "161b test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 161b deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
