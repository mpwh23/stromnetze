#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1840_156_blueprint_mitte_kamera_viewport"
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
COMMIT_MESSAGE="Update 156: Blueprint-centred 3D camera and compensated projection during handoff"
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
  echo "2) Update 156 im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 156 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 156: real camera over Blueprint centre, no grid pixel shift ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/CameraFlight150.tsx \
  frontend/src/components/cameraTransitions150.ts \
  frontend/src/components/cameraGridAlignment154.ts \
  frontend/src/components/cameraHandoffDiagnostics155.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "156 required source missing: $file"
done
grep -Fq 'STROM150P_BLUEPRINT_EXTENTS' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "156 requires installed Blueprint viewport diagnostics 150p. No changes made."
grep -Fq 'STROM150Q_3D_FLOOR_EXTENTS' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "156 requires installed 3D floor diagnostics 150q. No changes made."
grep -Fq 'STROM154_GRID_PIXEL_ALIGNMENT' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "156 requires installed camera calibration 154. No changes made."
grep -Fq 'export const ENTER_FADE150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "156 requires existing 5s fade. No changes made."
grep -Fq 'export const DURATION150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "156 requires existing 5s flight. No changes made."
grep -Fq 'STROM155_CAMERA_VIEWPORT_DIAGNOSTICS' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "156 requires installed camera diagnostic 155. No changes made."
grep -Fq 'STROM154_GRID_PIXEL_ALIGNMENT' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "156 requires installed viewport calibration 154. No changes made."
if grep -Fq 'STROM156_BLUEPRINT_CAMERA_CENTER' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"; then
  fail "156 is already installed. No changes made."
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
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "156 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "156 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/156_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch156.py" <<'STROM156_PY'
#!/usr/bin/env python3
"""Camera blueprint center without shifting the already matched grid on screen."""
import os
from pathlib import Path
src=Path(os.environ['STROM156_ROOT'])/'frontend/src'
flight=src/'components/CameraFlight150.tsx'
measure=src/'components/cameraHandoffDiagnostics155.ts'
new=src/'components/cameraBlueprintCenter156.ts'
for p in (flight,measure):
    if not p.exists():raise RuntimeError('156 missing prerequisite '+str(p))
if new.exists():raise RuntimeError('156 already installed')
f=flight.read_text('utf8')
m=measure.read_text('utf8')
for marker in ('STROM154_GRID_PIXEL_ALIGNMENT','STROM155_CAMERA_VIEWPORT_DIAGNOSTICS','STROM150N_NO_END_JUMP'):
    if marker not in f:raise RuntimeError('156 requires '+marker)
if 'STROM156_BLUEPRINT_CAMERA_CENTER' in f:raise RuntimeError('156 duplicate')

def swap(text,old,new,label):
    count=text.count(old)
    if count!=1:raise RuntimeError(f'156 {label}: expected one anchor, got {count}')
    return text.replace(old,new,1)

f=swap(f,
 "import { captureCameraHandoff155 } from './cameraHandoffDiagnostics155' // STROM155_CAMERA_VIEWPORT_DIAGNOSTICS",
 "import { captureCameraHandoff155 } from './cameraHandoffDiagnostics155' // STROM155_CAMERA_VIEWPORT_DIAGNOSTICS\nimport { alignBlueprintCenter156,applyViewOffset156,clearViewOffset156,type ViewOffset156 } from './cameraBlueprintCenter156' // STROM156_BLUEPRINT_CAMERA_CENTER",'import')
f=swap(f, '  previous?: CameraPose\n', '  previous?: CameraPose\n  viewOffset156?: ViewOffset156\n','flight metadata')
f=swap(f,
 '''          alignBlueprintGrid154(state.scene,camera,state.gl.domElement,
            running.start,currentFrame150(),pose=>apply(camera,pose))''',
 '''          const gridAligned154=alignBlueprintGrid154(state.scene,camera,state.gl.domElement,
            running.start,currentFrame150(),pose=>apply(camera,pose))
          if(gridAligned154){
            // The WebGL canvas and Blueprint viewport are different DOM rects.
            // Rebase the eye on the TRUE BP centre and retain screen-perfect
            // projection with a temporary camera lens/view offset.
            running.viewOffset156=alignBlueprintCenter156(
              state.scene,camera,state.gl.domElement,running.start,
              currentFrame150(),pose=>apply(camera,pose))||undefined
          }''','camera fit')
f=swap(f,
 '''    if (running.kind === 'entry' && running.phase === 'fade') {
      apply(camera, running.start)
      if (performance.now() >= running.startedAt) running.phase = 'flight'
      return
    }''',
 '''    if (running.kind === 'entry' && running.phase === 'fade') {
      apply(camera, running.start)
      if(running.viewOffset156)applyViewOffset156(camera,running.viewOffset156,1)
      if (performance.now() >= running.startedAt) running.phase = 'flight'
      return
    }''','fade')
f=swap(f,
 '''    apply(camera, pose)
    if (t < 1) return

    // STROM150N_NO_END_JUMP''',
 '''    apply(camera, pose)
    // Ease the compensating lens offset to zero together with the camera.
    // At the exact final frame the native, unshifted 3D camera is restored.
    if(running.kind==='entry'&&running.viewOffset156)
      applyViewOffset156(camera,running.viewOffset156,1-k)
    if (t < 1) return

    // STROM150N_NO_END_JUMP''','flight')
f=swap(f,
 '''    apply(camera, b)
    flight.current = null''',
 '''    apply(camera, b)
    if(running.kind==='entry'&&running.viewOffset156)clearViewOffset156(camera)
    flight.current = null''','flight end')
f=swap(f,
 '''      flight.current = null
      unlock()
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps''',
 '''      flight.current = null
      unlock()
      // Never leave off-axis camera projection behind after unmount.
      clearViewOffset156(get().camera)
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps''','unmount')

# Measurements continue to store the raw THREE axes for compatibility, but show
# user-facing architecture X/Y/Z, a world ray through Blueprint viewport centre,
# and the temporary lens correction separately.
m=swap(m,
 '''  const orthographicView=!perspective&&ortho.isOrthographicCamera?{''',
 '''  const bpViewportCentre=blueprint?.screen
  let bpCentreRayHit:THREE.Vector3|null=null
  if(bpViewportCentre&&canvasRect.width>0&&canvasRect.height>0){
    const nx=2*(bpViewportCentre.centerX-canvasRect.left)/canvasRect.width-1
    const ny=1-2*(bpViewportCentre.centerY-canvasRect.top)/canvasRect.height
    const a=new THREE.Vector3(nx,ny,-1).unproject(camera)
    const b=new THREE.Vector3(nx,ny,1).unproject(camera)
    const dir=b.clone().sub(a).normalize()
    const start=perspective?worldPosition:a
    const t0=Math.abs(dir.y)>1e-9?-start.y/dir.y:NaN
    if(valid155(t0)&&t0>=0)bpCentreRayHit=start.clone().addScaledVector(dir,t0)
  }
  const activeView=(camera as THREE.PerspectiveCamera).view
  const offAxisView=activeView?.enabled?{
    offsetX:round155(activeView.offsetX,2),offsetY:round155(activeView.offsetY,2)
  }:null
  const orthographicView=!perspective&&ortho.isOrthographicCamera?{''','BP ray')
m=swap(m,
 '''      position:coords155(worldPosition),
      direction:coords155(direction),
      viewportCenterOnZ0:hit?coords155(hit):null,''',
 '''      position:coords155(worldPosition),
      architecturalPosition:{x:round155(worldPosition.x),y:round155(worldPosition.z),z:round155(worldPosition.y)},
      direction:coords155(direction),
      architecturalDirection:{x:round155(direction.x),y:round155(direction.z),z:round155(direction.y)},
      blueprintCenterRayOnHeightZero:bpCentreRayHit?{x:round155(bpCentreRayHit.x),y:round155(bpCentreRayHit.z)}:null,
      lensOffsetCssPx:offAxisView,
      viewportCenterOnZ0:hit?coords155(hit):null,''','diagnostics data')
m=swap(m,
 '''  const gaze=result.camera.viewportCenterOnZ0
  section.textContent=''','''  const gaze=result.camera.viewportCenterOnZ0
  const bpRay=result.camera.blueprintCenterRayOnHeightZero
  const lens=result.camera.lensOffsetCssPx
  section.textContent=''','diagnostic panel variables')
m=swap(m,
 '''    +`3D-KAMERA (Three.js X/Y/Z, m)\\n`
    +`Position: X ${p.x} / Y ${p.y} / Z ${p.z}\\n`
    +`Blickrichtung: (${d.x}, ${d.y}, ${d.z})\\n`
    +(gaze?`Viewport-Mitte auf Hoehe 0: X ${gaze.x} / Y ${gaze.y} / Z ${gaze.z}\\n`
      :'Viewport-Mitte auf Hoehe 0: kein Strahlschnitt\\n')
    +`Rotation XYZ: ${r.x}° / ${r.y}° / ${r.z}°\\n`''',
 '''    +`3D-KAMERA (PLAN: X Breite / Y Tiefe / Z Hoehe)\\n`
    +`Position: X ${p.x} / Y ${p.z} / Z ${p.y} m\\n`
    +`Blickrichtung XYZ (Plan): (${d.x}, ${d.z}, ${d.y})\\n`
    +(bpRay?`Punkt unter Blueprint-Mitte (Z=0): X ${bpRay.x} / Y ${bpRay.y}\\n`
      :'Blueprint-Mitte: kein Strahlschnitt\\n')
    +(gaze?`Punkt unter 3D-Canvas-Mitte (Z=0): X ${gaze.x} / Y ${gaze.z}\\n`
      :'3D-Canvas-Mitte: kein Strahlschnitt\\n')
    +(lens?`Lens-/Canvas-Versatz: ${lens.offsetX}px / ${lens.offsetY}px\\n`:'')
    +`Rotation (intern Three XYZ): ${r.x}° / ${r.y}° / ${r.z}°\\n`''','visible labels')
new.write_text(Path(__file__).with_name('cameraBlueprintCenter156.ts').read_text('utf8'),'utf8')
flight.write_text(f,'utf8')
measure.write_text(m,'utf8')
print('PASS 156 camera rebase: actual viewport centre + temporary compensated off-axis projection')
STROM156_PY
cat > "$RESOURCE_DIR/cameraBlueprintCenter156.ts" <<'STROM156_TS'
import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'

/** STROM156_BLUEPRINT_CAMERA_CENTER
 * The Blueprint's visible *viewport* centre is the camera's world-space X/Z.
 * The WebGL canvas is a DIFFERENT DOM rectangle. To preserve exact grid pixels,
 * move the 3D eye to the Blueprint centre and compensate its differing canvas
 * principal point with a temporary, off-axis camera viewOffset. Fade the
 * viewOffset away with the existing 5s ease-out camera flight.
 *
 * Architectural X/Y/Z = Three world X/Z/Y. Do not change model coordinates,
 * world-zero grid, look direction, orbit endpoint or geometry.
 */
export type ViewOffset156 = {x:number;y:number;width:number;height:number}
type Point156 = {x:number;y:number}
type Pose156 = {
  position:THREE.Vector3
  rotation:THREE.Quaternion
  target:THREE.Vector3
  up:THREE.Vector3
  zoom:number
}
type Camera156 = THREE.PerspectiveCamera | THREE.OrthographicCamera
const isFinite156=(v:number)=>Number.isFinite(v)

function planAtPixel156(frame:BlueprintFrame150,px:number,py:number):Point156|null {
  const s=frame.screen150o
  if(!s)return null
  const determinant=s.ax*s.by-s.ay*s.bx
  if(![s.x,s.y,s.ax,s.ay,s.bx,s.by,determinant].every(isFinite156)||Math.abs(determinant)<1e-9)return null
  const dx=px-s.x,dy=py-s.y
  return {
    x:(s.by*dx-s.bx*dy)/determinant,
    y:(-s.ay*dx+s.ax*dy)/determinant,
  }
}
function planToWorld156(scene:THREE.Object3D,p:Point156):THREE.Vector3 {
  // Same transformed floor marker and architectural Z=0 rule as grid 152 / fit 154.
  scene.updateMatrixWorld(true)
  let marker:THREE.Object3D|null=null
  scene.traverse(obj=>{
    if(!marker&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
  })
  const matrix=marker?(marker as THREE.Object3D).matrixWorld.clone():new THREE.Matrix4()
  matrix.elements[13]=0
  const v=new THREE.Vector3(p.x,0,p.y).applyMatrix4(matrix)
  v.y=0
  return v
}
function projection156(world:THREE.Vector3,camera:THREE.Camera,rect:DOMRect):Point156 {
  camera.updateMatrixWorld(true)
  const ndc=world.clone().project(camera)
  return {x:rect.left+rect.width*(ndc.x+1)/2,y:rect.top+rect.height*(1-ndc.y)/2}
}
function cameraWithView156(camera:THREE.Camera):Camera156|null {
  const p=camera as THREE.PerspectiveCamera
  if(p.isPerspectiveCamera===true)return p
  const o=camera as THREE.OrthographicCamera
  return o.isOrthographicCamera===true?o:null
}

/** Set the compensating off-axis lens shift; 1 at fade, 0 at flight end. */
export function applyViewOffset156(camera:THREE.Camera,view:ViewOffset156|undefined,remaining:number):void {
  const c=cameraWithView156(camera)
  if(!c||!view)return
  const t=Math.max(0,Math.min(1,remaining))
  if(t<=1e-8){c.clearViewOffset();return}
  c.setViewOffset(view.width,view.height,view.x*t,view.y*t,view.width,view.height)
}
export function clearViewOffset156(camera:THREE.Camera):void {
  const c=cameraWithView156(camera)
  if(c?.view?.enabled)c.clearViewOffset()
}

export function alignBlueprintCenter156<T extends Pose156>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:T,frame:BlueprintFrame150|null,apply:(pose:T)=>void,
):ViewOffset156|null {
  const c=cameraWithView156(camera)
  if(!c||!frame?.screen150o)return null
  const rect=canvas.getBoundingClientRect()
  if(!(rect.width>30&&rect.height>30))return null
  let vp:{screenLeft:number;screenTop:number;width:number;height:number}|undefined
  try{
    const raw=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(raw)vp=(JSON.parse(raw) as {viewport?:typeof vp}).viewport
  }catch{return null}
  if(!vp||![vp.screenLeft,vp.screenTop,vp.width,vp.height].every(isFinite156)||vp.width<50||vp.height<50)return null
  const bpCenterPx={x:vp.screenLeft+vp.width/2,y:vp.screenTop+vp.height/2}
  const planCenter=planAtPixel156(frame,bpCenterPx.x,bpCenterPx.y)
  if(!planCenter)return null
  const desiredWorld=planToWorld156(scene,planCenter)
  if(![desiredWorld.x,desiredWorld.z].every(isFinite156))return null
  // The 154 alignment has already produced a verified pixel-exact projection.
  // Rebase only the camera's horizontal eye/target, preserving every screen pixel.
  const savedPosition=pose.position.clone(),savedTarget=pose.target.clone()
  const savedView=c.view?.enabled?{...c.view}:null
  const originWorld=planToWorld156(scene,{x:0,y:0})
  const before=projection156(originWorld,camera,rect)
  try {
    clearViewOffset156(camera)
    pose.position.x=desiredWorld.x
    pose.position.z=desiredWorld.z
    pose.target.x=desiredWorld.x
    pose.target.z=desiredWorld.z
    apply(pose)
    const after=projection156(originWorld,camera,rect)
    const shift:ViewOffset156={
      x:after.x-before.x, // viewOffset has the OPPOSITE sign to an image translation
      y:after.y-before.y,
      width:rect.width,height:rect.height,
    }
    // With the measured viewport difference this is about -140/-42 CSS px.
    if(![shift.x,shift.y].every(isFinite156)||Math.abs(shift.x)>rect.width*2||Math.abs(shift.y)>rect.height*2)
      throw Error('off-axis viewport shift exceeds safety bounds')
    applyViewOffset156(camera,shift,1)
    const corrected=projection156(originWorld,camera,rect)
    const errorPx=Math.hypot(corrected.x-before.x,corrected.y-before.y)
    if(!(errorPx<0.25))throw Error(`View offset projection mismatch ${errorPx.toFixed(3)} CSS px`)
    const data={version:156,architecturalCamera:{x:pose.position.x,y:pose.position.z,z:pose.position.y},
      blueprintCenter:planCenter,oldCamera:{x:savedPosition.x,y:savedPosition.z,z:savedPosition.y},
      canvasRect:{left:rect.left,top:rect.top,width:rect.width,height:rect.height},
      bpCenterPx,viewOffsetPx:shift,gridPixelErrorAfterRebase:errorPx}
    try{window.localStorage.setItem('strom.camera156.center',JSON.stringify(data))}catch{/* optional */}
    console.info('[STROM 156] Camera centred on Blueprint, same projected grid',data)
    return shift
  }catch(error){
    pose.position.copy(savedPosition)
    pose.target.copy(savedTarget)
    clearViewOffset156(camera)
    if(savedView?.enabled){
      c.setViewOffset(savedView.fullWidth,savedView.fullHeight,
        savedView.offsetX,savedView.offsetY,savedView.width,savedView.height)
    }
    apply(pose)
    console.warn('[STROM 156] Camera rebasing safely skipped; retained 154 alignment',error)
    return null
  }
}
STROM156_TS
cat > "$RESOURCE_DIR/test156.cjs" <<'STROM156_TEST'
'use strict'
const fs=require('fs'),path=require('path'),assert=require('assert')
const ts=require(process.env.STROM156_TS||'/opt/nvm/versions/node/v22.16.0/lib/node_modules/typescript')
const dir=process.env.STROM156_SOURCE||'/tmp/strom156/fixture/frontend/src'
const read=rel=>fs.readFileSync(path.join(dir,rel),'utf8')
for(const rel of ['components/CameraFlight150.tsx','components/cameraBlueprintCenter156.ts','components/cameraHandoffDiagnostics155.ts']){
 const s=read(rel),doc=ts.createSourceFile(rel,s,ts.ScriptTarget.Latest,true,rel.endsWith('tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 assert.equal(doc.parseDiagnostics.length,0,rel+': syntax')
}
const flight=read('components/CameraFlight150.tsx')
assert(flight.includes('STROM156_BLUEPRINT_CAMERA_CENTER'))
assert(flight.indexOf('alignBlueprintGrid154(state.scene')<flight.indexOf('alignBlueprintCenter156('))
assert(flight.indexOf('alignBlueprintCenter156(')<flight.indexOf("running.phase = 'fade'",flight.indexOf('alignBlueprintCenter156(')))
assert(flight.includes('applyViewOffset156(camera,running.viewOffset156,1-k)'))
assert(flight.includes('clearViewOffset156(camera)'))
assert(flight.includes('const k = easeOut(t)'))
assert(flight.includes('apply(camera, b)'))
const ui=read('components/cameraHandoffDiagnostics155.ts')
assert(ui.includes('Position: X ${p.x} / Y ${p.z} / Z ${p.y}'))
assert(ui.includes('Punkt unter Blueprint-Mitte'))
assert(ui.includes('lensOffsetCssPx'))

class Vec{
 constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}
 clone(){return new Vec(this.x,this.y,this.z)}
 copy(v){this.x=v.x;this.y=v.y;this.z=v.z;return this}
 applyMatrix4(m){const e=m.elements,x=this.x,y=this.y,z=this.z
   this.x=e[0]*x+e[4]*y+e[8]*z+e[12]
   this.y=e[1]*x+e[5]*y+e[9]*z+e[13]
   this.z=e[2]*x+e[6]*y+e[10]*z+e[14]
   return this
 }
 project(c){ // exact top-down perspective or ortho projection plus view offset in CSS px
   const ppm=c.ppm()
   const offX=c.view?.enabled?c.view.offsetX:0
   const offY=c.view?.enabled?c.view.offsetY:0
   return new Vec(2*((this.x-c.position.x)*ppm-offX)/c.rect.width,
          -2*((this.z-c.position.z)*ppm-offY)/c.rect.height,0)
 }
}
class Matrix{constructor(){this.elements=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]} clone(){const m=new Matrix();m.elements=[...this.elements];return m}}
class Cam{
 constructor(rect,kind='perspective',fov=48){this.rect=rect;this.isPerspectiveCamera=kind==='perspective';this.isOrthographicCamera=kind==='orthographic';this.fov=fov;this.zoom=1;this.position=new Vec(0,20,0);this.view=null}
 ppm(){return this.isPerspectiveCamera?this.rect.height/(2*Math.tan(this.fov*Math.PI/360)*this.position.y):80*this.zoom}
 updateMatrixWorld(){}
 setViewOffset(fw,fh,ox,oy,w,h){this.view={enabled:true,fullWidth:fw,fullHeight:fh,offsetX:ox,offsetY:oy,width:w,height:h}}
 clearViewOffset(){this.view=null}
}
const st=read('components/cameraBlueprintCenter156.ts')
const js=ts.transpileModule(st,{fileName:'cameraBlueprintCenter156.ts',compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText
const moduleExports={}
const storage=new Map()
const browser={localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v)}}
new Function('require','module','exports','window','console',js)(name=>{
 if(name==='three')return {Vector3:Vec,Matrix4:Matrix}
 throw Error('Unexpected runtime import '+name)
},{exports:moduleExports},moduleExports,browser,{info(){},warn(...a){throw Error(a.join(' '))}})
const {alignBlueprintCenter156,applyViewOffset156,clearViewOffset156}=moduleExports
function run(title,{x=5.960,y=3.849,ppm=82.63,bp={left:330.0,top:251.0,width:2054,height:1493},dx=0,dy=-107.2,sc=1,rx=0,rz=0,kind='perspective'}={}){
 const rect={left:bp.left+dx,top:bp.top+dy,width:bp.width-280,height:bp.height+130.3}
 const cx=bp.left+bp.width/2,cy=bp.top+bp.height/2
 const oldX=x*sc+rx+((rect.left+rect.width/2)-cx)/ppm
 const oldZ=y*sc+rz+((rect.top+rect.height/2)-cy)/ppm
 const height=kind==='perspective'?rect.height/(2*Math.tan(48*Math.PI/360)*ppm):10
 const cam=new Cam(rect,kind)
 cam.position=new Vec(oldX,height,oldZ)
 if(kind==='orthographic')cam.zoom=ppm/80
 const pose={position:cam.position.clone(),target:new Vec(oldX,0,oldZ),zoom:1,rotation:{},up:new Vec(0,0,-1)}
 const canvas={getBoundingClientRect:()=>rect}
 const s={x:cx-x*ppm,y:cy-y*ppm,ax:ppm,by:ppm,ay:0,bx:0}
 const frame={screen150o:s}
 storage.set('strom.camera150p.blueprintExtents',JSON.stringify({viewport:{screenLeft:bp.left,screenTop:bp.top,width:bp.width,height:bp.height}}))
 const matrix=new Matrix()
 matrix.elements[0]=sc;matrix.elements[10]=sc;matrix.elements[12]=rx;matrix.elements[14]=rz;matrix.elements[13]=4
 const marker={name:'strom150r-floor-reference',userData:{active150r:true},matrixWorld:matrix}
 const scene={updateMatrixWorld(){},traverse(fn){fn(marker)}}
 const proj=()=>new Vec(rx,0,rz).project(cam) // world origin of the architectural grid
 const pixel=()=>{const p=proj();return {x:rect.left+(p.x+1)*rect.width/2,y:rect.top+(1-p.y)*rect.height/2}}
 const before=pixel(),z0=cam.position.y
 const result=alignBlueprintCenter156(scene,cam,canvas,pose,frame,p=>{cam.position.copy(p.position)})
 assert(result,title+': alignment returned null')
 const after=pixel()
 assert(Math.abs(after.x-before.x)<1e-6&&Math.abs(after.y-before.y)<1e-6,title+': pixel jump')
 assert(Math.abs(cam.position.x-(x*sc+rx))<1e-6,title+': X centre')
 assert(Math.abs(cam.position.z-(y*sc+rz))<1e-6,title+': plan Y centre')
 assert.equal(cam.position.y,z0,title+': altitude unchanged')
 assert(Math.abs(result.x-(rect.left+rect.width/2-cx))<1e-6,title+': camera lens shift sign and size')
 assert(Math.abs(result.y-(rect.top+rect.height/2-cy))<1e-6,title+': lens y shift')
 applyViewOffset156(cam,result,0.5)
 assert(Math.abs(cam.view.offsetX-result.x/2)<1e-9,title+': fade lens shift eased')
 applyViewOffset156(cam,result,0)
 assert(!cam.view,title+': no view offset at end')
 console.log('PASS',title,'camera XYZ architectural',cam.position.x,cam.position.z,cam.position.y,'offset',result.x,result.y)
}
run('reported screenshot offset',{})
run('other viewport origin',{dx:90,dy:-46})
run('offset another direction',{bp:{left:20,top:80,width:1400,height:900},dx:80,dy:40,x:-11,y:24,ppm:46})
run('orthographic lens',{kind:'orthographic'})
run('world plan reference translation',{rx:12,rz:-7})
console.log('PASS 156: no projection jumps; camera exactly over visible BP centre; lens shift eased to zero')
STROM156_TEST
log "3) Apply 156 in isolated source tree ..."
python3 -m py_compile "$RESOURCE_DIR/patch156.py" >>"$DIAG_LOG" 2>&1 || fail "156 Python syntax failed"
STROM156_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch156.py" >>"$DIAG_LOG" 2>&1 || \
  fail "156 source patch failed; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build in isolated tree ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "156 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Verify exact Blueprint centre / projection / easing regression ..."
STROM156_SOURCE="$WORK_DIR/frontend/src" STROM156_TS="$DEPENDENCIES/typescript" \
  node "$RESOURCE_DIR/test156.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "156 camera regression failed; GitHub and Stage unchanged"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_156.md" <<'STROM156_DOC'
# Stromnetze 156 - Blueprint-centred camera with pixel-stable projection

- Analysis of screenshot 155: the 3D canvas is 280 px narrower, 130.3 px taller,
  and begins 107.2 px higher than the Blueprint viewport. The Canvas centre is
  -140 px/-42.05 px from Blueprint centre. At 82.63 px/metre this equals precisely
  the observed camera -1.694 m X and -0.509 m plan Y.
- Preserve calibrated true 3D grid projection from update 154, then rebase the
  camera eye and orbit target to the VISIBLE Blueprint viewport centre using
  the click-time screen matrix and the canonical 3D floor-reference matrix.
- Use Three.js camera.setViewOffset to compensate the 3D canvas vs Blueprint
  rectangle difference on the same frame; pixel-projected axes do not jump.
- Hold this temporary lens shift while Blueprint fades for 5 s, then ease the
  shift to zero simultaneously with the existing 5 s camera flight.
- Never alter 3D room geometry, the canonical grid/axes colors, camera angles,
  default flight endpoint or transition durations.
- Show diagnostic values using ARCHITECTURAL X=width, Y=depth, Z=height; retain
  separate raw Three.js axes in localStorage for compatibility. Add the ray
  intersection at the Blueprint centre and temporary camera lens offset.
- Logs: localStorage `strom.camera156.center` and `strom.camera155.handoff`.
- Local syntax and viewport-geometry tests; full Pi Vite build before Git push.
- Isolated GitHub source sync, Stage backup; deployment ONLY /strom-test/.
STROM156_DOC
log "6) Transfer checked source to Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "156 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY; no web deployment"
  exit 0
fi
log "7) Build Stage and deploy exclusively /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "156 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "156 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "156 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 156 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
