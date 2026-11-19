#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119_158b_rueckflug_blueprint_blende_fix"
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
COMMIT_MESSAGE="Update 158b: repair reverse Blueprint transition patch"
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
  echo "158 in isoliertem Git-Checkout anwenden und pruefen ..."
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

log "=== STROM 158b: korrigierter Rueckflug, Rasterpruefung und Blende ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
FLIGHT="$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"
DIAG="$STAGE_DIR/frontend/src/components/cameraHandoffDiagnostics155.ts"
[ -s "$FLIGHT" ] || fail "CameraFlight150.tsx fehlt"
[ -s "$DIAG" ] || fail "cameraHandoffDiagnostics155.ts fehlt"
grep -Fq 'STROM156_BLUEPRINT_CAMERA_CENTER' "$FLIGHT" || fail "Voraussetzung: erfolgreiches Update 156 fehlt"
grep -Fq 'STROM157_OPTICAL_AXIS_TO_EYE' "$DIAG" || fail "Voraussetzung: erfolgreiches Update 157 fehlt"
if grep -Fq 'STROM158_REVERSE_EXACT' "$FLIGHT"; then fail "158 ist bereits installiert"; fi
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

log "3) Kamera-Rueckflug, Rasterpruefung und Blende transaktional patchen ..."
cat > "$WORK_DIR/patch158.py" <<'STROM158_PY'
#!/usr/bin/env python3
"""Versioned, strictly anchored source patch for Stormnetze transition 158."""
from pathlib import Path
import os
import re

root = Path(os.environ['STROM158_ROOT'])
files = {name:root / 'frontend/src' / rel for name,rel in {
    'flight':'components/CameraFlight150.tsx',
    'transitions':'components/cameraTransitions150.ts',
    'app':'App.tsx',
    'css':'styles.css',
}.items()}
s = {name:path.read_text('utf8') for name,path in files.items()}
if any('STROM158_REVERSE_EXACT' in body for body in s.values()):
    raise RuntimeError('158 already applied: aborting without changes')

def rep(name,old,new,label):
    """One strictly unique semantic anchor; tolerate indentation-only drift."""
    body=s[name]
    count=body.count(old)
    if count==1:
        s[name]=body.replace(old,new,1)
        return
    if count==0 and '\n' in old:
        # Different source formatting must not cause a false negative. Require
        # *every* nonempty content line in its original order, and a UNIQUE match.
        src_lines=old.splitlines()
        pattern=r'(?m)^[ \t]*'+r'\r?\n[ \t]*'.join(re.escape(v.lstrip(' \t')) for v in src_lines)
        matches=list(re.finditer(pattern,body))
        if len(matches)==1:
            m=matches[0]
            s[name]=body[:m.start()]+new+body[m.end():]
            print(f'158b {name}: format-tolerant unique match: {label}')
            return
        count=len(matches)
    raise RuntimeError(f'{name} {label}: expected exactly one anchored occurrence, got {count}; anchor {old[:180]!r}')

# Preserve blueprint's pre-navigation layout for its later re-mounted fade overlay.
rep('transitions',
  'export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number;screen150o?:BlueprintScreen150o}',
  'export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number;screen150o?:BlueprintScreen150o;layout150o?:{left:number;top:number;width:number;height:number}}',
  'store original Blueprint layout')
rep('transitions',
  'export const DURATION150=5000',
  'export const DURATION150=5000\n/** STROM158_REVERSE_EXACT: fade begins only after 5s reverse flight finishes. */\nexport const EXIT_FADE158=5000',
  'reverse fade duration')
# Snapshot the original Blueprint DOM placement once, immediately before
# the real line which persists --strom150o-left; do NOT depend on indentation.
trans=s['transitions']
needle="plan.style.setProperty('--strom150o-left',`${planRect.left-hostRect.left}px`)"
if trans.count(needle)!=1:
    raise RuntimeError(f'transitions retain original layout: --strom150o-left line not unique (found {trans.count(needle)})')
line_pattern=re.compile(r'(?m)^([ \t]*)'+re.escape(needle)+r'[ \t]*$')
match=line_pattern.search(trans)
if not match:
    raise RuntimeError('transitions retain original layout: anchor is not at start of a source line')
context=trans[max(0,match.start()-420):match.start()]
if not re.search(r'if\s*\(\s*plan\s*&&\s*planRect\s*&&\s*hostRect',context):
    raise RuntimeError('transitions retain original layout: unexpected surrounding condition')
indent=match.group(1)
insert=(indent+'result.layout150o={left:planRect.left-hostRect.left,top:planRect.top-hostRect.top,\n'
        +indent+'  width:planRect.width,height:planRect.height}\n')
s['transitions']=trans[:match.start()]+insert+trans[match.start():]
print('158b transitions: captured original layout before DOM reflow')

# Reverse the exact interpolant and calibrated pixel-perfect camera end-pose.
rep('flight',
  '''type CameraPose = {
  position: THREE.Vector3
  rotation: THREE.Quaternion
  target: THREE.Vector3
  up: THREE.Vector3
  zoom: number
}''',
  '''type CameraPose = {
  position: THREE.Vector3
  rotation: THREE.Quaternion
  target: THREE.Vector3
  up: THREE.Vector3
  zoom: number
}
// STROM158_REVERSE_EXACT: reuse the calibrated Blueprint pose from the entry.
function clonePose158(p:CameraPose):CameraPose{
  return {position:p.position.clone(),rotation:p.rotation.clone(),
    target:p.target.clone(),up:p.up.clone(),zoom:p.zoom}
}
/** Check all three canonical world-grid anchors at the reverse endpoint.
 * No guess-based model or Blueprint shifts. Measurements are in CSS pixels. */
function checkReverseAxes158(scene:THREE.Object3D,camera:THREE.Camera,
  canvas:HTMLCanvasElement,frame:BlueprintFrame150|null):void{
  const b=frame?.screen150o
  if(!b)return
  const rect=canvas.getBoundingClientRect()
  if(!(rect.width>20&&rect.height>20))return
  scene.updateMatrixWorld(true)
  let marker:THREE.Object3D|null=null
  scene.traverse(obj=>{
    if(!marker&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
  })
  const matrix=marker?(marker as THREE.Object3D).matrixWorld.clone():new THREE.Matrix4()
  matrix.elements[13]=0
  camera.updateMatrixWorld(true)
  const compare=(x:number,y:number)=>{
    const point=new THREE.Vector3(x,0,y).applyMatrix4(matrix)
    point.y=0
    const projected=point.project(camera)
    const sx=rect.left+(projected.x+1)*rect.width/2
    const sy=rect.top+(1-projected.y)*rect.height/2
    const bx=b.x+b.ax*x+b.bx*y,by=b.y+b.ay*x+b.by*y
    return Math.hypot(sx-bx,sy-by)
  }
  const zero=compare(0,0),x1=compare(1,0),y1=compare(0,1)
  const toEye=camera.getWorldDirection(new THREE.Vector3()).negate().normalize()
  const verticalError=Math.hypot(toEye.x,toEye.z)
  const result={version:158,phase:'3D -> Blueprint, end of 5s reverse flight',
    gridErrorPx:{zero,x1,y1,max:Math.max(zero,x1,y1)},
    normalToEyeXYZ:{x:toEye.x,y:toEye.z,z:toEye.y},
    perpendicularError:verticalError,
    canvas:{left:rect.left,top:rect.top,width:rect.width,height:rect.height}}
  try{window.localStorage.setItem('strom.camera158.returnAlignment',JSON.stringify(result))}catch{/* optional */}
  console.info('[STROM 158] Exit frame grid/axes (0,0), (+1,0), (0,+1)',result)
  if(result.gridErrorPx.max>0.5||verticalError>1e-4)
    console.warn('[STROM 158] Screen/grid or normal mismatch at Blueprint return',result)
}''',
  'calibration check function')
rep('flight',
  '''  const pointsRef = useRef(points)
  pointsRef.current = points''',
  '''  const pointsRef = useRef(points)
  const exactOverhead158=useRef<{pose:CameraPose;offset?:ViewOffset156}|null>(null)
  pointsRef.current = points''',
  'retain matched entry endpoint')
rep('flight',
  '''      flight.current = null
      unlock()
      // Never leave off-axis camera projection behind after unmount.''',
  '''      flight.current = null
      exactOverhead158.current = null
      unlock()
      // Never leave off-axis camera projection behind after unmount.''',
  'clear captured pose on unmount')
rep('flight',
  '''    // Preserve the existing reverse-flight implementation for a separate update.
    if (requestedExit.current) {
      const finish = requestedExit.current
      requestedExit.current = null
      pending.current = null
      const original = capture(camera, control)
      const top = overheadPose(camera, pointsRef.current, currentFrame150(), aspect,
        original.target.y, state.gl.domElement)
      lock()
      flight.current = {
        kind: 'exit', phase: 'flight', start: original, end: top,
        startedAt: performance.now(), steady: 0, settleFrames: 0, preparedFrames: 0,
        finish,
      }
    }''',
  '''    // STROM158_REVERSE_EXACT: reverse the actual calibrated entry pose,
    // rather than constructing an uncalibrated overhead approximation.
    if (requestedExit.current) {
      const finish = requestedExit.current
      requestedExit.current = null
      pending.current = null
      const original = capture(camera, control)
      const matched=exactOverhead158.current
      const top=matched?clonePose158(matched.pose):overheadPose(
        camera,pointsRef.current,currentFrame150(),aspect,
        original.target.y,state.gl.domElement)
      let offset=matched?.offset?{...matched.offset}:undefined
      lock()
      // Re-check the canonical BP 0/+1 m axes against the currently mounted scene
      // before moving; never change the Blueprint model, axes or grid data.
      const frame=currentFrame150()
      if(frame?.screen150o){
        clearViewOffset156(camera)
        apply(camera,top)
        try{
          const aligned=alignBlueprintGrid154(state.scene,camera,state.gl.domElement,
            top,frame,pose=>apply(camera,pose))
          if(aligned){
            offset=alignBlueprintCenter156(state.scene,camera,state.gl.domElement,
              top,frame,pose=>apply(camera,pose))||undefined
          }
        }catch(error){console.warn('[STROM 158] Reverse grid fit skipped',error)}
        clearViewOffset156(camera)
        apply(camera,original)
      }
      flight.current = {
        kind: 'exit', phase: 'flight', start: original, end: top,
        startedAt: performance.now(), steady: 0, settleFrames: 0, preparedFrames: 0,
        viewOffset156:offset,finish,
      }
    }''',
  'replace old reverse flight')
rep('flight',
  '''        apply(camera,running.start)
        running.phase = 'fade'
        running.startedAt = performance.now() + ENTER_FADE150''',
  '''        apply(camera,running.start)
        // Exact start is also the destination of the reverse journey.
        exactOverhead158.current={pose:clonePose158(running.start),
          offset:running.viewOffset156?{...running.viewOffset156}:undefined}
        running.phase = 'fade'
        running.startedAt = performance.now() + ENTER_FADE150''',
  'save calibrated starting pose after 154 and 156')
rep('flight',
  '''    const k = easeOut(t)
    const a = running.start, b = running.end''',
  '''    // Inverse temporal path: forward easeOut(s)=1-(1-s)^3,
    // reverse progress=1-easeOut(1-t)=t^3. No camera jumps.
    const k = running.kind==='exit'?t*t*t:easeOut(t)
    const a = running.start, b = running.end''',
  'inverse easing')
rep('flight',
  '''    // Ease the compensating lens offset to zero together with the camera.
    // At the exact final frame the native, unshifted 3D camera is restored.
    if(running.kind==='entry'&&running.viewOffset156)
      applyViewOffset156(camera,running.viewOffset156,1-k)''',
  '''    // Entry: shifted -> unshifted; reverse: unshifted -> the same shifted BP view.
    if(running.viewOffset156)
      applyViewOffset156(camera,running.viewOffset156,
        running.kind==='entry'?1-k:k)''',
  'inverse principal-point compensation')
rep('flight',
  '''    if(running.kind==='entry'&&running.viewOffset156)clearViewOffset156(camera)
    flight.current = null
    if (running.kind === 'exit') {
      running.finish?.()
      return
    }
    unlock()''',
  '''    if(running.kind==='entry'&&running.viewOffset156)clearViewOffset156(camera)
    // The exit must remain overhead with the calibrated BP lens shift until
    // the *subsequent* 5-second Blueprint cross-fade has finished.
    if(running.kind==='exit'){
      if(running.viewOffset156)applyViewOffset156(camera,running.viewOffset156,1)
      // Independent measured floor-outline extrema, so the screenshot's tiny
      // edge residual can be distinguished from axis and camera misalignment.
      try{
        const outline158=captureThreeFloorExtrema150q(pointsRef.current,camera,
          state.gl.domElement,0,floorWorldPoints150r(state.scene))
        if(outline158)window.localStorage.setItem('strom.camera158.returnFloor',JSON.stringify(outline158))
      }catch(error){console.warn('[STROM 158] Reverse floor-outline check skipped',error)}
      checkReverseAxes158(state.scene,camera,state.gl.domElement,currentFrame150())
    }
    flight.current = null
    if (running.kind === 'exit') {
      running.finish?.()
      return
    }
    unlock()''',
  'hold matched final view during fade')

# Cross-fade the original Blueprint DOM after the flight completes.
rep('app',
  "import {queueEntry150,requestExit150,registerEnterReady150,ENTER_FADE150} from './components/cameraTransitions150'",
  "import {queueEntry150,requestExit150,registerEnterReady150,ENTER_FADE150,EXIT_FADE158,currentFrame150} from './components/cameraTransitions150'",
  'App transition constants')
rep('app',
  'useEffect, useMemo, useRef, useState',
  'useEffect, useLayoutEffect, useMemo, useRef, useState',
  'layout effect hook')
rep('app',
  '''  const enterPreviewTimer150 = useRef<number|null>(null)''',
  '''  const enterPreviewTimer150 = useRef<number|null>(null)
  // STROM158_REVERSE_EXACT: reverse flight then fade Blueprint in over still 3D.
  const [exitPreview158,setExitPreview158]=useState<'preparing'|'fading'|null>(null)
  const exitTimer158=useRef<number|null>(null)
  useLayoutEffect(()=>{
    if(!exitPreview158)return
    const layout=currentFrame150()?.layout150o
    const plan=document.querySelector('.workspace > .floorplan-layout') as HTMLElement|null
    if(!plan||!layout)return
    if(![layout.left,layout.top,layout.width,layout.height].every(Number.isFinite))return
    plan.classList.add('strom150o-viewport-frozen')
    plan.style.setProperty('--strom150o-left',`${layout.left}px`)
    plan.style.setProperty('--strom150o-top',`${layout.top}px`)
    plan.style.setProperty('--strom150o-width',`${layout.width}px`)
    plan.style.setProperty('--strom150o-height',`${layout.height}px`)
  },[exitPreview158])
  useEffect(()=>()=>{
    if(exitTimer158.current!==null)window.clearTimeout(exitTimer158.current)
  },[])''',
  'exit overlay state and frozen-layout rehydration')
rep('app',
  '''  function handleViewModeClick(mode: ViewMode) {
    if (!canUseViewMode(mode)) return''',
  '''  function handleViewModeClick(mode: ViewMode) {
    if(exitPreview158)return // prevent overlapping mode changes during reverse flight/fade
    if (!canUseViewMode(mode)) return''',
  'guard reverse transition')
rep('app',
  '''      if (requestExit150(() => setViewMode('floorplan'))) return''',
  '''      if(enterPreviewTimer150.current!==null){
        window.clearTimeout(enterPreviewTimer150.current)
        enterPreviewTimer150.current=null
      }
      setEnterPreview150(null)
      setExitPreview158('preparing')
      if (requestExit150(() => {
        // Called only when the 5-second reverse flight has reached the exact BP pose.
        setExitPreview158('fading')
        if(exitTimer158.current!==null)window.clearTimeout(exitTimer158.current)
        exitTimer158.current=window.setTimeout(()=>{
          exitTimer158.current=null
          setViewMode('floorplan')
          setExitPreview158(null)
        },EXIT_FADE158)
      }))return
      setExitPreview158(null)''',
  'hold fade until reverse flight ends')
rep('app',
  'className={`workspace ${enterPreview150 ? `strom150c-enter-${enterPreview150}` : ""}` }>',
  'className={`workspace ${enterPreview150 ? `strom150c-enter-${enterPreview150}` : ""}${exitPreview158 ? ` strom158-exit-${exitPreview158}` : ""}` }>',
  'exit fade class')
rep('app',
  "(enterPreview150 !== null && (viewMode === 'wall' || viewMode === 'threeD'))",
  "((enterPreview150 !== null || exitPreview158 !== null) && (viewMode === 'wall' || viewMode === 'threeD'))",
  'keep Blueprint DOM during exit')

s['css']+='''
/* STROM158_REVERSE_EXACT: identical Blueprint geometry, reverse camera movement,
   5s cross-fade ONLY AFTER the 5s reverse flight reaches its top-down endpoint. */
.workspace.strom158-exit-preparing,.workspace.strom158-exit-fading {
  position:relative; isolation:isolate;
}
.workspace.strom158-exit-preparing > .floorplan-layout,
.workspace.strom158-exit-fading > .floorplan-layout {
  position:absolute; inset:0; width:100%;height:100%;max-height:100%;overflow:hidden;
  z-index:15;pointer-events:none;opacity:0;
}
.workspace.strom158-exit-fading > .floorplan-layout {
  opacity:1; transition:opacity 5000ms ease;
}
/* The re-mounted Blueprint is frozen at exactly its pre-3D layout coordinates. */
.workspace.strom158-exit-preparing > .floorplan-layout.strom150o-viewport-frozen,
.workspace.strom158-exit-fading > .floorplan-layout.strom150o-viewport-frozen {
  inset:auto !important;
  left:var(--strom150o-left,0px) !important;
  top:var(--strom150o-top,0px) !important;
  right:auto !important;
  bottom:auto !important;
  width:var(--strom150o-width,100%) !important;
  min-width:0 !important;
  height:var(--strom150o-height,100%) !important;
  max-height:none !important;
}
'''

for name,path in files.items():
    path.write_text(s[name],encoding='utf8')
print('PASS 158: reverse exact calibrated camera and lens, +1m axis check, 5s reverse flight, 5s late Blueprint crossfade')
STROM158_PY
python3 -m py_compile "$WORK_DIR/patch158.py" >>"$DIAG_LOG" 2>&1 || fail "158 Python-Syntaxfehler"
STROM158_ROOT="$WORK_DIR" python3 "$WORK_DIR/patch158.py" >>"$DIAG_LOG" 2>&1 || fail "158 Quellcode-Anpassung fehlgeschlagen; Stage unveraendert"
rm -f "$WORK_DIR/patch158.py"

log "4) Vollstaendiger TypeScript-/Vite-Build ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "158 Frontend-Build fehlgeschlagen; Stage unveraendert"
log "5) Inverse Kamera-, Layout- und Crossfade-Regressionstests ..."
STROM158_SOURCE="$WORK_DIR/frontend/src" STROM158_THREE="$DEPENDENCIES/three" node <<'STROM158_TEST' >>"$DIAG_LOG" 2>&1 || fail "158 Regressionstest fehlgeschlagen; Stage unveraendert"
const fs=require('fs'),assert=require('assert')
const THREE=require(process.env.STROM158_THREE)
const root=process.env.STROM158_SOURCE
const f=fs.readFileSync(root+'/components/CameraFlight150.tsx','utf8')
const t=fs.readFileSync(root+'/components/cameraTransitions150.ts','utf8')
const a=fs.readFileSync(root+'/App.tsx','utf8')
const c=fs.readFileSync(root+'/styles.css','utf8')
const diag=fs.readFileSync(root+'/components/cameraHandoffDiagnostics155.ts','utf8')
assert(diag.includes('STROM157_OPTICAL_AXIS_TO_EYE'))
assert(f.includes('STROM158_REVERSE_EXACT'))
assert(f.includes('clonePose158(matched.pose)'))
assert(f.includes('alignBlueprintGrid154(state.scene,camera,state.gl.domElement'))
assert(f.includes('alignBlueprintCenter156(state.scene,camera,state.gl.domElement'))
assert(f.includes('exactOverhead158.current={pose:clonePose158(running.start)'))
assert(f.includes("running.kind==='exit'?t*t*t:easeOut(t)"))
assert(f.includes("running.kind==='entry'?1-k:k"))
assert(f.includes('checkReverseAxes158(state.scene,camera,state.gl.domElement,currentFrame150())'))
assert(f.includes("strom.camera158.returnFloor"))
assert(f.includes('if(running.viewOffset156)applyViewOffset156(camera,running.viewOffset156,1)'))
assert(t.includes('export const DURATION150=5000'))
assert(t.includes('export const EXIT_FADE158=5000'))
assert(t.includes('layout150o?:{left:number;top:number;width:number;height:number}'))
assert(a.includes("setExitPreview158('preparing')"))
assert(a.includes("setExitPreview158('fading')"))
assert(a.includes("setViewMode('floorplan')"))
assert(a.includes('},EXIT_FADE158)'))
assert(c.includes('.workspace.strom158-exit-fading > .floorplan-layout'))
assert(c.includes('opacity:1; transition:opacity 5000ms ease;'))
// Ensure the reverse temporal curve exactly retraces the 5-second forward curve.
const easeOut=t=>1-(1-t)**3
for(let i=0;i<=100;i++){
  const t=i/100
  const reverse=t*t*t
  assert(Math.abs(reverse-(1-easeOut(1-t)))<1e-12)
}
// Guarantee physical top-down normal +Z toward the eye, -Z toward the floor.
const camera=new THREE.PerspectiveCamera(48,1,0.1,1000)
camera.position.set(5.96,22.048,3.849)
camera.up.set(0,0,-1)
camera.lookAt(5.96,0,3.849)
const outward=camera.getWorldDirection(new THREE.Vector3()).negate()
assert(Math.abs(outward.x)<1e-10&&Math.abs(outward.z)<1e-10&&Math.abs(outward.y-1)<1e-10)
console.log('PASS 158: inverse easing, saved exact pose, inverse principal point, canonical axes, 5s+5s, 3D production untouched')
STROM158_TEST

mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_158.md" <<'STROM158_DOC'
# Stromnetze 158 - Rueckflug und exakte Blueprint-Blende

- Messung aus Screenshots: vor Wechsel gepruefte 3D-Bodengrenzen auf 0.0/0.1 CSS px an Blueprint-Bodengrenzen. Ein groesserer Versatz des sichtbaren Kontur-Overlays ist dadurch nicht belegt. Keine frei erfundenen globalen X/Y-Shifts!
- Den bereits auf X=0/Y=0 und +1m-Achsen kalibrierten Kamera-Startpunkt samt optischem ViewOffset aus dem Hinweg merken; Rueckflug an diesen Punkt.
- Vor dem Rueckflug Achsen/Raster gegen die damals wirklich sichtbare Blueprint-Matrix erneut kalibrieren. Keine Modelldaten, Grundrissachsen oder Grid-Geometrien umrechnen oder verschieben.
- Drei reale Projektionspunkte (0,0), (+1,0), (0,+1) und Senkrechtachse am Ende messen; Browser-Diagnose `strom.camera158.returnAlignment`.
- Rueckflug ueber 5000 ms mit Zeitinverse `t^3` der bestehenden Vorwaerts-Kurve `1-(1-t)^3`.
- Projektion umgekehrt animieren: ViewOffset 0 -> Originalwert, Kamera/Orbit-Target/Up/Zoom von aktueller 3D-Pose zum kalibrierten Blueprint-Punkt. Kamera blickt real entlang -Z des Plans; Achse zur Kamera +Z.
- Original-BP waehrend des Rueckflugs verdeckt wieder einblenden und auf die VOR dem Hinweg aufgenommene echte DOM-Position/-Groesse fixieren; erst nach 5000-ms-Rueckflug die Ueberblendung 5000 ms starten.
- 3D erst nach komplettem Crossfade demontieren, Blueprints danach regulär wieder editierbar.
- Nur /strom-test/ deployen; /strom/ bleibt unberuehrt. Vor Git-Push in isoliertem Checkout TypeScript/Vite-Build und Regressionstests.
STROM158_DOC

log "6) Gepruefte Quellen in Stage uebernehmen ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "158 Stage-Transfer fehlgeschlagen; Backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY - kein Web-Deployment"
  exit 0
fi
log "7) Stage bauen und ausschliesslich /strom-test/ bereitstellen ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "158 Stage-Build fehlgeschlagen; Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Frontend-Dist fehlt"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "158 Test-Deployment fehlgeschlagen; Backup: $BACKUP_DIR"
log "SUCCESS: 158 unter https://home.moja.de/strom-test/ installiert"
log "Produktion /strom/ unveraendert; Backup: $BACKUP_DIR"
