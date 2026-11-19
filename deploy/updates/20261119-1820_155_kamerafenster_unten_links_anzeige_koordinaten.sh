#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1820_155_kamerafenster_unten_links_anzeige_koordinaten"
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
COMMIT_MESSAGE="Update 155: read-only Blueprint viewport and live 3D camera diagnostics during fade"
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
  echo "2) Update 155 im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 155 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 155: Blueprint visible viewport + active 3D camera at fade start ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/CameraFlight150.tsx \
  frontend/src/components/cameraTransitions150.ts \
  frontend/src/components/cameraGridAlignment154.ts \
  frontend/src/components/threeFloorExtrema150q.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "155 required source missing: $file"
done
grep -Fq 'STROM150P_BLUEPRINT_EXTENTS' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "155 requires installed Blueprint viewport diagnostics 150p. No changes made."
grep -Fq 'STROM150Q_3D_FLOOR_EXTENTS' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "155 requires installed 3D floor diagnostics 150q. No changes made."
grep -Fq 'STROM154_GRID_PIXEL_ALIGNMENT' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "155 requires installed camera calibration 154. No changes made."
grep -Fq 'export const ENTER_FADE150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "155 requires existing 5s fade. No changes made."
grep -Fq 'export const DURATION150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "155 requires existing 5s flight. No changes made."
if grep -Fq 'STROM155_CAMERA_VIEWPORT_DIAGNOSTICS' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"; then
  fail "155 already installed. No changes made."
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
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "155 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "155 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/155_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch155.py" <<'STROM155_PATCH_PY'
#!/usr/bin/env python3
"""Update 155: viewport + live camera diagnostics at fade, layout only."""
import os
from pathlib import Path
root=Path(os.environ['STROM155_ROOT'])/'frontend/src'
bridge=root/'components/cameraTransitions150.ts'
flight=root/'components/CameraFlight150.tsx'
new=root/'components/cameraHandoffDiagnostics155.ts'
for f in (bridge,flight):
    if not f.is_file():raise RuntimeError(f'155 required source missing: {f}')
if new.exists():raise RuntimeError('Update 155 already installed')
b=bridge.read_text('utf8');f=flight.read_text('utf8')
for marker in ('STROM150P_BLUEPRINT_EXTENTS','STROM150O_PRE_NAV_SNAPSHOT'):
    if marker not in b:raise RuntimeError(f'155 Blueprint diagnostic prerequisite missing: {marker}')
for marker in ('STROM150Q_3D_FLOOR_EXTENTS','STROM154_GRID_PIXEL_ALIGNMENT'):
    if marker not in f:raise RuntimeError(f'155 live-camera prerequisite missing: {marker}')
if 'STROM155_CAMERA_VIEWPORT_DIAGNOSTICS' in f:
    raise RuntimeError('Update 155 already applied; no duplicate')
old="panel.style.cssText='position:fixed;top:16px;right:16px;z-index:2147483647;pointer-events:none;'"
replacement="panel.style.cssText='position:fixed;bottom:16px;left:16px;top:auto;right:auto;z-index:2147483647;pointer-events:none;'"
if b.count(old)!=1:raise RuntimeError(f'155 Blueprint panel position anchor count: {b.count(old)}')
b=b.replace(old,replacement,1)
# Preserve all current screen measurement values; merely move the panel.
old="      +'max-width:430px;white-space:pre-wrap;'"
replacement="      +'max-width:min(480px, calc(100vw - 32px));max-height:calc(100vh - 32px);overflow-y:auto;white-space:pre-wrap;'"
if b.count(old)!=1:raise RuntimeError(f'155 panel overflow anchor count: {b.count(old)}')
b=b.replace(old,replacement,1)
importline="import type { BlueprintFrame150, Enter150 } from './cameraTransitions150'"
if f.count(importline)!=1:raise RuntimeError('155 flight import anchor missing/nonunique')
f=f.replace(importline,importline+"\nimport { captureCameraHandoff155 } from './cameraHandoffDiagnostics155' // STROM155_CAMERA_VIEWPORT_DIAGNOSTICS",1)
needle='        notifyEnterReady150()'
if f.count(needle)!=1:raise RuntimeError(f'155 camera fade-start call anchor count: {f.count(needle)}')
f=f.replace(needle,'''
        // STROM155_CAMERA_VIEWPORT_DIAGNOSTICS: last fitted, LIVE R3F camera.
        // Read-only: does not change the start pose, controls, FOV or animation.
        try {
          captureCameraHandoff155(state.camera,state.gl.domElement,currentFrame150())
        } catch (error) {console.warn('[STROM 155] Kameradiagnose fehlgeschlagen',error)}
        notifyEnterReady150()'''.lstrip('\n'),1)
new.write_text(Path(__file__).with_name('cameraHandoffDiagnostics155.ts').read_text('utf8'),'utf8')
bridge.write_text(b,'utf8')
flight.write_text(f,'utf8')
print('PASS 155: Blueprint diagnosis bottom-left; live camera sample at fade start; choreography unchanged')
STROM155_PATCH_PY
cat > "$RESOURCE_DIR/cameraHandoffDiagnostics155.ts" <<'STROM155_TS'
import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'

/** STROM155_CAMERA_VIEWPORT_DIAGNOSTICS
 * Read-only measurement from the real, active R3F camera at the start of
 * the Blueprint -> 3D fade. Never changes a camera pose, controls, zoom or FOV.
 * Three.js axes are X horizontal, Y height, Z second plan axis;
 * architectural/Blueprint axes are X,Y in the horizontal plan.
 */
type Screen150o155 = {x:number;y:number;ax:number;ay:number;bx:number;by:number}
type Point155 = {x:number;y:number}
type BlueprintStored155 = {
  viewport?:{screenLeft:number;screenTop:number;width:number;height:number}
  drawing?:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}|null
}
type Rect155 = {left:number;top:number;width:number;height:number}

function valid155(v:number):boolean {return Number.isFinite(v)}
function round155(n:number,places=3):number {return Number(n.toFixed(places))}
function rect155(v:Rect155):Rect155 {return {left:v.left,top:v.top,width:v.width,height:v.height}}
function plan155(s:Screen150o155,screenX:number,screenY:number):Point155|null {
  const det=s.ax*s.by-s.ay*s.bx
  if(!valid155(det)||Math.abs(det)<1e-9)return null
  const dx=screenX-s.x,dy=screenY-s.y
  return {x:(s.by*dx-s.bx*dy)/det,y:(-s.ay*dx+s.ax*dy)/det}
}
function finiteRect155(v:Rect155|null|undefined):v is Rect155 {
  return !!v&&[v.left,v.top,v.width,v.height].every(valid155)&&v.width>1&&v.height>1
}
function coords155(v:THREE.Vector3):{x:number;y:number;z:number}{
  return {x:round155(v.x),y:round155(v.y),z:round155(v.z)}
}
function txt155(v:number|undefined,unit=''):string {return v===undefined?'nicht verfügbar':`${v.toFixed(2)}${unit}`}

export function captureCameraHandoff155(
  camera:THREE.Camera,canvas:HTMLCanvasElement,frame:BlueprintFrame150|null,
):void {
  let stored:BlueprintStored155|null=null
  try {
    const raw=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(raw)stored=JSON.parse(raw) as BlueprintStored155
  }catch{/* The diagnostic must never block navigation. */}
  const view0=stored?.viewport
  const view= view0 ? {left:view0.screenLeft,top:view0.screenTop,width:view0.width,height:view0.height} : null
  const canvasRect=rect155(canvas.getBoundingClientRect())
  const saved=frame?.screen150o
  const vp=finiteRect155(view)?view:null

  let blueprint:null|{
    screen:{xMin:number;xMax:number;yMin:number;yMax:number;centerX:number;centerY:number}
    visiblePlan:{xMin:number;xMax:number;yMin:number;yMax:number;centerX:number;centerY:number}
    drawingPx:BlueprintStored155['drawing']
  }=null
  if(vp&&saved){
    // Capture the FOUR original visible viewport corners, using the pre-navigation
    // SVG screen transform; do not use rendered-house polygon bounds as viewport limits.
    const corners=[
      plan155(saved,vp.left,vp.top),plan155(saved,vp.left+vp.width,vp.top),
      plan155(saved,vp.left,vp.top+vp.height),
      plan155(saved,vp.left+vp.width,vp.top+vp.height),
    ]
    const center=plan155(saved,vp.left+vp.width/2,vp.top+vp.height/2)
    if(center&&corners.every((v):v is Point155=>v!==null)){
      const points=corners as Point155[]
      blueprint={
        screen:{xMin:round155(vp.left,1),xMax:round155(vp.left+vp.width,1),
          yMin:round155(vp.top,1),yMax:round155(vp.top+vp.height,1),
          centerX:round155(vp.left+vp.width/2,1),centerY:round155(vp.top+vp.height/2,1)},
        visiblePlan:{xMin:round155(Math.min(...points.map(v=>v.x))),
          xMax:round155(Math.max(...points.map(v=>v.x))),
          yMin:round155(Math.min(...points.map(v=>v.y))),
          yMax:round155(Math.max(...points.map(v=>v.y))),
          centerX:round155(center.x),centerY:round155(center.y)},
        drawingPx:stored?.drawing,
      }
    }
  }

  // Read the live world-space camera, not its React props or captured flight target.
  camera.updateMatrixWorld(true)
  const worldPosition=camera.getWorldPosition(new THREE.Vector3())
  const worldRotation=camera.getWorldQuaternion(new THREE.Quaternion())
  const angles=new THREE.Euler().setFromQuaternion(worldRotation,'XYZ')
  // The ray through NDC (0,0) is the ACTUAL pixel-centre ray, even if
  // projectionMatrix has a film/lens shift; no camera controls are consulted.
  const near=new THREE.Vector3(0,0,-1).unproject(camera)
  const far=new THREE.Vector3(0,0,1).unproject(camera)
  const direction=far.clone().sub(near).normalize()
  const perspective=(camera as THREE.PerspectiveCamera).isPerspectiveCamera===true
  const origin=perspective?worldPosition:near
  const t=Math.abs(direction.y)>1e-9?(0-origin.y)/direction.y:NaN
  const hit=valid155(t)&&t>=0 ? origin.clone().addScaledVector(direction,t) : null
  const projection=(camera as THREE.PerspectiveCamera).projectionMatrix.elements
  const fovVertical=perspective&&projection&&Math.abs(projection[5])>1e-9
    ?THREE.MathUtils.radToDeg(2*Math.atan(1/Math.abs(projection[5]))):undefined
  const fovHorizontal=perspective&&projection&&Math.abs(projection[0])>1e-9
    ?THREE.MathUtils.radToDeg(2*Math.atan(1/Math.abs(projection[0]))):undefined
  const ortho=camera as THREE.OrthographicCamera
  const orthographicView=!perspective&&ortho.isOrthographicCamera?{
    widthM:round155((ortho.right-ortho.left)/ortho.zoom),
    heightM:round155((ortho.top-ortho.bottom)/ortho.zoom),
  }:null
  const rad=THREE.MathUtils.radToDeg
  const result={
    version:'155',phase:'3D-Kamera nach Ausrichtung, direkt vor der Blende',
    measuredAt:new Date().toISOString(),
    blueprintViewport:vp?rect155(vp):null,
    threeCanvasViewport:canvasRect,
    viewportOffsetPx:vp?{
      left:round155(canvasRect.left-vp.left,1),top:round155(canvasRect.top-vp.top,1),
      width:round155(canvasRect.width-vp.width,1),height:round155(canvasRect.height-vp.height,1),
    }:null,
    blueprint,
    camera:{
      axes:'Three.js world: X horizontal, Y elevation, Z horizontal (Blueprint Y)',
      type:perspective?'PerspectiveCamera':ortho.isOrthographicCamera?'OrthographicCamera':'Camera',
      position:coords155(worldPosition),
      direction:coords155(direction),
      viewportCenterOnZ0:hit?coords155(hit):null,
      rotationXYZDegrees:{x:round155(rad(angles.x),2),y:round155(rad(angles.y),2),z:round155(rad(angles.z),2)},
      fovVerticalDegrees:fovVertical===undefined?null:round155(fovVertical,2),
      fovHorizontalDegrees:fovHorizontal===undefined?null:round155(fovHorizontal,2),
      orthoView:orthographicView,
    },
  }
  try{window.localStorage.setItem('strom.camera155.handoff',JSON.stringify(result))}catch{/* optional */}
  console.info('[STROM 155] Blueprint-Viewport und reale 3D-Kamera beim Blendenstart',result)

  const panel=document.getElementById('strom-150p-viewport-geometry')
  if(!panel)return
  // Also set position at measurement time for already-mounted Blueprint panels.
  Object.assign(panel.style,{
    position:'fixed',left:'16px',bottom:'16px',top:'auto',right:'auto',
    maxHeight:'calc(100vh - 32px)',maxWidth:'min(480px, calc(100vw - 32px))',
    overflowY:'auto',zIndex:'2147483647',
  })
  let section=document.getElementById('strom-155-camera-values')
  if(!section){
    section=document.createElement('span')
    section.id='strom-155-camera-values'
    section.style.cssText='display:block;margin-top:9px;padding-top:8px;'
      +'border-top:1px solid rgba(255,255,255,.3);color:#ffd18b;font-weight:500;'
    panel.appendChild(section)
  }
  const bp=blueprint?.visiblePlan
  const p=result.camera.position,d=result.camera.direction,r=result.camera.rotationXYZDegrees
  const gaze=result.camera.viewportCenterOnZ0
  section.textContent=
    `SICHTBARER BLUEPRINT-VIEWPORT (Plan, m)\n`
    +(bp?`Xmin: ${bp.xMin}  | Xmax: ${bp.xMax}\n`
        +`Ymin: ${bp.yMin}  | Ymax: ${bp.yMax}\n`
        +`Mitte: X ${bp.centerX} / Y ${bp.centerY} m\n`
      :'Nicht messbar: Blueprint-Transform/Viewport fehlt\n')
    +(blueprint?`Pixel-Bereich: X ${blueprint.screen.xMin}..${blueprint.screen.xMax}`
       +` / Y ${blueprint.screen.yMin}..${blueprint.screen.yMax}\n`
       +`Pixel-Mitte: ${blueprint.screen.centerX} / ${blueprint.screen.centerY}\n`:'')
    +`3D-KAMERA (Three.js X/Y/Z, m)\n`
    +`Position: X ${p.x} / Y ${p.y} / Z ${p.z}\n`
    +`Blickrichtung: (${d.x}, ${d.y}, ${d.z})\n`
    +(gaze?`Viewport-Mitte auf Hoehe 0: X ${gaze.x} / Y ${gaze.y} / Z ${gaze.z}\n`
      :'Viewport-Mitte auf Hoehe 0: kein Strahlschnitt\n')
    +`Rotation XYZ: ${r.x}° / ${r.y}° / ${r.z}°\n`
    +(perspective?`Blickwinkel: vert. ${txt155(fovVertical,'°')} / horiz. ${txt155(fovHorizontal,'°')}\n`
      :orthographicView?`Orthografisch (kein FOV): ${orthographicView.widthM} × ${orthographicView.heightM} m\n`
        :'Blickwinkel: Kameratyp unbekannt\n')
    +(result.viewportOffsetPx?
       `Canvas minus BP: Links ${result.viewportOffsetPx.left}px, Oben ${result.viewportOffsetPx.top}px\n`
         +`Breite Δ${result.viewportOffsetPx.width}px / Hoehe Δ${result.viewportOffsetPx.height}px\n`:'')
    +'Details: Browser-Konsole [STROM 155]'
}
STROM155_TS
cat > "$RESOURCE_DIR/test155.cjs" <<'STROM155_TEST'
'use strict'
const fs=require('fs'),assert=require('assert'),ts=require(process.env.STROM155_TS),THREE=require(process.env.STROM155_THREE)
const path=require('path'),src=process.env.STROM155_SOURCE
const flight=fs.readFileSync(path.join(src,'components/CameraFlight150.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(src,'components/cameraTransitions150.ts'),'utf8')
const moduleText=fs.readFileSync(path.join(src,'components/cameraHandoffDiagnostics155.ts'),'utf8')
for(const [name,code,kind] of [
  ['flight',flight,ts.ScriptKind.TSX],['bridge',bridge,ts.ScriptKind.TS],['155',moduleText,ts.ScriptKind.TS],
]) {
 const ast=ts.createSourceFile(name,code,ts.ScriptTarget.Latest,true,kind)
 assert.equal(ast.parseDiagnostics.length,0,name+': TS parse '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
assert(flight.includes('STROM154_GRID_PIXEL_ALIGNMENT'))
assert(flight.includes('STROM155_CAMERA_VIEWPORT_DIAGNOSTICS'))
assert(flight.includes('STROM150Q_3D_FLOOR_EXTENTS'))
assert(flight.indexOf('captureCameraHandoff155(')>flight.indexOf('alignBlueprintGrid154('))
assert(flight.indexOf('captureCameraHandoff155(')<flight.indexOf('notifyEnterReady150()'))
assert(flight.includes("running.phase = 'fade'")&&flight.includes("if (running.kind === 'exit')"))
assert(bridge.includes("position:fixed;bottom:16px;left:16px;top:auto;right:auto;"))
assert(!bridge.includes("position:fixed;top:16px;right:16px;z-index:2147483647"))
assert(moduleText.includes('new THREE.Vector3(0,0,-1).unproject(camera)'))
assert(moduleText.includes("'strom.camera155.handoff'"))
// Real Three.js test: visible viewport inverse affine mapping, camera world pose,
// NDC centre ray to architectural Z=0 plane, actual projected FOV and DOM panel.
const mod={exports:{}}
const transpiled=ts.transpileModule(moduleText,{fileName:'cameraHandoffDiagnostics155.ts',compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText
const saved=new Map()
const dom=new Map()
const panel={id:'strom-150p-viewport-geometry',style:{},children:[],appendChild(child){this.children.push(child);dom.set(child.id,child)}}
dom.set(panel.id,panel)
const document={getElementById(id){return dom.get(id)||null},createElement(){return {style:{cssText:''},textContent:'',id:''}}}
const window={localStorage:{getItem(k){return saved.get(k)||null},setItem(k,v){saved.set(k,v)}}}
const logger={info(){},warn(...a){throw Error(a.join(' '))}}
new Function('require','module','exports','window','document','console',transpiled)(name=>{
 if(name==='three')return THREE
 throw Error('unexpected require '+name)
},mod,mod.exports,window,document,logger)
const capture=mod.exports.captureCameraHandoff155
saved.set('strom.camera150p.blueprintExtents',JSON.stringify({
 viewport:{screenLeft:500,screenTop:250,width:1000,height:800},
 drawing:{xMinPx:100,xMaxPx:800,yMinPx:90,yMaxPx:600},
}))
const frame={floorId:'f',screen150o:{x:400,y:200,ax:50,ay:0,bx:0,by:50}}
const camera=new THREE.PerspectiveCamera(60,1.5,.1,1000)
camera.position.set(4,20,7)
camera.up.set(0,0,-1)
camera.lookAt(4,0,7)
camera.updateMatrixWorld(true)
const beforeP=camera.position.clone(),beforeQ=camera.quaternion.clone()
const canvas={getBoundingClientRect(){return {left:520,top:260,width:980,height:780}}}
capture(camera,canvas,frame)
const r=JSON.parse(saved.get('strom.camera155.handoff'))
assert.equal(r.blueprint.visiblePlan.xMin,2)
assert.equal(r.blueprint.visiblePlan.xMax,22)
assert.equal(r.blueprint.visiblePlan.yMin,1)
assert.equal(r.blueprint.visiblePlan.yMax,17)
assert.equal(r.blueprint.visiblePlan.centerX,12)
assert.equal(r.blueprint.visiblePlan.centerY,9)
assert.equal(r.blueprint.screen.centerX,1000)
assert.equal(r.blueprint.screen.centerY,650)
assert.equal(r.camera.position.x,4)
assert.equal(r.camera.position.y,20)
assert.equal(r.camera.position.z,7)
assert(Math.abs(r.camera.viewportCenterOnZ0.x-4)<1e-6)
assert(Math.abs(r.camera.viewportCenterOnZ0.y)<1e-6)
assert(Math.abs(r.camera.viewportCenterOnZ0.z-7)<1e-6)
assert(Math.abs(r.camera.fovVerticalDegrees-60)<.01)
assert.equal(r.viewportOffsetPx.left,20)
assert.equal(r.viewportOffsetPx.top,10)
assert(camera.position.equals(beforeP)&&camera.quaternion.equals(beforeQ),'Camera must remain unchanged')
assert.equal(panel.style.bottom,'16px')
assert.equal(panel.style.left,'16px')
assert(panel.children[0].textContent.includes('Rotation XYZ:'))
assert(panel.children[0].textContent.includes('Blickwinkel:'))
console.log('PASS 155: visible Blueprint limits/centre and live camera position, ray intersection, rotations, FOV, no camera mutation')
STROM155_TEST
log "3) Install read-only 155 diagnostic UI in isolated tree ..."
python3 -m py_compile "$RESOURCE_DIR/patch155.py" >>"$DIAG_LOG" 2>&1 || fail "155 Python syntax failed"
STROM155_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch155.py" >>"$DIAG_LOG" 2>&1 || \
  fail "155 source patch failed; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build in isolated tree ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "155 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Verify camera/viewport measurements without changing camera ..."
STROM155_SOURCE="$WORK_DIR/frontend/src" STROM155_TS="$DEPENDENCIES/typescript" STROM155_THREE="$DEPENDENCIES/three" \
  node "$RESOURCE_DIR/test155.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "155 camera diagnostic regression failed; GitHub and Stage unchanged"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_155.md" <<'STROM155_DOC'
# Stromnetze 155 - real Blueprint viewport + live 3D camera measurements

- Blueprint diagnostic panel remains the same and is now fixed bottom-left.
- At the instant the final starting camera pose is applied, **before releasing the fade**,
  measure the ACTUAL Canvas/R3F camera in world coordinates, not requested props.
- Show actual visible Blueprint viewport min/max and midpoint in architecture metres:
  inverse of the **click-time** saved SVG affine mapping on the four viewport corners.
- Show Blueprint viewport global screen pixel limits and screen centre.
- Show real 3D world camera position X/Y/Z (Three.js Y is height), precise
  centre-of-projection ray through NDC(0,0), ray intersection with elevation 0,
  Euler XYZ angles in degrees, and actual horizontal/vertical perspective FOV.
- Show differences of 3D canvas and Blueprint viewport screen rectangles, to detect
  CSS viewport offsets. Preserve existing Blueprint drawing and cyan floor values.
- Inspect full values at localStorage `strom.camera155.handoff` and console [STROM 155].
- No adjustments to grid, start pose, controls, 5-second fade/flight or return flight.
- Stage backup + isolated TypeScript/Vite build + real Three.js projection tests;
  deploy only /strom-test/ (production /strom/ unchanged).
STROM155_DOC
log "6) Transfer checked source to Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "155 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY; no web deployment"
  exit 0
fi
log "7) Build Stage and deploy exclusively /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "155 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "155 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "155 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 155 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
