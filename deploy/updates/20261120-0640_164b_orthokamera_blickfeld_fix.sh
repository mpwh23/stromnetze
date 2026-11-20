#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261120-0640_164b_orthokamera_blickfeld_fix"
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
COMMIT_MESSAGE="Update 164b: exact canvas-aspect camera calibration, 1m and 5m grid"
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
  echo "2) Update 164b im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 164b isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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

log "=== Update 164b: eine exakte Blueprint-3D Rasterprojektion und 5m Linien ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts frontend/src/components/cameraBlueprintCenter156.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "164 required source missing: $file"
done
for marker in STROM163_BLUEPRINT_VIEWPORT_TRUTH STROM162_EXACT_RENDERED_BLUEPRINT_RETURN; do
  grep -Fq "$marker" "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || fail "164 prerequisite $marker missing; no changes made"
done
if grep -Fq 'STROM164_ONE_EXACT_TRANSFORM' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"; then
  fail "164 already installed; no changes made"
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
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "164 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "164 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/164_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch164.py" <<'STROM164_PATCH'
#!/usr/bin/env python3
"""Patch 164: one exact Blueprint-grid-to-camera mapping and every-5m grid marks.
Apply only to isolated source. Reject duplicate/unexpected source structure.
"""
from pathlib import Path
import os

root = Path(os.environ['STROM164_ROOT'])/'frontend/src'
flight = root/'components/CameraFlight150.tsx'
grid = root/'components/CanonicalGrid152.tsx'
style = root/'styles.css'
app = root/'App.tsx'
helper = root/'components/cameraGridAnalytic164.ts'
for p in (flight, grid, style, app):
    if not p.is_file():raise RuntimeError('164 required source missing: '+str(p))
if helper.exists():raise RuntimeError('164 already installed: cameraGridAnalytic164.ts')
f=flight.read_text('utf8');g=grid.read_text('utf8');s=style.read_text('utf8');a=app.read_text('utf8')
for marker in ('STROM163_BLUEPRINT_VIEWPORT_TRUTH','STROM162_EXACT_RENDERED_BLUEPRINT_RETURN',
               'STROM150N_NO_END_JUMP'):
    if marker not in f:raise RuntimeError(f'164 camera prerequisite missing: {marker}')
for marker in ('STROM152_BLUEPRINT_GRID','STROM153_3D_AXIS_STYLES'):
    if marker not in g:raise RuntimeError(f'164 grid prerequisite missing: {marker}')
for marker in ('STROM153_AXIS_PIXEL_WIDTH','STROM153_BP_AXIS_STYLES'):
    if marker not in (s+a):raise RuntimeError(f'164 Blueprint prerequisite missing: {marker}')
if 'STROM164_' in f+g+s:raise RuntimeError('164 already applied')

def one(text,old,new,label):
    count=text.count(old)
    if count!=1:raise RuntimeError(f'164 {label}: expected exactly one anchor, found {count}')
    return text.replace(old,new,1)

# Replace only the final late pre-fade camera alignment. Other camera state,
# forward/back times and return lens driver remain untouched.
f=one(f,"import { alignViewportExactly163 } from './cameraViewportExact163' // STROM163_BLUEPRINT_VIEWPORT_TRUTH",
      "import { alignGridAnalytic164 } from './cameraGridAnalytic164' // STROM164_ONE_EXACT_TRANSFORM",'camera import')
f=one(f,'const exact163=alignViewportExactly163(state.scene,camera,state.gl.domElement,',
      'const exact163=alignGridAnalytic164(state.scene,camera,state.gl.domElement,','one pre-fade call')
f=one(f,'        if(exact163)running.viewOffset156=exact163',
      '''        if(!exact163){
          // Retry with current (not guessed) scene/canvas geometry on next frame.
          // Never start a fade using an unverified camera or grid.
          running.preparedFrames += 1
          if(running.preparedFrames<=120)invalidate()
          else if(running.preparedFrames===121)
            console.error('[STROM164] Exact grid alignment unavailable: no unverified fade started')
          return
        }
        running.viewOffset156=exact163''','reject unverified alignment')
if f.count('alignGridAnalytic164(')!=1 or f.count('useFrame(')!=1:
    raise RuntimeError('164 camera has multiple alignments / drivers')

# The 3D grid must cover the actual Blueprint viewport at handoff, not just
# a model bounding box. The same click-time matrix provides its exact corners.
g=one(g,"import * as THREE from 'three'",
      "import * as THREE from 'three'\nimport { currentFrame150 } from './cameraTransitions150' // STROM164_VIEWPORT_GRID_EXTENT",
      'grid viewport import')
g=one(g,'    return Math.ceil(Math.min(500,extent+10)/5)*5\n  },[points])',
'''    // Cover every visible Blueprint corner even when the model is panned away.
    const snap=currentFrame150()
    const s=snap?.screen150o,vr=snap?.viewport163
    if(s&&vr){
      const det=s.ax*s.by-s.ay*s.bx
      if(Number.isFinite(det)&&Math.abs(det)>1e-9){
        for(const px of [vr.left,vr.left+vr.width])for(const py of [vr.top,vr.top+vr.height]){
          const dx=px-s.x,dy=py-s.y
          extent=Math.max(extent,Math.abs((s.by*dx-s.bx*dy)/det),
            Math.abs((-s.ay*dx+s.ax*dy)/det))
        }
      }
    }
    return Math.ceil(Math.min(2000,extent+10)/5)*5
  },[points])''','grid viewport extent')

# Grid: draw a 1-m minor line AND a 2-CSS-pixel 5-m line. Browser WebGL
# commonly ignores gl.lineWidth>1, so major lines are real flat quads.
g=one(g,'  const step=half>150?5:1\n','  // STROM164_FIVE_METRE_GRID: do not drop the 1-m lines at large zoom ranges.\n', 'old coarse grid step')
g=one(g,'''    for(let n=-half;n<=half;n+=step){
      if(Math.abs(n)<1e-8)continue // Zero is drawn once, with thick explicit X/Y axes.
      data.push(n,-0.018,-half,n,-0.018,half)
      data.push(-half,-0.018,n,half,-0.018,n)
    }''','''    for(let n=-half;n<=half;n+=1){
      if(n===0||n%5===0)continue // 0: colored axes; multiples of 5: major mesh.
      data.push(n,-0.018,-half,n,-0.018,half)
      data.push(-half,-0.018,n,half,-0.018,n)
    }''','1-m minor grid without 5-m overlaps')
g=one(g,'  },[half,step])\n  useEffect(()=>()=>gridGeometry.dispose(),[gridGeometry])', '''  },[half])
  useEffect(()=>()=>gridGeometry.dispose(),[gridGeometry])
  const majorMarks164=useMemo(()=>{
    const marks:number[]=[]
    for(let n=-half;n<=half;n+=5)if(n!==0)marks.push(n)
    return marks
  },[half])
  const majorMesh164=useMemo(()=>{
    const mesh=new THREE.InstancedMesh(new THREE.PlaneGeometry(1,1),
      new THREE.MeshBasicMaterial({color:'#8798ae',opacity:0.7,transparent:true,
        toneMapped:false,depthWrite:false,side:THREE.DoubleSide}),majorMarks164.length*2)
    mesh.name='strom164-five-metre-lines'
    mesh.frustumCulled=false
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage)
    return mesh
  },[majorMarks164])
  useEffect(()=>()=>{majorMesh164.geometry.dispose();majorMesh164.material.dispose()},[majorMesh164])
  const majorRotation164=useMemo(()=>new THREE.Quaternion().setFromEuler(new THREE.Euler(-Math.PI/2,0,0)),[])
  const majorMatrix164=useMemo(()=>new THREE.Matrix4(),[])
  const majorPosition164=useMemo(()=>new THREE.Vector3(),[])
  const majorScale164=useMemo(()=>new THREE.Vector3(),[])''','major geometries')
g=one(g,'  useFrame(()=>{','  useFrame((state)=>{','3D grid frame callback')
needle='''      group.current.matrixWorldNeedsUpdate=true
    }
    // Legacy helper meshes'''
ins='''      group.current.matrixWorldNeedsUpdate=true
      group.current.updateWorldMatrix(true,false)
      // Major lines keep a 2-CSS-pixel footprint at the fade/top-down view.
      // Unlike WebGL lineWidth, planar instanced meshes work in every browser.
      const rect=state.gl.domElement.getBoundingClientRect()
      const cam=state.camera as THREE.PerspectiveCamera
      const ortho=state.camera as THREE.OrthographicCamera
      const scaleX=Math.hypot(group.current.matrixWorld.elements[0],group.current.matrixWorld.elements[2])
      const scaleY=Math.hypot(group.current.matrixWorld.elements[8],group.current.matrixWorld.elements[10])
      const planeY=new THREE.Vector3(0,-0.018,0).applyMatrix4(group.current.matrixWorld).y
      const distance=Math.abs(state.camera.position.y-planeY)
      let pxPerWorld=0
      if(cam.isPerspectiveCamera && distance>0.001)
        pxPerWorld=rect.height*cam.projectionMatrix.elements[5]/(2*distance)
      else if(ortho.isOrthographicCamera && ortho.top>ortho.bottom)
        pxPerWorld=rect.height*ortho.zoom/(ortho.top-ortho.bottom)
      if(pxPerWorld>0.01 && scaleX>0 && scaleY>0){
        const thicknessX=2/(pxPerWorld*scaleX)
        const thicknessY=2/(pxPerWorld*scaleY)
        let index=0
        for(const n of majorMarks164){
          majorPosition164.set(n,-0.018,0)
          majorScale164.set(thicknessX,half*2,1)
          majorMatrix164.compose(majorPosition164,majorRotation164,majorScale164)
          majorMesh164.setMatrixAt(index++,majorMatrix164)
          majorPosition164.set(0,-0.018,n)
          majorScale164.set(half*2,thicknessY,1)
          majorMatrix164.compose(majorPosition164,majorRotation164,majorScale164)
          majorMesh164.setMatrixAt(index++,majorMatrix164)
        }
        majorMesh164.count=index
        majorMesh164.instanceMatrix.needsUpdate=true
      }
    }
    // Legacy helper meshes'''
g=one(g,needle,ins,'5-m screen-space ribbon update')
g=one(g,'''      </lineSegments>
      {/* STROM153_3D_AXIS_STYLES: matched viewport-pixel width, no thick boxes. */}''','''      </lineSegments>
      <primitive object={majorMesh164} />
      {/* STROM153_3D_AXIS_STYLES: matched viewport-pixel width, no thick boxes. */}''','major mesh render')

# Colored zero axes must be on EXACTLY the same physical grid plane as
# the 1-m and 5-m lines; even 5mm of Y parallax breaks a close-up blend.
g=one(g,'x:make([-half,-0.013,0,half,-0.013,0])',
      'x:make([-half,-0.018,0,half,-0.018,0])','X zero-axis grid plane')
g=one(g,'y:make([0,-0.012,-half,0,-0.012,half])',
      'y:make([0,-0.018,-half,0,-0.018,half])','Y zero-axis grid plane')

# Blueprint: minor=1px, every fifth metre=2px, colored 0 axes=1px.
# The preceding 153 stylesheet had erroneously made major lines 1px too.
s+='''
/* STROM164_FIVE_METRE_GRID: identical Blueprint and 3D screen-pixel cadence. */
.floorplan-canvas .grid line { stroke-width:1px !important; vector-effect:non-scaling-stroke; }
.floorplan-canvas .grid line.major:not(.strom153-zero-x):not(.strom153-zero-y) {
  stroke-width:2px !important;
}
.floorplan-canvas .grid line.strom153-zero-x,
.floorplan-canvas .grid line.strom153-zero-y { stroke-width:1px !important; }
'''

helper.write_text(Path(__file__).with_name('cameraGridAnalytic164.ts').read_text('utf8'),'utf8')
flight.write_text(f,'utf8')
grid.write_text(g,'utf8')
style.write_text(s,'utf8')
print('PASS 164: one direct BP-to-rendered-grid transform, all 1-m minor and 5-m thick major lines')
STROM164_PATCH
cat > "$RESOURCE_DIR/cameraGridAnalytic164.ts" <<'STROM164_TS'
import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'
import type { ViewOffset156 } from './cameraBlueprintCenter156'

/** STROM164_ONE_EXACT_TRANSFORM
 * The EXACT displayed 3D grid is the geometric source of truth.  Its matrixWorld
 * is used unchanged.  Blueprint supplies one affine screen mapping in CSS px.
 * One inversion, one lens-scale formula, one lens-translation formula.
 * No bounds, guessed height, iteration, hardcoded pan, or second camera driver.
 * Architectural (X,Y,Z) == Three (X,Z,Y).
 */
type BlueprintBasis164={x:number;y:number;ax:number;ay:number;bx:number;by:number}
type Rect164={left:number;top:number;width:number;height:number}
type Pose164={position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;up:THREE.Vector3;zoom:number}
type Camera164=THREE.PerspectiveCamera|THREE.OrthographicCamera
const finite164=(...v:number[])=>v.every(Number.isFinite)
const distance164=(a:{x:number;y:number},b:{x:number;y:number})=>Math.hypot(a.x-b.x,a.y-b.y)

export function viewportToPlan164(s:BlueprintBasis164,v:Rect164){
  if(!finite164(s.x,s.y,s.ax,s.ay,s.bx,s.by,v.left,v.top,v.width,v.height)
     ||v.width<20||v.height<20)return null
  const determinant=s.ax*s.by-s.ay*s.bx
  const pxX=Math.hypot(s.ax,s.ay),pxY=Math.hypot(s.bx,s.by)
  const dot=s.ax*s.bx+s.ay*s.by
  // A single real camera cannot reproduce anisotropic/sheared blueprint pixels.
  // Reject instead of silently approximating these transforms.
  if(!(determinant>1e-8&&pxX>0.1&&pxY>0.1)
     ||Math.abs(pxX-pxY)>Math.max(pxX,pxY)*0.00005
     ||Math.abs(dot)>pxX*pxY*0.00005)return null
  const pixelCenter={x:v.left+v.width/2,y:v.top+v.height/2}
  const dx=pixelCenter.x-s.x,dy=pixelCenter.y-s.y
  const planCenter={x:(s.by*dx-s.bx*dy)/determinant,y:(-s.ay*dx+s.ax*dy)/determinant}
  return {planCenter,pixelCenter,pixelsPerMetre:pxX}
}

function worldToScreen164(p:THREE.Vector3,camera:THREE.Camera,rect:Rect164){
  camera.updateMatrixWorld(true)
  const ndc=p.clone().project(camera)
  return {x:rect.left+(ndc.x+1)*rect.width/2,y:rect.top+(1-ndc.y)*rect.height/2}
}
function cameraType164(camera:THREE.Camera):Camera164|null{
  const p=camera as THREE.PerspectiveCamera
  if(p.isPerspectiveCamera===true)return p
  const o=camera as THREE.OrthographicCamera
  return o.isOrthographicCamera===true?o:null
}

/** Returns a view offset only if the actual Three projection matches ALL
 * independently sampled Blueprint origin, 1 m and 5 m grid lines.
 * Called once, before removing the loading spinner.
 */
export function alignGridAnalytic164<T extends Pose164>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:T,frame:BlueprintFrame150|null,apply:(p:T)=>void,
):ViewOffset156|null{
  const cam=cameraType164(camera),bp=frame?.screen150o,viewport=frame?.viewport163
  if(!cam||!bp||!viewport){
    console.error('[STROM164] Click-time Blueprint/3D camera data missing')
    return null
  }
  const rect=canvas.getBoundingClientRect()
  if(!finite164(rect.left,rect.top,rect.width,rect.height)||rect.width<20||rect.height<20)return null
  const map=viewportToPlan164(bp,viewport)
  if(!map){console.error('[STROM164] Blueprint screen matrix is invalid or distorted');return null}

  // Use exactly the SAME world matrix as the rendered 3D grid, not the nearby
  // floor marker whose Y may differ by the selected storey elevation.
  const grid=scene.getObjectByName('strom152-blueprint-grid')
  if(!grid){console.error('[STROM164] Canonical 3D grid has not mounted');return null}
  grid.updateWorldMatrix(true,false)
  const matrix=grid.matrixWorld.clone()
  const world=(x:number,y:number)=>new THREE.Vector3(x,-0.018,y).applyMatrix4(matrix)
  const o=world(0,0),wx=world(1,0),wy=world(0,1)
  const cx=world(map.planCenter.x,map.planCenter.y)
  const u=wx.clone().sub(o),v=wy.clone().sub(o)
  const ux=Math.hypot(u.x,u.z),uy=Math.hypot(v.x,v.z)
  if(!(ux>1e-5&&uy>1e-5)||Math.abs(ux-uy)>Math.max(ux,uy)*0.00005
      ||Math.abs(u.dot(v))>ux*uy*0.00005
      ||Math.abs(u.y)>1e-6||Math.abs(v.y)>1e-6
      ||u.clone().cross(v).y>=0){
    console.error('[STROM164] 3D grid axes are not a horizontal uniform right-handed XY grid')
    return null
  }

  const old={position:pose.position.clone(),rotation:pose.rotation.clone(),up:pose.up.clone(),
    target:pose.target.clone(),zoom:pose.zoom}
  const oldView=cam.view?.enabled?{fullWidth:cam.view.fullWidth,fullHeight:cam.view.fullHeight,
    offsetX:cam.view.offsetX,offsetY:cam.view.offsetY,width:cam.view.width,height:cam.view.height}:null
  const isPerspective=(cam as THREE.PerspectiveCamera).isPerspectiveCamera===true
  const persp=cam as THREE.PerspectiveCamera
  const ortho=cam as THREE.OrthographicCamera
  const oldAspect=isPerspective?persp.aspect:0
  // STROM164B_ORTHOGRAPHIC_ASPECT: restore the entire original frustum on error.
  const oldOrtho=!isPerspective?{left:ortho.left,right:ortho.right,
    top:ortho.top,bottom:ortho.bottom}:null
  try{
    cam.clearViewOffset()
    if(isPerspective){
      persp.aspect=rect.width/rect.height
      persp.updateProjectionMatrix()
    }
    // The 2D Blueprint axes determine the camera yaw; its look vector remains
    // exactly (0,-1,0) in Three.  This also supports rotated SVG or floor grid.
    const unitX=u.clone().divideScalar(ux),unitY=v.clone().divideScalar(uy)
    const right=unitX.clone().multiplyScalar(bp.ax/map.pixelsPerMetre)
      .addScaledVector(unitY,bp.bx/map.pixelsPerMetre).normalize()
    const up=unitX.clone().multiplyScalar(-bp.ay/map.pixelsPerMetre)
      .addScaledVector(unitY,-bp.by/map.pixelsPerMetre).normalize()
    const back=new THREE.Vector3(0,1,0)
    if(right.clone().cross(up).distanceTo(back)>0.00005)
      throw Error('3D grid and Blueprint coordinate handedness differ')
    pose.rotation.setFromRotationMatrix(new THREE.Matrix4().makeBasis(right,up,back))
    pose.up.copy(up)
    pose.target.copy(cx)
    pose.position.x=cx.x
    pose.position.z=cx.z
    if(isPerspective){
      const focal=persp.projectionMatrix.elements[5]
      const height=rect.height*focal*ux/(2*map.pixelsPerMetre)
      if(!finite164(height)||height<=0.05)throw Error('Invalid camera height')
      pose.position.y=cx.y+height
    }else{
      const span=ortho.top-ortho.bottom
      if(!(span>0))throw Error('Invalid orthographic camera height range')
      // OrthographicCamera has independent horizontal and vertical world spans.
      // The 3D canvas can have a different aspect from the camera's constructor
      // (e.g. 1130/1100 canvas vs. 22/14 nominal camera). Zoom alone matches
      // only Y; X was off by precisely 445.040 CSS px at the 21-m sample.
      // The optical centre must be the Blueprint viewport centre on BOTH axes.
      const halfHorizontal=span*rect.width/(2*rect.height)
      if(!finite164(halfHorizontal)||halfHorizontal<=0)
        throw Error('Invalid orthographic camera aspect')
      ortho.left=-halfHorizontal
      ortho.right=halfHorizontal
      ortho.top=span/2
      ortho.bottom=-span/2
      pose.zoom=span*map.pixelsPerMetre/(rect.height*ux)
      pose.position.y=cx.y+Math.max(1,Math.abs(old.position.y-cx.y))
    }
    apply(pose)

    // One exact lens translation: the same plan centre must be drawn at the
    // SAME browser pixel in both independent DOM viewports.
    const screenCenter=worldToScreen164(cx,cam,rect)
    const offset:ViewOffset156={
      x:screenCenter.x-map.pixelCenter.x,
      y:screenCenter.y-map.pixelCenter.y,
      width:rect.width,height:rect.height,
    }
    if(!finite164(offset.x,offset.y))throw Error('Invalid canvas viewport displacement')
    cam.setViewOffset(offset.width,offset.height,offset.x,offset.y,offset.width,offset.height)

    // This is a verification, NOT a corrective fit.  Reject any mismatch.
    const samples=[[-5,-5],[0,0],[1,0],[0,1],[5,0],[0,5],[10,-10],[21,13]]
    let maximum=0
    for(const [x,y] of samples){
      const measured=worldToScreen164(world(x,y),cam,rect)
      const desired={x:bp.x+bp.ax*x+bp.bx*y,y:bp.y+bp.ay*x+bp.by*y}
      maximum=Math.max(maximum,distance164(measured,desired))
    }
    if(!(maximum<0.05))throw Error(`3D and Blueprint differ by ${maximum.toFixed(3)} CSS px`)

    const results={version:164,source:'same rendered 3D grid matrix and click-time Blueprint SVG',
      blueprintCenter:map.planCenter,blueprintViewport:viewport,
      threeCanvas:{left:rect.left,top:rect.top,width:rect.width,height:rect.height},
      cameraXYZ:{x:pose.position.x,y:pose.position.z,z:pose.position.y},
      gridWorldPlaneZ:cx.y,pixelsPerMetre:map.pixelsPerMetre,
      lensOffsetCssPx:{x:offset.x,y:offset.y},maxErrorCssPx:maximum}
    try{window.localStorage.setItem('strom.camera164.alignment',JSON.stringify(results))}catch{/* storage optional */}
    console.info('[STROM164] One-step Blueprint/3D grid alignment',results)
    return offset
  }catch(error){
    pose.position.copy(old.position);pose.rotation.copy(old.rotation);pose.up.copy(old.up)
    pose.target.copy(old.target);pose.zoom=old.zoom
    cam.clearViewOffset()
    if(isPerspective){persp.aspect=oldAspect;persp.updateProjectionMatrix()}
    if(oldOrtho){
      ortho.left=oldOrtho.left;ortho.right=oldOrtho.right
      ortho.top=oldOrtho.top;ortho.bottom=oldOrtho.bottom
      ortho.updateProjectionMatrix()
    }
    if(oldView)cam.setViewOffset(oldView.fullWidth,oldView.fullHeight,
      oldView.offsetX,oldView.offsetY,oldView.width,oldView.height)
    apply(pose)
    console.error('[STROM164] No approximation permitted; camera calibration rejected',error)
    return null
  }
}
STROM164_TS
cat > "$RESOURCE_DIR/test164.cjs" <<'STROM164_TEST'
'use strict'
const fs=require('fs'),path=require('path'),assert=require('assert')
const source=process.env.STROM164_SOURCE, modules=process.env.STROM164_MODULES
assert(source&&modules,'STROM164_SOURCE/STROM164_MODULES required')
const ts=require(path.join(modules,'typescript'))
const THREE=require(path.join(modules,'three'))
const fl=fs.readFileSync(path.join(source,'components/CameraFlight150.tsx'),'utf8')
const gr=fs.readFileSync(path.join(source,'components/CanonicalGrid152.tsx'),'utf8')
const bp=fs.readFileSync(path.join(source,'App.tsx'),'utf8')
const css=fs.readFileSync(path.join(source,'styles.css'),'utf8')
const helper=fs.readFileSync(path.join(source,'components/cameraGridAnalytic164.ts'),'utf8')
for(const [name,code,kind] of [
  ['CameraFlight150.tsx',fl,ts.ScriptKind.TSX],['CanonicalGrid152.tsx',gr,ts.ScriptKind.TSX],
  ['cameraGridAnalytic164.ts',helper,ts.ScriptKind.TS],['App.tsx',bp,ts.ScriptKind.TSX]]){
  const ast=ts.createSourceFile(name,code,ts.ScriptTarget.Latest,true,kind)
  assert.equal(ast.parseDiagnostics.length,0,`${name}: ${ast.parseDiagnostics.map(d=>d.messageText).join(',')}`)
}
assert.equal((fl.match(/\buseFrame\s*\(/g)||[]).length,1,'second camera driver')
assert.equal((fl.match(/alignGridAnalytic164\s*\(/g)||[]).length,1,'one camera calibration')
assert(!fl.includes('alignViewportExactly163('),'obsolete camera fit still active')
assert(fl.indexOf('alignGridAnalytic164(')<fl.indexOf("running.phase = 'fade'"),'fit must occur while concealed')
assert(gr.includes('for(let n=-half;n<=half;n+=1)'),'1m minor grid')
assert(gr.includes('currentFrame150()'),'grid includes all measured Blueprint viewport corners')
assert(gr.includes('for(let n=-half;n<=half;n+=5)'),'5m major grid')
assert(gr.includes("mesh.name='strom164-five-metre-lines'"),'major grid should be rendered as width-safe mesh')
assert(gr.includes('const thicknessX=2/(pxPerWorld*scaleX)'),'exact 2px major X')
assert(gr.includes('const thicknessY=2/(pxPerWorld*scaleY)'),'exact 2px major Y')
assert(css.includes('STROM164_FIVE_METRE_GRID')&&css.includes('stroke-width:2px !important;'),'Blueprint 5m stroke width')
assert(bp.includes("className={meter === 0 ? 'strom153-zero-y' : (major ? 'major' : '')}"),'Blueprint major line class')
assert(bp.includes("className={meter === 0 ? 'strom153-zero-x' : (major ? 'major' : '')}"),'Blueprint major line class Y')
const transpiled=ts.transpileModule(helper,{fileName:'cameraGridAnalytic164.ts',
  compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}})
const scope={exports:{}}
const records=[]
new Function('require','module','exports','console','window',transpiled.outputText)(
  name=>{if(name==='three')return THREE;throw Error('Unexpected runtime import '+name)},
  scope,scope.exports,{log(){},info(){},warn(){},error(...args){records.push(args.map(String).join(' '))}},
  {localStorage:{setItem(k,v){records.push([k,JSON.parse(v)])}}}
)
const {alignGridAnalytic164,viewportToPlan164}=scope.exports
const eq=(a,b,eps=1e-6)=>Math.abs(a-b)<=eps
const screen=(v,cam,rect)=>{const n=v.clone().project(cam);return {x:rect.left+(n.x+1)*rect.width/2,y:rect.top+(1-n.y)*rect.height/2}}
const tests=[
  {name:'actual user middle, viewport difference 280/130px',c:[5.960,3.849],ppm:82.6,
    vp:[330,251,1743.9,1493.9],canvas:[330,143.8,1463.9,1624.2]},
  {name:'zoom out and pan left',c:[-13.7,15.25],ppm:23.5,vp:[10,45,900,720],canvas:[200,-150,730,870]},
  {name:'zoom in and pan right',c:[37.25,-22.6],ppm:270,vp:[185,280,2150,1200],canvas:[0,100,1500,850]},
  {name:'upper floor marker height ignored: datum grid is 0',c:[8.2,3.7],ppm:65.1,floor:6.3},
  {name:'basement marker height ignored: datum grid is 0',c:[-8.2,-3.7],ppm:61.1,floor:-3},
  {name:'translated and scaled real grid',c:[4.15,-7.21],ppm:97.1,translation:[-31,9],scale:1.6},
  {name:'rotated 3D grid, matching top-down yaw',c:[10,5],ppm:57.25,yaw:0.3},
  {name:'rotated Blueprint SVG matrix',c:[5,-6],ppm:101.31,bpRotation:0.3},
  {name:'rotated both Blueprint and model',c:[-1.22,-5.21],ppm:40.3,bpRotation:-0.27,yaw:0.35},
  {name:'camera zoom factor 1.38',c:[12,1],ppm:110.3,camZoom:1.38},
  {name:'orthographic, zoom and pan',c:[3,-11],ppm:71.4,kind:'ortho'},
  {name:'orthographic rotated + scaled',c:[3,-11],ppm:133.9,kind:'ortho',bpRotation:0.2,yaw:-0.2,scale:1.25},
  {name:'orthographic asymmetric original frustum',c:[13.2,-8.1],ppm:39.3,
    kind:'ortho',orthoBounds:[-13,11,9,-7],vp:[180,210,1200,770],canvas:[45,-100,1600,810]},
  {name:'orthographic zoomed and displaced canvas',c:[-21.3,6.5],ppm:251.35,
    kind:'ortho',orthoBounds:[-29,7,11,-9],canvas:[-400,130,510,1450],bpRotation:0.24},
]
function run(t){
  const [cx,cy]=t.c
  const vr=t.vp||[130,50,1400,970],cr=t.canvas||[190,-5,1130,1100]
  const vp={left:vr[0],top:vr[1],width:vr[2],height:vr[3]}
  const canvas={left:cr[0],top:cr[1],width:cr[2],height:cr[3]}
  const angle=t.bpRotation||0,ppm=t.ppm
  const ax=ppm*Math.cos(angle),ay=ppm*Math.sin(angle),bx=-ppm*Math.sin(angle),by=ppm*Math.cos(angle)
  const vcx=vp.left+vp.width/2,vcy=vp.top+vp.height/2
  const snap={x:vcx-ax*cx-bx*cy,y:vcy-ay*cx-by*cy,ax,ay,bx,by}
  const center=viewportToPlan164(snap,vp)
  assert(center,`${t.name}: Blueprint inverse`)
  assert(eq(center.planCenter.x,cx)&&eq(center.planCenter.y,cy),`${t.name}: actual BP centre`)
  const scene=new THREE.Scene(),parent=new THREE.Group(),grid=new THREE.Group()
  parent.position.set((t.translation||[0,0])[0],0,(t.translation||[0,0])[1])
  parent.rotation.y=t.yaw||0
  parent.scale.set(t.scale||1,1,t.scale||1)
  grid.name='strom152-blueprint-grid'
  parent.add(grid);scene.add(parent)
  const floor=new THREE.Group();floor.name='strom150r-floor-reference';floor.position.y=t.floor||0
  floor.userData.active150r=true;parent.add(floor)
  scene.updateMatrixWorld(true)
  const ortho=t.kind==='ortho'
  const bounds=t.orthoBounds||[-11,11,7,-7]
  const cam=ortho?new THREE.OrthographicCamera(...bounds,0.01,2000):
    new THREE.PerspectiveCamera(48,canvas.width/canvas.height,0.01,2000)
  cam.position.set(20,50,20);cam.lookAt(0,0,0)
  cam.zoom=t.camZoom||1;cam.updateProjectionMatrix()
  const pose={position:cam.position.clone(),rotation:cam.quaternion.clone(),up:cam.up.clone(),
    target:new THREE.Vector3(),zoom:cam.zoom}
  const apply=p=>{cam.position.copy(p.position);cam.quaternion.copy(p.rotation);cam.up.copy(p.up);
    if(ortho){cam.zoom=p.zoom;cam.updateProjectionMatrix()};cam.updateMatrixWorld(true)}
  const lens=alignGridAnalytic164(scene,cam,{getBoundingClientRect(){return canvas}},pose,
    {screen150o:snap,viewport163:vp},apply)
  assert(lens,`${t.name}: alignment rejected ${records.at(-1)}`)
  if(ortho){
    const horizontal=cam.right-cam.left,vertical=cam.top-cam.bottom
    assert(eq(horizontal/vertical,canvas.width/canvas.height,1e-12),
      `${t.name}: ortho camera aspect was not matched to canvas`)
    assert(eq(cam.left+cam.right,0,1e-12)&&eq(cam.top+cam.bottom,0,1e-12),
      `${t.name}: orthographic optical centre is not centred`)
  }
  const world=new THREE.Vector3(cx,-0.018,cy).applyMatrix4(grid.matrixWorld)
  assert(eq(cam.position.x,world.x)&&eq(cam.position.z,world.z),`${t.name}: camera world centre`)
  assert(cam.position.y>world.y,`${t.name}: camera positive height`)
  const dir=new THREE.Vector3();cam.getWorldDirection(dir)
  assert(eq(dir.x,0,1e-8)&&eq(dir.y,-1,1e-8)&&eq(dir.z,0,1e-8),`${t.name}: downwards`)
  assert(eq(lens.x,canvas.left+canvas.width/2-vcx,1e-6),`${t.name}: exact CSS x translation`)
  assert(eq(lens.y,canvas.top+canvas.height/2-vcy,1e-6),`${t.name}: exact CSS y translation`)
  let worst=0
  for(const [x,y] of [[-50,-50],[-10,-10],[0,0],[1,0],[0,1],[5,0],[0,5],[10,-5],[21,13],[50,50]]){
    const w=new THREE.Vector3(x,-0.018,y).applyMatrix4(grid.matrixWorld)
    const projected=screen(w,cam,canvas)
    const desired={x:snap.x+snap.ax*x+snap.bx*y,y:snap.y+snap.ay*x+snap.by*y}
    worst=Math.max(worst,Math.hypot(projected.x-desired.x,projected.y-desired.y))
  }
  assert(worst<0.00002,`${t.name}: ${worst} css pixel error`)
  // The 5-m wide grid strips must be exactly 2 viewport pixels wide at top view.
  const sx=grid.matrixWorld.elements[0],sz=grid.matrixWorld.elements[2]
  const scaleX=Math.hypot(sx,sz)
  const d=Math.abs(cam.position.y-world.y)
  const pxPerWorld=ortho?canvas.height*cam.zoom/(cam.top-cam.bottom):canvas.height*cam.projectionMatrix.elements[5]/(2*d)
  const stripWidth=2/(pxPerWorld*scaleX)
  const a=screen(new THREE.Vector3(-stripWidth/2,-0.018,0).applyMatrix4(grid.matrixWorld),cam,canvas)
  const b=screen(new THREE.Vector3(stripWidth/2,-0.018,0).applyMatrix4(grid.matrixWorld),cam,canvas)
  assert(eq(Math.hypot(a.x-b.x,a.y-b.y),2,1e-6),`${t.name}: 2px major width`)
  console.log('PASS 164:',t.name,'error',worst.toFixed(9),'CSS px')
}
for(const t of tests)run(t)
const originalErrors=records.length
assert.equal(viewportToPlan164({x:0,y:0,ax:50,ay:0,bx:5,by:45},
  {left:0,top:0,width:500,height:400}),null,'sheared SVG rejected')
assert.equal(viewportToPlan164({x:0,y:0,ax:50,ay:0,bx:0,by:-50},
  {left:0,top:0,width:500,height:400}),null,'inverted SVG rejected')
console.log('PASS 164b: exact 0/1/5m 2D-3D equality in all 14 real Three.js perspective/orthographic cases; all 5m lines are 2px.')
STROM164_TEST
log "3) Apply single exact 2D-to-3D grid calibration and major 5m lines ..."
python3 -m py_compile "$RESOURCE_DIR/patch164.py" >>"$DIAG_LOG" 2>&1 || fail "164 Python patch syntax error"
STROM164_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch164.py" >>"$DIAG_LOG" 2>&1 || \
  fail "164 source mismatch; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build BEFORE committing ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "164 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Regression: actual Three.js 0/1/5m pixel projections, viewport zoom and pan ..."
STROM164_SOURCE="$WORK_DIR/frontend/src" STROM164_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test164.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "164 real Three.js projection regression failed; GitHub and Stage unchanged"
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch164.py" "$WORK_DIR/deploy/updates/${SCRIPT_NAME}_patch.py"
cat > "$WORK_DIR/docs/STROM_UPDATE_164b.md" <<'STROM164_DOC'
# Strom 164b: orthographic canvas aspect and exact Blueprint-to-3D grid transform

- One click-time Blueprint SVG matrix in CSS pixels and one visible viewport.
- Exactly the displayed 3D grid's matrixWorld is the 3D coordinate reference.
- Camera architectural XY above Blueprint viewport centre, optical axis vertical.
- Eye height from one closed-form FOV/pixel-scale formula, no iterations.
- Ortho camera horizontal span is derived exactly from real canvas CSS aspect;
  top/bottom and left/right centred before zoom. This removes the 445.040 CSS px
  horizontal mismatch in the failing 164 orthographic test.
- On calibration failure, restore original orthographic frustum as well as pose.
- Only an exact projection shift for different canvas/viewport DOM rectangles.
- Origin, 1m and 5m basis verified by the real Three.js projection before fade.
- 1m minor lines 1 CSS px; 5m major lines 2 CSS px in BP and 3D.
- 3D major widths use instanced planar geometry (not unsupported glLineWidth).
- Existing axis colors, all animation timings, endpoint, reverse driver untouched.
- All prerequisites / TypeScript / actual THREE regressions checked before push.
- Test deployment only. Production unchanged.
- Browser record: localStorage['strom.camera164.alignment'].
STROM164_DOC
rm -rf "$RESOURCE_DIR"
log "6) Synchronize verified source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "164 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "7) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "164 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "164 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "164 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 164 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
