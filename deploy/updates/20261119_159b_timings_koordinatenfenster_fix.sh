#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119_159b_timings_koordinatenfenster_fix"
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
COMMIT_MESSAGE="Update 159b: transition timings and robust coordinate overlay removal"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"

# Mac launch: retain established single-password SSH connection.
if [ "$(uname -s)" = "Darwin" ] && [ -z "$MODE" ]; then
  echo "=== $SCRIPT_NAME / Mac ==="
  echo "Startordner: $MAC_PROJECT_DIR"
  echo "GitHub: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO} ($GITHUB_BRANCH)"
  echo "Pi: $REMOTE_HOST"
  [ "$(pwd)" = "$MAC_PROJECT_DIR" ] || {
    echo "FEHLER: Bitte aus $MAC_PROJECT_DIR starten." >&2
    exit 1
  }
  command -v ssh >/dev/null || { echo "ssh fehlt" >&2; exit 1; }
  command -v scp >/dev/null || { echo "scp fehlt" >&2; exit 1; }
  SSH_CONTROL_PATH="/tmp/strom-ssh-${UID:-0}-$$"
  SSH_CONTROL_OPTS=(-o ControlMaster=auto -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=600)
  close_master() {
    ssh -o ControlPath="$SSH_CONTROL_PATH" -O exit "$REMOTE_HOST" >/dev/null 2>&1 || true
    rm -f "$SSH_CONTROL_PATH" >/dev/null 2>&1 || true
  }
  trap close_master EXIT INT TERM
  echo "0) SSH-Masterverbindung zum Pi herstellen (Passwort nur einmal) ..."
  ssh -M -N -f -o ControlMaster=yes -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=600 "$REMOTE_HOST"
  ssh "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" true >/dev/null
  REMOTE_TMP_SCRIPT="${REMOTE_TMP_DIR}/$(basename "$SELF_PATH")"
  REMOTE_DEPLOY_SCRIPT="${REMOTE_DEPLOY_DIR}/$(basename "$SELF_PATH")"
  echo "1) Skript temporaer auf Pi kopieren ..."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_TMP_SCRIPT"
  echo "2) Isolierter Git-Build, Tests und GitHub-Push ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "chmod +x '$REMOTE_TMP_SCRIPT'; '$REMOTE_TMP_SCRIPT' --git-phase"
  echo "3) Skript in ~/deploy ablegen ..."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_DEPLOY_SCRIPT"
  echo "4) Geprueften Patch auf /strom-test/ ausrollen ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "rm -f '$REMOTE_TMP_SCRIPT'; chmod +x '$REMOTE_DEPLOY_SCRIPT'; cd '$REMOTE_DEPLOY_DIR'; './$(basename "$SELF_PATH")' --stage-phase"
  exit $?
fi

# Pi: Git phase, same established Git deploy key as Update 156.
if [ "$MODE" = "--git-phase" ]; then
  if [ "$(id -u)" -ne 0 ]; then exec sudo -H "$SELF_PATH" --git-phase-root; fi
  MODE="--git-phase-root"
fi
if [ "$MODE" = "--git-phase-root" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "FEHLER: Git-Phase erfordert root." >&2; exit 1; }
  [ -d "$STAGE_DIR/frontend/src" ] || { echo "FEHLER: Stage fehlt: $STAGE_DIR" >&2; exit 1; }
  [ -f /root/.ssh/config ] || { echo "FEHLER: /root/.ssh/config fehlt." >&2; exit 1; }
  grep -Eq '^[[:space:]]*Host[[:space:]]+.*github-stromnetze([[:space:]]|$)' /root/.ssh/config || {
    echo "FEHLER: SSH-Alias github-stromnetze fehlt." >&2; exit 1;
  }
  GIT_TMP="$(mktemp -d "/tmp/${SCRIPT_NAME}_gitrepo_XXXXXX")"
  trap 'rm -rf -- "$GIT_TMP"' EXIT
  echo "=== $SCRIPT_NAME / Git-Phase ==="
  GIT_SSH_COMMAND="ssh -F /root/.ssh/config" git clone --branch "$GITHUB_BRANCH" "$GITHUB_REMOTE" "$GIT_TMP"
  for dir in backend db deploy frontend tools; do
    [ -d "$STAGE_DIR/$dir" ] || continue
    mkdir -p "$GIT_TMP/$dir"
    case "$dir" in
      frontend) rsync -a --delete --exclude 'node_modules/' --exclude 'dist/' "$STAGE_DIR/$dir/" "$GIT_TMP/$dir/" ;;
      deploy) rsync -a --delete --exclude 'updates/' "$STAGE_DIR/$dir/" "$GIT_TMP/$dir/" ;;
      *) rsync -a --delete "$STAGE_DIR/$dir/" "$GIT_TMP/$dir/" ;;
    esac
  done
  for file in .gitignore .env.example Makefile README.md; do
    [ ! -f "$STAGE_DIR/$file" ] || cp -a "$STAGE_DIR/$file" "$GIT_TMP/$file"
  done
  echo "159b in isoliertem Git-Checkout anwenden und pruefen ..."
  PATCH_ONLY=1 STAGE_DIR="$GIT_TMP" PROD_DIR="$STAGE_DIR" BACKUP_BASE=/tmp "$SELF_PATH" --stage-phase
  mkdir -p "$GIT_TMP/deploy/updates"
  cp -a "$SELF_PATH" "$GIT_TMP/deploy/updates/$(basename "$SELF_PATH")"
  chmod 755 "$GIT_TMP/deploy/updates/$(basename "$SELF_PATH")"
  rm -rf "$GIT_TMP/frontend/node_modules" "$GIT_TMP/frontend/dist"
  git -C "$GIT_TMP" rm -r -f --cached --ignore-unmatch frontend/node_modules frontend/dist >/dev/null 2>&1 || true
  git -C "$GIT_TMP" config user.name "HomePi Adminpanel"
  git -C "$GIT_TMP" config user.email "homepi-adminpanel@localhost"
  git -C "$GIT_TMP" add -A
  if ! git -C "$GIT_TMP" diff --cached --quiet; then
    git -C "$GIT_TMP" commit -m "$COMMIT_MESSAGE"
  fi
  git -C "$GIT_TMP" branch -M "$GITHUB_BRANCH"
  GIT_SSH_COMMAND="ssh -F /root/.ssh/config" git -C "$GIT_TMP" push "$GITHUB_REMOTE" "$GITHUB_BRANCH:$GITHUB_BRANCH"
  echo "Git-Push erfolgreich: $(git -C "$GIT_TMP" rev-parse --short HEAD)"
  exit 0
fi

[ "$MODE" = "--stage-phase" ] || { echo "FEHLER: Unbekannter Modus $MODE" >&2; exit 1; }

if [ ! -d "$BACKUP_BASE" ]; then BACKUP_BASE="$(dirname "$STAGE_DIR")"; fi
BACKUP_DIR="$BACKUP_BASE/strom_stage_backup_${SCRIPT_NAME}_$(date +%Y%m%d-%H%M%S)"
WORK_DIR="$(mktemp -d "/tmp/${SCRIPT_NAME}_work_$(id -u)_XXXXXX")"
DIAG_LOG="/tmp/${SCRIPT_NAME}_diagnostics_$(date +%Y%m%d-%H%M%S)_$$.log"
run_sudo() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
log() { echo "$@" | tee -a "$DIAG_LOG"; }
fail() {
  log "ERROR: $*"
  log "Diagnostics: $DIAG_LOG"
  if [ -f "$DIAG_LOG" ]; then tail -n 100 "$DIAG_LOG"; fi
  exit 1
}
cleanup_work() { [ ! -d "$WORK_DIR" ] || rm -rf -- "$WORK_DIR"; }
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
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best_v" "$version" | sort -V | tail -n 1)" = "$version" ]; then
      best="$candidate"; best_v="$version"
    fi
  done
  [ -n "$best" ] || fail "Node >=20.19 oder >=22.12 fehlt"
  export PATH="$(dirname "$best"):$PATH"
  hash -r 2>/dev/null || true
  log "Node: $best ($best_v)"
}

log "=== STROM 159b: Zeiten und Diagnosefenster ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
FLIGHT="$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"
DIAG="$STAGE_DIR/frontend/src/components/cameraHandoffDiagnostics155.ts"
[ -s "$FLIGHT" ] || fail "CameraFlight150.tsx fehlt"
[ -s "$DIAG" ] || fail "cameraHandoffDiagnostics155.ts fehlt"
grep -Fq 'STROM156_BLUEPRINT_CAMERA_CENTER' "$FLIGHT" || fail "Voraussetzung: erfolgreiches Update 156 fehlt"
grep -Fq 'STROM157_OPTICAL_AXIS_TO_EYE' "$DIAG" || fail "Voraussetzung: erfolgreiches Update 157 fehlt"
grep -Fq 'STROM158_REVERSE_EXACT' "$FLIGHT" || fail "159b setzt erfolgreiches Update 158b voraus"
if grep -Fq 'STROM159_TIMINGS' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts"; then
  fail "159 / 159b ist bereits installiert"
fi
[ -s "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" ] || fail "cameraTransitions150.ts fehlt"
[ -s "$STAGE_DIR/frontend/src/App.tsx" ] || fail "App.tsx fehlt"
[ -s "$STAGE_DIR/frontend/src/styles.css" ] || fail "styles.css fehlt"
select_node
log "1) Stage sichern ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolierter Git-Checkout, kein Backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage-Backup fehlgeschlagen"
fi
log "2) Isolierte Arbeitskopie vorbereiten ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage-Kopie fehlgeschlagen"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ]; then
    DEPENDENCIES="$candidate"
    break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "TypeScript/Vite/Three-Abhaengigkeiten fehlen"
rm -rf "$WORK_DIR/frontend/node_modules"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"

log "3) Zeiten und Diagnosefenster transaktional patchen ..."
cat > "$WORK_DIR/patch159.py" <<'STROM159_PY'
#!/usr/bin/env python3
"""STROM159B_TIMINGS: stable UI fix on top of 158b."""
from pathlib import Path
import os

root = Path(os.environ['STROM159_ROOT']) / 'frontend' / 'src'
files = {
    'transitions': root / 'components' / 'cameraTransitions150.ts',
    'flight': root / 'components' / 'CameraFlight150.tsx',
    'diag': root / 'components' / 'cameraHandoffDiagnostics155.ts',
    'app': root / 'App.tsx',
    'css': root / 'styles.css',
}
s = {name: path.read_text(encoding='utf8') for name, path in files.items()}
if 'STROM158_REVERSE_EXACT' not in s['flight'] or 'STROM158_REVERSE_EXACT' not in s['css']:
    raise RuntimeError('Voraussetzung fehlt: erfolgreich installiertes Update 158b')
if any('STROM159_TIMINGS' in text for text in s.values()):
    raise RuntimeError('STROM159_TIMINGS bereits vorhanden: keine Doppelinstallation')

def replace_one(name: str, old: str, new: str, description: str):
    occurrences = s[name].count(old)
    if occurrences != 1:
        raise RuntimeError(f'{name}: {description}: erwartete 1 Fundstelle, gefunden {occurrences}: {old[:100]!r}')
    s[name] = s[name].replace(old, new, 1)
    print(f'OK {name}: {description}')

# All flight/fade timing constants live in one module. The entry spinner is
# deliberately event-driven and is NOT modified to a duration-based spinner.
replace_one('transitions',
    '// STROM150I_ANALYSIS_5S: temporary diagnostic timings; no camera geometry changes.',
    '// STROM159_TIMINGS: loading remains readiness-driven; milliseconds below.',
    'alte 5s-Versuchsnotiz aktualisieren')
replace_one('transitions', 'export const ENTER_FADE150=5000',
            'export const ENTER_FADE150=750', 'Blende hinein 750ms')
replace_one('transitions', 'export const DURATION150=5000',
            'export const DURATION150=2500', 'Hinflug 2500ms')
replace_one('transitions',
    '/** STROM158_REVERSE_EXACT: fade begins only after 5s reverse flight finishes. */\nexport const EXIT_FADE158=5000',
    '/** STROM158_REVERSE_EXACT: fade starts after the reverse flight ends. */\n'
    'export const EXIT_FADE158=500\n'
    '/** STROM159_TIMINGS: reverse flight independently configurable from forward flight. */\n'
    'export const EXIT_FLIGHT159=1000',
    'Rueckflug 1000ms und Rueckblende 500ms')
replace_one('transitions',
    'const timeout=window.setTimeout(complete,DURATION150+1000)',
    'const timeout=window.setTimeout(complete,EXIT_FLIGHT159+2000)',
    'Fallback fuer Rueckflug anpassen (kein normaler Zeitablauf)')

# STROM159B_COORDINATE_WINDOW_FIX
# Keep the existing measurement routine and camera diagnostics byte-for-byte
# except for one DOM operation. The previous version tried to delete a large
# block by exact whitespace/closing-brace anchors, and failed on the Pi.
# A detached <pre> may receive textContent but is never attached to the page.
# The 155 diagnostic module checks whether that DOM node exists and returns
# after logging/storing its values, so it requires NO source modification.
replace_one('transitions',
    'document.body.appendChild(panel)',
    '/* STROM159B_NO_COORDINATE_POPUP: do not attach debug window. */\n    panel.remove()',
    '150p Koordinatenfenster nicht mehr einhaengen')
print('OK diag: 155 Messung bleibt erhalten; kein sichtbarer 150p-Container')

# 158b uses a single duration for entry and exit; split ONLY the denominator.
# Existing ease-out and reverse-inverse path, poses and offsets are untouched.
replace_one('flight',
    '  registerExit150, notifyEnterReady150, DURATION150, ENTER_FADE150,',
    '  registerExit150, notifyEnterReady150, DURATION150, ENTER_FADE150, EXIT_FLIGHT159,',
    'gesonderte Rueckflugkonstante importieren')
replace_one('flight',
    '    const t = clamp01((performance.now() - running.startedAt) / DURATION150)',
    '    // STROM159_TIMINGS: separate 2500ms forward from 1000ms reverse duration.\n'
    "    const duration159=running.kind==='exit'?EXIT_FLIGHT159:DURATION150\n"
    '    const t = clamp01((performance.now() - running.startedAt) / duration159)',
    'Flugdauer je Richtung')

# CSS matches JS's event/timer constants, so transitions cannot drift apart.
replace_one('css',
    '.workspace.strom150c-enter-fading > .floorplan-layout {opacity:0;transition:opacity 5000ms ease;}',
    '.workspace.strom150c-enter-fading > .floorplan-layout {opacity:0;transition:opacity 750ms ease;}',
    'Einblendung 750ms')
replace_one('css',
    '  opacity:1; transition:opacity 5000ms ease;\n}',
    '  opacity:1; transition:opacity 500ms ease;\n}',
    'Rueckblende 500ms')
s['css'] += '''
/* STROM159_HIDE_CAMERA_DIAGNOSTICS: hide any stale 150p/155 popup from cached JS. */
#strom-150p-viewport-geometry, #strom-155-camera-values { display:none !important; }
'''

# Validate cross-module transition contract before writing a single file.
assert 'export const ENTER_FADE150=750' in s['transitions']
assert 'export const DURATION150=2500' in s['transitions']
assert 'export const EXIT_FLIGHT159=1000' in s['transitions']
assert 'export const EXIT_FADE158=500' in s['transitions']
assert "running.kind==='exit'?EXIT_FLIGHT159:DURATION150" in s['flight']
assert "running.kind==='exit'?t*t*t:easeOut(t)" in s['flight']
assert "running.kind==='entry'?1-k:k" in s['flight']
assert 'notifyEnterReady150()' in s['flight']
assert 'setEnterPreview150(null)' in s['app']
assert '}, ENTER_FADE150)' in s['app']
assert '},EXIT_FADE158)' in s['app']
assert 'strom150c-loader-ring' in s['app']
assert 'captureCameraHandoff155(' in s['flight']
assert "strom.camera155.handoff" in s['diag']
assert "strom.camera150p.blueprintExtents" in s['transitions']
assert 'document.body.appendChild(panel)' not in s['transitions']
assert 'STROM159B_NO_COORDINATE_POPUP' in s['transitions']
assert s['diag'] == files['diag'].read_text(encoding='utf8')
assert 'strom150o-viewport-frozen' in s['css']
assert 'STROM158_REVERSE_EXACT' in s['flight']
for name, path in files.items():
    if s[name] != path.read_text(encoding='utf8'):
        path.write_text(s[name], encoding='utf8')
        print(f'WRITE {path.relative_to(root)}')
print('PASS 159b: loading until ready, 750ms fade, 2500ms easeOut forward, 1000ms reverse, 500ms fade; no coordinate popup')
STROM159_PY
python3 - "$WORK_DIR/patch159.py" >>"$DIAG_LOG" 2>&1 <<'STROM159_SYNTAX' || fail "159 Python-Syntaxfehler"
import ast, pathlib, sys
ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf8'))
STROM159_SYNTAX
STROM159_ROOT="$WORK_DIR" python3 "$WORK_DIR/patch159.py" >>"$DIAG_LOG" 2>&1 || \
  fail "159b Quellcode-Anpassung fehlgeschlagen; Stage unveraendert"
rm -f "$WORK_DIR/patch159.py"

log "4) Vollstaendiger TypeScript-/Vite-Build ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "159b Frontend-Build fehlgeschlagen; Stage unveraendert"

log "5) Regressionstests: Zeiten, Phasen, Ease-out, Debug-UI, Kamerapose ..."
STROM159_SOURCE="$WORK_DIR/frontend/src" node <<'STROM159_TEST' >>"$DIAG_LOG" 2>&1 || \
  fail "159b Regressionstest fehlgeschlagen; Stage unveraendert"
const fs=require('node:fs'),assert=require('node:assert/strict')
const root=process.env.STROM159_SOURCE
const t=fs.readFileSync(root+'/components/cameraTransitions150.ts','utf8')
const f=fs.readFileSync(root+'/components/CameraFlight150.tsx','utf8')
const a=fs.readFileSync(root+'/App.tsx','utf8')
const c=fs.readFileSync(root+'/styles.css','utf8')
const d=fs.readFileSync(root+'/components/cameraHandoffDiagnostics155.ts','utf8')
for(const [label,source,regex] of [
  ['entry fade 750',t,/export const ENTER_FADE150=750\b/],
  ['forward flight 2500',t,/export const DURATION150=2500\b/],
  ['reverse flight 1000',t,/export const EXIT_FLIGHT159=1000\b/],
  ['exit fade 500',t,/export const EXIT_FADE158=500\b/],
  ['forward CSS 750',c,/\.workspace\.strom150c-enter-fading > \.floorplan-layout \{opacity:0;transition:opacity 750ms ease;\}/],
  ['reverse CSS 500',c,/\.workspace\.strom158-exit-fading > \.floorplan-layout \{\s*opacity:1; transition:opacity 500ms ease;/],
]) assert.match(source,regex,label)
assert(f.includes("running.kind==='exit'?EXIT_FLIGHT159:DURATION150"))
assert(f.includes('const t = clamp01((performance.now() - running.startedAt) / duration159)'))
assert(f.includes("running.kind==='exit'?t*t*t:easeOut(t)"),'inverse reverse path maintained')
assert(f.includes("running.kind==='entry'?1-k:k"),'camera lens offset animation maintained')
assert(f.includes('exactOverhead158.current={pose:clonePose158(running.start)'))
assert(f.includes('alignBlueprintCenter156('),'calibration not removed')
assert(f.includes('checkReverseAxes158('),'return diagnostics kept')
assert(f.includes('notifyEnterReady150()'),'readiness event retained')
assert(a.includes("enterPreview150 === 'loading'"),'spinner stays during async load')
assert(a.includes('strom150c-loader-ring'),'spinner retained')
assert(a.includes("setEnterPreview150(current => current === 'loading' ? 'fading' : current)"),'fade only after ready')
assert(a.includes('}, ENTER_FADE150)'),'entry fade timeout controlled by constant')
assert(a.includes('},EXIT_FADE158)'),'exit fade timeout controlled by constant')
assert(t.includes("const timeout=window.setTimeout(complete,EXIT_FLIGHT159+2000)"))
assert(t.includes("strom.camera150p.blueprintExtents"),'BP data still logged')
assert(d.includes("strom.camera155.handoff"),'camera diagnostics still logged')
assert(!t.includes('document.body.appendChild(panel)'),'150p window no longer rendered')
assert(t.includes('STROM159B_NO_COORDINATE_POPUP'),'150p DOM insertion replaced')
assert(d.includes("if(!panel)return"),'155 DOM rendering inactive when popup is detached')
assert(c.includes('#strom-150p-viewport-geometry, #strom-155-camera-values { display:none !important; }'))
assert(!c.includes('opacity:1; transition:opacity 5000ms ease;'),'old reverse fade removed')
assert(!c.includes('opacity:0;transition:opacity 5000ms ease;'),'old entry fade removed')
const easeOut=t=>1-(1-t)**3
for(let i=0;i<=100;i++){
  const x=i/100, forward=easeOut(x), reverse=x*x*x
  assert(Math.abs(reverse-(1-easeOut(1-x)))<1e-12)
  assert(forward>=0&&forward<=1&&reverse>=0&&reverse<=1)
}
console.log('PASS 159b: dynamic loading, 750/2500ms forward, 1000/500ms reverse, hide 150p+155 UI; 158b geometry unchanged')
STROM159_TEST

mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_159b.md" <<'STROM159_DOC'
# STROM 159b - Uebergangszeiten und Koordinatenfenster (robuster Fix)

Voraussetzung: erfolgreiches Update 158b (inkl. 157 optische Achse).

## Hinweg: Blueprint -> Wanddetail / 3D
- Der vorhandene Ladekreis bleibt sichtbar, bis Three.js und Kamera fertig ausgerichtet sind; kein kuenstlicher Timer. Der bisherige 30-s-Fehler-Schutz bleibt bestehen.
- Danach Blueprint-Blende in exakt 750 ms (CSS und Ready-Event-Timer synchron).
- Anschliessend 2500 ms Kameraflug mit unveraendertem `easeOut(t)=1-(1-t)^3`.

## Rueckweg: Wanddetail / 3D -> Blueprint
- 1000 ms Rueckflug entlang derselben Kameraposen, inverser `t^3`-Kurve und Lens-Offset-Kalibrierung aus Version 158b.
- Erst wenn die Rueckflug-Endpose erreicht wurde: 500 ms Blende zum originalen Blueprint.

## Anzeige
- Neues Koordinaten-Debugfenster wird nicht mehr in das DOM eingefuegt; alte Overlays werden per CSS ausgeblendet.
- Messdaten von 150p und 155 in Browser-Konsole und LocalStorage erhalten; 155-Quellcode bleibt unveraendert. Grid/Axis-Fit, Kamerapositionen, Blendenfolge und Restversatz unveraendert.

## Deployment
- Unveraenderter Mac/Pi/Git-Workflow: isolierter Patch, npm Build, Regressionstests, GitHub-Push, Backup, nur /strom-test/ ausrollen. Produktion /strom/ nicht anfassen.
STROM159_DOC

log "6) Gepruefte Quellen in Stage uebernehmen ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "159b Stage-Transfer fehlgeschlagen; Backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY - kein Web-Deployment"
  exit 0
fi
log "7) Stage bauen und ausschliesslich /strom-test/ bereitstellen ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "159b Stage-Build fehlgeschlagen; Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Frontend-Dist fehlt"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "159b Test-Deployment fehlgeschlagen; Backup: $BACKUP_DIR"
log "SUCCESS: 159b unter https://home.moja.de/strom-test/ installiert"
log "Produktion /strom/ unveraendert; Backup: $BACKUP_DIR"
