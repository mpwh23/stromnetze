#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1930_157_kamera_sichtachse_korrektur"
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
COMMIT_MESSAGE="Update 157: report physical camera viewing axis independently of lens offset"
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
  echo "157 in isoliertem Git-Checkout anwenden und pruefen ..."
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

log "=== STROM 157: Sichtachse statt verschobener Canvas-Mittelpunkt-Strahl ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
FLIGHT="$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"
DIAG="$STAGE_DIR/frontend/src/components/cameraHandoffDiagnostics155.ts"
[ -s "$FLIGHT" ] || fail "CameraFlight150.tsx fehlt"
[ -s "$DIAG" ] || fail "cameraHandoffDiagnostics155.ts fehlt"
grep -Fq 'STROM156_BLUEPRINT_CAMERA_CENTER' "$FLIGHT" || fail "Voraussetzung: erfolgreiches Update 156 fehlt"
grep -Fq 'STROM155_CAMERA_VIEWPORT_DIAGNOSTICS' "$DIAG" || fail "Voraussetzung: Diagnose 155 fehlt"
if grep -Fq 'STROM157_OPTICAL_AXIS_TO_EYE' "$DIAG"; then fail "157 ist bereits installiert"; fi
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

log "3) Gezielt nur die Kameradiagnose korrigieren ..."
cat > "$WORK_DIR/patch157.py" <<'STROM157_PY'
#!/usr/bin/env python3
from pathlib import Path
import os
root=Path(os.environ['STROM157_ROOT'])
path=root/'frontend/src/components/cameraHandoffDiagnostics155.ts'
s=path.read_text('utf8')
if 'STROM157_OPTICAL_AXIS_TO_EYE' in s:
    raise RuntimeError('157: Bereits installiert')

def replace_one(old,new,label):
    global s
    n=s.count(old)
    if n!=1:
        raise RuntimeError(f'157 {label}: genau ein Anker erwartet, {n} gefunden: {old!r}')
    s=s.replace(old,new,1)

# The original diagnostic reports the centre-of-CANVAS ray. The projection
# intentionally uses an off-axis viewOffset to align the Blueprint viewport,
# so that ray is NOT the camera's straight optical axis.
# The user-requested +Z is the optical axis directed FROM the scene TO the eye.
# It is NOT the physical looking direction (that remains -Z, toward the floor).
replace_one(
 "  const angles=new THREE.Euler().setFromQuaternion(worldRotation,'XYZ')",
 """  const angles=new THREE.Euler().setFromQuaternion(worldRotation,'XYZ')
  // STROM157_OPTICAL_AXIS_TO_EYE: real camera orientation, unaffected by lens/viewOffset.
  // Positive architectural Z is the direction from floor to the observer.
  // The actual forward viewing direction is the opposite vector (toward -Z).
  const toEye157=camera.getWorldDirection(new THREE.Vector3()).negate().normalize()
  const zero157=(value:number):number=>Math.abs(value)<0.0005?0:round155(value)
  const opticalAxisToEye157={
    x:zero157(toEye157.x),y:zero157(toEye157.z),z:zero157(toEye157.y),
  }""",
 'measured camera optical axis')
replace_one(
 "      architecturalDirection:{x:round155(direction.x),y:round155(direction.z),z:round155(direction.y)},",
 """      architecturalDirection:{x:round155(direction.x),y:round155(direction.z),z:round155(direction.y)},
      // Optical camera axis in plan coordinates, oriented toward the observer.
      opticalAxisToEye157,""",
 'stored geometry diagnostics')
replace_one(
 "  const p=result.camera.position,d=result.camera.direction,r=result.camera.rotationXYZDegrees",
 """  const p=result.camera.position,r=result.camera.rotationXYZDegrees
  const facing=result.camera.opticalAxisToEye157""",
 'panel variables')
replace_one(
 "    +`Blickrichtung XYZ (Plan): (${d.x}, ${d.z}, ${d.y})\\n`",
 "    +`Blickachse zur Kamera XYZ (Plan): (${facing.x}, ${facing.y}, ${facing.z})\\n`",
 'panel direction vector')
path.write_text(s,'utf8')
print('PASS 157: real +Z viewing normal, original -Z line of sight and pixel projection unchanged')
STROM157_PY
python3 -m py_compile "$WORK_DIR/patch157.py" >>"$DIAG_LOG" 2>&1 || fail "157 Python-Syntaxfehler"
STROM157_ROOT="$WORK_DIR" python3 "$WORK_DIR/patch157.py" >>"$DIAG_LOG" 2>&1 || fail "157 Quelle konnte nicht angepasst werden"
rm -f "$WORK_DIR/patch157.py"

log "4) Vollstaendiger TypeScript-/Vite-Build ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "157 Frontend-Build fehlgeschlagen; Stage unveraendert"
log "5) Kameraachsen- und Regressionspruefung ..."
STROM157_SOURCE="$WORK_DIR/frontend/src" STROM157_THREE="$DEPENDENCIES/three" node <<'STROM157_TEST' >>"$DIAG_LOG" 2>&1 || fail "157 Kameratests fehlgeschlagen; Stage unveraendert"
const fs=require('fs'),assert=require('assert')
const THREE=require(process.env.STROM157_THREE)
const root=process.env.STROM157_SOURCE
const s=fs.readFileSync(root+'/components/cameraHandoffDiagnostics155.ts','utf8')
const f=fs.readFileSync(root+'/components/CameraFlight150.tsx','utf8')
assert(s.includes('STROM157_OPTICAL_AXIS_TO_EYE'))
assert(s.includes('Blickachse zur Kamera XYZ (Plan)'))
assert(s.includes('opticalAxisToEye157'))
assert(s.includes('const direction=far.clone().sub(near).normalize()'), 'Existing true canvas-centre ray preserved')
assert(f.includes('STROM156_BLUEPRINT_CAMERA_CENTER'), 'Blueprint centre calibration preserved')
assert(f.includes('applyViewOffset156(camera,running.viewOffset156,1-k)'), 'Flight lens compensation preserved')
const c=new THREE.PerspectiveCamera(48,1774/1623.3,0.1,1000)
c.position.set(5.96,22.048,3.849)
c.up.set(0,0,-1)
c.lookAt(5.96,0,3.849)
c.setViewOffset(1774,1623.3,-140,-42.05,1774,1623.3)
const eye=c.getWorldDirection(new THREE.Vector3()).negate().normalize()
assert(Math.abs(eye.x)<1e-10&&Math.abs(eye.z)<1e-10&&Math.abs(eye.y-1)<1e-10,
       'Straight optical camera normal must be +Z in architectural coordinates')
const rayA=new THREE.Vector3(0,0,-1).unproject(c)
const rayB=new THREE.Vector3(0,0,1).unproject(c)
const ray=rayB.sub(rayA).normalize()
assert(Math.abs(ray.x)>1e-3||Math.abs(ray.z)>1e-3,
       'Off-axis canvas-centre ray remains different from real optical axis')
console.log('PASS 157: physically true +Z camera normal; actual downward view, lens offset, 5s flight unchanged')
STROM157_TEST

mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_157.md" <<'STROM157_DOC'
# Stromnetze 157 - Kamerasichtachse korrekt messen

- Die Kamera befindet sich ueber dem Plan (architektonisch Z=+22.048 m) und blickt physikalisch nach unten (0,0,-1).
- Auf dem Bildschirm ist die entgegengesetzte geometrische Sichtachse Z+ zur Kamera gewuenscht; sie ergibt sich aus der realen Kamera-Quaternion (kein hartkodierter Messwert).
- Der bisherige Wert (-0.077,-0.023,-0.997) ist der durch das verschobene 3D-CANVAS-Zentrum laufende Projektionsstrahl und nicht die eigentliche optische Achse. Er bleibt in den Browser-Diagnosedaten erhalten.
- Die Bildschirmanzeige verwendet jetzt die korrekt benannte optische Achse 'Blickachse zur Kamera XYZ (Plan)' (0,0,1) bei exakt senkrechter Kamera.
- Kamera, Blueprint, Lens-/Canvas-Versatz, Navigation, Kameraflug und Geometrie bleiben unveraendert.
- Nur /strom-test/ wird bereitgestellt; /strom/ bleibt unveraendert. Vor Git-Push: isolierter TypeScript-/Vite-Build und Kameratest.
STROM157_DOC

log "6) Gepruefte Quellen in Stage uebernehmen ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "157 Stage-Transfer fehlgeschlagen; Backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY - kein Web-Deployment"
  exit 0
fi
log "7) Stage bauen und ausschliesslich /strom-test/ bereitstellen ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "157 Stage-Build fehlgeschlagen; Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Frontend-Dist fehlt"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "157 Test-Deployment fehlgeschlagen; Backup: $BACKUP_DIR"
log "SUCCESS: 157 unter https://home.moja.de/strom-test/ installiert"
log "Produktion /strom/ unveraendert; Backup: $BACKUP_DIR"
