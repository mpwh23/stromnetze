#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1740_154_kamera_raster_viewport_pixelgenau"
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
COMMIT_MESSAGE="Update 154: fit top-down camera from actual Blueprint 0/0 and 1m raster axes"
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
  echo "2) Update 154 im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 154 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 154: real Blueprint 0/0 + axis basis -> exact 3D grid handoff ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/CanonicalGrid152.tsx \
  frontend/src/components/CameraFlight150.tsx \
  frontend/src/components/cameraTransitions150.ts \
  frontend/src/components/cameraViewportAlignment153.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "154 required source missing: $file"
done
grep -Fq 'STROM153_CAMERA_VIEWPORT_FIT' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "154 requires installed 153. No changes made."
grep -Fq 'STROM152_BLUEPRINT_GRID' "$STAGE_DIR/frontend/src/components/CanonicalGrid152.tsx" || \
  fail "154 requires installed canonical 3D grid 152. No changes made."
grep -Fq 'STROM150O_PRE_NAV_SNAPSHOT' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "154 requires click-time Blueprint screen matrix from 150o. No changes made."
grep -Fq 'export const ENTER_FADE150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "154 requires 5s fade. No changes made."
grep -Fq 'export const DURATION150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "154 requires 5s camera flight. No changes made."
if grep -Fq 'STROM154_GRID_PIXEL_ALIGNMENT' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"; then
  fail "154 is already installed. No changes made."
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
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "154 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "154 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/154_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch154.py" <<'STROM154_PATCH_PY'
#!/usr/bin/env python3
"""Update 154: replace building-bounds camera fit with actual Blueprint GRID match."""
from pathlib import Path
import os
root=Path(os.environ['STROM154_ROOT'])/'frontend/src'
flight=root/'components/CameraFlight150.tsx'
new=root/'components/cameraGridAlignment154.ts'
if not flight.is_file(): raise RuntimeError(f'154 missing CameraFlight150: {flight}')
if new.exists(): raise RuntimeError('154 was already applied')
s=flight.read_text('utf8')
anchor="import { alignBlueprintViewport153 } from './cameraViewportAlignment153' // STROM153_CAMERA_VIEWPORT_FIT"
if s.count(anchor)!=1: raise RuntimeError('154 requires installed update 153 camera alignment')
s=s.replace(anchor,anchor+"\nimport { alignBlueprintGrid154 } from './cameraGridAlignment154' // STROM154_GRID_PIXEL_ALIGNMENT",1)
old='''          alignBlueprintViewport153(state.scene,camera,state.gl.domElement,
            running.start,currentFrame150(),pose=>apply(camera,pose))'''
if s.count(old)!=1: raise RuntimeError(f'154 handoff anchor not unique ({s.count(old)})')
newcall='''          // STROM154_GRID_PIXEL_ALIGNMENT: direct 0/0 + 1m X/Y match from
          // the click-time SVG matrix. Do NOT align using floor bounding extents.
          alignBlueprintGrid154(state.scene,camera,state.gl.domElement,
            running.start,currentFrame150(),pose=>apply(camera,pose))'''
s=s.replace(old,newcall,1)
# Keep the 153 import despite no call, only if typecheck noUnusedLocals is disabled?
# Standard TS strict noUnusedLocals likely enabled; remove dead import.
if s.count(anchor)!=1:raise RuntimeError('154 prior fit import not unique')
s=s.replace(anchor+'\n','',1)
# Guard: do not unintentionally change known-good transition choreography.
for oldanchor in ["running.phase = 'fade'","running.kind === 'entry' && running.phase === 'fade'",'const k = easeOut(t)',"if (running.kind === 'exit')",'unlock()']:
    if oldanchor not in s:raise RuntimeError(f'154 flight choreography anchor missing: {oldanchor}')
flight.write_text(s,'utf8')
new.write_text(Path(__file__).with_name('cameraGridAlignment154.ts').read_text('utf8'),'utf8')
print('PASS 154: grid marker 0/0 and 1m axes projection fits click-time BP matrix before fade')
STROM154_PATCH_PY
cat > "$RESOURCE_DIR/cameraGridAlignment154.ts" <<'STROM154_TS'
import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'

/** STROM154_GRID_PIXEL_ALIGNMENT
 * Match the actual Blueprint coordinate grid, NOT the building/floor envelope.
 * This is a single, pre-fade camera setup; the original 5s fade, 5s flight,
 * target 3D pose, orbit handling and reverse flight are deliberately unchanged.
 *
 * Blueprint SVG screen transform captured at the click:
 * screen = [x,y] + [[ax,bx],[ay,by]] * [planX,planY].
 * The 3D grid uses the matrixWorld of the same floor reference as Grid152,
 * but lies on architectural Z=0 (Three.js world Y=0).
 */
export type Alignment154 = {
  source: string
  camera: 'perspective'|'orthographic'
  viewport: {left:number;top:number;width:number;height:number}
  blueprintZero: {x:number;y:number}
  projectedZero: {x:number;y:number}
  blueprintPixelsPerMetre: {x:number;y:number}
  threePixelsPerMetre: {x:number;y:number}
  midpointPlan: {x:number;y:number}
  heightAboveZ0Metres:number
  maxAxisDifferencePx:number
  axisDifferencePx:{zero:number;x1:number;y1:number}
}
type Pose154 = {
  position:THREE.Vector3
  rotation:THREE.Quaternion
  target:THREE.Vector3
  up:THREE.Vector3
  zoom:number
}
type Screen154 = {x:number;y:number}
const finite154=(v:number)=>Number.isFinite(v)
const length154=(p:Screen154)=>Math.hypot(p.x,p.y)
const sub154=(a:Screen154,b:Screen154)=>({x:a.x-b.x,y:a.y-b.y})
const dot154=(a:Screen154,b:Screen154)=>a.x*b.x+a.y*b.y
const difference154=(a:Screen154,b:Screen154)=>length154(sub154(a,b))

function gridMatrix154(scene:THREE.Object3D):{matrix:THREE.Matrix4;source:string}{
  // This is intentionally the SAME marker selection/matrix rule as CanonicalGrid152.
  scene.updateMatrixWorld(true)
  let marker:THREE.Object3D|null=null
  scene.traverse(obj=>{
    if(!marker&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
  })
  const matrix=marker?(marker as THREE.Object3D).matrixWorld.clone():new THREE.Matrix4()
  // CanonicalGrid152 places its grid at the architectural Z=0 datum.
  // The marker's XY plan translation/rotation is preserved, only elevation is reset.
  matrix.elements[13]=0
  return {matrix,source:marker?'actual CanonicalGrid152 floor-reference matrix':'identity (no floor reference)'}
}
function project154(p:THREE.Vector3,camera:THREE.Camera,rect:DOMRect):Screen154{
  const v=p.clone().project(camera)
  return {x:rect.left+(v.x+1)*rect.width/2,y:rect.top+(1-v.y)*rect.height/2}
}

/** Return null without blocking navigation if the original click snapshot is absent. */
export function alignBlueprintGrid154<T extends Pose154>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:T,frame:BlueprintFrame150|null,apply:(p:T)=>void,
):Alignment154|null{
  const b=frame?.screen150o
  if(!b||![b.x,b.y,b.ax,b.ay,b.bx,b.by].every(finite154)){
    console.warn('[Strom 154] Blueprint-Matrix beim Klick fehlt; 3D-Betrieb bleibt freigegeben')
    return null
  }
  const rect=canvas.getBoundingClientRect()
  if(!(rect.width>40&&rect.height>40))return null
  const determinant=b.ax*b.by-b.bx*b.ay
  const sx=Math.hypot(b.ax,b.ay),sy=Math.hypot(b.bx,b.by)
  if(!(determinant>1e-5&&sx>1&&sy>1))return null
  const saved={position:pose.position.clone(),rotation:pose.rotation.clone(),
    target:pose.target.clone(),up:pose.up.clone(),zoom:pose.zoom}
  const ortho=camera as THREE.OrthographicCamera
  const persp=camera as THREE.PerspectiveCamera
  const priorAspect=persp.isPerspectiveCamera?persp.aspect:undefined
  try{
    const reference=gridMatrix154(scene)
    const toWorld=(x:number,y:number)=>{
      const v=new THREE.Vector3(x,0,y).applyMatrix4(reference.matrix)
      // Identical to Grid152 zero plane. Architectural Z=0 is Three world Y=0.
      v.y=0
      return v
    }
    const zero=toWorld(0,0),wx=toWorld(1,0),wy=toWorld(0,1)
    const worldX=wx.clone().sub(zero),worldY=wy.clone().sub(zero)
    const wxLength=Math.hypot(worldX.x,worldX.z),wyLength=Math.hypot(worldY.x,worldY.z)
    if(!(wxLength>0.0001&&wyLength>0.0001))throw Error('Degenerate actual 3D grid transform')

    // Blueprint's zero and one-metre axis marks, in SCREEN (not world) pixels.
    const desiredZero:Screen154={x:b.x,y:b.y}
    const desiredX:Screen154={x:b.x+b.ax,y:b.y+b.ay}
    const desiredY:Screen154={x:b.x+b.bx,y:b.y+b.by}

    // The camera must be above the WORLD point represented by the centre
    // of the 3D viewport, not above the building bounds or (0,0).
    const canvasCx=rect.left+rect.width/2,canvasCy=rect.top+rect.height/2
    const dx=canvasCx-b.x,dy=canvasCy-b.y
    const planCx=( b.by*dx-b.bx*dy)/determinant
    const planCy=(-b.ay*dx+b.ax*dy)/determinant
    const worldCenter=toWorld(planCx,planCy)
    pose.target.set(worldCenter.x,0,worldCenter.z)
    pose.position.x=worldCenter.x
    pose.position.z=worldCenter.z

    // The start camera is already exactly top-down (from CameraFlight150).
    // Use its REAL projection matrix/FOV and real WebGL canvas size, never
    // the polygon bounding box. A constant m/px scale covers the full viewport.
    const worldMetresPerPlanMetre=(wxLength+wyLength)/2
    const targetPixelsPerWorldMetre=(sx/wxLength+sy/wyLength)/2
    if(persp.isPerspectiveCamera){
      const actualAspect=rect.width/rect.height
      if(Math.abs(persp.aspect-actualAspect)>0.0001){
        persp.aspect=actualAspect
        persp.updateProjectionMatrix()
      }
      const focalY=persp.projectionMatrix.elements[5]
      if(!(focalY>0&&finite154(focalY)))throw Error('Invalid 3D perspective field of view')
      // CSS pixels / world-metre at Z=0 = H*focalY/(2*cameraHeight).
      const height=rect.height*focalY/(2*targetPixelsPerWorldMetre)
      if(!(height>0.05&&height<1e6&&finite154(height)))throw Error('Invalid camera altitude from FOV')
      pose.position.y=height
    }else if(ortho.isOrthographicCamera){
      const verticalSize=Math.abs(ortho.top-ortho.bottom)
      if(!(verticalSize>0))throw Error('Invalid 3D orthographic frustum')
      pose.zoom=targetPixelsPerWorldMetre*verticalSize/rect.height
      pose.position.y=Math.max(10,Math.abs(saved.position.y),worldMetresPerPlanMetre*2)
    }else throw Error('Unsupported 3D camera projection')
    apply(pose)

    // Pixel-exact final correction using the LIVE Three.js projection,
    // including camera zoom, canvas position and projection matrix offsets.
    // 3D X and Y basis must coincide with the Blueprint 1-metre basis.
    for(let iteration=0;iteration<4;iteration++){
      const p0=project154(zero,camera,rect)
      const px=project154(wx,camera,rect)
      const py=project154(wy,camera,rect)
      const basisX=sub154(px,p0),basisY=sub154(py,p0)
      const bpX=sub154(desiredX,desiredZero),bpY=sub154(desiredY,desiredZero)
      // Least-squares uniform scale, shared by X and Y: never distort the house.
      const denominator=dot154(basisX,basisX)+dot154(basisY,basisY)
      const ratio=(dot154(bpX,basisX)+dot154(bpY,basisY))/denominator
      if(!(denominator>1e-10&&ratio>0.05&&ratio<20&&finite154(ratio)))
        throw Error('3D coordinate axes cannot be matched with this camera orientation')
      if(Math.abs(ratio-1)>0.00001){
        if(persp.isPerspectiveCamera)pose.position.y/=ratio
        else pose.zoom*=ratio
        apply(pose)
      }
      const s0=project154(zero,camera,rect)
      const sx1=project154(wx,camera,rect),sy1=project154(wy,camera,rect)
      const ax=sx1.x-s0.x,bx=sy1.x-s0.x,ay=sx1.y-s0.y,by=sy1.y-s0.y
      const det=ax*by-bx*ay
      if(!finite154(det)||Math.abs(det)<1e-9)throw Error('3D grid Jacobian not invertible')
      const errorX=desiredZero.x-s0.x,errorY=desiredZero.y-s0.y
      const panPlanX=(by*errorX-bx*errorY)/det
      const panPlanY=(-ay*errorX+ax*errorY)/det
      const panWorld=worldX.clone().multiplyScalar(panPlanX)
        .add(worldY.clone().multiplyScalar(panPlanY))
      pose.position.sub(panWorld)
      pose.target.sub(panWorld)
      apply(pose)
      if(Math.hypot(errorX,errorY)<0.01&&Math.abs(ratio-1)<0.00001)break
    }
    const p0=project154(zero,camera,rect),px=project154(wx,camera,rect),py=project154(wy,camera,rect)
    const err0=difference154(p0,desiredZero),errX=difference154(px,desiredX),errY=difference154(py,desiredY)
    const maxError=Math.max(err0,errX,errY)
    if(!finite154(maxError)||maxError>8){
      throw Error(`3D grid does not match Blueprint (max error ${maxError.toFixed(2)} px)`)
    }
    const result:Alignment154={
      source:reference.source,
      camera:persp.isPerspectiveCamera?'perspective':'orthographic',
      viewport:{left:rect.left,top:rect.top,width:rect.width,height:rect.height},
      blueprintZero:desiredZero,projectedZero:p0,
      blueprintPixelsPerMetre:{x:sx,y:sy},
      threePixelsPerMetre:{x:difference154(px,p0),y:difference154(py,p0)},
      midpointPlan:{x:planCx,y:planCy},
      heightAboveZ0Metres:pose.position.y,
      maxAxisDifferencePx:maxError,
      axisDifferencePx:{zero:err0,x1:errX,y1:errY},
    }
    try{window.localStorage.setItem('strom.camera154.gridAlignment',JSON.stringify(result))}catch{/* optional */}
    console.info('[Strom 154] Blueprint- und 3D-Raster exakt auf X=0/Y=0 und 1-m-Achsen ausgerichtet',result)
    return result
  }catch(error){
    pose.position.copy(saved.position)
    pose.rotation.copy(saved.rotation)
    pose.target.copy(saved.target)
    pose.up.copy(saved.up)
    pose.zoom=saved.zoom
    if(persp.isPerspectiveCamera&&priorAspect!==undefined&&persp.aspect!==priorAspect){
      persp.aspect=priorAspect;persp.updateProjectionMatrix()
    }
    apply(pose)
    console.warn('[Strom 154] Rasterkalibrierung übersprungen, vorhandene Startansicht beibehalten',error)
    return null
  }
}
STROM154_TS
cat > "$RESOURCE_DIR/test154.cjs" <<'STROM154_TEST'
'use strict'
const fs=require('fs'),assert=require('assert'),ts=require(process.env.STROM154_TYPESCRIPT||'/opt/nvm/versions/node/v22.16.0/lib/node_modules/typescript')
const path=require('path')
const root=process.env.STROM154_SOURCE||'/tmp/fixture154/frontend/src'
for(const rel of ['components/CameraFlight150.tsx','components/CanonicalGrid152.tsx','components/cameraGridAlignment154.ts']){
 const name=path.join(root,rel),source=fs.readFileSync(name,'utf8')
 const ast=ts.createSourceFile(name,source,ts.ScriptTarget.Latest,true,name.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 assert.equal(ast.parseDiagnostics.length,0,rel+': '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const grid=fs.readFileSync(path.join(root,'components/CanonicalGrid152.tsx'),'utf8')
const align=fs.readFileSync(path.join(root,'components/cameraGridAlignment154.ts'),'utf8')
assert(flight.includes('STROM154_GRID_PIXEL_ALIGNMENT')&&flight.includes('alignBlueprintGrid154(state.scene'))
assert(!flight.includes('alignBlueprintViewport153(state.scene'))
assert(flight.indexOf('alignBlueprintGrid154(state.scene')<flight.indexOf("running.phase = 'fade'",flight.indexOf('alignBlueprintGrid154(state.scene')))
assert(flight.includes('const k = easeOut(t)')&&flight.includes('unlock()'))
assert(grid.includes('group.current.matrix.elements[13]=0')&&align.includes('matrix.elements[13]=0'))
assert(align.includes('desiredZero')&&align.includes('desiredX')&&align.includes('desiredY'))
assert(align.includes('persp.projectionMatrix.elements[5]'))

class V{
 constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}
 clone(){return new V(this.x,this.y,this.z)}
 copy(v){this.x=v.x;this.y=v.y;this.z=v.z;return this}
 set(x,y,z){this.x=x;this.y=y;this.z=z;return this}
 sub(v){this.x-=v.x;this.y-=v.y;this.z-=v.z;return this}
 add(v){this.x+=v.x;this.y+=v.y;this.z+=v.z;return this}
 multiplyScalar(s){this.x*=s;this.y*=s;this.z*=s;return this}
 applyMatrix4(m){const x=this.x,y=this.y,z=this.z,e=m.elements
   this.x=e[0]*x+e[4]*y+e[8]*z+e[12]
   this.y=e[1]*x+e[5]*y+e[9]*z+e[13]
   this.z=e[2]*x+e[6]*y+e[10]*z+e[14];return this}
 project(cam){const h=cam.isPerspectiveCamera?cam.position.y-this.y:1,p=cam.projectionMatrix.elements
   return new V((this.x-cam.position.x)*p[0]/h,-(this.z-cam.position.z)*p[5]/h,0)}
}
class Q {clone(){return new Q()}copy(){return this}}
class M{constructor(){this.elements=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}clone(){const m=new M();m.elements=[...this.elements];return m}}
const source=ts.transpileModule(align,{fileName:'cameraGridAlignment154.ts',compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText
const bridgeExports={}
const saved=new Map()
const logger={info(){},warn(msg,...arg){throw Error(msg+' '+arg)}}
new Function('require','module','exports','window','console',source)(name=>{
 if(name==='three')return {Matrix4:M,Vector3:V}
 throw Error('unexpected runtime import: '+name)
},{exports:bridgeExports},bridgeExports,{localStorage:{setItem(k,v){saved.set(k,v)}}},logger)
const fit=bridgeExports.alignBlueprintGrid154
function run(title,{rect={left:220,top:90,width:1000,height:760},px=58,bpX=520,bpY=360,
   scale=1,tx=0,tz=0,floorY=0,kind='perspective',fov=50,priorAspect=3}={}){
 const matrix=new M();matrix.elements[0]=scale;matrix.elements[10]=scale
 matrix.elements[12]=tx;matrix.elements[13]=floorY;matrix.elements[14]=tz
 const marker={name:'strom150r-floor-reference',userData:{active150r:true},matrixWorld:matrix}
 const scene={updateMatrixWorld(){},traverse(fn){fn(marker)}}
 const cam={isPerspectiveCamera:kind==='perspective',isOrthographicCamera:kind==='orthographic',
 position:new V(400,80,200),aspect:priorAspect,fov,zoom:1,top:10,bottom:-10,
 projectionMatrix:{elements:new Array(16).fill(0)},updateProjectionMatrix(){
   this.projectionMatrix.elements[5]=this.isPerspectiveCamera?this.zoom/Math.tan(this.fov*Math.PI/360):this.zoom/10
   this.projectionMatrix.elements[0]=this.isPerspectiveCamera?this.projectionMatrix.elements[5]/this.aspect:this.zoom/10*(rect.height/rect.width)
 }}
 cam.updateProjectionMatrix()
 const pose={position:cam.position.clone(),rotation:new Q(),target:new V(0,0,0),up:new V(0,0,-1),zoom:1}
 const b={x:bpX,y:bpY,ax:px,ay:0,bx:0,by:px}
 const frame={floorId:'test',screen150o:b}
 const apply=p=>{cam.position.copy(p.position);cam.zoom=p.zoom;cam.updateProjectionMatrix()}
 const result=fit(scene,cam,{getBoundingClientRect(){return rect}},pose,frame,apply)
 assert(result,title+': failed')
 assert(result.maxAxisDifferencePx<0.001,title+': pixel error = '+result.maxAxisDifferencePx)
 assert.equal(result.midpointPlan.x,(rect.left+rect.width/2-bpX)/px)
 assert.equal(result.midpointPlan.y,(rect.top+rect.height/2-bpY)/px)
 assert(Math.abs(result.threePixelsPerMetre.x-px)<0.001)
 assert(Math.abs(result.threePixelsPerMetre.y-px)<0.001)
 assert(Math.abs(cam.position.y-(kind==='perspective'?rect.height/(2*Math.tan(fov*Math.PI/360)*(px/scale)):cam.position.y))<0.001)
 if(kind==='perspective')assert(Math.abs(cam.aspect-rect.width/rect.height)<0.0001)
 assert(saved.has('strom.camera154.gridAlignment'))
 console.log(title,'PASS; error=',result.maxAxisDifferencePx.toFixed(6),'height=',cam.position.y.toFixed(4))
}
run('Viewport 1000x760, different camera aspect',{rect:{left:220,top:90,width:1000,height:760},bpX:455,bpY:260})
run('Viewport offset, plan origin outside viewport',{rect:{left:120,top:80,width:1100,height:800},bpX:-260,bpY:-160,px:45,tx:15,tz:-6})
run('Selected floor is 5m above Z0; grid stays Z0',{floorY:5,px:33,tx:-52,tz:40,scale:1.3})
run('Camera FOV 35, far pan and zoom',{fov:35,px:105,tx:125,tz:-91,bpX:1000,bpY:950})
// Orthographic camera expected to have matching left/right frustum geometry
run('Orthographic camera',{kind:'orthographic',px:70,tx:20,tz:-2,scale:1.1})
console.log('PASS 154: BP grid 0/0 + both one-metre axes align at handoff in five cases, original flight preserved')
STROM154_TEST
log "3) Install exact Blueprint grid camera mapping in isolated tree ..."
python3 -m py_compile "$RESOURCE_DIR/patch154.py" >>"$DIAG_LOG" 2>&1 || fail "154 Python syntax failed"
STROM154_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch154.py" >>"$DIAG_LOG" 2>&1 || \
  fail "154 source patch failed; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build in isolated tree ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "154 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Camera projection regression, preserved animation check ..."
STROM154_SOURCE="$WORK_DIR/frontend/src" STROM154_TYPESCRIPT="$DEPENDENCIES/typescript" \
  node "$RESOURCE_DIR/test154.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "154 viewport/raster regression failed; GitHub and Stage unchanged"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_154.md" <<'STROM154_DOC'
# Stromnetze 154 - pixel-aligned Blueprint and Three.js axes at camera handoff

- The 153 camera fit wrongly used selected floor *geometry bounds* as reference. The
  154 fit instead uses the click-time full Blueprint affine XY -> CSS-screen mapping.
- Fit the 3D canonical grid origin and 1m X/Y steps to the Blueprint raster, using
  the EXACT marker matrix that CanonicalGrid152 uses to position its grid.
- Project a true top-down camera above the corresponding Blueprint viewport centre.
  Compute its height from vertical FOV, viewport size and Blueprint px per metre.
  Refine with the live 3D projection, using a single scale and a Jacobian pan.
- Support architectural Z0 separately from arbitrary current floor elevations.
  Grid plane lies at world Y=0 (architectural Z=0); do not assume the floor is y=0.
- Keep the red, green and blue axes and one-pixel grid styling from 153 unchanged.
- No modifications to 5s fade, 5s flight, existing easing, settled final camera,
  nor reverse-flight implementation; only the entry start pose is changed.
- On unable-to-align, keep previous camera and never block navigation.
- Read diagnostics in browser console [Strom 154], storage
  strom.camera154.gridAlignment (origin and 1m basis errors in CSS pixels).
- Isolated frontend TypeScript/Vite build + 5 numerical viewport cases before push;
  deploy exclusively /strom-test/, production /strom/ untouched.
STROM154_DOC
log "6) Transfer checked source to Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "154 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY; no web deployment"
  exit 0
fi
log "7) Build Stage and deploy exclusively /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "154 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "154 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "154 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 154 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
