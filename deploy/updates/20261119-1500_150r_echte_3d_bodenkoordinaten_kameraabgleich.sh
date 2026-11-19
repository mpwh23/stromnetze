#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1500_150r_echte_3d_bodenkoordinaten_kameraabgleich"
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
COMMIT_MESSAGE="Update 150r: match actual transformed 3D floor vertices to measured Blueprint viewport before fade"
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
  echo "2) Update 150r im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150r isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150r: real 3D floor-world projection and camera viewport match ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/FloorSlab149.tsx frontend/src/components/CameraFlight150.tsx \
  frontend/src/components/cameraTransitions150.ts frontend/src/components/threeFloorExtrema150q.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "150r required source missing: $file"
done
grep -Fq 'STROM150Q_3D_FLOOR_EXTENTS' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "150r requires installed update 150q; Stage unchanged"
grep -Fq 'STROM150P_BLUEPRINT_EXTENTS' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "150r requires measured Blueprint extents from 150p"
grep -Fq 'STROM150O_PRE_NAV_SNAPSHOT' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "150r requires 150o camera snapshot"
grep -Fq 'export const ENTER_FADE150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "150r requires 5 second fade to remain unchanged"
grep -Fq 'export const DURATION150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "150r requires 5 second flight to remain unchanged"
select_node
log "1) Backup Stage source ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no live source backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
fi
log "2) Prepare completely isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150r source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "150r TypeScript/Vite/Three dependencies missing"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/150r_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150r.py" <<'STROM150R_PY'
#!/usr/bin/env python3
"""Apply 150r on top of the installed 150q stage in an isolated working tree."""
from pathlib import Path
import os
root = Path(os.environ['STROM150R_ROOT']) / 'frontend/src'
scene = root/'components/Building3DWorkspace.tsx'
slab = root/'components/FloorSlab149.tsx'
flight = root/'components/CameraFlight150.tsx'
probe = root/'components/threeFloorExtrema150q.ts'
bridge = root/'components/cameraTransitions150.ts'
for p in (scene, slab, flight, probe, bridge):
    if not p.is_file():raise RuntimeError(f'150r missing required current source: {p}')
a, b, c, d, e = (p.read_text('utf8') for p in (scene, slab, flight, probe, bridge))
if 'STROM150R_REAL_FLOOR_PROBE' in b or 'STROM150R_CAMERA_MATCH' in c:
    raise RuntimeError('150r already installed')
for desc, body, req in [
    ('3D scene',a,'STROM149_FLOOR_SLAB'),
    ('floor slab',b,'function FloorSlab149'),
    ('3D flight',c,'STROM150N_DEFAULT_SETTLED'),
    ('3D extrema',d,'STROM150Q_3D_FLOOR_EXTENTS'),
    ('Blueprint snapshot',e,'STROM150O_PRE_NAV_SNAPSHOT'),
]:
    if req not in body:raise RuntimeError(f'150r requires {desc} marker {req}')
for duration in ('ENTER_FADE150=5000','DURATION150=5000'):
    if duration not in e:raise RuntimeError(f'150r requires existing analysis timing {duration}')

def one(source, old, new, description):
    n = source.count(old)
    if n != 1:raise RuntimeError(f'150r {description}: expected unique anchor, found {n}')
    return source.replace(old, new, 1)

# Add non-rendering references at the *same transform parent as the real floor meshes*.
b=one(b,
  'export default function FloorSlab149({room,thicknessM}:{room:BuildingRoom;thicknessM:number}) {',
  'export default function FloorSlab149({room,thicknessM,ghost150r=false}:{room:BuildingRoom;thicknessM:number;ghost150r?:boolean}) {',
  'floor slab props')
old='''  // Stairwells must remain open: a full floor plate here would block the 3D stairs.
  if(room.kind==='outer'||room.kind==='stair'||!Number.isFinite(thicknessM)||thicknessM<0.001)return null
  return <mesh rotation={[-Math.PI/2,0,0]} position={[0,-thicknessM,0]} receiveShadow>
    <extrudeGeometry args={[shape,{depth:thicknessM,bevelEnabled:false,steps:1}]} />
    <meshStandardMaterial color="#aebdce" roughness={0.93} side={THREE.DoubleSide}/>
  </mesh>'''
new='''  // STROM150R_REAL_FLOOR_PROBE: measurement-only, invisible 3D reference. Same parent
  // matrix as the actual floor/rooms, including every storey transform; works with 0 mm slabs.
  // Stairwells are still open. Neither material nor physical meshes are modified.
  return <>
    <group name="strom150r-floor-reference"
      userData={{active150r:!ghost150r,vertices150r:room.vertices,roomId150r:room.id}} />
    {room.kind!=='outer'&&room.kind!=='stair'&&Number.isFinite(thicknessM)&&thicknessM>=0.001 &&
      <mesh rotation={[-Math.PI/2,0,0]} position={[0,-thicknessM,0]} receiveShadow>
        <extrudeGeometry args={[shape,{depth:thicknessM,bevelEnabled:false,steps:1}]} />
        <meshStandardMaterial color="#aebdce" roughness={0.93} side={THREE.DoubleSide}/>
      </mesh>}
  </>'''
b=one(b,old,new,'unmodified slab mesh + hidden probes')
# The ghost storeys use the same component. Tag them to exclude them from measurement.
a=one(a,
 'thicknessM={readSlabThickness149(entry146.model.floorId,entry146.id,window.localStorage)} />',
 'thicknessM={readSlabThickness149(entry146.model.floorId,entry146.id,window.localStorage)} ghost150r />',
 'exclude ghost storeys')

# Camera rig needs absolute object world positions, not guessed (x,0,z) points.
anchor="import { captureThreeFloorExtrema150q } from './threeFloorExtrema150q' // STROM150Q_3D_FLOOR_EXTENTS"
c=one(c,anchor,anchor+"\nimport { calibrateFloorStart150r, floorWorldPoints150r } from './cameraFloorMatch150r' // STROM150R_CAMERA_MATCH", 'camera measurement import')
c=one(c,
 '''      lock()
      apply(camera, start)
      return''',
 '''      lock()
      // STROM150R_CAMERA_MATCH: calibrate the locked 3D start pose from *actual*
      // transformed, selected-level floor anchors against the click-time BP transform.
      // It changes only the START of this flight, never the final default camera.
      calibrateFloorStart150r(state.scene,camera,state.gl.domElement,start,currentFrame150(),
        pose => apply(camera,pose))
      apply(camera, start)
      return''',
 'entry start calibration')
c=one(c,
 'captureThreeFloorExtrema150q(pointsRef.current, state.camera, state.gl.domElement, 0)',
 'captureThreeFloorExtrema150q(pointsRef.current, state.camera, state.gl.domElement, 0, floorWorldPoints150r(state.scene))',
 'real geometry projection in diagnostic')

# Pass real selected-level world-space vertices to the original 150q overlay.
d=one(d,
 '''  points:readonly FloorPoint150q[],camera:THREE.Camera,canvas:HTMLCanvasElement,floorY:number,
):FloorSnapshot150q|null{''',
 '''  points:readonly FloorPoint150q[],camera:THREE.Camera,canvas:HTMLCanvasElement,floorY:number,
  worldPoints150r?:readonly THREE.Vector3[],
):FloorSnapshot150q|null{''',
 '3D extrema measurement signature')
old='''  const probe=new THREE.Vector3()
  for(const point of points){
    if(!Number.isFinite(point.x)||!Number.isFinite(point.y))continue
    // Real 3D scene maps Blueprint X/Y to world X/Z; the floor is world Y=0.
    probe.set(point.x,floorY,point.y).project(camera)
    if(!Number.isFinite(probe.x)||!Number.isFinite(probe.y)||!Number.isFinite(probe.z))continue
    const x=bounds.left+(probe.x+1)*bounds.width/2-left
    const y=bounds.top+(1-probe.y)*bounds.height/2-top
    xMin=Math.min(xMin,x);xMax=Math.max(xMax,x)
    yMin=Math.min(yMin,y);yMax=Math.max(yMax,y)
    count++
  }'''
new='''  // STROM150R_REAL_FLOOR_PROBE: use real mesh-parent matrixWorld points; Y=0 is
  // valid ONLY as fallback when the reference meshes do not exist yet.
  const real=worldPoints150r&&worldPoints150r.length>0
  const probes=real?worldPoints150r!:points.filter(p=>Number.isFinite(p.x)&&Number.isFinite(p.y)).map(p=>new THREE.Vector3(p.x,floorY,p.y))
  for(const position of probes){
    const probe=position.clone().project(camera)
    if(!Number.isFinite(probe.x)||!Number.isFinite(probe.y)||!Number.isFinite(probe.z))continue
    const x=bounds.left+(probe.x+1)*bounds.width/2-left
    const y=bounds.top+(1-probe.y)*bounds.height/2-top
    xMin=Math.min(xMin,x);xMax=Math.max(xMax,x)
    yMin=Math.min(yMin,y);yMax=Math.max(yMax,y)
    count++
  }'''
d=one(d,old,new,'project transformed real 3D vertices')
d=one(d,
 "reference:bpView?'Blueprint-Viewport (0,0)':'3D-Canvas (0,0), BP-Referenz fehlt',floorY,",
 "reference:real?'Blueprint-Viewport (0,0), echte 3D-Weltpunkte':bpView?'Blueprint-Viewport (0,0), ersatzweise Y=0':'3D-Canvas (0,0), BP-Referenz fehlt',\n    floorY:real?probes.reduce((sum,p)=>sum+p.y,0)/probes.length:floorY,",
 'correct metadata for actual floor elevation')
d=one(d,
 "subsection.textContent='3D-Bodenfläche · Blendenbeginn (cyan)\\n'",
 "subsection.textContent=(real?'3D-Bodenfläche (echte Weltkoordinaten) · Blendenbeginn (cyan)\\n':'3D-Bodenfläche (Näherung Y=0) · Blendenbeginn (cyan)\\n')",
 'correct q overlay label')

# All anchors validated before writing; stage itself is patched only in isolated checkout.
for path,body in ((scene,a),(slab,b),(flight,c),(probe,d)):
    path.write_text(body,'utf8')
print('PASS 150r: real selected-floor mesh transforms, perspective-aware camera calibration, actual world coordinate extents')
STROM150R_PY
cat > "$RESOURCE_DIR/cameraFloorMatch150r.ts" <<'STROM150R_TS'
import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'

/** STROM150R_REAL_FLOOR_PROBE: sample invisible markers mounted directly beside the
 * active 3D floor meshes. Their matrixWorld includes every actual parent group transform,
 * so no (x,0,z) or guessed elevation assumption is involved. */
type PointM150r = {x:number;y:number}
type FloorSample150r = {plan:PointM150r;world:THREE.Vector3}
type CameraPose150r = {
  position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;up:THREE.Vector3;zoom:number
}
type Screen150r = {x:number;y:number}
type FitResult150r = {pairs:number;source:string;initialErrorPx:number;finalErrorPx:number;floorY:number;zoomFactor:number;shiftM:number}
const finite150r=(x:number)=>Number.isFinite(x)

export function floorSamples150r(scene:THREE.Object3D):FloorSample150r[]{
  scene.updateMatrixWorld(true)
  const samples:FloorSample150r[]=[]
  scene.traverse(obj=>{
    if(obj.name!=='strom150r-floor-reference'||obj.userData?.active150r!==true)return
    const vertices:unknown=obj.userData.vertices150r
    if(!Array.isArray(vertices))return
    for(const raw of vertices){
      if(!raw||typeof raw!=='object')continue
      const point=raw as PointM150r
      if(!finite150r(point.x)||!finite150r(point.y))continue
      const world=new THREE.Vector3(point.x,0,point.y).applyMatrix4(obj.matrixWorld)
      if(finite150r(world.x)&&finite150r(world.y)&&finite150r(world.z))samples.push({plan:point,world})
    }
  })
  return samples
}
export function floorWorldPoints150r(scene:THREE.Object3D):THREE.Vector3[]{
  return floorSamples150r(scene).map(p=>p.world)
}

function project150r(point:THREE.Vector3,camera:THREE.Camera,rect:DOMRect):Screen150r{
  const v=point.clone().project(camera)
  return {x:rect.left+(v.x+1)*rect.width/2,y:rect.top+(1-v.y)*rect.height/2}
}
function bpPixel150r(point:PointM150r,screen:NonNullable<BlueprintFrame150['screen150o']>):Screen150r{
  return {x:screen.x+screen.ax*point.x+screen.bx*point.y,
    y:screen.y+screen.ay*point.x+screen.by*point.y}
}
type Envelope150r={xMin:number;xMax:number;yMin:number;yMax:number}
function envelope150r(points:readonly Screen150r[]):Envelope150r{
  return {xMin:Math.min(...points.map(p=>p.x)),xMax:Math.max(...points.map(p=>p.x)),
    yMin:Math.min(...points.map(p=>p.y)),yMax:Math.max(...points.map(p=>p.y))}
}
function envelopeError150r(a:Envelope150r,b:Envelope150r):number{
  return Math.max(Math.abs(a.xMin-b.xMin),Math.abs(a.xMax-b.xMax),
    Math.abs(a.yMin-b.yMin),Math.abs(a.yMax-b.yMax))
}
function envelopeCenter150r(b:Envelope150r):Screen150r{
  return {x:(b.xMin+b.xMax)/2,y:(b.yMin+b.yMax)/2}
}
/** 150p measures real SVG polygon points via each polygon's getScreenCTM().
 * Prefer these verified bounds over the older 150o estimated root-SVG matrix. */
function measuredBlueprint150r(frame:BlueprintFrame150|null):Envelope150r|null{
  try{
    const raw=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(!raw)return null
    const data=JSON.parse(raw) as {
      floorId?:string;measuredAt?:string;
      viewport?:{screenLeft:number;screenTop:number};
      drawing?:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}
    }
    if(!frame||data.floorId!==frame.floorId||!data.viewport||!data.drawing)return null
    const v=data.viewport,d=data.drawing
    const numbers=[v.screenLeft,v.screenTop,d.xMinPx,d.xMaxPx,d.yMinPx,d.yMaxPx]
    if(!numbers.every(finite150r)||d.xMaxPx-d.xMinPx<10||d.yMaxPx-d.yMinPx<10)return null
    if(data.measuredAt&&Math.abs(Date.now()-Date.parse(data.measuredAt))>60000)return null
    return {xMin:v.screenLeft+d.xMinPx,xMax:v.screenLeft+d.xMaxPx,
      yMin:v.screenTop+d.yMinPx,yMax:v.screenTop+d.yMaxPx}
  }catch{return null}
}

/** Match measured SVG polygon bounding extrema to actual transformed 3D floor extrema.
 * Top-view rotation is deliberately unchanged; only camera altitude/zoom and XZ pan
 * are altered. The existing 5s fade, 5s flight, exit path and final default camera stay.
 * Never blocks navigation if a measurement is unavailable. */
export function calibrateFloorStart150r(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:CameraPose150r,frame:BlueprintFrame150|null,
  apply:(p:CameraPose150r)=>void,
):FitResult150r|null{
  const samples=floorSamples150r(scene)
  const rect=canvas.getBoundingClientRect()
  if(samples.length<3||rect.width<20||rect.height<20)return null
  const yMin=Math.min(...samples.map(p=>p.world.y)),yMax=Math.max(...samples.map(p=>p.world.y))
  // A selected floor must be a single plane. Never mix ghost levels or walls.
  if(yMax-yMin>0.075){console.warn('[STROM 150r] mixed floor elevations; matching skipped',yMin,yMax);return null}
  const floorY=(yMin+yMax)/2
  const measured=measuredBlueprint150r(frame)
  const mapping=frame?.screen150o
  if(!measured&&!mapping)return null
  const desired=measured||envelope150r(samples.map(p=>bpPixel150r(p.plan,mapping!)))
  if(!Object.values(desired).every(finite150r))return null
  const originalPosition=pose.position.clone(),originalTarget=pose.target.clone(),originalZoom=pose.zoom
  const perspective=camera as THREE.PerspectiveCamera
  const ortho=camera as THREE.OrthographicCamera
  let zoomFactor=1
  try{
    apply(pose)
    const initial=envelope150r(samples.map(p=>project150r(p.world,camera,rect)))
    const initialErrorPx=envelopeError150r(initial,desired)
    const desiredCenter=envelopeCenter150r(desired)
    const targetWidth=desired.xMax-desired.xMin,targetHeight=desired.yMax-desired.yMin
    if(!(targetWidth>20&&targetHeight>20))throw Error('Blueprint geometry too small')
    for(let iteration=0;iteration<3;iteration++){
      const actual=samples.map(p=>project150r(p.world,camera,rect))
      if(actual.some(p=>!finite150r(p.x)||!finite150r(p.y)))throw Error('3D projection not finite')
      const actualBounds=envelope150r(actual)
      const currentWidth=actualBounds.xMax-actualBounds.xMin
      const currentHeight=actualBounds.yMax-actualBounds.yMin
      if(!(currentWidth>1&&currentHeight>1))throw Error('3D geometry too small')
      // A top-down camera has one physical scale (no independent X/Y stretching).
      const ratio=(targetWidth/currentWidth+targetHeight/currentHeight)/2
      if(!(ratio>0.45&&ratio<2.5))throw Error('Camera scale difference out of bounds')
      if(perspective.isPerspectiveCamera){
        const distance=pose.position.y-floorY
        if(!(distance>0.2))throw Error('Camera is below selected floor')
        pose.position.y=floorY+distance/ratio
        pose.target.y=floorY
      }else if(ortho.isOrthographicCamera){
        pose.zoom*=ratio
      }else throw Error('Unsupported 3D camera type')
      zoomFactor*=ratio
      apply(pose)
      const adjusted=samples.map(p=>project150r(p.world,camera,rect))
      const now=envelopeCenter150r(envelope150r(adjusted))
      const delta={x:desiredCenter.x-now.x,y:desiredCenter.y-now.y}
      // Numerically derive the world->screen Jacobian of the ACTUAL camera,
      // instead of assuming CSS pixels per metre or an untransformed floor.
      const p=samples[0].world
      const a=project150r(p,camera,rect)
      const x=project150r(p.clone().add(new THREE.Vector3(1,0,0)),camera,rect)
      const z=project150r(p.clone().add(new THREE.Vector3(0,0,1)),camera,rect)
      const xx=x.x-a.x,xy=x.y-a.y,zx=z.x-a.x,zy=z.y-a.y
      const determinant=xx*zy-zx*xy
      if(!finite150r(determinant)||Math.abs(determinant)<0.000001)throw Error('Camera cannot be shifted on XZ plane')
      const shiftX=(delta.x*zy-zx*delta.y)/determinant
      const shiftZ=(xx*delta.y-xy*delta.x)/determinant
      if(Math.hypot(shiftX,shiftZ)>100)throw Error('Camera pan out of bounds')
      // Moving the camera by -shift moves the stationary model by +delta.
      pose.position.x-=shiftX;pose.position.z-=shiftZ
      pose.target.x-=shiftX;pose.target.z-=shiftZ
      apply(pose)
    }
    const finalActual=envelope150r(samples.map(p=>project150r(p.world,camera,rect)))
    const finalErrorPx=envelopeError150r(finalActual,desired)
    if(!finite150r(finalErrorPx)||finalErrorPx>Math.max(25,initialErrorPx*1.2))throw Error('Unstable projection calibration')
    const result:FitResult150r={pairs:samples.length,
      source:measured?'real SVG polygon extrema (150p)':'saved root-SVG projection (fallback)',
      initialErrorPx,finalErrorPx,
      floorY,zoomFactor,shiftM:Math.hypot(pose.position.x-originalPosition.x,pose.position.z-originalPosition.z)}
    console.info('[STROM 150r] echte 3D-Bodenpunkte gegen Blueprint ausgerichtet',result)
    try{window.localStorage.setItem('strom.camera150r.calibration',JSON.stringify(result))}catch{/* optional */}
    return result
  }catch(error){
    pose.position.copy(originalPosition);pose.target.copy(originalTarget);pose.zoom=originalZoom
    apply(pose)
    console.warn('[STROM 150r] camera match skipped; original start pose preserved',error)
    return null
  }
}
STROM150R_TS
cat > "$RESOURCE_DIR/test150r.cjs" <<'STROM150R_TEST'
'use strict'
const ts=require(process.env.STROM150R_TS||'/opt/nvm/versions/node/v22.16.0/lib/node_modules/typescript')
const fs=require('fs'),assert=require('assert'),path=require('path')
const root=process.env.STROM150R_SOURCE
for(const rel of ['components/FloorSlab149.tsx','components/Building3DWorkspace.tsx','components/CameraFlight150.tsx','components/cameraFloorMatch150r.ts','components/threeFloorExtrema150q.ts']){
  const p=path.join(root,rel),source=fs.readFileSync(p,'utf8'),ast=ts.createSourceFile(p,source,ts.ScriptTarget.Latest,true,rel.endsWith('tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
  assert.equal(ast.parseDiagnostics.length,0,rel+': TS syntax broken: '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join(';'))
}
const matchCode=fs.readFileSync(path.join(root,'components/cameraFloorMatch150r.ts'),'utf8')
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const qCode=fs.readFileSync(path.join(root,'components/threeFloorExtrema150q.ts'),'utf8')
assert(flight.indexOf('calibrateFloorStart150r(')<flight.indexOf('notifyEnterReady150()'),'camera must align BEFORE fade')
assert(qCode.includes('worldPoints150r?:readonly THREE.Vector3[]'),'3D diagnostic accepts actual floor points')
assert(flight.includes('DURATION150')&&flight.includes('ENTER_FADE150'),'5s timings preserved')
const jsx=fs.readFileSync(path.join(root,'components/FloorSlab149.tsx'),'utf8')
assert(jsx.includes('strom150r-floor-reference')&&jsx.includes('ghost150r=false'),'0mm slab gets active geometry probe')
class V {
  constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}
  clone(){return new V(this.x,this.y,this.z)}
  copy(v){this.x=v.x;this.y=v.y;this.z=v.z;return this}
  add(v){this.x+=v.x;this.y+=v.y;this.z+=v.z;return this}
  applyMatrix4(m){this.x+=m.dx;this.y+=m.dy;this.z+=m.dz;return this}
  project(c){
    let px,py
    if(c.isPerspectiveCamera){
      const height=c.position.y-this.y,tan=Math.tan(c.fov*Math.PI/360)
      px=(this.x-c.position.x)/(height*tan*c.aspect)
      py=-(this.z-c.position.z)/(height*tan)
    }else{
      px=(this.x-c.position.x)*c.zoom/(c.right-c.left)*2
      py=-(this.z-c.position.z)*c.zoom/(c.top-c.bottom)*2
    }
    return new V(px,py,0)
  }
}
const fakeThree={Vector3:V}
const compiled=ts.transpileModule(matchCode,{fileName:'cameraFloorMatch150r.ts',compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}})
assert.equal((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0)
const m={exports:{}}
const bpSnapshot={floorId:'floor-test',measuredAt:new Date().toISOString(),viewport:{screenLeft:150,screenTop:90},
  drawing:{xMinPx:150,xMaxPx:1000,yMinPx:110,yMaxPx:620}}
new Function('require','module','exports','console','window',compiled.outputText)(name=>{
 if(name==='three')return fakeThree
 if(name==='./cameraTransitions150')return {}
 throw Error('unexpected import '+name)
},m,m.exports,{info(){},warn(...args){throw Error(args.join(' '))}},{localStorage:{setItem(){},getItem(key){return key==='strom.camera150p.blueprintExtents'?JSON.stringify(bpSnapshot):null}}})
const {calibrateFloorStart150r,floorWorldPoints150r,floorSamples150r}=m.exports
function marker(vertices,tx,ty,tz,active){return {name:'strom150r-floor-reference',userData:{active150r:active,vertices150r:vertices},matrixWorld:{dx:tx,dy:ty,dz:tz}}}
const area1=[{x:0,y:0},{x:5,y:0},{x:5,y:4},{x:0,y:4}],area2=[{x:5,y:0},{x:10,y:0},{x:10,y:6},{x:5,y:6}]
const scene={updateMatrixWorld(){},traverse(fn){fn(marker(area1,8,3.2,-4,true));fn(marker(area2,8,3.2,-4,true));fn(marker([{x:-100,y:-100},{x:100,y:100}],8,5.7,-4,false))}}
const samples=floorSamples150r(scene)
assert.equal(samples.length,8)
assert.equal(floorWorldPoints150r(scene)[0].y,3.2)
const camera={position:new V(11,14,1),up:new V(0,0,-1),fov:42,aspect:1100/800,isPerspectiveCamera:true,isOrthographicCamera:false,zoom:1,updateProjectionMatrix(){},updateMatrixWorld(){}}
const pose={position:camera.position.clone(),target:new V(11,0,1),rotation:{},up:camera.up,zoom:1}
const canvas={getBoundingClientRect(){return {left:150,top:90,width:1100,height:800}}}
const frame={floorId:'floor-test',screen150o:{x:500,y:300,ax:120,ay:0,bx:0,by:120}}
const apply=(p)=>{camera.position.copy(p.position);camera.zoom=p.zoom;camera.updateProjectionMatrix();camera.updateMatrixWorld()}
const result=calibrateFloorStart150r(scene,camera,canvas,pose,frame,apply)
assert(result,'calibration should run on real active floor points')
assert.equal(result.pairs,8)
assert(result.source.includes('real SVG polygon extrema'),'correct 150p actual Polygon matrix is used, not 150o fallback')
assert(Math.abs(result.floorY-3.2)<1e-9)
assert(result.initialErrorPx>30,'initial mismatch detectable')
assert(result.finalErrorPx<0.1,'camera must match actual 3D projections to BP within 0.1 px; got '+result.finalErrorPx)
const preservedX=pose.position.x
const noFrame=calibrateFloorStart150r(scene,camera,canvas,pose,null,apply)
assert.equal(noFrame,null)
assert.equal(pose.position.x,preservedX)
// Orthographic reprojection covers zoom without moving the simulated scene.
const ortho={position:new V(4,14,4),up:new V(0,0,-1),isPerspectiveCamera:false,isOrthographicCamera:true,left:-5.5,right:5.5,top:4,bottom:-4,zoom:1,updateProjectionMatrix(){},updateMatrixWorld(){}}
const orthoPose={position:ortho.position.clone(),target:new V(4,0,4),rotation:{},up:ortho.up,zoom:1}
const oapply=(p)=>{ortho.position.copy(p.position);ortho.zoom=p.zoom}
const orthoResult=calibrateFloorStart150r(scene,ortho,canvas,orthoPose,frame,oapply)
assert(orthoResult && orthoResult.finalErrorPx < 0.1,'orthographic camera must align too')
console.log('PASS 150r: real model world transforms, ghost excluded, zero slab, 3D/BP <0.1px in perspective + orthographic, safe fallback')
STROM150R_TEST

log "3) Install real floor probes and calibrate entry camera before fade ..."
python3 -m py_compile "$RESOURCE_DIR/patch150r.py" >>"$DIAG_LOG" 2>&1 || fail "150r Python syntax failed"
STROM150R_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150r.py" >>"$DIAG_LOG" 2>&1 || \
  fail "150r source patch failed; GitHub and Stage unchanged"
install -m 0644 "$RESOURCE_DIR/cameraFloorMatch150r.ts" \
  "$WORK_DIR/frontend/src/components/cameraFloorMatch150r.ts"
log "4) TypeScript/Vite build against Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "150r TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) 3D world-transform and pixel-alignment regression tests ..."
STROM150R_SOURCE="$WORK_DIR/frontend/src" STROM150R_TS="$DEPENDENCIES/typescript" \
  node "$RESOURCE_DIR/test150r.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "150r floor projection regression failed; GitHub and Stage unchanged"
log "PASS 150r: selected-level 3D world points measured, viewport start fitted to actual Blueprint polygon bounds"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150R.md" <<'STROM150R_DOC'
# Stromnetze update 150r — actual 3D-world floor projection and camera calibration
- Blueprint bounds: use live polygon.getScreenCTM() coordinates saved at click by update 150p. Do not infer screen position from an assumed SVG origin or outer root matrix.
- Actual 3D floor: add invisible, non-rendered reference points as siblings of real active-level FloorSlab149 meshes. Their parent matrixWorld includes the real level/group elevation, rotation and position. Also works when slabThicknessM=0.
- Exclude ghost-floor meshes from start-pose camera matching. Use actual projected world vertices in 150q cyan diagnostic.
- Fit the 3D camera's start pose to real Blueprint bounding extrema (pan + zoom/altitude only); do not rotate the camera or change the default end pose.
- No loading waits; preserve 5000 ms blend, 5000 ms eased flight, spinner, existing exit flight and 3D geometry.
- Full tsc/vite build + geometry regression before Git push; deploy only /strom-test/.
STROM150R_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "150r Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY; no web deployment"
  exit 0
fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "150r Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150r frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "150r /strom-test/ deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150r deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
