#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261127-1000_178_masse_mittig"
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
COMMIT_MESSAGE="Update 178: opening dimensions centered in doors and windows"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"
# STROM178: Fingerabdruck des Bundles, das vor der Auslieferung im echten Browser geprueft wurde.
EXPECTED_BUNDLE178="0381862f4ac9092369469eb8520dbff7c7b31c6123f35c2c2c3f432886a09c9a"
ALLOW_UNTESTED178="${STROM178_ALLOW_UNTESTED_BUNDLE:-0}"
if [ "${2:-}" = "allow-untested-bundle" ]; then ALLOW_UNTESTED178=1; fi
ALLOW_ARG178=""
if [ "$ALLOW_UNTESTED178" = "1" ]; then ALLOW_ARG178="allow-untested-bundle"; fi

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
  echo "2) Update 178 im isolierten Git-Checkout bauen, pruefen und nach GitHub pushen ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "chmod +x '$REMOTE_TMP_SCRIPT' && '$REMOTE_TMP_SCRIPT' --git-phase $ALLOW_ARG178"

  echo ""
  echo "3) Git-Push erfolgreich. Update-Script jetzt nach ~/deploy kopieren ..."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_DEPLOY_SCRIPT"

  echo ""
  echo "4) Stage-Update auf dem Pi ausfuehren ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "rm -f '$REMOTE_TMP_SCRIPT'; chmod +x '$REMOTE_DEPLOY_SCRIPT'; cd '$REMOTE_DEPLOY_DIR'; './$(basename "$SELF_PATH")' --stage-phase $ALLOW_ARG178"
  exit $?
fi

# -----------------------------------------------------------------------------
# Pi Git phase. Uses the already configured HomePi deploy key:
#   Host github-stromnetze -> /root/.ssh/.../github-stromnetze
# No Mac Git repository and no GitHub CLI are required.
# -----------------------------------------------------------------------------
if [ "$MODE" = "--git-phase" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -H "$SELF_PATH" --git-phase-root $ALLOW_ARG178
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

  echo "1.3) Update 178 isoliert anwenden, TypeScript/Vite-Build, Tests und Bundle-Abgleich ..."
  PATCH_ONLY=1 \
    STAGE_DIR="$GIT_TMP" \
    PROD_DIR="$STAGE_DIR" \
    BACKUP_BASE=/tmp \
    "$SELF_PATH" --stage-phase $ALLOW_ARG178

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
fail() { log ""; log "ERROR: $*"; log "Diagnostics: $DIAG_LOG"; if [ -f "$DIAG_LOG" ]; then echo '--- Last diagnostic lines ---'; tail -n 90 "$DIAG_LOG"; fi; exit 1; }
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

# ----- 178: Hilfsfunktionen ----------------------------------------------------------------
dist_fingerprint178() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) | sha256sum | cut -d' ' -f1
}
check_bundle178() {
  local have; have="$(dist_fingerprint178 "$1")"
  log "Bundle-Fingerabdruck: $have"
  if [ "$have" = "$EXPECTED_BUNDLE178" ]; then
    log "PASS: Bundle ist identisch mit dem im Browser geprueften Bundle."
  elif [ "$ALLOW_UNTESTED178" = "1" ]; then
    log "WARNUNG: Bundle weicht vom geprueften Bundle ab ($EXPECTED_BUNDLE178); ausdruecklich erlaubt."
  else
    ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) >>"$DIAG_LOG" 2>&1 || true
    fail "178 Bundle weicht vom im Browser geprueften Bundle ab (erwartet $EXPECTED_BUNDLE178). $2 Bewusst trotzdem: STROM178_ALLOW_UNTESTED_BUNDLE=1 vor den Mac-Befehl setzen."
  fi
}

log "=== Update 178: Masse mittig in Tueren und Fenstern ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
if grep -Fq 'STROM178_' "$STAGE_DIR/frontend/src/App.tsx" 2>/dev/null; then
  fail "178 ist bereits installiert; nichts veraendert"
fi
for file in frontend/src/App.tsx frontend/src/styles.css; do
  [ -s "$STAGE_DIR/$file" ] || fail "178 Ausgangsdatei fehlt: $file"
done
grep -Fq 'STROM177_HAIRLINES' "$STAGE_DIR/frontend/src/styles.css" || \
  fail "178 setzt den Stand 177 voraus (Haarlinien 177 fehlen); nichts veraendert"
command -v python3 >/dev/null 2>&1 || fail "python3 fehlt"
command -v rsync >/dev/null 2>&1 || fail "rsync fehlt"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum fehlt"
select_node
log "1) Backup Stage ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no Stage backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
  log "   Stage-Backup: $BACKUP_DIR"
fi
log "2) Prepare isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "178 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "178 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/178_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch178.py" <<'STROM178_PATCH'
#!/usr/bin/env python3
"""Update 178: Masse von Tueren und Fenstern mittig in der Oeffnung."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM178_ROOT']) / 'frontend'
app_path = root / 'src/App.tsx'
have = hashlib.sha256(app_path.read_bytes()).hexdigest()
if have != 'ba3852faba4fad3bc6a69565279d4ec96caaaf3919d44c176f62c1b29e063cc7':
    raise RuntimeError(f'178: App.tsx entspricht nicht Stand 177 ({have})')
app = app_path.read_text(encoding='utf-8')
if 'STROM178_' in app:
    raise RuntimeError('178: bereits installiert')
old = "        const labelAt = { x: inner.x + nx * 0.2, y: inner.y + ny * 0.2 }\n"
new = ("        // STROM178_LABEL_CENTER: Masse mittig in der Tuer bzw. im Fenster (Mitte zwischen beiden Wandseiten).\n"
       "        void nx; void ny\n"
       "        const labelAt = mid(midA, midB)\n")
if app.count(old) != 1:
    raise RuntimeError('178: Beschriftungsposition nicht gefunden')
app_path.write_text(app.replace(old, new), encoding='utf-8')
print('178: Quelltext gepatcht')
STROM178_PATCH
cat > "$RESOURCE_DIR/test166.mjs" <<'STROM178_TEST166'
// Regression 166 (enthaelt alle Pruefungen aus 165). Echtes three, echte OrbitControls.
// Prueft (1) Quelltextstruktur, (2) die Geometrie der Draufsicht, (3) dass ungesperrte
// OrbitControls den Fehler erzeugen und gesperrte ihn beseitigen.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const source = process.env.STROM166_SOURCE, modulesRaw = process.env.STROM166_MODULES
assert(source && modulesRaw, 'STROM166_SOURCE/STROM166_MODULES fehlen')
const modules = fs.realpathSync(modulesRaw)
const require = createRequire(path.join(modules, 'noop.js'))
const ts = require('typescript')
const THREE = await import(pathToFileURL(path.join(modules, 'three/build/three.module.js')).href)
const { OrbitControls } = await import(pathToFileURL(path.join(modules, 'three/examples/jsm/controls/OrbitControls.js')).href)
const read = name => fs.readFileSync(path.join(source, name), 'utf8')

// ---- 1) Struktur ---------------------------------------------------------------------------
const flight = read('components/CameraFlight150.tsx'), workspace = read('components/Building3DWorkspace.tsx')
const app = read('App.tsx'), bridge = read('components/cameraTransitions150.ts'), top = read('components/cameraTop165.ts')
for (const [name, code, kind] of [['CameraFlight150.tsx', flight, ts.ScriptKind.TSX],
  ['Building3DWorkspace.tsx', workspace, ts.ScriptKind.TSX], ['App.tsx', app, ts.ScriptKind.TSX],
  ['cameraTransitions150.ts', bridge, ts.ScriptKind.TS], ['cameraTop165.ts', top, ts.ScriptKind.TS]]) {
  const ast = ts.createSourceFile(name, code, ts.ScriptTarget.Latest, true, kind)
  assert.equal(ast.parseDiagnostics.length, 0, `${name}: Syntaxfehler`)
}
assert(workspace.includes('setRootState165({ controls })'), 'OrbitControls nicht im R3F-Store angemeldet')
assert.equal((workspace.match(/new OrbitControls\(/g) || []).length, 1, 'genau eine OrbitControls-Instanz')
assert.equal((flight.match(/\buseFrame\s*\(/g) || []).length, 1, 'zweiter Kameratreiber in CameraFlight150')
assert(flight.includes('control.enabled = false') && flight.includes('control.update = () => {}'), 'Controls werden nicht gesperrt')
assert(flight.includes('scene.onAfterRender'), 'Messung nach dem Zeichnen fehlt')
assert(flight.includes('measureBlueprint165()'), 'Live-Messung des Blueprints fehlt')
assert(flight.indexOf('active.verified >= VERIFY_FRAMES165') < flight.indexOf('notifyEnterReady150()'), 'Blende ohne Nachmessung')
assert(app.includes('registerEnterFailed165(') && app.includes('Building3DWorkspaceLazy165'), 'App-Anbindung 165 fehlt')
assert(!app.includes('storedViewport.zoom * 1.1'), 'alter Zoomausgleich x 1,1 noch vorhanden')
const removed = ['cameraBlueprintCenter156', 'cameraFloorMatch150r', 'cameraGridAlignment154', 'cameraGridAnalytic164',
  'cameraHandoffDiagnostics155', 'cameraViewportAlignment153', 'cameraViewportExact163', 'threeFloorExtrema150q']
const walk = dir => fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry =>
  entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)])
for (const file of walk(source).filter(name => /\.(ts|tsx)$/.test(name))) {
  const code = fs.readFileSync(file, 'utf8')
  for (const name of removed) {
    assert(!new RegExp(`from\\s+['"][^'"]*${name}['"]`).test(code), `${path.basename(file)} importiert noch ${name}`)
  }
}
for (const name of removed) assert(!fs.existsSync(path.join(source, 'components', name + '.ts')), `${name}.ts noch vorhanden`)
console.log('PASS 165: Quelltextstruktur')

// ---- 2) Geometrie --------------------------------------------------------------------------
const js = ts.transpileModule(top, { fileName: 'cameraTop165.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText
const scope = { exports: {} }
new Function('require', 'module', 'exports', js)(name => {
  if (name === 'three') return THREE
  throw Error('Unerwarteter Import ' + name)
}, scope, scope.exports)
const { solveTopView165, poseAt165, gridErrorPx165, lensAt165, planToWorld165, MIN_START_DISTANCE165 } = scope.exports
const BASE_FOV = 48, START_FOV = 2
function blueprint(center, pixelsPerMetre, viewport, rotation = 0) {
  const c = Math.cos(rotation) * pixelsPerMetre, s = Math.sin(rotation) * pixelsPerMetre
  const px = viewport.left + viewport.width / 2, py = viewport.top + viewport.height / 2
  return { ax: c, ay: s, bx: -s, by: c, x: px - (c * center[0] - s * center[1]), y: py - (s * center[0] + c * center[1]) }
}
function gridMatrix({ translation = [0, 0], scale = 1, yaw = 0 } = {}) {
  return new THREE.Matrix4().compose(new THREE.Vector3(translation[0], 0, translation[1]),
    new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), yaw), new THREE.Vector3(scale, scale, scale))
}
function applyPose(camera, topView, orbit, s) {
  const pose = poseAt165(topView, orbit, s, BASE_FOV, START_FOV)
  camera.position.copy(pose.position); camera.quaternion.copy(pose.quaternion); camera.fov = pose.fov
  camera.near = Math.max(0.05, pose.distance * 0.2); camera.far = pose.distance * 2 + 500
  const o = topView.offset, f = pose.offsetFactor
  if (f > 1e-6 && (Math.abs(o.x) > 1e-6 || Math.abs(o.y) > 1e-6)) camera.setViewOffset(o.width, o.height, o.x * f, o.y * f, o.width, o.height)
  else camera.clearViewOffset()
  camera.updateMatrixWorld(true)
  return pose
}
const cases = [
  { name: 'Messwerte aus dem Handover (Canvas 280 px schmaler, 107 px hoeher)', c: [5.960, 3.849], ppm: 82.68,
    vp: [330, 251, 2054, 1492.9], canvas: [330, 143.8, 1774, 1623.2] },
  { name: 'herausgezoomt, weit verschoben', c: [24.7, 10.0], ppm: 13.2, vp: [330, 252, 1526, 735], canvas: [330, 145, 1276, 850] },
  { name: 'Zoom 1000 %', c: [2, 2], ppm: 600, vp: [330, 252, 1526, 735], canvas: [330, 145, 1276, 850] },
  { name: 'negativer Bereich', c: [-8.2, -3.7], ppm: 61.1, vp: [10, 45, 900, 720], canvas: [200, -150, 730, 870] },
  { name: 'gedrehtes Blueprint-SVG', c: [5, -6], ppm: 101.31, vp: [185, 280, 2150, 1200], canvas: [0, 100, 1500, 850], bpRotation: 0.3 },
  { name: 'verschobenes, skaliertes 3D-Raster', c: [4.15, -7.21], ppm: 97.1, vp: [330, 252, 1526, 735], canvas: [330, 145, 1276, 850],
    grid: { translation: [-31, 9], scale: 1.6 } },
  { name: 'gedrehtes Blueprint und gedrehtes 3D-Raster', c: [-1.22, -5.21], ppm: 40.3, vp: [330, 252, 1526, 735],
    canvas: [330, 145, 1276, 850], bpRotation: -0.27, grid: { yaw: 0.35 } },
]
const rect = ([left, top, width, height]) => ({ left, top, width, height })
let worstTop = 0
for (const test of cases) {
  const viewport = rect(test.vp), canvas = rect(test.canvas), grid = gridMatrix(test.grid)
  const bp = blueprint(test.c, test.ppm, viewport, test.bpRotation)
  const topView = solveTopView165(bp, viewport, canvas, grid, BASE_FOV)
  assert.notEqual(typeof topView, 'string', `${test.name}: ${topView}`)
  assert(Math.abs(topView.planCenter.x - test.c[0]) < 1e-9 && Math.abs(topView.planCenter.y - test.c[1]) < 1e-9, `${test.name}: Planmitte`)
  const camera = new THREE.PerspectiveCamera(BASE_FOV, canvas.width / canvas.height, 0.05, 400)
  const iso = new THREE.PerspectiveCamera(BASE_FOV, canvas.width / canvas.height, 0.05, 400)
  const house = planToWorld165(grid, 4.5, 4).setY(1.3)
  iso.position.copy(house).add(new THREE.Vector3(11, 11.4, 11)); iso.lookAt(house); iso.updateMatrixWorld(true)
  const orbit = { pivot: house.clone(), quaternion: iso.quaternion.clone(), distance: iso.position.distanceTo(house) }
  // s = 0: senkrecht ueber der Blueprint-Mitte, Raster deckungsgleich
  const start = applyPose(camera, topView, orbit, 0)
  const direction = camera.getWorldDirection(new THREE.Vector3())
  assert(Math.abs(direction.x) < 1e-9 && Math.abs(direction.y + 1) < 1e-9 && Math.abs(direction.z) < 1e-9, `${test.name}: nicht senkrecht`)
  const centerWorld = planToWorld165(grid, test.c[0], test.c[1])
  assert(Math.abs(camera.position.x - centerWorld.x) < 1e-7 && Math.abs(camera.position.z - centerWorld.z) < 1e-7, `${test.name}: Kamera nicht ueber der Blueprint-Mitte`)
  assert(start.distance >= MIN_START_DISTANCE165 - 1e-6, `${test.name}: Starthoehe ${start.distance}`)
  const error = gridErrorPx165(bp, viewport, canvas, grid, camera)
  assert(error && error.max < 1e-4, `${test.name}: Rasterfehler ${error && error.max} px`)
  worstTop = Math.max(worstTop, error.max)
  // 2,6 m hohe Wand am Rand des sichtbaren Blueprints: hoechstens wenige Pixel neben der Linie
  const edge = { x: test.c[0] + viewport.width / 2 / test.ppm, y: test.c[1] }
  const wallTop = planToWorld165(grid, edge.x, edge.y).add(new THREE.Vector3(0, 2.6 * (test.grid?.scale || 1), 0)).project(camera)
  const foot = planToWorld165(grid, edge.x, edge.y).project(camera)
  const parallax = Math.hypot((wallTop.x - foot.x) * canvas.width / 2, (wallTop.y - foot.y) * canvas.height / 2)
  assert(parallax < 6, `${test.name}: Wandversatz ${parallax.toFixed(2)} px`)
  // s = 1: exakt die freie 3D-Ansicht, normaler Blickwinkel, keine Linsenverschiebung
  const end = applyPose(camera, topView, orbit, 1)
  assert(end.position.distanceTo(iso.position) < 1e-6 && Math.abs(end.fov - BASE_FOV) < 1e-9 && end.offsetFactor === 0, `${test.name}: Flugende`)
  assert(camera.quaternion.angleTo(iso.quaternion) < 1e-9, `${test.name}: Blickrichtung am Flugende`)
  // unterwegs: Kamera blickt immer genau auf den wandernden Blickpunkt, Abstand bleibt sicher
  let previous = null
  for (let i = 0; i <= 200; i++) {
    const s = i / 200, pose = poseAt165(topView, orbit, s, BASE_FOV, START_FOV)
    const pivot = topView.pivot.clone().lerp(orbit.pivot, s)
    const forward = new THREE.Vector3(0, 0, -1).applyQuaternion(pose.quaternion)
    assert(pose.position.clone().addScaledVector(forward, pose.distance).distanceTo(pivot) < 1e-6, `${test.name}: Blickpunkt bei s=${s}`)
    assert(pose.distance >= Math.min(topView.distanceBase, orbit.distance) - 1e-9, `${test.name}: Kamera zu nah bei s=${s}`)
    if (previous) assert(pose.fov >= previous.fov - 1e-12, `${test.name}: Blickwinkel nicht monoton`)
    previous = pose
  }
  console.log('PASS 165:', test.name, '- Rasterfehler', error.max.toExponential(1), 'px, Wandversatz am Rand', parallax.toFixed(2), 'px')
}
assert(typeof solveTopView165({ x: 0, y: 0, ax: 50, ay: 0, bx: 5, by: 45 }, rect([0, 0, 500, 400]), rect([0, 0, 500, 400]), new THREE.Matrix4(), 48) === 'string', 'verzerrtes SVG nicht abgelehnt')
assert(typeof solveTopView165({ x: 0, y: 0, ax: 50, ay: 0, bx: 0, by: -50 }, rect([0, 0, 500, 400]), rect([0, 0, 500, 400]), new THREE.Matrix4(), 48) === 'string', 'gespiegeltes SVG nicht abgelehnt')
assert(Math.abs(lensAt165(48, 2, 1).fov - 48) < 1e-12 && Math.abs(lensAt165(48, 2, 0).fov - 2) < 1e-12, 'Blickwinkel-Endwerte')

// ---- 3) Ursache und Wirkung mit echten OrbitControls ---------------------------------------
{
  const viewport = rect([330, 252, 1526, 735]), canvas = rect([330, 145, 1276, 850]), grid = new THREE.Matrix4()
  const bp = blueprint([7.5, 4], 60, viewport) // Blueprint 3 m neben der Hausmitte
  const topView = solveTopView165(bp, viewport, canvas, grid, BASE_FOV)
  const camera = new THREE.PerspectiveCamera(BASE_FOV, canvas.width / canvas.height, 0.05, 400)
  camera.position.set(15.3, 12.4, 14.8)
  const element = { style: {}, addEventListener() {}, removeEventListener() {}, clientHeight: canvas.height, clientWidth: canvas.width,
    getRootNode() { return { addEventListener() {}, removeEventListener() {} } },
    ownerDocument: { addEventListener() {}, removeEventListener() {} } }
  const controls = new OrbitControls(camera, element)
  controls.target.set(4.5, 1.3, 4); controls.enableDamping = true; controls.update()
  const orbit = { pivot: controls.target.clone(), quaternion: camera.quaternion.clone(), distance: camera.position.distanceTo(controls.target) }
  // Zustand vor 165: Kameraflug schreibt die Pose, danach laeuft controls.update() im selben Frame.
  applyPose(camera, topView, orbit, 0); controls.update(); camera.updateMatrixWorld(true)
  const before = gridErrorPx165(bp, viewport, canvas, grid, camera).max
  assert(before > 50, `Test unempfindlich: ungesperrte Controls erzeugen nur ${before} px`)
  // Zustand 165: Controls gesperrt wie in CameraFlight150.lock().
  const original = controls.update
  controls.enabled = false; controls.update = () => {}
  applyPose(camera, topView, orbit, 0); controls.update(); camera.updateMatrixWorld(true)
  const after = gridErrorPx165(bp, viewport, canvas, grid, camera).max
  assert(after < 1e-4, `gesperrte Controls: ${after} px`)
  // Flugende: Controls uebernehmen ohne Sprung.
  const end = applyPose(camera, topView, orbit, 1)
  const position = end.position.clone(), quaternion = camera.quaternion.clone()
  controls.update = original; controls.enabled = true; controls.update()
  assert(camera.position.distanceTo(position) < 1e-6 && camera.quaternion.angleTo(quaternion) < 1e-6, 'Sprung bei Uebergabe an die Controls')
  console.log(`PASS 165: OrbitControls ungesperrt ${before.toFixed(1)} px Versatz, gesperrt ${after.toExponential(1)} px, Uebergabe ohne Sprung`)
}


// ---- 4) 166: Rueckweg gespiegelt, Waende wachsen ------------------------------------------
{
  const growthSource = read('components/wallGrowth166.ts')
  const css = read('styles.css')
  assert(flight.includes('setGrowth166(pending.current ? 0 : 1)'), '166: 3D startet nicht mit Wandhoehe 0')
  assert(flight.includes('reverseTime166(active.from, tau)'), '166: Rueckweg ist nicht der gespiegelte Hinweg')
  assert(flight.includes('place(camera, active.top, active.orbit, t, grid)'), '166: Hinflug ohne Wandwachstum')
  assert(bridge.includes('export const EXIT_FLIGHT159=DURATION150/2') && bridge.includes('export const EXIT_FADE158=ENTER_FADE150/2'),
    '166: Rueckweg nicht doppelt so schnell')
  assert(css.includes('transition:opacity 375ms cubic-bezier(.75,0,.75,.9)'), '166: Rueckblende-CSS passt nicht zu EXIT_FADE158')
  assert(css.includes('transition:opacity 750ms ease'), '166: Hinblende-CSS veraendert')
  assert.equal((workspace.match(/<Growth166>/g) || []).length, 4, '166: Waende, Tueren, Treppen, Daecher der aktiven Ebene')
  assert.equal((workspace.match(/<Growth166 kind="level"/g) || []).length, 1, '166: weitere Etagen')
  for (const forbidden of ['<Growth166><FloorMesh', '<Growth166><FloorSlab149', '<Growth166><CanonicalGrid152'])
    assert(!workspace.includes(forbidden), '166: Boden/Raster duerfen nicht skaliert werden')
  const growthJs = ts.transpileModule(growthSource, { fileName: 'wallGrowth166.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText
  const growthScope = { exports: {} }
  new Function('require', 'module', 'exports', growthJs)(() => THREE, growthScope, growthScope.exports)
  const G = growthScope.exports
  // Zeitverlauf: Hinweg Kamera Ease-out, Hoehe Ease-in-out; Rueckweg exakt rueckwaerts.
  assert.equal(G.progress166(0).camera, 0); assert.equal(G.progress166(1).camera, 1)
  assert.equal(G.progress166(0).height, 0); assert.equal(G.progress166(1).height, 1)
  assert(Math.abs(G.progress166(0.5).height - 0.5) < 1e-12, 'Ease-in-out symmetrisch')
  for (const t0 of [1, 0.73, 0.2]) {
    let previous = Infinity
    for (let i = 0; i <= 100; i++) {
      const tau = i / 100, t = G.reverseTime166(t0, tau)
      assert(Math.abs(t - t0 * (1 - tau)) < 1e-12 && t <= previous + 1e-12, 'Rueckweg laeuft nicht rueckwaerts')
      previous = t
    }
    assert.equal(G.reverseTime166(t0, 0), t0); assert.equal(G.reverseTime166(t0, 1), 0)
  }
  // Ease-in auf dem Rueckweg: am Anfang langsam, an der Draufsicht schnell.
  const s = tau => G.progress166(G.reverseTime166(1, tau)).camera
  assert(1 - s(0.1) < 0.002 && s(0.9) - s(1) > 0.2, 'Rueckflug ist kein Ease-in')
  // Hoehengruppen
  const wall = new THREE.Group(), level = new THREE.Group()
  const material = new THREE.MeshStandardMaterial({ opacity: 1, transparent: false })
  level.add(new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1), material))
  const offWall = G.registerGrowth166(wall, 'height'), offLevel = G.registerGrowth166(level, 'level')
  G.setGrowth166(0)
  assert.equal(wall.scale.y, G.MIN_GROWTH166); assert.equal(level.scale.y, G.MIN_GROWTH166)
  assert(G.MIN_GROWTH166 * 2.0 > 0.015, 'Waende bei Hoehe 0 liegen nicht ueber dem Boden (1,5 cm)')
  assert(!level.visible && material.transparent && material.opacity === 0 && material.depthWrite === false, 'weitere Etage nicht ausgeblendet')
  G.setGrowth166(0.5)
  assert(Math.abs(wall.scale.y - (G.MIN_GROWTH166 + (1 - G.MIN_GROWTH166) * 0.5)) < 1e-12)
  assert(level.visible && Math.abs(material.opacity - 0.5) < 1e-12)
  G.setGrowth166(1)
  assert.equal(wall.scale.y, 1); assert.equal(level.scale.y, 1)
  assert(level.visible && material.transparent === false && material.opacity === 1 && material.depthWrite === true, 'Material nicht wiederhergestellt')
  G.setGrowth166(0); offLevel()
  assert(material.transparent === false && material.opacity === 1, 'Material nach Abmelden nicht wiederhergestellt')
  offWall(); G.setGrowth166(1)
  console.log('PASS 166: Rueckweg = Hinweg rueckwaerts (1250 ms Ease-in, Blende 375 ms), Waende wachsen 1 % -> 100 %')
}
console.log('PASS 166: alle Pruefungen bestanden')
STROM178_TEST166
cat > "$RESOURCE_DIR/test168.mjs" <<'STROM178_TEST168'
// Regression 168: Blueprint-Zoom. Statische Pruefung des gepatchten Quelltexts.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM168_SOURCE, modulesRaw = process.env.STROM168_MODULES
assert(source && modulesRaw, 'STROM168_SOURCE/STROM168_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const app = fs.readFileSync(path.join(source, 'App.tsx'), 'utf8')
const css = fs.readFileSync(path.join(source, 'styles.css'), 'utf8')
const ast = ts.createSourceFile('App.tsx', app, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
assert.equal(ast.parseDiagnostics.length, 0, 'App.tsx: Syntaxfehler')

const start = app.indexOf('function FloorplanEditor(')
const end = app.indexOf('function WallDetailEditor(')
assert(start > 0 && end > start, 'FloorplanEditor nicht gefunden')
const editor = app.slice(start, end)
assert(app.includes("import { flushSync } from 'react-dom'"), 'flushSync-Import fehlt')
assert(editor.includes("scroll.addEventListener('wheel', onWheel, passiveOff)") && editor.includes('{ passive: false }'),
  'Blueprint: nativer, nicht-passiver wheel-Listener fehlt')
assert(!/className="canvas-scroll" ref=\{canvasScrollRef\} onWheelCapture/.test(editor), 'Blueprint: React-onWheelCapture (passiv) noch aktiv')
assert(editor.includes('flushSync(() => setZoom(next))'), 'Zoom wird nicht synchron gezeichnet')
assert(editor.includes("Math.pow(2, -limited * (event.ctrlKey ? 0.01 : 0.002))"), 'Zoomfaktor nicht proportional zur Raddrehung')
assert(editor.includes('if (!frame) frame = window.requestAnimationFrame(run)'), 'Ereignisse werden nicht pro Bild gebuendelt')
assert(editor.includes("'gesturestart'") && editor.includes("'gesturechange'"), 'Safari-Pinch fehlt')
assert(editor.includes('flushViewportRef168.current() // letzte Ansicht'), 'Ansicht wird beim Verlassen nicht gespeichert')
assert(editor.includes('<CanvasRulers zoom={zoom} scrollRef={canvasScrollRef} syncRef={rulerSync168} />'), 'Lineale nicht entkoppelt')
assert(!/function handleCanvasScroll\(\) \{[^}]*setScrollPosition/.test(editor), 'Scroll baut den Editor weiter neu auf')
assert(editor.includes('zoomStep168(1.25)') && editor.includes('zoomStep168(1 / 1.25)'), 'Zoomknoepfe nicht multiplikativ')
assert(editor.includes('Mausrad und Zwei-Finger-Zoom zoomen am Mauszeiger'), 'Hilfetext nicht angepasst')
assert(app.includes("translate3d(${sheet.left - topBox.getBoundingClientRect().left}px, 0, 0)"), 'Lineal nicht an der Zeichnung ausgerichtet')
assert(css.includes('.canvas-ruler-track168 { position:absolute; inset:0; will-change:transform; }'), 'CSS Lineal-Spur fehlt')
assert(css.includes('.canvas-ruler-top, .canvas-ruler-left, .canvas-toolbox, .canvas-settings { backdrop-filter: none; }'), 'CSS Unschaerfe nicht entfernt')
// Wanddetail (klassisch) bleibt unveraendert.
const wall = app.slice(end)
assert(wall.includes('onWheelCapture={handleCanvasWheel}'), 'klassische Wandansicht unerwartet veraendert')
// Zoomformel: eine Raste (100 px) = 2^0,2 = +14,9 %; Hin und zurueck heben sich exakt auf.
const step = dy => Math.pow(2, -Math.max(-200, Math.min(200, dy)) * 0.002)
assert(Math.abs(step(-100) - 1.1487) < 1e-4 && Math.abs(step(-100) * step(100) - 1) < 1e-12, 'Zoomformel')
assert(Math.abs(step(-4) - 1.0056) < 1e-4, 'Trackpad: kleine Schritte')
console.log('PASS 168: Blueprint-Zoom am Mauszeiger, nicht-passiv, pro Bild gebuendelt, Lineale entkoppelt')
STROM178_TEST168
cat > "$RESOURCE_DIR/test169.mjs" <<'STROM178_TEST169'
// Regression 169: einheitlicher Iconsatz. Prueft den gepatchten Quelltext statisch.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM169_SOURCE, modulesRaw = process.env.STROM169_MODULES
assert(source && modulesRaw, 'STROM169_SOURCE/STROM169_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const read = (rel) => fs.readFileSync(path.join(source, rel), 'utf8')

// 1) Iconsatz laden (TS -> JS) und Inhalte pruefen.
const setTs = read('components/iconSet169.ts')
const js = ts.transpileModule(setTs, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2020 } }).outputText
const { iconSet169, iconAlias169 } = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'))
const names = Object.keys(iconSet169)
assert(names.length >= 60, `Iconsatz zu klein (${names.length})`)
const tones = new Set(['nav', 'create', 'edit', 'danger', 'view', 'layer', 'stair', 'object', 'power'])
for (const [name, [tone, body]] of Object.entries(iconSet169)) {
  assert(/^[a-z0-9-]+$/.test(name), `Iconname ungueltig: ${name}`)
  assert(tones.has(tone), `${name}: unbekannte Farbgruppe ${tone}`)
  assert(body.length > 10 && !/<script|on[a-z]+=|href=|style=|<svg/i.test(body), `${name}: unzulaessiger SVG-Inhalt`)
  // Tags ausgeglichen (nur selbstschliessende Formen oder Paare)
  const open = (body.match(/<(path|rect|circle|ellipse|line|polyline|polygon|g)\b[^>]*[^/]>/g) || []).length
  const close = (body.match(/<\/(path|rect|circle|ellipse|line|polyline|polygon|g)>/g) || []).length
  assert.equal(open, close, `${name}: SVG-Tags nicht ausgeglichen`)
  for (const cls of body.match(/class="([^"]+)"/g) || []) {
    for (const c of cls.slice(7, -1).split(/\s+/)) assert(['t', 'a', 'at', 'af', 'k', 'thin'].includes(c), `${name}: Klasse ${c}`)
  }
}
for (const [from, to] of Object.entries(iconAlias169)) assert(iconSet169[to], `Alias ${from} -> ${to} fehlt`)

// 2) Alle verwendeten Iconnamen muessen im Satz stehen (auch ueber Bedingungen/Hilfsfunktionen).
const files = ['App.tsx', 'components/Building3DWorkspace.tsx', 'components/RoofEditor148.tsx']
const used = new Map()
for (const rel of files) {
  const text = read(rel)
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  assert.equal(sf.parseDiagnostics.length, 0, `${rel}: Syntaxfehler`)
  const fns = new Map()
  const walkFns = (n) => { if (ts.isFunctionDeclaration(n) && n.name) fns.set(n.name.text, n); ts.forEachChild(n, walkFns) }
  walkFns(sf)
  const leaves = (e, out) => {
    if (!e) return
    if (ts.isParenthesizedExpression(e)) return leaves(e.expression, out)
    if (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) return out.push(e.text)
    if (ts.isConditionalExpression(e)) { leaves(e.whenTrue, out); return leaves(e.whenFalse, out) }
    if (ts.isIdentifier(e)) {
      let scope = e.parent
      while (scope && !ts.isFunctionLike(scope)) scope = scope.parent
      let found = false
      const look = (n) => { if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === e.text && n.initializer) { found = true; leaves(n.initializer, out) } ts.forEachChild(n, look) }
      if (scope) look(scope)
      if (!found) out.push('?param:' + e.text)
      return
    }
    if (ts.isCallExpression(e) && ts.isIdentifier(e.expression) && fns.has(e.expression.text)) {
      const look = (n) => { if (ts.isReturnStatement(n)) leaves(n.expression, out); ts.forEachChild(n, look) }
      return look(fns.get(e.expression.text))
    }
    out.push('?expr:' + e.getText())
  }
  const visit = (n) => {
    if ((ts.isJsxSelfClosingElement(n) || ts.isJsxOpeningElement(n))) {
      const tag = n.tagName.getText()
      assert(tag !== 'StromIcon150', `${rel}: StromIcon150 noch verwendet`)
      if (tag === 'StromIcon') {
        const attr = n.attributes.properties.find((p) => ts.isJsxAttribute(p) && p.name.getText() === 'name')
        assert(attr && attr.initializer, `${rel}: StromIcon ohne name`)
        const out = []
        if (ts.isStringLiteral(attr.initializer)) out.push(attr.initializer.text)
        else leaves(attr.initializer.expression, out)
        for (const v of out) used.set(v, (used.get(v) || 0) + 1)
      }
    }
    ts.forEachChild(n, visit)
  }
  visit(sf)
}
const unknown = [...used.keys()].filter((n) => !iconSet169[n])
assert.deepEqual(unknown, [], 'Unbekannte oder nicht aufloesbare Iconnamen: ' + unknown.join(', '))
assert(used.size >= 55, `zu wenige Icons verwendet (${used.size})`)

// 3) Keine Zeichen-/Emoji-Ersatzicons und kein zweiter Iconsatz mehr.
const app = read('App.tsx'), ws = read('components/Building3DWorkspace.tsx'), css = read('styles.css')
for (const [rel, text] of [['App.tsx', app], ['Building3DWorkspace.tsx', ws]]) {
  const m = text.match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}▸▾◌✕↺↻]/u)
  assert(!m, `${rel}: Zeichen-Icon ${m && m[0]} noch vorhanden`)
}
assert(!fs.existsSync(path.join(source, '../public/strom-icons-v7.svg')), 'alte Sprite-Datei noch vorhanden')
assert(!/strom-icons-v7|<use\b/.test(app + ws + read('components/StromIcon.tsx')), 'Sprite-Verweis noch vorhanden')
assert(read('components/StromIcon150.tsx').includes("import StromIcon from './StromIcon'"), 'StromIcon150 leitet nicht weiter')
assert(css.includes('STROM169_ICONS') && css.includes('[data-tone="danger"]') && css.includes('--si-accent:currentColor'), 'Icon-CSS fehlt')
assert(ws.includes('aria-pressed={transparent}><StromIcon name="walls-transparent"'), 'Waende transparent: Zustand nicht angezeigt')
assert(app.includes('function stairLibraryIcon169('), 'Treppenbibliothek ohne Icons')
// 165/166/168 bleiben erhalten.
assert(app.includes('STROM168_WHEEL_ZOOM'), '168 fehlt')
console.log(`PASS 169: ${names.length} Icons, ${used.size} verschiedene im Einsatz, alle aufloesbar, keine Zeichen-Icons, Sprite entfernt`)
STROM178_TEST169
cat > "$RESOURCE_DIR/test170.mjs" <<'STROM178_TEST170'
// Regression 170: Treppenrichtung und Raum loeschen. Statische Pruefung des gepatchten Quelltexts.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM170_SOURCE, modulesRaw = process.env.STROM170_MODULES
assert(source && modulesRaw, 'STROM170_SOURCE/STROM170_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const app = fs.readFileSync(path.join(source, 'App.tsx'), 'utf8')
const css = fs.readFileSync(path.join(source, 'styles.css'), 'utf8')
const sf = ts.createSourceFile('App.tsx', app, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
assert.equal(sf.parseDiagnostics.length, 0, 'App.tsx: Syntaxfehler')
const fn = (name) => { const s = app.indexOf(`function ${name}(`); assert(s > 0, name + ' fehlt'); return app.slice(s, app.indexOf('\n  }\n', s) + 4) }

// Treppenrichtung
const choose = fn('chooseStairDirection147')
assert(choose.includes('if (other) { onSelectRoom(other.id); return }'), 'Richtung anklicken zeigt den Treppenraum nicht')
assert(choose.includes('if (currentDirection && currentDirection !== direction) return'), 'nicht angelegte Gegenrichtung aendert die Richtung')
const create = fn('createOtherStair147')
assert(create.includes('stairCreating170.current = true') && create.includes('finally { stairCreating170.current = false'), 'Gegenrichtung nicht gegen Doppelklick geschuetzt')
assert(create.includes('onSelectRoom(selectedRoom.id)') && !create.includes('onSelectRoom(created.id)'), 'Auswahl springt nach dem Anlegen')
assert(app.includes("disabled={stairMissing170('up')}") && app.includes("disabled={stairMissing170('down')}"), 'Gegenrichtung nicht ausgegraut')
assert(app.includes('Neue Treppe · Richtung wählen') && app.includes('strom-stair-ask170'), 'Richtungsabfrage fehlt')
assert(/stairRoomsHere147\.length === 1 && \(\s*<div className="strom-stair-create-row170">/.test(app), 'Gegenrichtung-Knopf nicht an eine einzelne Richtung gebunden')
assert(app.includes("if (event.key === 'Delete' && !stairPanelOpen && (selectedRoom || allSelected))"), 'Entf im Treppeneditor loescht den Raum')
// Raum loeschen
const confirm = fn('confirmDeleteSelectedRoom')
const iWall = confirm.indexOf('await deleteWallObjectsOfRoom170(roomId, target.floorId)'), iRoom = confirm.indexOf('await deleteRoom(roomId)')
assert(iWall > 0 && iRoom > iWall, 'Wandobjekte werden nicht vor dem Raum entfernt')
assert(confirm.includes('setDeleteError170(message)') && confirm.includes('setDeleteBusy170(false)'), 'Fehler/Fortschritt im Fenster fehlt')
assert(fn('deleteWallObjectsOfRoom170').includes('entry.roomId === roomId'), 'nur Wandobjekte dieses Raums loeschen')
assert(app.includes('busy={deleteBusy170}') && app.includes('error={deleteError170}'), 'Fenster bekommt Zustand nicht')
assert(app.includes("{error && <p className=\"confirm-modal-error170\" role=\"alert\">"), 'Fehlertext im Fenster fehlt')
assert(app.includes('roomType: room.roomType, // STROM170'), 'Rueckgaengig verliert den Raumtyp')
assert(css.includes('.strom-stair-direction-actions147 button.strom-stair-missing170') && css.includes('.confirm-modal-delete170 .confirm-modal-confirm170'), 'CSS 170 fehlt')
// Vorstufen bleiben
assert(app.includes('STROM168_WHEEL_ZOOM') && fs.existsSync(path.join(source, 'components/iconSet169.ts')), '168/169 fehlen')
console.log('PASS 170: Treppenrichtung (Abfrage, ausgegraut, Gegenrichtung, Wechsel) und Raum loeschen (Wandobjekte zuerst, Fehler sichtbar)')
STROM178_TEST170
cat > "$RESOURCE_DIR/test171.mjs" <<'STROM178_TEST171'
// Regression 171: Treppendurchgang -> gekoppelter Treppenraum. Statische Pruefung + Logiktest.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM171_SOURCE, modulesRaw = process.env.STROM171_MODULES
assert(source && modulesRaw, 'STROM171_SOURCE/STROM171_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const app = fs.readFileSync(path.join(source, 'App.tsx'), 'utf8')
const css = fs.readFileSync(path.join(source, 'styles.css'), 'utf8')
const sf = ts.createSourceFile('App.tsx', app, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
assert.equal(sf.parseDiagnostics.length, 0, 'App.tsx: Syntaxfehler')

// Logik des Kopplungsmoduls
const modTs = fs.readFileSync(path.join(source, 'building/stairFlights171.ts'), 'utf8')
const js = ts.transpileModule(modTs, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2020 } }).outputText
const m = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'))
const data = new Map([['strom.floorplan.layers.f1.stairFlights171', JSON.stringify({ d2: 'u1', x: 'x', bad: 5 })], ['other', '{"d2":"zz"}']])
const store = { get length() { return data.size }, key: (i) => [...data.keys()][i] ?? null, getItem: (k) => data.get(k) ?? null }
assert.equal(m.stairLayoutOwner171('d2', store), 'u1', 'gekoppelter Raum liest Eigentuemer')
assert.equal(m.stairLayoutOwner171('u1', store), 'u1', 'Eigentuemer liest sich selbst')
assert.equal(m.stairLayoutOwner171('x', store), 'x', 'Selbstverweis ignoriert')
assert.deepEqual(m.readStairFlights171('f1', store), { d2: 'u1' }, 'ungueltige Eintraege verworfen')
assert.equal(m.stairFlightPartner171({ d2: 'u1' }, 'u1'), 'd2')
assert.equal(m.stairFlightPartner171({ d2: 'u1' }, 'd2'), 'u1')
assert.equal(m.stairFlightPartner171({ d2: 'u1' }, 'q'), null)
assert.equal(m.baseStairName171('Treppe (abwärts)'), 'Treppe')
assert.equal(m.baseStairName171('Treppe (abwärts) (aufwärts)'), 'Treppe (abwärts)')

// Einbau in App.tsx
assert(app.includes('return `strom-stair-layout:${stairLayoutOwner171(roomId)}`'), 'Stufen nicht gemeinsam')
assert(app.includes('return `strom-stair-edge-assignments:${stairLayoutOwner171(roomId)}`'), 'Kanten nicht gemeinsam')
assert(app.includes("onClick={event=>{event.stopPropagation();setSelectedPortal171(room.id);onSelectRoom('');setTool('select')}}"), 'Durchgang nicht auswaehlbar')
assert(app.includes('function createCoupledStair171(source: Room)') && app.includes('const nextFlights: StairFlights171 = { ...stairFlights171, [created.id]: source.id }'), 'gekoppeltes Anlegen fehlt')
assert(app.includes("const here: StairDirection147 = stairDirections147[source.id] === 'down' ? 'up' : 'down'"), 'Richtung nicht gegenlaeufig')
assert(app.includes('.filter(({ room }) => { // STROM171'), 'Durchgang bleibt trotz Treppenraum sichtbar')
assert(app.includes('const gone = (id: string) => seen.has(id) && !ids.has(id)'), 'Kopplung wird zu frueh bereinigt')
assert(app.includes('const source = coupledChanged && !ownerChanged ? coupled : owner'), 'Grundriss nicht gekoppelt')
assert(app.includes('if (roomDrag || groupDrag || polygonEdgeDrag || vertexDrag || rectHandleDrag) return'), 'Abgleich waehrend des Ziehens')
assert(app.includes('{!stairPartnerId171 && <button type="button" className="strom-stair-swap170"'), 'gekoppelte Richtung tauschbar')
assert(app.includes('className="strom-stair-link171"'), 'Kopplung nicht angezeigt')
assert(app.includes('name: `${baseStairName171(selectedRoom.name)} ('), 'Name der Gegenrichtung doppelt')
assert(css.includes('.strom-stair-portal148.selected polygon') && css.includes('.strom-stair-link171'), 'CSS 171 fehlt')
assert(app.includes('STROM170_STAIR_DIRECTION') && app.includes('STROM168_WHEEL_ZOOM'), '168/170 fehlen')
console.log('PASS 171: Treppendurchgang auswaehlbar, gekoppelter Treppenraum (Stufen und Grundriss gemeinsam), Ergaenzung der Gegenrichtung')
STROM178_TEST171
cat > "$RESOURCE_DIR/test172.mjs" <<'STROM178_TEST172'
// Regression 172: Treppen im 3D je Etage; Aussenwand einer Nachbarebene uebernehmen. Statische Pruefung.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM172_SOURCE, modulesRaw = process.env.STROM172_MODULES
assert(source && modulesRaw, 'STROM172_SOURCE/STROM172_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const read = (rel) => fs.readFileSync(path.join(source, rel), 'utf8')
const app = read('App.tsx'), ws = read('components/Building3DWorkspace.tsx'), css = read('styles.css')
for (const [name, text] of [['App.tsx', app], ['Building3DWorkspace.tsx', ws]]) {
  const sf = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  assert.equal(sf.parseDiagnostics.length, 0, name + ': Syntaxfehler')
}
// 3D: aktive Etage zeigt nur ihre Treppen
assert(ws.includes('const activeStairs146 = stairs.filter((surface146) => surface146.levelId === activeLevel.id)\n'), '3D: Treppen aller Etagen weiterhin sichtbar')
assert(ws.includes('stairs={activeStairs146}'), '3D: Szene nutzt gefilterte Treppen nicht')
assert(ws.includes('{entry146.stairs.map((surface146) => ('), '3D: weitere Etagen bringen ihre Treppen nicht mehr mit')
// Aussenwand uebernehmen
assert(app.includes('const outerWallsOf172 = (layerId: string) => rooms.filter((room) => isOuterWallRoom(room)'), 'Aussenwand-Erkennung fehlt')
assert(app.includes("if (index < 0 || outerWallsOf172(activeLayerId).length) return []"), 'Angebot trotz vorhandener Aussenwand')
assert(app.includes("relation: 'darunter'") && app.includes("relation: 'darüber'"), 'Nachbarebenen darunter/darueber fehlen')
assert(app.includes('async function adoptOuterWall172(') && app.includes('wallThicknessM: wall.wallThicknessM,') && app.includes('vertices: wall.vertices.map((point) => ({ ...point })),'), 'Kopie unvollstaendig')
assert(app.includes('for (const id of createdIds) next[id] = activeLayerId'), 'Kopie nicht der aktiven Ebene zugeordnet')
assert(app.includes('{outerOffer172 && (') && app.includes('className="strom-stair-direction-floating147 strom-stair-ask170 strom-outer-offer172"'), 'Angebotsfenster fehlt')
assert(app.includes("void chooseTool('outerwall')"), 'Selbst zeichnen fehlt')
assert(css.includes('.strom-outer-offer-outline172 polygon'), 'CSS 172 fehlt')
assert(app.includes('STROM171_STAIR_FLIGHT') && app.includes('STROM170_STAIR_DIRECTION'), '170/171 fehlen')
console.log('PASS 172: Treppen im 3D nur auf ihrer Etage; Aussenwand von Nachbarebene uebernehmen')
STROM178_TEST172
cat > "$RESOURCE_DIR/test173.mjs" <<'STROM178_TEST173'
// Regression 173 (Stand 175): ein Ebenenmenue (Blueprint/3D), standardmaessig offen; verschiebbare Fenster. Statische Pruefung.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM173_SOURCE, modulesRaw = process.env.STROM173_MODULES
assert(source && modulesRaw, 'STROM173_SOURCE/STROM173_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const read = (rel) => fs.readFileSync(path.join(source, rel), 'utf8')
const files = { app: 'App.tsx', ws: 'components/Building3DWorkspace.tsx', menu: 'components/LevelMenu173.tsx', drag: 'components/floatDrag173.ts', store: 'building/levelStore173.ts', icon: 'components/StromIcon.tsx' }
const src = Object.fromEntries(Object.entries(files).map(([k, rel]) => {
  const text = read(rel)
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, rel.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
  assert.equal(sf.parseDiagnostics.length, 0, rel + ': Syntaxfehler')
  return [k, text]
}))
const css = read('styles.css')
// Ein Menue fuer beide
assert.equal((src.app.match(/<LevelMenu173\b/g) || []).length, 1, 'Blueprint nutzt das gemeinsame Menue nicht')
assert.equal((src.ws.match(/<LevelMenu173\b/g) || []).length, 1, '3D nutzt das gemeinsame Menue nicht')
assert(!src.app.includes("<div className={`canvas-layer-menu ${layersOpen ? 'open' : ''}`} aria-label=\"Ebenen\">"), 'altes Blueprint-Menue noch vorhanden')
assert(!src.ws.includes('building3d-floating-level-row145'), 'altes 3D-Menue noch vorhanden')
for (const part of ['layer-zero-marker151', 'layer-eye', 'aria-label="Ebenenname"', 'layer-height-control', 'layer-slab-control149', 'layer-grip', 'layer-add', 'layer-delete'])
  assert(src.menu.includes(part), 'Menue: ' + part + ' fehlt')
// standardmaessig offen
assert(src.app.includes('const [layersOpen, setLayersOpen] = useState(true) // STROM173: Ebenenmenue standardmaessig offen'), 'Blueprint-Menue nicht offen')
assert(src.ws.includes('const [levelsOpen145, setLevelsOpen145] = useState(true)'), '3D-Menue nicht offen')
assert(src.app.includes("const [layersOpen, setLayersOpen] = useState(true) // STROM173\n"), 'Wand-Menue nicht offen')
// 3D: gleiche Daten
for (const fn of ['patchRawLayer173(floor, id, { name })', 'moveRawLayer173(floor, dragId, targetId)', 'writeZeroLevel151(floor.id, id, window.localStorage)', 'async function confirmDeleteLevel173()', 'function addLevel173()'])
  assert(src.ws.includes(fn), '3D: ' + fn + ' fehlt')
assert(src.ws.includes('entry146.id !== activeLevel.id && levelVisible173(entry146.id)'), '3D: Auge wirkt nicht auf weitere Etagen')
// verschiebbar
const ids = [...(src.app + src.ws + src.menu).matchAll(/floatRef173\('([a-z0-9-]+)'\)/g)].map((m) => m[1])
for (const id of ['blueprint-info', 'blueprint-door', 'blueprint-recess', 'blueprint-distance', 'blueprint-draft', 'blueprint-recess-help', 'levels', 'roof'])
  assert(ids.includes(id), 'nicht verschiebbar: ' + id)
assert(src.menu.includes('ref={floatRef173(floatId)}') && src.ws.includes('floatId="levels"') && src.app.includes('floatId="levels"'), 'Ebenenmenues nicht verschiebbar (175: gemeinsame ID)')
assert(src.drag.includes("el.style.setProperty('position', 'fixed')") && src.drag.includes('NO_DRAG') && src.drag.includes("addEventListener('dblclick'"), 'Verschiebe-Logik unvollstaendig')
assert(src.icon.includes('export default memo(StromIcon)') && css.includes('svg.strom-icon, svg.strom-icon * { pointer-events: none !important; }'), 'Icon-Klickziel nicht stabil')
assert(src.app.includes('STROM172_OUTER_WALL_ADOPT') && src.ws.includes('STROM172_STAIR_LEVELS'), '172 fehlt')
console.log('PASS 173: ein Ebenenmenue fuer Blueprint und 3D (offen), alle schwebenden Fenster verschiebbar')
STROM178_TEST173
cat > "$RESOURCE_DIR/test174.mjs" <<'STROM178_TEST174'
// Regression 174: beliebige Ebenen einblenden, Vorgaben Solo/Nachbar/Alle. Logiktest + statische Pruefung.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM174_SOURCE, modulesRaw = process.env.STROM174_MODULES
assert(source && modulesRaw, 'STROM174_SOURCE/STROM174_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const read = (rel) => fs.readFileSync(path.join(source, rel), 'utf8')
const js = ts.transpileModule(read('building/levelVisibility174.ts'), { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2020 } }).outputText
const v = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'))
const L = [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }]
const vis = (list) => list.map((l) => (l.visible ? 1 : 0)).join('')
assert.equal(vis(v.applyPreset174(L, 'b', 'solo')), '0100')
assert.equal(vis(v.applyPreset174(L, 'b', 'neighbors')), '1110')
assert.equal(vis(v.applyPreset174(L, 'a', 'neighbors')), '1100')
assert.equal(vis(v.applyPreset174(L, 'b', 'all')), '1111')
assert.equal(v.derivePreset174(v.applyPreset174(L, 'c', 'neighbors'), 'c'), 'neighbors')
assert.equal(v.derivePreset174(v.applyPreset174(L, 'c', 'solo'), 'c'), 'solo')
assert.equal(v.derivePreset174([{ id: 'a', visible: true }, { id: 'b', visible: false }, { id: 'c', visible: false }, { id: 'd', visible: true }], 'a'), 'custom')
assert.equal(v.derivePreset174([{ id: 'a', visible: true }, { id: 'b', visible: true }], 'a', 'neighbors'), 'neighbors', 'Gleichstand per Hinweis')
assert.equal(v.derivePreset174([{ id: 'a', visible: true }, { id: 'b', visible: true }], 'a', 'all'), 'all')
// Umstellung: bisheriger Modus bestimmt die Schalter
const store = (entries) => { const m = new Map(Object.entries(entries)); return { getItem: (k) => m.get(k) ?? null, setItem: (k, x) => m.set(k, x), m } }
const P = 'strom.floorplan.layers.f1.'
const list = JSON.stringify([{ id: 'a', visible: true }, { id: 'b', visible: true }, { id: 'c', visible: true }, { id: 'd', visible: false }])
let s = store({ [P + 'list']: list, [P + 'active']: '"b"', [P + 'visibilityMode']: '"active"' }); v.migrateVisibility174('f1', s)
assert.equal(vis(JSON.parse(s.m.get(P + 'list'))), '0100', 'Umstellung solo'); assert.equal(s.m.get(P + 'visibility174'), '1')
s = store({ [P + 'list']: list, [P + 'active']: '"b"', [P + 'visibilityMode']: '"adjacentGhostDims"' }); v.migrateVisibility174('f1', s)
assert.equal(vis(JSON.parse(s.m.get(P + 'list'))), '1110', 'Umstellung Nachbar')
s = store({ [P + 'list']: list, [P + 'active']: '"b"', [P + 'visibilityMode']: '"allGhostNoDims"' }); v.migrateVisibility174('f1', s)
assert.equal(vis(JSON.parse(s.m.get(P + 'list'))), '1110', 'Umstellung Alle (ausgeblendete bleiben aus)')
s.m.set(P + 'list', list); v.migrateVisibility174('f1', s)
assert.equal(s.m.get(P + 'list'), list, 'Umstellung nur einmal')
// Einbau
const app = read('App.tsx'), ws = read('components/Building3DWorkspace.tsx'), menu = read('components/LevelMenu173.tsx'), css = read('styles.css')
assert(app.includes('migrateVisibility174(floorId, window.localStorage)') && read('building/levelStore173.ts').includes('migrateVisibility174(floor.id, window.localStorage)'), 'Umstellung nicht eingebaut')
assert(app.includes("return { visible: true, ghost: true, dimensions: layerVisibilityMode === 'adjacentGhostDims', interactive: false }"), 'Blueprint: Ebenen nicht einzeln einblendbar')
assert(app.includes("setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, visible: layer.visible === false } : layer))"), 'Blueprint-Auge')
assert(app.includes('onPreset={(preset) => applyLevelPreset174(preset)}') && ws.includes('onPreset={(preset) => applyLevelPreset174(preset)}'), 'Vorgaben nicht angeschlossen')
assert(menu.includes("{ id: 'solo', label: 'Solo'") && menu.includes("{ id: 'neighbors', label: 'Nachbar'") && menu.includes("{ id: 'all', label: 'Alle'"), 'Vorgabe-Knoepfe fehlen')
assert(!ws.includes('useState(false)\n  const [separateLevels146') && ws.includes('const showAllLevels146 = layers173.some('), '3D: eigener Alle-Etagen-Zustand noch vorhanden')
assert(ws.includes('  const extraLevels146 = showAllLevels146\n') && ws.includes('showAllLevels146={showAllLevels146}'), 'Wanddetail zeigt keine weiteren Etagen')
assert(ws.includes("patchRawLayer173(floor, id, { visible: !levelVisible173(id) })") && !ws.includes('setShowAllLevels146(true)'), '3D-Auge blendet weiterhin alle ein')
assert(css.includes('.level-menu173 .layer-visibility-presets174 button.active'), 'CSS 174 fehlt')
console.log('PASS 174: Ebenen einzeln einblendbar (Blueprint, 3D Haus, Wanddetail), Solo/Nachbar/Alle, Umstellung')
STROM178_TEST174
cat > "$RESOURCE_DIR/test175.mjs" <<'STROM178_TEST175'
// Regression 175: Eigenschaften oben in 3D Haus/Wanddetail; Fensterpositionen in Bildschirmkoordinaten.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM175_SOURCE, modulesRaw = process.env.STROM175_MODULES
assert(source && modulesRaw, 'STROM175_SOURCE/STROM175_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const read = (rel) => fs.readFileSync(path.join(source, rel), 'utf8')
const app = read('App.tsx'), ws = read('components/Building3DWorkspace.tsx'), drag = read('components/floatDrag173.ts'), css = read('styles.css')
for (const [name, text, kind] of [['App.tsx', app, ts.ScriptKind.TSX], ['Building3DWorkspace.tsx', ws, ts.ScriptKind.TSX], ['floatDrag173.ts', drag, ts.ScriptKind.TS]]) {
  const sf = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, kind)
  assert.equal(sf.parseDiagnostics.length, 0, name + ': Syntaxfehler')
}
// Eigenschaften oben
assert(!ws.includes('<aside className="building3d-inspector">'), '3D: rechte Seitenleiste noch vorhanden')
const iBar = ws.indexOf('className={`properties-topbar building3d-properties175'), iContent = ws.indexOf('<div className="building3d-content">'), iToolbar = ws.indexOf('<div className="building3d-toolbar">')
assert(iToolbar > 0 && iBar > iToolbar && iContent > iBar, '3D: Eigenschaftenleiste nicht zwischen Werkzeugleiste und Ansicht')
for (const part of ['shiftSelectedRoom((xMm / 1000) - centroid.x, (yMm / 1000) - centroid.y)', '<DoorForm model={model} door={selectedDoor}', "'Keine Auswahl'", 'building3d-directional175'])
  assert(ws.includes(part), '3D-Eigenschaften: ' + part + ' fehlt')
assert(ws.includes("<div ref={floatRef173('roof')} className=\"strom-roof-floating148\"><RoofEditor148 floorId={floor.id}"), '3D: Dachschraege nicht schwebend')
assert(css.includes('.building3d-layout > .building3d-content { grid-template-columns: minmax(0, 1fr) !important; }'), '3D: Ansicht nicht volle Breite')
assert(ws.includes('const allLevelsVisible174 = layers173.length > 1 && layers173.every('), 'eine Ebene gilt als "Alle Etagen"')
// Positionen gehalten
assert(app.includes('floatId="levels"') && ws.includes('floatId="levels"') && app.includes("ref={floatRef173('levels')}"), 'Ebenenfenster nicht mit gemeinsamer ID')
assert(app.includes("ref={floatRef173('roof')}"), 'Dachschraege nicht mit gemeinsamer ID')
for (const part of ["el.style.setProperty('position', 'fixed')", 'const lastSeen = new Map<string, Pos175>()', 'function targetPos(', "window.addEventListener('resize'", 'return () => {', "OLD173 = 'strom.ui.floatOffsets173'"])
  assert(drag.includes(part), 'Verschieben: ' + part + ' fehlt')
assert(css.includes('.canvas-card.wall-detail-card { z-index: 11; }'), 'Wanddetail verdeckt gehaltene Fenster')
assert(ws.includes('STROM174_LEVEL_VISIBILITY'), '174 fehlt')
console.log('PASS 175: Eigenschaften oben in 3D Haus/Wanddetail; Fenster behalten ihre Bildschirmposition beim Ansichtswechsel')
STROM178_TEST175
cat > "$RESOURCE_DIR/test176.mjs" <<'STROM178_TEST176'
// Regression 176: Ziehen nur ausgewaehlt; Tueren/Fenster orange, Fenster als H, Masse; Einheiten im Ebenenfenster; Z=0-Icon.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM176_SOURCE, modulesRaw = process.env.STROM176_MODULES
assert(source && modulesRaw, 'STROM176_SOURCE/STROM176_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const read = (rel) => fs.readFileSync(path.join(source, rel), 'utf8')
const app = read('App.tsx'), menu = read('components/LevelMenu173.tsx'), css = read('styles.css'), icons = read('components/iconSet169.ts')
for (const [name, text] of [['App.tsx', app], ['LevelMenu173.tsx', menu]]) {
  const sf = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  assert.equal(sf.parseDiagnostics.length, 0, name + ': Syntaxfehler')
}
// Einheiten lesen (Funktion aus der Komponente)
const start = menu.indexOf('export function parseLengthMm176('), end = menu.indexOf('\n}\n', start) + 3
const fnJs = ts.transpileModule(menu.slice(start, end).replace('export function', 'function'), { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText
const parse = new Function(fnJs + '\nreturn parseLengthMm176')()
const cases = [['2600', 2600], ['2600mm', 2600], ['2600 mm', 2600], ['2,6 m', 2600], ['2.6m', 2600], ['260cm', 2600], ['26dm', 2600], ['1m', 1000], ['0,25 M', 250], ['12,5', 13], ['.5m', 500], ['abc', null], ['2 600', 2600], ['', null], ['m', null]]
for (const [input, expected] of cases) assert.equal(parse(input), expected, `"${input}" -> ${expected}`)
// Ziehen nur ausgewaehlt
assert(app.includes('if (!allSelected && room.id !== selectedRoomId) {') && app.includes('STROM176_SELECT_BEFORE_DRAG'), 'Ziehen nicht ausgewaehlter Objekte')
assert(app.includes('if (suppressCanvasClickRef.current) { suppressCanvasClickRef.current = false; return }'), 'Klick nach Verschieben waehlt aus')
assert(app.includes('// STROM176: Raumname eines nicht ausgewaehlten Raums'), 'Raumname zieht unausgewaehlten Raum')
// Oeffnungen
assert(app.includes("(item.objectType === 'door' || item.objectType === 'window')"), 'Fenster nicht im Blueprint')
assert(app.includes("'blueprint-window-jamb176'") && app.includes("'blueprint-window-glass176'"), 'Fenster nicht als H')
assert(app.includes('BRH ${o.sillMm}') && app.includes('showDimensions={dimensionsVisible && tool === \'select\'}'), 'Masse an Oeffnungen fehlen')
assert(css.includes('.blueprint-openings176 .blueprint-door176 .blueprint-wall-door-edge { stroke: #b45309; }') && css.includes('stroke: #b45309; stroke-width: 2.2'), 'Oeffnungen nicht orange')
// Ebenenfenster
assert(!menu.includes('type="number"') && (menu.match(/<MmField176 /g) || []).length === 2, 'Masseingabe nicht ersetzt')
assert(!menu.includes('(mm)</span>'), 'Einheit steht noch ueber dem Feld')
assert(!menu.includes('type="radio"') && menu.includes('role="radio"') && menu.includes('<StromIcon name="zero-level"'), 'Z=0 nicht als Icon')
assert(icons.includes('"zero-level": ["layer",'), 'Icon zero-level fehlt')
assert(css.includes('.level-menu173 .mm-unit176') && css.includes('button.layer-zero176.active'), 'CSS 176 fehlt')
assert(app.includes('STROM175') || read('components/Building3DWorkspace.tsx').includes('STROM175_PROPERTIES_TOP'), '175 fehlt')
console.log('PASS 176: Ziehen nur ausgewaehlt, Tueren/Fenster orange (Fenster als H, Masse), Einheiten m/dm/cm/mm, Z=0-Icon')
STROM178_TEST176
cat > "$RESOURCE_DIR/test177.mjs" <<'STROM178_TEST177'
// Regression 177: Tueren/Fenster als Haarlinien, Masse dezent (statische Pruefung).
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
const source = process.env.STROM177_SOURCE
assert(source, 'STROM177_SOURCE fehlt')
const css = fs.readFileSync(path.join(source, 'styles.css'), 'utf8')
const block = css.slice(css.indexOf('STROM177_HAIRLINES'))
assert(block.length > 100, 'CSS 177 fehlt')
for (const sel of ['polygon.blueprint-wall-connection-door', '.blueprint-wall-door-edge', 'line.blueprint-window-jamb176', 'line.blueprint-window-glass176'])
  assert(block.includes(sel), 'Haarlinie fehlt: ' + sel)
assert((block.match(/stroke-width: 0\.75px; vector-effect: non-scaling-stroke;/g) || []).length === 3, 'Linienstaerke nicht 0,75 px')
assert(block.includes('font-weight: 500;') && block.includes('font-size: calc(var(--floorplan-small-text-size, 12.8px) * 0.9) !important;') && block.includes('opacity: 0.8;'), 'Masse nicht dezent')
assert(css.includes('STROM176_OPENINGS'), '176 fehlt')
console.log('PASS 177: Tueren/Fenster als Haarlinien (0,75 px), Masse dezent')
STROM178_TEST177
cat > "$RESOURCE_DIR/test178.mjs" <<'STROM178_TEST'
// Regression 178: Masse von Tueren/Fenstern mittig in der Oeffnung (statische Pruefung).
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
const source = process.env.STROM178_SOURCE
assert(source, 'STROM178_SOURCE fehlt')
const app = fs.readFileSync(path.join(source, 'App.tsx'), 'utf8')
const i = app.indexOf('STROM178_LABEL_CENTER')
assert(i > 0, 'Marker 178 fehlt')
const near = app.slice(i, i + 400)
assert(near.includes('const labelAt = mid(midA, midB)'), 'Beschriftung nicht mittig')
assert(!app.includes('inner.x + nx * 0.2'), 'alte Beschriftungsposition noch vorhanden')
const css = fs.readFileSync(path.join(source, 'styles.css'), 'utf8')
assert(css.includes('STROM177_HAIRLINES') && app.includes('STROM176_OPENINGS'), '176/177 fehlen')
console.log('PASS 178: Masse mittig in Tuer/Fenster')
STROM178_TEST
cat > "$RESOURCE_DIR/STROM_UPDATE_178.md" <<'STROM178_DOC'
# Update 178: Masse mittig in Tueren und Fenstern

- Die kleinen Masse (Tuer b×h, Fenster b×h·BRH) stehen jetzt mittig in der Oeffnung,
  also in der Mitte zwischen beiden Wandseiten und in der Mitte der Breite.
- Farbe, Schriftgroesse, weisse Freistellung und Ausrichtung entlang der Wand bleiben wie in 177.
- Nur Testumgebung /strom-test/; Produktion unveraendert.
STROM178_DOC
log "3) Quelltext patchen (Masse mittig) ..."
python3 -m py_compile "$RESOURCE_DIR/patch178.py" >>"$DIAG_LOG" 2>&1 || fail "178 Python patch syntax error"
STROM178_ROOT="$WORK_DIR" STROM178_RESOURCES="$RESOURCE_DIR" python3 "$RESOURCE_DIR/patch178.py" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Ausgangsstand passt nicht; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build BEFORE committing ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "178 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Regression: 165/166, Zoom 168, Icons 169, Treppen 170/171, 3D-Treppen/Aussenwand 172, Ebenenmenue 173, Sichtbarkeit 174, Eigenschaften/Fenster 175, Ziehen/Oeffnungen 176, Haarlinien 177, Masse mittig 178 ..."
STROM166_SOURCE="$WORK_DIR/frontend/src" STROM166_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test166.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression 165/166 fehlgeschlagen; GitHub and Stage unchanged"
STROM168_SOURCE="$WORK_DIR/frontend/src" STROM168_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test168.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Blueprint-Zoom 168 fehlgeschlagen; GitHub and Stage unchanged"
STROM169_SOURCE="$WORK_DIR/frontend/src" STROM169_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test169.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Iconsatz 169 fehlgeschlagen; GitHub and Stage unchanged"
STROM170_SOURCE="$WORK_DIR/frontend/src" STROM170_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test170.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Treppenrichtung/Loeschen 170 fehlgeschlagen; GitHub and Stage unchanged"
STROM171_SOURCE="$WORK_DIR/frontend/src" STROM171_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test171.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Treppendurchgang 171 fehlgeschlagen; GitHub and Stage unchanged"
STROM172_SOURCE="$WORK_DIR/frontend/src" STROM172_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test172.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression 3D-Treppen/Aussenwand 172 fehlgeschlagen; GitHub and Stage unchanged"
STROM173_SOURCE="$WORK_DIR/frontend/src" STROM173_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test173.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Ebenenmenue/Fenster 173 fehlgeschlagen; GitHub and Stage unchanged"
STROM174_SOURCE="$WORK_DIR/frontend/src" STROM174_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test174.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Ebenen-Sichtbarkeit 174 fehlgeschlagen; GitHub and Stage unchanged"
STROM175_SOURCE="$WORK_DIR/frontend/src" STROM175_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test175.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Eigenschaften/Fensterpositionen 175 fehlgeschlagen; GitHub and Stage unchanged"
STROM176_SOURCE="$WORK_DIR/frontend/src" STROM176_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test176.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Ziehen/Oeffnungen/Ebenenfenster 176 fehlgeschlagen; GitHub and Stage unchanged"
STROM177_SOURCE="$WORK_DIR/frontend/src" STROM177_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test177.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Haarlinien 177 fehlgeschlagen; GitHub and Stage unchanged"
STROM178_SOURCE="$WORK_DIR/frontend/src" STROM178_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test178.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "178 Regression Masse mittig fehlgeschlagen; GitHub and Stage unchanged"
grep -F -e 'PASS 166: alle' -e 'PASS 168' -e 'PASS 169' -e 'PASS 170' -e 'PASS 171' -e 'PASS 172' -e 'PASS 173' -e 'PASS 174' -e 'PASS 175' -e 'PASS 176' -e 'PASS 177' -e 'PASS 178' "$DIAG_LOG" | tail -n 12 || true
log "6) Bundle mit dem im Browser geprueften Bundle vergleichen ..."
check_bundle178 "$WORK_DIR/frontend/dist" "GitHub and Stage unchanged."
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch178.py" "$WORK_DIR/deploy/updates/${SCRIPT_NAME}_patch.py"
cp -a "$RESOURCE_DIR/STROM_UPDATE_178.md" "$WORK_DIR/docs/STROM_UPDATE_178.md"
rm -rf "$RESOURCE_DIR"
log "7) Synchronize verified source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "178 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "8) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "178 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "178 frontend/dist missing"
check_bundle178 "$STAGE_DIR/frontend/dist" "Testseite unveraendert; Stage-Backup: $BACKUP_DIR."
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "178 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 178 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
