#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-2220_163_kamera_blueprint_viewport_exakt"
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
COMMIT_MESSAGE="Update 163: exact camera above click-time Blueprint viewport, elevation/scale/lens fit"
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
  echo "2) Update 163 im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 163 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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

log "=== Update 163: Kamera exakt ueber sichtbarer Blueprint-Mitte ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts frontend/src/components/cameraBlueprintCenter156.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "163 required source missing: $file"
done
for marker in STROM162_EXACT_RENDERED_BLUEPRINT_RETURN STROM156_BLUEPRINT_CAMERA_CENTER; do
  grep -Fq "$marker" "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || fail "163 prerequisite $marker missing; no changes made"
done
if grep -Fq 'STROM163_BLUEPRINT_VIEWPORT_TRUTH' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"; then
  fail "163 already installed; no changes made"
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
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "163 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "163 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/163_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch163.py" <<'STROM163_PATCH'
#!/usr/bin/env python3
"""163: reconstruct camera from the SAME click-time BP viewport and SVG matrix.
Only bridge snapshot and the final start-pose calibration are modified.
"""
from pathlib import Path
import os,re

root=Path(os.environ['STROM163_ROOT'])/'frontend/src'
bridge=root/'components/cameraTransitions150.ts'
flight=root/'components/CameraFlight150.tsx'
helper=root/'components/cameraViewportExact163.ts'
for p in (bridge,flight):
    if not p.is_file(): raise RuntimeError(f'163: required source missing: {p}')
if helper.exists(): raise RuntimeError('163: already installed')
b=bridge.read_text('utf8')
f=flight.read_text('utf8')
for a in ('STROM150O_PRE_NAV_SNAPSHOT','STROM150P_BLUEPRINT_EXTENTS','export type BlueprintFrame150='):
    if a not in b:raise RuntimeError(f'163: snapshot prerequisite missing: {a}')
for a in ('STROM162_EXACT_RENDERED_BLUEPRINT_RETURN','STROM156_BLUEPRINT_CAMERA_CENTER',
          'STROM150N_NO_END_JUMP','running.viewOffset156','notifyEnterReady150()',
          "running.kind === 'entry' && running.phase === 'prepare'"):
    if a not in f:raise RuntimeError(f'163: camera prerequisite missing: {a}')
if 'STROM163_BLUEPRINT_VIEWPORT_TRUTH' in f or 'viewport163' in b:
    raise RuntimeError('163: already installed')

# The viewport and SVG transform MUST come from the same frame/click.
frame_re=re.compile(r'(?m)^(export type BlueprintFrame150=\{)([^\n]*)(\})$')
marks=list(frame_re.finditer(b))
if len(marks)!=1: raise RuntimeError(f'163: expected one BlueprintFrame150 type; found {len(marks)}')
m=marks[0]
if 'screen150o?' not in m.group(2):raise RuntimeError('163: click-time screen matrix unavailable')
b=b[:m.start()]+m.group(1)+m.group(2)+';viewport163?:{left:number;top:number;width:number;height:number}'+m.group(3)+b[m.end():]
anchor='    if(svg&&matrix&&rect&&rect.width>30&&rect.height>30){'
if b.count(anchor)!=1:raise RuntimeError(f'163: click geometry anchor count = {b.count(anchor)}')
b=b.replace(anchor,anchor+'''
      // STROM163_BLUEPRINT_VIEWPORT_TRUTH: one atomic, before-navigation capture.
      // The 3D Canvas can occupy a different rectangle AFTER mounting.
      result.viewport163={left:rect.left,top:rect.top,width:rect.width,height:rect.height}
''',1)

# Inject at the LAST preparatory point immediately before the fade phase;
# this supersedes all earlier 154/156 estimates without changing choreography.
imp="import { alignViewportExactly163 } from './cameraViewportExact163' // STROM163_BLUEPRINT_VIEWPORT_TRUTH"
import_anchor="import { alignBlueprintCenter156,applyViewOffset156,clearViewOffset156,type ViewOffset156 } from './cameraBlueprintCenter156' // STROM156_BLUEPRINT_CAMERA_CENTER"
if f.count(import_anchor)!=1: raise RuntimeError('163: 156 import has unexpected structure')
f=f.replace(import_anchor,import_anchor+'\n'+imp,1)
pat=re.compile(r'(?m)^(?P<indent>[ \t]*)running\.phase\s*=\s*[\'\"]fade[\'\"]\s*;?[ \t]*$')
found=list(pat.finditer(f))
if len(found)!=1:raise RuntimeError(f'163: expected one prepared->fade transition, found {len(found)}')
m=found[0]
indent=m.group('indent')
pre='''// STROM163_BLUEPRINT_VIEWPORT_TRUTH: direct camera over the CURRENT
// Blueprint viewport centre. Override both earlier 154/156 estimates.
// Never recalculate this during the fade or flight.
const exact163=alignViewportExactly163(state.scene,camera,state.gl.domElement,
  running.start,currentFrame150(),pose=>apply(camera,pose))
if(exact163)running.viewOffset156=exact163
'''
insert=''.join(indent+line+'\n' for line in pre.splitlines())
f=f[:m.start()]+insert+f[m.start():]
if len(re.findall(r'\buseFrame\s*\(',f))!=1:raise RuntimeError('163: second camera driver detected')
if f.count('alignViewportExactly163(')!=1:raise RuntimeError('163: multiple viewport fitting calls')
if f.index('alignViewportExactly163(')>f.index("running.phase = 'fade'"):
    raise RuntimeError('163: fit must precede fade')
for required in ['interpolateLens162(camera,returnLens162.current.from,returnLens162.current.to,k)',
                 'returnHold162.current += 1', 'STROM150N_NO_END_JUMP']:
    if required not in f:raise RuntimeError(f'163: missing existing return invariant {required}')
# Write only after all assertions succeed.
new=Path(__file__).with_name('cameraViewportExact163.ts').read_text('utf8')
helper.write_text(new,'utf8')
bridge.write_text(b,'utf8')
flight.write_text(f,'utf8')
print('PASS 163: same-click viewport and SVG matrix; exactly centred vertical 3D camera, height and off-axis pixel registration')
STROM163_PATCH
cat > "$RESOURCE_DIR/cameraViewportExact163.ts" <<'STROM163_TS'
import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'
import type { ViewOffset156 } from './cameraBlueprintCenter156'

/** STROM163_BLUEPRINT_VIEWPORT_TRUTH
 * Source of truth: Blueprint SVG screen matrix + the visible Blueprint viewport
 * sampled in the SAME click handler, before React changes the layout.
 * Architecture: X=width, Y=depth, Z=height; Three: X, Z, Y.
 */
type Screen163 = {x:number;y:number;ax:number;ay:number;bx:number;by:number}
type Rect163 = {left:number;top:number;width:number;height:number}
type Pose163 = {
  position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;
  up:THREE.Vector3;zoom:number
}
type ViewCamera163 = THREE.PerspectiveCamera | THREE.OrthographicCamera
const good163=(v:number)=>Number.isFinite(v)
const distance163=(a:{x:number;y:number},b:{x:number;y:number})=>Math.hypot(a.x-b.x,a.y-b.y)

export function viewportMath163(screen:Screen163,viewport:Rect163,canvas:Rect163){
  const vals=[screen.x,screen.y,screen.ax,screen.ay,screen.bx,screen.by,
    viewport.left,viewport.top,viewport.width,viewport.height,
    canvas.left,canvas.top,canvas.width,canvas.height]
  if(!vals.every(good163)||viewport.width<30||viewport.height<30||canvas.width<30||canvas.height<30)
    return null
  const det=screen.ax*screen.by-screen.ay*screen.bx
  if(!(det>1e-7))return null
  const bpCx=viewport.left+viewport.width/2
  const bpCy=viewport.top+viewport.height/2
  const dx=bpCx-screen.x,dy=bpCy-screen.y
  const center={x:(screen.by*dx-screen.bx*dy)/det,y:(-screen.ay*dx+screen.ax*dy)/det}
  const sx=Math.hypot(screen.ax,screen.ay),sy=Math.hypot(screen.bx,screen.by)
  if(!(sx>0.1&&sy>0.1))return null
  return {center,viewportCenterPx:{x:bpCx,y:bpCy},
    canvasCenterPx:{x:canvas.left+canvas.width/2,y:canvas.top+canvas.height/2},
    svgPixelsPerM:{x:sx,y:sy},
    desiredZero:{x:screen.x,y:screen.y},
    desiredX:{x:screen.x+screen.ax,y:screen.y+screen.ay},
    desiredY:{x:screen.x+screen.bx,y:screen.y+screen.by}}
}
function viewCamera163(camera:THREE.Camera):ViewCamera163|null {
  const p=camera as THREE.PerspectiveCamera
  if(p.isPerspectiveCamera)return p
  const o=camera as THREE.OrthographicCamera
  return o.isOrthographicCamera?o:null
}
function project163(world:THREE.Vector3,camera:THREE.Camera,rect:Rect163){
  camera.updateMatrixWorld(true)
  const v=world.clone().project(camera)
  return {x:rect.left+rect.width*(v.x+1)/2,
    y:rect.top+rect.height*(1-v.y)/2}
}

/** Run only once, hidden behind the spinner, on the actual R3F camera. */
export function alignViewportExactly163<T extends Pose163>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:T,frame:BlueprintFrame150|null,apply:(p:T)=>void,
):ViewOffset156|null {
  const cam=viewCamera163(camera)
  const isPerspective163=(cam as THREE.PerspectiveCamera | null)?.isPerspectiveCamera===true
  const bp=frame?.screen150o
  const viewport=frame?.viewport163
  if(!cam||!bp||!viewport){
    console.warn('[Strom 163] Click-time Blueprint viewport/matrix missing; preserving previous calibration')
    return null
  }
  const rect=canvas.getBoundingClientRect()
  const math=viewportMath163(bp,viewport,rect)
  if(!math){console.warn('[Strom 163] Invalid Blueprint/Canvas transformation');return null}
  const original={position:pose.position.clone(),target:pose.target.clone(),
    rotation:pose.rotation.clone(),up:pose.up.clone(),zoom:pose.zoom}
  const oldView=cam.view?.enabled?{fullWidth:cam.view.fullWidth,fullHeight:cam.view.fullHeight,
    offsetX:cam.view.offsetX,offsetY:cam.view.offsetY,width:cam.view.width,height:cam.view.height}:null
  const oldAspect=isPerspective163?(cam as THREE.PerspectiveCamera).aspect:null
  try {
    // Same REAL model transform as the floor slabs (150r). Do NOT set Y=0:
    // upper/lower floors must be calibrated at their real elevation.
    scene.updateMatrixWorld(true)
    let marker:THREE.Object3D|null=null
    scene.traverse(obj=>{
      if(!marker&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
    })
    const m=marker?(marker as THREE.Object3D).matrixWorld.clone():new THREE.Matrix4()
    const world=(x:number,y:number)=>new THREE.Vector3(x,0,y).applyMatrix4(m)
    const origin=world(0,0),wx=world(1,0),wy=world(0,1)
    const center=world(math.center.x,math.center.y)
    if(![origin.x,origin.y,origin.z,center.x,center.y,center.z].every(good163))
      throw Error('Invalid 3D floor/coordinate matrix')
    cam.clearViewOffset()
    if(isPerspective163){
      const p=cam as THREE.PerspectiveCamera
      const aspect=rect.width/rect.height
      if(Math.abs(p.aspect-aspect)>1e-7){p.aspect=aspect;p.updateProjectionMatrix()}
    }
    // Enforce exactly vertical optical axis, retaining the already-correct
    // rotation around that axis (Blueprint landscape/portrait orientation).
    const right=new THREE.Vector3(1,0,0).applyQuaternion(pose.rotation)
    right.y=0
    if(right.lengthSq()<1e-10)right.set(1,0,0)
    right.normalize()
    const back=new THREE.Vector3(0,1,0)
    const up=new THREE.Vector3().crossVectors(back,right).normalize()
    pose.rotation.setFromRotationMatrix(new THREE.Matrix4().makeBasis(right,up,back))
    pose.up.copy(up)
    pose.target.copy(center)
    pose.position.x=center.x
    pose.position.z=center.z

    const sx=math.svgPixelsPerM.x / Math.hypot(wx.x-origin.x,wx.z-origin.z)
    const sy=math.svgPixelsPerM.y / Math.hypot(wy.x-origin.x,wy.z-origin.z)
    if(!(sx>0&&sy>0&&good163(sx)&&good163(sy)))throw Error('Invalid model metre scale')
    const ppm=(sx+sy)/2
    if(isPerspective163){
      const p=cam as THREE.PerspectiveCamera
      const focal=p.projectionMatrix.elements[5]
      if(!(focal>0&&good163(focal)))throw Error('Invalid camera FOV')
      const height=rect.height*focal/(2*ppm)
      if(!(height>0.1&&height<1e6))throw Error('Invalid calibrated height')
      pose.position.y=center.y+height
    }else{
      const o=cam as THREE.OrthographicCamera
      const span=Math.abs(o.top-o.bottom)
      if(!(span>0))throw Error('Invalid orthographic span')
      pose.zoom=ppm*span/rect.height
      pose.position.y=center.y+Math.max(10,Math.abs(original.position.y-center.y))
    }
    apply(pose)

    // Solve SCALE from both exact projected world-space basis vectors; never
    // infer scale from model bounds or the camera's pre-switch zoom.
    for(let i=0;i<5;i++){
      const p0=project163(origin,camera,rect),px=project163(wx,camera,rect),py=project163(wy,camera,rect)
      const px0={x:px.x-p0.x,y:px.y-p0.y},py0={x:py.x-p0.x,y:py.y-p0.y}
      const bx={x:math.desiredX.x-math.desiredZero.x,y:math.desiredX.y-math.desiredZero.y}
      const by={x:math.desiredY.x-math.desiredZero.x,y:math.desiredY.y-math.desiredZero.y}
      const den=px0.x*px0.x+px0.y*px0.y+py0.x*py0.x+py0.y*py0.y
      const ratio=(px0.x*bx.x+px0.y*bx.y+py0.x*by.x+py0.y*by.y)/den
      if(!(den>1e-8&&ratio>0.05&&ratio<20&&good163(ratio)))
        throw Error('3D axes orientation incompatible with Blueprint; cannot align by height')
      if(Math.abs(ratio-1)<1e-9)break
      if(isPerspective163)pose.position.y=center.y+(pose.position.y-center.y)/ratio
      else pose.zoom*=ratio
      apply(pose)
    }
    // Solve TRANSLATION in the projection (not in the physical camera). The
    // physical camera stays above the Blueprint viewport world-space centre.
    const p0=project163(origin,camera,rect)
    const offset:ViewOffset156={x:p0.x-math.desiredZero.x,y:p0.y-math.desiredZero.y,
      width:rect.width,height:rect.height}
    if(![offset.x,offset.y].every(good163)||Math.abs(offset.x)>rect.width*4||Math.abs(offset.y)>rect.height*4)
      throw Error('3D viewport principal point offset outside limits')
    cam.setViewOffset(offset.width,offset.height,offset.x,offset.y,offset.width,offset.height)
    const actual0=project163(origin,camera,rect),actualX=project163(wx,camera,rect),actualY=project163(wy,camera,rect)
    const maxErrorPx=Math.max(distance163(actual0,math.desiredZero),
      distance163(actualX,math.desiredX),distance163(actualY,math.desiredY))
    if(!(maxErrorPx<=0.75))throw Error(`Cannot align axes: ${maxErrorPx.toFixed(2)}px`)
    const data={version:163,reference:'Blueprint viewport at click',
      blueprintViewport:viewport,threeViewport:{left:rect.left,top:rect.top,width:rect.width,height:rect.height},
      blueprintCenter:math.center,physicalCamera:{x:pose.position.x,y:pose.position.z,z:pose.position.y},
      planeZ:center.y,cameraHeightOverPlane:pose.position.y-center.y,
      lensOffsetPx:{x:offset.x,y:offset.y},gridErrorPx:maxErrorPx}
    try{window.localStorage.setItem('strom.camera163.alignment',JSON.stringify(data))}catch{/* optional */}
    console.info('[Strom 163] Camera exactly above BP viewport centre; axes matched',data)
    return offset
  }catch(error){
    pose.position.copy(original.position);pose.rotation.copy(original.rotation)
    pose.target.copy(original.target);pose.up.copy(original.up);pose.zoom=original.zoom
    cam.clearViewOffset()
    if(oldAspect!==null&&isPerspective163){
      (cam as THREE.PerspectiveCamera).aspect=oldAspect;cam.updateProjectionMatrix()
    }
    if(oldView)cam.setViewOffset(oldView.fullWidth,oldView.fullHeight,
      oldView.offsetX,oldView.offsetY,oldView.width,oldView.height)
    apply(pose)
    console.warn('[Strom 163] Exact viewport fit rejected; old pose restored',error)
    return null
  }
}
STROM163_TS
cat > "$RESOURCE_DIR/test163.cjs" <<'STROM163_TEST'
'use strict'
const fs=require('fs'),assert=require('assert'),ts=require(process.env.STROM163_TS||'typescript'),path=require('path')
const root=process.env.STROM163_SOURCE
const f=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const b=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const s=fs.readFileSync(path.join(root,'components/cameraViewportExact163.ts'),'utf8')
for (const [name,code,kind] of [['CameraFlight150.tsx',f,ts.ScriptKind.TSX],['cameraTransitions150.ts',b,ts.ScriptKind.TS],['cameraViewportExact163.ts',s,ts.ScriptKind.TS]]){
 const ast=ts.createSourceFile(name,code,ts.ScriptTarget.Latest,true,kind)
 assert.equal(ast.parseDiagnostics.length,0,`${name}: ${ast.parseDiagnostics.map(d=>d.messageText).join('; ')}`)
}
for(const x of ['STROM163_BLUEPRINT_VIEWPORT_TRUTH','viewport163','alignViewportExactly163('])assert(f.includes(x)||b.includes(x),x)
assert(f.indexOf('alignViewportExactly163(')<f.indexOf("running.phase = 'fade'"))
assert.equal((f.match(/\buseFrame\s*\(/g)||[]).length,1)
assert(f.includes('STROM162_EXACT_RENDERED_BLUEPRINT_RETURN'))
assert(f.includes('returnHold162.current += 1'))
assert(f.includes('interpolateLens162(camera,returnLens162.current.from,returnLens162.current.to,k)'))
assert(b.includes('result.viewport163={left:rect.left,top:rect.top,width:rect.width,height:rect.height}'))

class Vec{
 constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}
 set(x,y,z){this.x=x;this.y=y;this.z=z;return this}
 clone(){return new Vec(this.x,this.y,this.z)}
 copy(v){this.x=v.x;this.y=v.y;this.z=v.z;return this}
 normalize(){const length=Math.sqrt(this.lengthSq())||1;this.x/=length;this.y/=length;this.z/=length;return this}
 lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z}
 crossVectors(a,b){this.set(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x);return this}
 applyQuaternion(){return this}
 applyMatrix4(m){const [sx,sy,sz,tx,ty,tz]=m._args;this.x=this.x*sx+tx;this.y=this.y*sy+ty;this.z=this.z*sz+tz;return this}
 project(cam){let ppm=cam.kind==='perspective'?cam.canvasRect.height*cam.projectionMatrix.elements[5]/(2*(cam.position.y-this.y)):
    cam.canvasRect.height*cam.zoom/Math.abs(cam.top-cam.bottom)
  const cx=cam.canvasRect.left+cam.canvasRect.width/2,cy=cam.canvasRect.top+cam.canvasRect.height/2
  const x=cx+(this.x-cam.position.x)*ppm-(cam.view?.enabled?cam.view.offsetX:0)
  const y=cy+(this.z-cam.position.z)*ppm-(cam.view?.enabled?cam.view.offsetY:0)
  this.x=(x-cx)*2/cam.canvasRect.width;this.y=(cy-y)*2/cam.canvasRect.height;this.z=0
  return this
 }
}
class Q{clone(){return new Q()}copy(){return this}setFromRotationMatrix(){return this}}
class M{constructor(args=[1,1,1,0,0,0]){this._args=args}clone(){return new M(this._args.slice())}makeBasis(){return this}}
const log=[]
const localStorage={setItem(k,v){log.push([k,JSON.parse(v)])}}
const comp=ts.transpileModule(s,{fileName:'cameraViewportExact163.ts',compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}})
const modExports={}
new Function('require','module','exports','console','window',comp.outputText)(name=>{
  if(name==='three')return {Matrix4:M,Vector3:Vec}
  throw Error(name)
},{exports:modExports},modExports,{warn:(...x)=>{throw Error(x.map(String).join(' '))},info(){}},{localStorage})
const {viewportMath163,alignViewportExactly163}=modExports
const norm=(a,b)=>Math.abs(a-b)<1e-6
function run({name,px=80,c={x:5.96,y:3.849},vp={left:300,top:220,width:1600,height:980},
 cv={left:370,top:85,width:1280,height:1120},planeY=0,modelScale=1,worldX=0,worldZ=0,kind='perspective'}) {
 const bpCenter={x:vp.left+vp.width/2,y:vp.top+vp.height/2}
 const snap={x:bpCenter.x-px*c.x,y:bpCenter.y-px*c.y,ax:px,ay:0,bx:0,by:px}
 const math=viewportMath163(snap,vp,cv)
 assert(math&&norm(math.center.x,c.x)&&norm(math.center.y,c.y),name+' viewport world centre')
 const cam={kind,canvasRect:cv,position:new Vec(2,30,2),view:null,
   projectionMatrix:{elements:[0,0,0,0,0,2.414,0,0,0,0,0,0,0,0,0,0]},
   aspect:cv.width/cv.height,zoom:1.15,top:10,bottom:-10,
   isPerspectiveCamera:kind==='perspective',isOrthographicCamera:kind==='orthographic',
   updateProjectionMatrix(){},updateMatrixWorld(){},
   clearViewOffset(){this.view=null},
   setViewOffset(fullWidth,fullHeight,offsetX,offsetY,width,height){this.view={enabled:true,fullWidth,fullHeight,offsetX,offsetY,width,height}},
 }
 const marker={name:'strom150r-floor-reference',userData:{active150r:true},matrixWorld:new M([modelScale,1,modelScale,worldX,planeY,worldZ])}
 const scene={updateMatrixWorld(){},traverse(f){f(marker)}}
 const pose={position:new Vec(2,25,2),target:new Vec(),up:new Vec(0,0,-1),rotation:new Q(),zoom:1.15}
 const canvas={getBoundingClientRect(){return cv}}
 function apply(p){cam.position.copy(p.position);cam.zoom=p.zoom}
 const view=alignViewportExactly163(scene,cam,canvas,pose,{screen150o:snap,viewport163:vp},apply)
 assert(view,name+' view calibration returned null')
 const expectedX=worldX+modelScale*c.x,expectedZ=worldZ+modelScale*c.y
 assert(norm(pose.position.x,expectedX)&&norm(pose.position.z,expectedZ),name+' camera physical centre')
 assert(norm(pose.target.x,expectedX)&&norm(pose.target.z,expectedZ),name+' camera target centre')
 assert(pose.position.y>planeY&&Math.abs(pose.target.y-planeY)<1e-10,name+' vertical position')
 const last=log.at(-1)[1]
 assert(last.gridErrorPx<0.0001,name+' full-grid reprojection '+last.gridErrorPx)
 assert(norm(last.physicalCamera.z,pose.position.y),name+' architecture z=Three y')
 assert(norm(view.x,cv.left+cv.width/2-bpCenter.x),name+' real CSS viewport offset x')
 assert(norm(view.y,cv.top+cv.height/2-bpCenter.y),name+' real CSS viewport offset y')
 console.log('PASS 163:',name,'camera',last.physicalCamera,'lens',last.lensOffsetPx,'pixel error',last.gridErrorPx)
}
run({name:'actual example 5.960 / 3.849 zoom=80'})
run({name:'zoomed-out 39 px/m',px:39,vp:{left:75,top:160,width:1400,height:710},cv:{left:235,top:53,width:1000,height:890},c:{x:-12.25,y:8.45}})
run({name:'zoomed-in 220 px/m pan',px:220,vp:{left:5,top:320,width:2220,height:910},cv:{left:280,top:128,width:1670,height:1130},c:{x:24.1,y:-19.2}})
run({name:'positive floor elevation 6.3m',planeY:6.3,modelScale:1.25,worldX:1.2,worldZ:-3.4})
run({name:'negative floor elevation -2m',planeY:-2,px:65})
run({name:'orthographic camera',kind:'orthographic',px:115,planeY:3})
console.log('PASS 163: TSX/TS parse, one driver, six exact viewport + zoom + floor elevation projection cases')
STROM163_TEST
log "3) Save click-time viewport; fit real 3D camera and projection ..."
python3 -m py_compile "$RESOURCE_DIR/patch163.py" >>"$DIAG_LOG" 2>&1 || fail "163 Python patch syntax error"
STROM163_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch163.py" >>"$DIAG_LOG" 2>&1 || \
  fail "163 source mismatch; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build BEFORE committing ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "163 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Regression: Blueprint zoom, pan, offsets, floor elevations, reverse driver ..."
STROM163_SOURCE="$WORK_DIR/frontend/src" STROM163_TS="$DEPENDENCIES/typescript" \
  node "$RESOURCE_DIR/test163.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "163 regression failed; GitHub and Stage unchanged"
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch163.py" "$WORK_DIR/deploy/updates/${SCRIPT_NAME}_patch.py"
cat > "$WORK_DIR/docs/STROM_UPDATE_163.md" <<'STROM163_DOC'
# Stromnetze 163: exakt zentrierte Blueprint-Kamera

## Geometrische Invariante
- Klickzeitpunkt: SVG-Screenmatrix und das **sichtbare Blueprint-Viewport-Rechteck**
  werden gemeinsam im selben `BlueprintFrame150` gespeichert. Keine veralteten
  localStorage-Viewportwerte oder Haus-Bounding-Box als Ersatz.
- Mittelpunkt: Mittelpunkt des sichtbaren Blueprint-Viewports, per invertierter
  SVG-Matrix in Blueprint-X/Y-Meter umgerechnet; dann mit realer Floor-
  `matrixWorld` in Three-Welt X/Z transformiert.
- Z: Kamera exakt senkrecht nach unten, ueber der echten aktiven Geschosshoehe;
  Kamera-Three-Y = Geschosshoehe + (proportional aus Zoom und FOV ermittelte Hoehe).
- Bildmassstab: 3D-Meterprojektion stimmt mit 1-m-Achsen der Blueprint-SVG-Matrix
  ueberein, unabhaengig von Zoom und Scrollposition.
- Canvas-Ausschnitt: 3D-Canvas ist oft ein anderes DOM-Rechteck; nur dessen
  zeitweiliger **off-axis lens shift** kompensiert den Pixelversatz. Die
  physikalische Kameraposition wird nicht zu diesem Zweck versetzt.
- Kontrolle: drei Basiswerte 0/0, X+1, Y+1 im selben Browser-CSS-Pixelraum;
  nur akzeptiert, wenn max. Fehler <= 0,75 CSS-Pixel.
- Rueckflug benutzt weiterhin den gespeicherten tatsaechlich sichtbaren
  Hinflug-Startzustand aus Patch 162 und wird nicht neu implementiert.
- Animation, Achsenfarben, Slider, UI und Zeitwerte bleiben erhalten.
- Deployment nur nach `/var/www/strom-test/`, Produktion `/strom/` unveraendert.

Browserdiagnose: `localStorage['strom.camera163.alignment']`.
STROM163_DOC
rm -rf "$RESOURCE_DIR"
log "6) Synchronize verified source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "163 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "7) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "163 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "163 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "163 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 163 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
