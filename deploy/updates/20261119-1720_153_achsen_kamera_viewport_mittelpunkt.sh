#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1720_153_achsen_kamera_viewport_mittelpunkt"
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
COMMIT_MESSAGE="Update 153: unified colored axes and exact BP viewport camera entry"
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
  echo "2) Update 153 im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 153 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 153: identical axis styling and correct viewport-centered top view ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/CanonicalGrid152.tsx \
  frontend/src/components/CameraFlight150.tsx \
  frontend/src/components/cameraTransitions150.ts \
  frontend/src/components/cameraFloorMatch150r.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "153 required source missing: $file"
done
grep -Fq 'STROM152_BLUEPRINT_GRID' "$STAGE_DIR/frontend/src/components/CanonicalGrid152.tsx" || \
  fail "153 requires installed update 152, no changes applied"
grep -Fq 'STROM150R_CAMERA_MATCH' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "153 requires installed camera calibration 150r, no changes applied"
grep -Fq 'STROM150P_BLUEPRINT_EXTENTS' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "153 requires real Blueprint viewport snapshot 150p, no changes applied"
select_node
log "1) Backup Stage ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no Stage backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
fi
log "2) Prepare isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "153 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "153 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/153_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch153.py" <<'STROM153_PATCH_PY'
#!/usr/bin/env python3
'''Update 153: coordinate styling, selected-floor projection, final camera fit.

Every patch runs in a copied tree; exact prerequisites checked before modifications.
'''
from pathlib import Path
import os
root=Path(os.environ['STROM153_ROOT'])/'frontend/src'
app=root/'App.tsx'
css=root/'styles.css'
flight=root/'components/CameraFlight150.tsx'
grid=root/'components/CanonicalGrid152.tsx'
for f in (app,css,flight,grid):
    if not f.is_file():raise RuntimeError(f'Missing prerequisite {f}')
a=app.read_text('utf8');s=css.read_text('utf8');f=flight.read_text('utf8');g=grid.read_text('utf8')
if any('STROM153_' in t for t in (a,s,f,g)):
    raise RuntimeError('153 already applied; refusing duplicate')

def one(t,old,new,desc):
    n=t.count(old)
    if n!=1:raise RuntimeError(f'153 {desc}: expected one anchor, got {n}')
    return t.replace(old,new,1)

# Blueprint: x=0 line runs along plan Y; y=0 line runs along plan X.
# Color by DIRECTION, not by the variable name of a grid-loop iterator.
start=a.find('function Grid(')
end=a.find('\nfunction ',start+10)
if start<0 or end<0:raise RuntimeError('Blueprint Grid function not found')
portion=a[start:end]
old="className={major ? 'major' : ''}"
if portion.count(old)!=2:raise RuntimeError('Expected two Blueprint SVG grid lines, found '+str(portion.count(old)))
portion=portion.replace(old,"className={meter === 0 ? 'strom153-zero-y' : (major ? 'major' : '')}",1)
portion=portion.replace(old,"className={meter === 0 ? 'strom153-zero-x' : (major ? 'major' : '')}",1)
a=a[:start]+portion+a[end:]
a='// STROM153_BP_AXIS_STYLES: XY lines use one viewport-pixel width.\n'+a

s+='''
/* STROM153_AXIS_PIXEL_WIDTH: equal width in Blueprint and Three.js (WebGL 1 CSS px).
   SVG vector-effect prevents line widths growing with Blueprint zoom. */
.floorplan-canvas .grid line,
.floorplan-canvas .grid line.major {
  stroke-width:1px !important;
  vector-effect:non-scaling-stroke;
}
.floorplan-canvas .grid line.strom153-zero-x {stroke:#e14b4b !important;stroke-opacity:1;}
.floorplan-canvas .grid line.strom153-zero-y {stroke:#269e59 !important;stroke-opacity:1;}
'''

# 3D uses the same ONE-pixel line primitive for X, Y and Z.
# 3D world axes: X=plan X (red); world Z=plan Y (green); world Y=architectural Z (blue).
needle='''  useEffect(()=>()=>gridGeometry.dispose(),[gridGeometry])'''
insert='''  // STROM153_3D_AXIS_STYLES: lines are 1 CSS pixel, regardless of camera distance.
  // Red X, green plan Y (Three Z), blue height Z (Three Y).
  const axisGeometry153=useMemo(()=>{
    const make=(coords:number[])=>{
      const geo=new THREE.BufferGeometry()
      geo.setAttribute('position',new THREE.Float32BufferAttribute(coords,3))
      return geo
    }
    const z= Math.max(6,Math.min(20,half))
    return {
      x:make([-half,-0.013,0,half,-0.013,0]),
      y:make([0,-0.012,-half,0,-0.012,half]),
      z:make([0,-z,0,0,z,0]),
    }
  },[half])
  useEffect(()=>()=>Object.values(axisGeometry153).forEach(geometry=>geometry.dispose()),[axisGeometry153])
'''
g=one(g,needle,needle+'\n'+insert,'3D axis geometry')
start=g.index('      {/* Blueprint X=0 (through Y axis)')
end=g.index('    </group>,scene,',start)
new='''      {/* STROM153_3D_AXIS_STYLES: matched viewport-pixel width, no thick boxes. */}
      <lineSegments name="strom152-x-axis" geometry={axisGeometry153.x} frustumCulled={false}>
        <lineBasicMaterial color="#e14b4b" linewidth={1} toneMapped={false}/>
      </lineSegments>
      <lineSegments name="strom152-y-axis" geometry={axisGeometry153.y} frustumCulled={false}>
        <lineBasicMaterial color="#269e59" linewidth={1} toneMapped={false}/>
      </lineSegments>
      <lineSegments name="strom153-z-axis" geometry={axisGeometry153.z} frustumCulled={false}>
        <lineBasicMaterial color="#3377db" linewidth={1} toneMapped={false}/>
      </lineSegments>
'''
g=g[:start]+new+g[end:]

# The 150r pass stays intact. Refit the actual ACTIVE camera at the very last
# preparation frame (still behind spinner) with Blueprint's measured viewport center.
imp="import { calibrateFloorStart150r, floorWorldPoints150r } from './cameraFloorMatch150r' // STROM150R_CAMERA_MATCH"
f=one(f,imp,imp+"\nimport { alignBlueprintViewport153 } from './cameraViewportAlignment153' // STROM153_CAMERA_VIEWPORT_FIT",'final alignment import')
old='''      if (running.preparedFrames >= 3) {
        running.phase = 'fade' '''
# Some builds have 150q measurement before notify, but phase block is unique.
needle='''      if (running.preparedFrames >= 3) {
        running.phase = 'fade' '''
if needle not in f:
    needle='''      if (running.preparedFrames >= 3) {
        running.phase = 'fade'\n'''
    if f.count(needle)!=1:raise RuntimeError('Camera phase handoff unavailable')
    subst='''      if (running.preparedFrames >= 3) {
        // STROM153_CAMERA_VIEWPORT_FIT: at the LAST concealed frame, fit the
        // actual 3D projection to the stored Blueprint xMin/xMax/yMin/yMax.
        // No waiting, no changes to either 5-second transition duration.
        try {
          alignBlueprintViewport153(state.scene,camera,state.gl.domElement,
            running.start,currentFrame150(),pose=>apply(camera,pose))
        } catch(error){console.warn('[Strom 153] Viewport-Abgleich nicht möglich',error)}
        apply(camera,running.start)
        running.phase = 'fade'\n'''
else:
    subst='''      if (running.preparedFrames >= 3) {
        // STROM153_CAMERA_VIEWPORT_FIT: fit at last hidden render frame.
        try {
          alignBlueprintViewport153(state.scene,camera,state.gl.domElement,
            running.start,currentFrame150(),pose=>apply(camera,pose))
        } catch(error){console.warn('[Strom 153] Viewport-Abgleich nicht möglich',error)}
        apply(camera,running.start)
        running.phase = 'fade' '''
f=one(f,needle,subst,'entry final hidden frame')

for p,t in [(app,a),(css,s),(flight,f),(grid,g)]:p.write_text(t,'utf8')
print('PASS 153: SVG axis widths and colors, matching 3D line axes, late viewport camera fit')
STROM153_PATCH_PY
cat > "$RESOURCE_DIR/cameraViewportAlignment153.ts" <<'STROM153_TS'
import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'
import { floorSamples150r } from './cameraFloorMatch150r'

/** STROM153_CAMERA_VIEWPORT_FIT: exact blueprint viewport extrema -> 3D camera.
 * The desired PIXEL centre is xMin+(xMax-xMin)/2, same for y. Pixel coordinates
 * must NEVER be put directly into camera.position, which is in THREE WORLD metres.
 * Instead, fit the 3D world-projected footprint (including floor level Z<>0)
 * to the saved Blueprint CSS-pixel viewport using camera projection/Jacobian.
 * The 3D scene uses Y-up: architectural height Z maps to Three.js world Y.
 */
type Point153 = {x:number;y:number}
type Extrema153={xMin:number;xMax:number;yMin:number;yMax:number}
type Pose153={position:THREE.Vector3;target:THREE.Vector3;zoom:number}
type BlueprintData153={
  floorId?:string;measuredAt?:string;
  viewport?:{screenLeft:number;screenTop:number;width:number;height:number};
  drawing?:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}
}
export type Fit153={source:string;blueprintCenter:Point153;projectedCenter:Point153;
  originalCenterErrorPx:number;finalCenterErrorPx:number;boundsErrorPx:number;
  widthRatio:number;heightRatio:number;floorZ:number;cameraZAboveFloor:number}
const finite=(n:number)=>Number.isFinite(n)
const mid=(min:number,max:number)=>min+(max-min)/2
const center=(r:Extrema153):Point153=>({x:mid(r.xMin,r.xMax),y:mid(r.yMin,r.yMax)})
function bounds(points:Point153[]):Extrema153{
  return {xMin:Math.min(...points.map(p=>p.x)),xMax:Math.max(...points.map(p=>p.x)),
    yMin:Math.min(...points.map(p=>p.y)),yMax:Math.max(...points.map(p=>p.y))}
}
function projected(point:THREE.Vector3,camera:THREE.Camera,rect:DOMRect):Point153{
  const v=point.clone().project(camera)
  return {x:rect.left+(v.x+1)*rect.width/2,y:rect.top+(1-v.y)*rect.height/2}
}
function blueprintBounds(frame:BlueprintFrame150|null,plans:Point153[]):{source:string;box:Extrema153}|null{
  if(!frame)return null
  try{
    const saved=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(saved){
      const item=JSON.parse(saved) as BlueprintData153
      const v=item.viewport,d=item.drawing
      if(item.floorId===frame.floorId&&v&&d&&
          [v.screenLeft,v.screenTop,d.xMinPx,d.xMaxPx,d.yMinPx,d.yMaxPx].every(finite)&&
          d.xMaxPx>d.xMinPx+1&&d.yMaxPx>d.yMinPx+1&&
          (!item.measuredAt||Math.abs(Date.now()-Date.parse(item.measuredAt))<120000)){
        return {source:'150p: tatsächliche Blueprint-Extrema bei Klick',box:{
          xMin:v.screenLeft+d.xMinPx,xMax:v.screenLeft+d.xMaxPx,
          yMin:v.screenTop+d.yMinPx,yMax:v.screenTop+d.yMaxPx}}
      }
    }
  }catch{/* prefer frame snapshot fallback */}
  const t=frame.screen150o
  if(!t)return null
  const pts=plans.filter(p=>finite(p.x)&&finite(p.y)).map(p=>({
    x:t.x+t.ax*p.x+t.bx*p.y,y:t.y+t.ay*p.x+t.by*p.y,
  }))
  if(pts.length<3)return null
  return {source:'150o: gespeicherte Blueprint-SVG-Abbildung',box:bounds(pts)}
}

export function alignBlueprintViewport153<TPose extends Pose153>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:TPose,frame:BlueprintFrame150|null,apply:(p:TPose)=>void,
):Fit153|null{
  const samples=floorSamples150r(scene)
  if(samples.length<3)return null
  const rect=canvas.getBoundingClientRect()
  if(!(rect.width>40&&rect.height>40))return null
  const desired=blueprintBounds(frame,samples.map(s=>s.plan))
  if(!desired)return null
  const floorZ=Math.max(...samples.map(s=>s.world.y))
  const minZ=Math.min(...samples.map(s=>s.world.y))
  if(!finite(floorZ)||floorZ-minZ>0.075)return null // Never mix different storeys.
  const bp=desired.box
  const bpWidth=bp.xMax-bp.xMin,bpHeight=bp.yMax-bp.yMin
  if(!(bpWidth>3&&bpHeight>3))return null
  const bpCenter=center(bp)
  const originalPosition=pose.position.clone(),originalTarget=pose.target.clone(),originalZoom=pose.zoom
  const perspective=camera as THREE.PerspectiveCamera
  const ortho=camera as THREE.OrthographicCamera
  try{
    apply(pose)
    const points=()=>samples.map(s=>projected(s.world,camera,rect))
    const first=bounds(points()),firstCenter=center(first)
    const originalCenterErrorPx=Math.hypot(firstCenter.x-bpCenter.x,firstCenter.y-bpCenter.y)
    const originalWidth=first.xMax-first.xMin,originalHeight=first.yMax-first.yMin
    if(!(originalWidth>0.01&&originalHeight>0.01))throw Error('3D-Footprint not projectable')

    // One physical camera scale for both axes; a ratio disagreement is a model/
    // sample mismatch, never a reason to stretch the building non-uniformly.
    const widthRatio=bpWidth/originalWidth,heightRatio=bpHeight/originalHeight
    let zoomFactor=(bpWidth*originalWidth+bpHeight*originalHeight)/
       (originalWidth*originalWidth+originalHeight*originalHeight)
    if(!(zoomFactor>0.01&&zoomFactor<100&&finite(zoomFactor)))throw Error('Invalid zoom factor')
    if(perspective.isPerspectiveCamera){
      const dist=pose.position.y-floorZ
      if(!(dist>0.01))throw Error('Camera under/inside selected floor')
      const targetDist=Math.max(0.25,dist/zoomFactor)
      pose.position.y=floorZ+targetDist
      // Preserve architectural floor elevation (Z in Blueprint, Y in Three).
      pose.target.y=floorZ
    }else if(ortho.isOrthographicCamera){
      pose.zoom=Math.max(0.0001,Math.min(10000,pose.zoom*zoomFactor))
    }else throw Error('Unsupported camera projection')
    apply(pose)

    // Solve the exact screen-space pan with the Jacobian of the LIVE 3D camera;
    // works with translated floors, non-centred world origins and arbitrary CSS canvas rects.
    for(let i=0;i<3;i++){
      const now=center(bounds(points()))
      const deltaX=bpCenter.x-now.x,deltaY=bpCenter.y-now.y
      if(Math.hypot(deltaX,deltaY)<0.05)break
      const p=samples[0].world
      const base=projected(p,camera,rect)
      const stepX=projected(p.clone().add(new THREE.Vector3(1,0,0)),camera,rect)
      const stepY=projected(p.clone().add(new THREE.Vector3(0,0,1)),camera,rect)
      const a=stepX.x-base.x,b=stepY.x-base.x,c=stepX.y-base.y,d=stepY.y-base.y
      const determinant=a*d-b*c
      if(!finite(determinant)||Math.abs(determinant)<1e-9)throw Error('Cannot invert 3D projection')
      const dx=(d*deltaX-b*deltaY)/determinant
      const dz=(-c*deltaX+a*deltaY)/determinant
      if(!finite(dx)||!finite(dz)||Math.hypot(dx,dz)>1e5)throw Error('Camera displacement invalid')
      // Translating camera by -dx/-dz shifts fixed geometry by +delta pixels.
      pose.position.x-=dx;pose.position.z-=dz
      pose.target.x-=dx;pose.target.z-=dz
      apply(pose)
    }
    const final=bounds(points()),actualCenter=center(final)
    const finalCenterErrorPx=Math.hypot(actualCenter.x-bpCenter.x,actualCenter.y-bpCenter.y)
    const boundsErrorPx=Math.max(Math.abs(final.xMin-bp.xMin),Math.abs(final.xMax-bp.xMax),
        Math.abs(final.yMin-bp.yMin),Math.abs(final.yMax-bp.yMax))
    const cameraZAboveFloor=pose.position.y-floorZ
    if(!(cameraZAboveFloor>0.1&&finite(cameraZAboveFloor)&&finalCenterErrorPx<1.5))
      throw Error('Viewport center not reached reliably')
    const result:Fit153={source:desired.source,blueprintCenter:bpCenter,
      projectedCenter:actualCenter,originalCenterErrorPx,finalCenterErrorPx,
      boundsErrorPx,widthRatio,heightRatio,floorZ,cameraZAboveFloor}
    try{window.localStorage.setItem('strom.camera153.alignment',JSON.stringify(result))}catch{/*optional*/}
    console.info('[Strom 153] Blueprint/3D viewport-center',result)
    if(boundsErrorPx>3){
      console.warn('[Strom 153] Mittelpunkt abgeglichen, aber unterschiedliche Footprint-Abmessungen',
        {blueprint:bp,projected:final,widthRatio,heightRatio})
    }
    return result
  }catch(e){
    pose.position.copy(originalPosition);pose.target.copy(originalTarget);pose.zoom=originalZoom
    apply(pose)
    console.warn('[Strom 153] ursprüngliche Kamera beibehalten, Kalibrierung fehlgeschlagen',e)
    return null
  }
}
STROM153_TS
cat > "$RESOURCE_DIR/test153.cjs" <<'STROM153_TEST'
'use strict'
const fs=require('fs'),assert=require('node:assert/strict'),path=require('path')
const ts=require(process.env.STROM153_TYPESCRIPT)
const source=process.env.STROM153_SOURCE
for(const rel of ['App.tsx','components/CanonicalGrid152.tsx','components/CameraFlight150.tsx','components/cameraViewportAlignment153.ts','components/cameraFloorMatch150r.ts']){
 const filename=path.join(source,rel),content=fs.readFileSync(filename,'utf8')
 const ast=ts.createSourceFile(filename,content,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 assert.equal(ast.parseDiagnostics.length,0,rel+' parse errors: '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
const a=fs.readFileSync(path.join(source,'App.tsx'),'utf8')
const g=fs.readFileSync(path.join(source,'components/CanonicalGrid152.tsx'),'utf8')
const c=fs.readFileSync(path.join(source,'components/CameraFlight150.tsx'),'utf8')
const fit=fs.readFileSync(path.join(source,'components/cameraViewportAlignment153.ts'),'utf8')
const css=fs.readFileSync(path.join(source,'styles.css'),'utf8')
assert(a.includes('strom153-zero-y')&&a.includes('strom153-zero-x'))
assert(css.includes('vector-effect:non-scaling-stroke'))
assert(g.includes('strom153-z-axis')&&g.includes('linewidth={1}'))
assert(g.includes('color="#e14b4b"')&&g.includes('color="#269e59"')&&g.includes('color="#3377db"'))
assert(!g.includes('boxGeometry args={[half*2,0.006,0.05]}'),'thick zero axis must be gone')
assert(c.includes('STROM153_CAMERA_VIEWPORT_FIT'))
assert(c.indexOf('alignBlueprintViewport153(state.scene')<c.indexOf("running.phase = 'fade'",c.indexOf('STROM153_CAMERA_VIEWPORT_FIT')),'alignment before fade')
assert(fit.includes('mid(r.xMin,r.xMax)')&&fit.includes('mid(r.yMin,r.yMax)'))
assert(fit.includes('pose.position.y=floorZ+targetDist'))
assert(c.includes('ENTER_FADE150')&&c.includes('DURATION150'))
console.log('PASS 153: axes, color codes, one-pixel line primitives, fit before fade, Z positive above selected floor')
STROM153_TEST
cat > "$RESOURCE_DIR/testViewportMath153.cjs" <<'STROM153_MATH_TEST'
'use strict'
const fs=require('fs'),assert=require('node:assert/strict'),ts=require(process.env.STROM153_TYPESCRIPT)
const js=ts.transpileModule(fs.readFileSync(require('path').join(process.env.STROM153_SOURCE,'components/cameraViewportAlignment153.ts'),'utf8'),{fileName:'fit153.ts',compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText
class V{
 constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}
 clone(){return new V(this.x,this.y,this.z)}
 copy(a){this.x=a.x;this.y=a.y;this.z=a.z;return this}
 add(a){this.x+=a.x;this.y+=a.y;this.z+=a.z;return this}
 project(camera){
   const rect=camera.rect
   const dist=camera.position.y-camera.floorZ
   const px= camera.isPerspectiveCamera ? rect.height/(2*Math.tan((camera.fov*Math.PI/180)/2)*dist) : camera.zoom*44
   const screenX=rect.left+rect.width/2+(this.x-camera.position.x)*px
   const screenY=rect.top+rect.height/2+(this.z-camera.position.z)*px
   return new V(2*(screenX-rect.left)/rect.width-1,1-2*(screenY-rect.top)/rect.height,0)
 }
}
const storage=new Map()
const window={localStorage:{getItem(k){return storage.get(k)||null},setItem(k,v){storage.set(k,v)}}}
const moduleExports={}
const printer={info(){},warn(...a){throw Error(a.join(' '))}}
new Function('require','module','exports','window','console',js)(name=>{
 if(name==='three')return {Vector3:V}
 if(name==='./cameraFloorMatch150r')return {floorSamples150r(scene){return scene.samples}}
 if(name==='./cameraTransitions150')return {}
 throw Error(name)
},{exports:moduleExports},moduleExports,window,printer)
const {alignBlueprintViewport153}=moduleExports
function run(name,{floorZ=2.6,dist=80,tx=10,tz=-8,type='persp',stored=true,blueprintScale=42}={}){
 const rect={left:220,top:90,width:980,height:760}
 const samples=[]
 for(const [x,z] of [[0,0],[12,0],[12,8],[0,8]])samples.push({plan:{x,y:z},world:new V(x+tx,floorZ,z+tz)})
 const scene={samples}
 const camera={isPerspectiveCamera:type==='persp',isOrthographicCamera:type==='ortho',position:new V(4,floorZ+dist,-4),fov:47,zoom:1,rect,floorZ,updateMatrixWorld(){},updateProjectionMatrix(){}}
 const pose={position:camera.position.clone(),target:new V(4,floorZ,-4),zoom:camera.zoom}
 const snap={floorId:'house',screen150o:{x:400,y:230,ax:blueprintScale,ay:0,bx:0,by:blueprintScale}}
 if(stored){
   storage.set('strom.camera150p.blueprintExtents',JSON.stringify({floorId:'house',measuredAt:new Date().toISOString(),viewport:{screenLeft:120,screenTop:70,width:1400,height:900},drawing:{xMinPx:160,xMaxPx:160+12*blueprintScale,yMinPx:180,yMaxPx:180+8*blueprintScale}}))
 }else{storage.delete('strom.camera150p.blueprintExtents')}
 const apply=p=>{camera.position.copy(p.position);camera.zoom=p.zoom}
 const result=alignBlueprintViewport153(scene,camera,{getBoundingClientRect(){return rect}},pose,snap,apply)
 assert(result,name+' failed to return result')
 assert(result.finalCenterErrorPx<0.001,name+' center diff '+result.finalCenterErrorPx)
 assert(result.boundsErrorPx<0.001,name+' bounds diff '+result.boundsErrorPx)
 assert(Math.abs(camera.position.y-floorZ)>0.1,name+' camera above floor')
 console.log(name,'PASS','X,Y center',result.projectedCenter,'bounds err',result.boundsErrorPx.toFixed(4),'cameraZFloor',result.cameraZAboveFloor.toFixed(4))
}
run('Perspective top view, extreme zoom >2.5x',{dist:85,tx:10,tz:-8})
run('Perspective second elevated floor',{dist:20,floorZ:5.2,tx:-50,tz:16,blueprintScale:57})
run('Perspective floor below datum',{dist:20,floorZ:-3.2,tx:140,tz:-30,blueprintScale:37})
run('Orthographic camera',{type:'ortho',tx:20,tz:40})
run('Saved SVG matrix fallback',{stored:false,dist:30,tx:15,tz:25})
console.log('PASS all 5 alignment cases')
STROM153_MATH_TEST
log "3) Install viewport camera fit and common axis style in isolated tree ..."
python3 -m py_compile "$RESOURCE_DIR/patch153.py" >>"$DIAG_LOG" 2>&1 || fail "153 Python syntax failed"
STROM153_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch153.py" >>"$DIAG_LOG" 2>&1 || \
 fail "153 source patch failed; GitHub and Stage unchanged"
install -m 0644 "$RESOURCE_DIR/cameraViewportAlignment153.ts" \
  "$WORK_DIR/frontend/src/components/cameraViewportAlignment153.ts"
log "4) Full TypeScript/Vite build in isolated tree ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "153 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Source and viewport regression checks ..."
STROM153_SOURCE="$WORK_DIR/frontend/src" STROM153_TYPESCRIPT="$DEPENDENCIES/typescript" \
 node "$RESOURCE_DIR/test153.cjs" >>"$DIAG_LOG" 2>&1 || \
 fail "153 regression failed; GitHub and Stage unchanged"
STROM153_SOURCE="$WORK_DIR/frontend/src" STROM153_TYPESCRIPT="$DEPENDENCIES/typescript" \
 node "$RESOURCE_DIR/testViewportMath153.cjs" >>"$DIAG_LOG" 2>&1 || \
 fail "153 viewport math failed; GitHub and Stage unchanged"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_153.md" <<'STROM153_DOC'
# Stromnetze 153 — identical blueprint/3D axis styling and centered crossfade

- Blueprint XY coordinates are authoritative. A line is 1 CSS pixel regardless
  of zoom, in both Blueprint SVG and Three.js WebGL grid.
- Blueprint X zero axis (horizontal) red, Y zero axis (vertical) green.
  3D X axis red, plan Y = Three Z green, architectural Z = Three Y blue.
- The Blueprint selected-level Z=0 datum from 151 is preserved; 3D vertical
  camera height is correctly computed above actual world floor elevation.
- At the final concealed frame, Blueprint click-time xMin/xMax/yMin/yMax yield
  screen centre (xMax-xMin)/2+xMin, similarly Y, in CSS viewport pixels.
- The camera is panned via the actual Three projection Jacobian, never by
  assigning pixel values to world coordinates. Physical scale is uniform.
- Original entry/exit durations, easing, camera finish and scene geometry
  remain untouched; added alignment runs before 5-second fade starts.
- Browser diagnostics: console [Strom 153] and storage strom.camera153.alignment.
- Build/validation in isolated temporary tree, deploy only /strom-test/.
STROM153_DOC
log "6) Transfer checked source to Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "153 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY; no web deployment"
  exit 0
fi
log "7) Build Stage and deploy exclusively /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "153 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "153 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "153 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 153 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
