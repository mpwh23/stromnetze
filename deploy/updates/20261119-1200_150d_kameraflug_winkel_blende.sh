#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1200_150d_kameraflug_winkel_blende"
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
COMMIT_MESSAGE="Update 150d: preserve real camera quaternion, 500ms fade and 1500ms flight"
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
  echo "2) Update 150d im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150d isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150d: 500ms Blueprint fade, 1500ms stable camera flights ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
grep -Fq 'STROM150_CAMERA_BRIDGE' "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 150 prerequisite not found"
grep -Fq 'STROM150_CAMERA' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "Update 150 3D prerequisite missing"
grep -Fq 'STROM150C_PRESERVE_BLUEPRINT' "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 150c prerequisite not found"
select_node
log "1) Backup current Stage source ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no live source backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
fi
log "2) Prepare fully isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Unable to copy Stage source"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "Missing existing TypeScript/Vite/Three dependencies"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/150d_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150d.py" <<'STROM150D_PY'
#!/usr/bin/env python3
"""Incremental 150d: keep 150c's loading indicator and actual mounted Blueprint, update fade."""
from pathlib import Path
import os

src = Path(os.environ['STROM150D_ROOT']) / 'frontend/src'
app = src / 'App.tsx'
css = src / 'styles.css'
scene = src / 'components/Building3DWorkspace.tsx'
bridge = src / 'components/cameraTransitions150.ts'
flight = src / 'components/CameraFlight150.tsx'
for path in (app,css,scene,bridge,flight):
    if not path.is_file():
        raise RuntimeError(f'150d required file missing: {path}')

a = app.read_text('utf8')
c = css.read_text('utf8')
b = bridge.read_text('utf8')
f = flight.read_text('utf8')
if 'STROM150D_CAMERA_FIX' in c:
    raise RuntimeError('150d already installed, no double patch')
if 'STROM150C_PRESERVE_BLUEPRINT' not in a or 'STROM150C_PRESERVE_BLUEPRINT' not in c:
    raise RuntimeError('150d requires 150c Blueprint hold and spinner')
if 'STROM150_CAMERA' not in scene.read_text('utf8'):
    raise RuntimeError('150d expects the existing CameraFlight in the 3D scene')
if 'const UP150=' not in f or 'const easing150=' not in f or 'export const DURATION150=750' not in b:
    raise RuntimeError('150d camera prerequisite mismatch; no changes made')
old_css = '.workspace.strom150c-enter-fading > .floorplan-layout {opacity:0;transition:opacity 250ms ease;}'
new_css = '.workspace.strom150c-enter-fading > .floorplan-layout {opacity:0;transition:opacity 500ms ease;}'
if c.count(old_css)!=1:
    raise RuntimeError(f'150d fade CSS expected once, found {c.count(old_css)}')
c = c.replace(old_css,new_css,1)
c += '\n/* STROM150D_CAMERA_FIX: 500ms crossfade; 1500ms 3D flight, 150c spinner and Blueprint DOM retained. */\n'
css.write_text(c,'utf8')
print('PASS 150d: 150c Blueprint hold and spinner preserved; fade set to 500ms')
STROM150D_PY
cat > "$RESOURCE_DIR/cameraTransitions150.ts" <<'STROM150D_BRIDGE_TS'
/** STROM150_CAMERA_BRIDGE: coordinate view navigation without delaying React rendering. */
export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number}
export type Mode150='wall'|'threeD'
export type Enter150={mode:Mode150;frame:BlueprintFrame150}
let pending150:Enter150|null=null
let current150:Enter150|null=null
let activeExit150:((done:()=>void)=>void)|null=null
let activeReady150:(()=>void)|null=null
let exitPending150=false
let readySent150=false
export const ENTER_FADE150=500
export const DURATION150=1500

function storedLevel150(floorId:string):string{
  try {
    const raw=window.localStorage.getItem(`strom.floorplan.layers.${floorId}.active`)
    const value:unknown=JSON.parse(raw||'null')
    return typeof value==='string'?value:''
  }catch{return ''}
}
function viewFrame150(floorId:string):BlueprintFrame150{
  const result:BlueprintFrame150={floorId,levelId:storedLevel150(floorId),cx:0,cy:0,widthM:0,heightM:0}
  try {
    const svg=document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement|null
    const container=(svg?.closest('.canvas-scroll,.canvas-viewport,.canvas-scroll-area')||svg?.parentElement) as HTMLElement|null
    const matrix=svg?.getScreenCTM()
    const rect=container?.getBoundingClientRect()
    if(svg&&matrix&&rect&&rect.width>30&&rect.height>30){
      const center=svg.createSVGPoint();center.x=rect.left+rect.width/2;center.y=rect.top+rect.height/2
      const p=center.matrixTransform(matrix.inverse())
      result.cx=(p.x-670)/60;result.cy=(p.y-670)/60
      const pxPerUnit=Math.hypot(matrix.a,matrix.b)
      if(pxPerUnit>1e-5){result.widthM=rect.width/(60*pxPerUnit);result.heightM=rect.height/(60*pxPerUnit)}
    }
  }catch{/* fallback to model-room geometry if no live SVG was found */}
  return result
}
export function queueEntry150(mode:Mode150,floorId:string){
  pending150={mode,frame:viewFrame150(floorId)}
  current150=pending150
  exitPending150=false
  readySent150=false
}
export function consumeEntry150():Enter150|null{
  const value=pending150
  pending150=null
  return value
}
export function restoreEntry150(value:Enter150){if(!pending150)pending150=value}
export function currentFrame150():BlueprintFrame150|null{return current150?.frame||null}
export function registerEnterReady150(handler:()=>void):()=>void{
  activeReady150=handler
  return ()=>{if(activeReady150===handler)activeReady150=null}
}
export function notifyEnterReady150(){
  if(readySent150)return
  readySent150=true
  try {activeReady150?.()} catch {/* UI fade is optional */}
}
export function registerExit150(handler:(done:()=>void)=>void):()=>void{
  activeExit150=handler
  return ()=>{if(activeExit150===handler)activeExit150=null}
}
export function requestExit150(finish:()=>void):boolean{
  if(!activeExit150){pending150=null;current150=null;return false}
  if(exitPending150)return true
  exitPending150=true
  let completed=false
  const timeout=window.setTimeout(complete,DURATION150+1000)
  function complete(){if(completed)return;completed=true;window.clearTimeout(timeout);exitPending150=false;finish()}
  try {activeExit150(complete)}catch{complete()}
  return true
}
STROM150D_BRIDGE_TS
cat > "$RESOURCE_DIR/CameraFlight150.tsx" <<'STROM150D_FLIGHT_TSX'
import {useLayoutEffect,useRef} from 'react'
import {useFrame,useThree} from '@react-three/fiber'
import * as THREE from 'three'
import {consumeEntry150,restoreEntry150,currentFrame150,registerExit150,DURATION150,ENTER_FADE150,notifyEnterReady150} from './cameraTransitions150'
import type {BlueprintFrame150,Enter150} from './cameraTransitions150'

type P150={x:number;y:number}
type Control150={target?:THREE.Vector3;enabled?:boolean;update?:()=>void}
type Pose150={position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;zoom:number}
type Flight150={start:Pose150;end:Pose150;started:number;done?:()=>void;restoreControls?:boolean}
const easing150=(t:number)=>1-Math.pow(1-t,3)
const clamp150=(n:number,a:number,b:number)=>Math.min(b,Math.max(a,n))
const UP150=new THREE.Vector3(0,0,-1)

function planBounds150(points:readonly P150[],frame:BlueprintFrame150|null){
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity
  for(const p of points){if(!Number.isFinite(p.x)||!Number.isFinite(p.y))continue
    minX=Math.min(minX,p.x);maxX=Math.max(maxX,p.x);minY=Math.min(minY,p.y);maxY=Math.max(maxY,p.y)
  }
  if(!Number.isFinite(minX)){minX=-4;maxX=4;minY=-3;maxY=3}
  const cx=(minX+maxX)/2,cy=(minY+maxY)/2
  const width=Math.max(2,maxX-minX),height=Math.max(2,maxY-minY)
  if(frame&&frame.widthM>0.1&&frame.heightM>0.1&&frame.widthM<150&&frame.heightM<150){
    return {cx:frame.cx,cy:frame.cy,width:frame.widthM,height:frame.heightM}
  }
  return {cx,cy,width:width*1.14,height:height*1.14}
}
function topPose150(camera:THREE.Camera,bounds:ReturnType<typeof planBounds150>,aspect:number):Pose150{
  const target=new THREE.Vector3(bounds.cx,0,bounds.cy)
  const zoom=Math.max(1,(camera as THREE.OrthographicCamera).zoom||1)
  let distance=12
  let newZoom=zoom
  if((camera as THREE.PerspectiveCamera).isPerspectiveCamera){
    const fov=THREE.MathUtils.degToRad((camera as THREE.PerspectiveCamera).fov||45)
    const tangent=Math.max(0.05,Math.tan(fov/2))
    distance=clamp150(Math.max(bounds.height/2/tangent,bounds.width/2/Math.max(0.3,aspect)/tangent),2,500)
  }else if((camera as THREE.OrthographicCamera).isOrthographicCamera){
    const ortho=camera as THREE.OrthographicCamera
    const viewWidth=Math.abs(ortho.right-ortho.left),viewHeight=Math.abs(ortho.top-ortho.bottom)
    newZoom=clamp150(Math.min(viewWidth/bounds.width,viewHeight/bounds.height),0.05,100)
    distance=Math.max(10,bounds.height*2,bounds.width*2)
  }
  const position=new THREE.Vector3(bounds.cx,distance,bounds.cy)
  // Blueprint X/Y maps onto 3D X/Z; the overhead camera is exactly vertical.
  const topView=new THREE.Matrix4().lookAt(position,target,UP150)
  return {position,rotation:new THREE.Quaternion().setFromRotationMatrix(topView),target,zoom:newZoom}
}
function snapshot150(camera:THREE.Camera,control:Control150|null,fallbackTarget:THREE.Vector3):Pose150{
  // STROM150D_CAMERA_FIX: preserve the actual camera quaternion. 150c replaced it
  // with a lookAt built from -Z up, which caused an instantaneous roll on both flights.
  return {position:camera.position.clone(),rotation:camera.quaternion.clone(),
    target:control?.target?.clone()||fallbackTarget.clone(),
    zoom:(camera as THREE.OrthographicCamera).zoom||1}
}

/** Hold the real Blueprint through 3D load; fade 500ms then fly 1500ms. */
export default function CameraFlight150({points}:{points:readonly P150[]}){
  const camera=useThree(state=>state.camera)
  // Never subscribe to changing OrbitControls identity: its late registration caused
  // a useLayoutEffect cleanup/re-entry and jumped the camera back to its old angle.
  const getState=useThree(state=>state.get)
  const size=useThree(state=>state.size)
  const invalidate=useThree(state=>state.invalidate)
  const gl=useThree(state=>state.gl)
  const entryRenderFrame=useRef(0)
  const entryWaiting=useRef(false)
  const queuedEntry=useRef<Enter150|null>(null)
  const flight=useRef<Flight150|null>(null)
  const initialPose=useRef<Pose150|null>(null)
  const initialControlsEnabled=useRef<boolean|undefined>(undefined)
  const latest=useRef<{points:readonly P150[];aspect:number}>({points,aspect:Math.max(.3,size.width/Math.max(size.height,1))})
  latest.current={points,aspect:Math.max(.3,size.width/Math.max(size.height,1))}
  const controls150=()=>((getState().controls||null) as Control150|null)

  const apply=(pose:Pose150)=>{
    camera.position.copy(pose.position)
    camera.quaternion.copy(pose.rotation)
    const controls=controls150()
    if(controls?.target)controls.target.copy(pose.target)
    const ortho=camera as THREE.OrthographicCamera
    if(ortho.isOrthographicCamera){ortho.zoom=pose.zoom;ortho.updateProjectionMatrix()}
    camera.updateMatrixWorld()
    invalidate()
  }
  useLayoutEffect(()=>{
    // Consume once per Canvas mount; avoid reinitializing when OrbitControls registers.
    queuedEntry.current=consumeEntry150()
    const unregister=registerExit150((done)=>{
      const controls=controls150()
      const bounds=planBounds150(latest.current.points,currentFrame150())
      const bird=topPose150(camera,bounds,latest.current.aspect)
      // Reverse starts from the exact displayed quaternion, including any user rotation.
      const current=snapshot150(camera,controls,bird.target)
      queuedEntry.current=null
      entryWaiting.current=false
      if(controls)controls.enabled=false
      flight.current={start:current,end:bird,started:performance.now(),done,
        restoreControls:initialControlsEnabled.current}
      invalidate()
    })
    return ()=>{
      unregister()
      const controls=controls150()
      if(controls&&initialControlsEnabled.current!==undefined)
        controls.enabled=initialControlsEnabled.current
      // Teardown only: do not reset the camera angle during a normal view switch.
      if(queuedEntry.current)restoreEntry150(queuedEntry.current)
      queuedEntry.current=null
      flight.current=null
      entryWaiting.current=false
    }
  // Camera and renderer identity are stable for this Canvas; controls can change.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  },[camera,gl,getState])

  useFrame(()=>{
    if(queuedEntry.current){
      const controls=controls150()
      if(!controls){invalidate();return}
      const incoming=queuedEntry.current
      queuedEntry.current=null
      const original=snapshot150(camera,controls,new THREE.Vector3())
      initialPose.current=original
      initialControlsEnabled.current=controls.enabled
      const bounds=planBounds150(latest.current.points,incoming.frame)
      const bird=topPose150(camera,bounds,latest.current.aspect)
      controls.enabled=false
      apply(bird)
      // Hold the top pose until it has actually been rendered by WebGL.
      entryRenderFrame.current=gl.info.render.frame
      entryWaiting.current=true
      flight.current={start:bird,end:original,started:Number.POSITIVE_INFINITY,
        restoreControls:initialControlsEnabled.current}
      return
    }
    const running=flight.current
    if(!running)return
    if(entryWaiting.current){
      if(gl.info.render.frame>entryRenderFrame.current){
        entryWaiting.current=false
        running.started=performance.now()+ENTER_FADE150
        notifyEnterReady150()
      }
      invalidate()
      return
    }
    const t=clamp150((performance.now()-running.started)/DURATION150,0,1)
    const k=easing150(t)
    const a=running.start,b=running.end
    const next:Pose150={position:a.position.clone().lerp(b.position,k),
      rotation:a.rotation.clone().slerp(b.rotation,k),
      target:a.target.clone().lerp(b.target,k),zoom:a.zoom+(b.zoom-a.zoom)*k}
    apply(next)
    if(t>=1){
      apply(b)
      flight.current=null
      if(running.done){
        // Stay disabled until unmount so OrbitControls cannot snap at bird's eye.
        running.done()
      }else{
        const controls=controls150()
        if(controls){
          // Synchronize orbit internals *before* restoring interaction.
          controls.update?.()
          apply(b)
          controls.enabled=running.restoreControls??true
        }
      }
    }
  })
  return null
}

STROM150D_FLIGHT_TSX
log "3) Apply incremental patch to isolated source ..."
python3 -m py_compile "$RESOURCE_DIR/patch150d.py" >>"$DIAG_LOG" 2>&1 || fail "150d Python syntax failed"
STROM150D_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150d.py" >>"$DIAG_LOG" 2>&1 || fail "150d CSS/precondition patch failed; GitHub and Stage unchanged"
cp "$RESOURCE_DIR/cameraTransitions150.ts" "$WORK_DIR/frontend/src/components/cameraTransitions150.ts"
cp "$RESOURCE_DIR/CameraFlight150.tsx" "$WORK_DIR/frontend/src/components/CameraFlight150.tsx"
log "4) Full TypeScript AST audit and duplicate JSX check ..."
STROM150D_SOURCE="$WORK_DIR/frontend/src" STROM150D_TS="$DEPENDENCIES/typescript" node <<'STROM150D_AST' >>"$DIAG_LOG" 2>&1 || fail "150d AST audit failed; GitHub and Stage unchanged"
const fs=require('fs'),path=require('path'),ts=require(process.env.STROM150D_TS)
const root=process.env.STROM150D_SOURCE
let files=0
function walkDirectory(dir){for(const name of fs.readdirSync(dir)){
  const file=path.join(dir,name),stat=fs.statSync(file)
  if(stat.isDirectory()){if(!['node_modules','dist','.git'].includes(name))walkDirectory(file);continue}
  if(!/\.tsx?$/.test(name))continue
  const text=fs.readFileSync(file,'utf8')
  const tree=ts.createSourceFile(file,text,ts.ScriptTarget.Latest,true,name.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
  if(tree.parseDiagnostics.length)throw Error(file+': '+tree.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
  function visit(node){if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node)){
    const seen=new Set();for(const attribute of node.attributes.properties){if(!ts.isJsxAttribute(attribute))continue
      const n=attribute.name.getText(tree);if(seen.has(n))throw Error(file+' duplicated JSX attribute '+n);seen.add(n)}
  }ts.forEachChild(node,visit)}visit(tree);files++
}}
walkDirectory(root)
console.log('PASS AST:',files,'TS/TSX files parsed without duplicate attributes')
STROM150D_AST
log "5) Full TypeScript/Vite build against existing Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150d TypeScript/Vite build failed before GitHub push"
log "5.1) Camera regression tests ..."
STROM150D_SOURCE="$WORK_DIR/frontend/src" STROM150D_TS="$DEPENDENCIES/typescript" node <<'STROM150D_TEST' >>"$DIAG_LOG" 2>&1 || fail "150d regression tests failed; GitHub and Stage unchanged"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150D_TS)
const root=process.env.STROM150D_SOURCE
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const js=ts.transpileModule(bridge,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
let timeout=0
const mockWindow={localStorage:{getItem:(k)=>k.endsWith('.active')?'"top"':null},
 setTimeout:(_,ms)=>{timeout=ms;return 1},clearTimeout:()=>{}}
const m={exports:{}}
new Function('module','exports','require','window','document',js)(m,m.exports,require,mockWindow,{querySelector:()=>null})
const b=m.exports
assert.equal(b.ENTER_FADE150,500)
assert.equal(b.DURATION150,1500)
b.queueEntry150('threeD','house');assert.equal(b.consumeEntry150().frame.levelId,'top')
let ready=0;const unregisterReady=b.registerEnterReady150(()=>ready++)
b.notifyEnterReady150();b.notifyEnterReady150();assert.equal(ready,1);unregisterReady()
let exits=0;const unregisterExit=b.registerExit150(done=>{exits++;done()})
assert(b.requestExit150(()=>{exits++}));assert.equal(exits,2)
assert(timeout>=b.DURATION150+500,'early navigation fallback could snap camera')
unregisterExit()
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
assert(flight.includes('rotation:camera.quaternion.clone()'),'must copy actual camera quaternion')
assert(flight.includes('const getState=useThree(state=>state.get)'),'stable controls lookup')
assert(!flight.includes('useThree(state=>(state.controls'),'must not resubscribe controls and restart camera')
assert(flight.includes('rotation:a.rotation.clone().slerp(b.rotation,k)'),'continuous quaternion slerp')
assert(flight.includes('running.started=performance.now()+ENTER_FADE150'))
assert(flight.includes('gl.info.render.frame>entryRenderFrame.current'))
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
const css=fs.readFileSync(path.join(root,'styles.css'),'utf8')
assert(app.includes('STROM150C_PRESERVE_BLUEPRINT'))
assert(css.includes('strom150c-loader-ring'))
assert(css.includes('transition:opacity 500ms ease'))
console.log('PASS 150d: true camera quaternion, 500ms fade, 1500ms flights, loading spinner and reverse fallback')
STROM150D_TEST

rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150D.md" <<'STROM150D_DOC'
# Update 150d – Kamerafahrt ohne Winkelsprung
- Blueprint remains mounted until WebGL has painted the 3D start pose.
- Existing loading spinner retained; fade duration 500 ms.
- Forward and reverse camera flights are 1500 ms, cubic ease-out.
- Preserve the actual camera quaternion before each flight; no rederived camera roll.
- Stable OrbitControls access avoids animation restarts when controls mount.
- Reverse navigation timeout exceeds the full 1500 ms flight.
- Deployment only to /strom-test/ after isolated GitHub build and Stage checks.
STROM150D_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150d Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy to /strom-test/ only ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150d Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150d frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150d test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150d deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
