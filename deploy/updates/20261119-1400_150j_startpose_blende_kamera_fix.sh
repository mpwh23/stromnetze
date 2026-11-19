#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1400_150j_startpose_blende_kamera_fix"
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
COMMIT_MESSAGE="Update 150j: real render camera and fixed starting pose throughout Blueprint fade"
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
  echo "2) Update 150j im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150j isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150j: freeze real top-view camera during 5s fade, then fly for 5s ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
grep -Fq 'STROM150H_LANDSCAPE' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || fail "150j requires successfully installed 150h"
grep -Fq 'STROM150E_LOADING_GUARD' "$STAGE_DIR/frontend/src/App.tsx" || fail "150j requires 150e loading-guard UI"
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
RESOURCE_DIR="$WORK_DIR/150j_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150j.py" <<'STROM150J_PY'
#!/usr/bin/env python3
"""150j: use the active R3F render camera throughout intro fade and flight."""
from pathlib import Path
import os

src=Path(os.environ['STROM150J_ROOT'])/'frontend/src'
flight=src/'components/CameraFlight150.tsx'
bridge=src/'components/cameraTransitions150.ts'
app=src/'App.tsx'
css=src/'styles.css'
for path in (flight,bridge,app,css):
    if not path.is_file():raise RuntimeError(f'150j source missing: {path}')
f=flight.read_text('utf8')
b=bridge.read_text('utf8')
a=app.read_text('utf8')
c=css.read_text('utf8')
if 'STROM150J_ACTIVE_RENDER_CAMERA' in f:
    raise RuntimeError('150j already installed')
for marker in ('STROM150H_LANDSCAPE','topBasis150h', 'STROM150F_BLUEPRINT_AXES',
               'orbitFrozen150f', 'freezeOrbit150f()', 'STROM150E_NO_CONTROLS_WAIT',
               'entryWaitFrames150e.current>=1', 'running.started=performance.now()+ENTER_FADE150'):
    if marker not in f:raise RuntimeError(f'150j requires installed 150j camera module: {marker}')
for text,marker in ((b,'export const ENTER_FADE150=5000'),(b,'export const DURATION150=5000'),
                    (a,'STROM150C_PRESERVE_BLUEPRINT'),(a,'STROM150E_LOADING_GUARD'),
                    (c,'transition:opacity 5000ms ease;')):
    if marker not in text:raise RuntimeError(f'150j required 150j base missing: {marker}')

def one(old,new,label):
    global f
    count=f.count(old)
    if count!=1:raise RuntimeError(f'150j {label}: 1 anchor expected; {count} found')
    f=f.replace(old,new,1)

# Do NOT subscribe the rig lifetime to camera identity. A camera swap during 3D
# initialization used to tear down the active flight, leaving the old 3D pose
# visible under the Blueprint during its fade.
one('''  const camera=useThree(state=>state.camera)
  // Never subscribe to changing OrbitControls identity: its late registration caused''',
'''  // STROM150J_ACTIVE_RENDER_CAMERA: do not subscribe to a potentially changing camera.
  // Always address the camera actually used by the Canvas renderer.
  // Never subscribe to changing OrbitControls identity: its late registration caused''',
'camera subscription removal')
one('''  const getState=useThree(state=>state.get)
  const size=useThree(state=>state.size)''',
'''  const getState=useThree(state=>state.get)
  const activeCamera150j=()=>getState().camera
  const size=useThree(state=>state.size)''',
'active render camera accessor')
one('''  const flight=useRef<Flight150|null>(null)
  const initialPose=useRef<Pose150|null>(null)''',
'''  const flight=useRef<Flight150|null>(null)
  const flightCamera150j=useRef<THREE.Camera|null>(null)
  const initialPose=useRef<Pose150|null>(null)''',
'camera instance tracking')

# Camera application cannot use a stale instance from an earlier <Canvas> frame.
# Apply all pose properties consistently to the current R3F render camera.
old_apply='''  const apply=(pose:Pose150)=>{
    camera.position.copy(pose.position)
    camera.quaternion.copy(pose.rotation)
    const controls=controls150()
    if(controls?.target)controls.target.copy(pose.target)
    const ortho=camera as THREE.OrthographicCamera
    if(ortho.isOrthographicCamera){ortho.zoom=pose.zoom;ortho.updateProjectionMatrix()}
    camera.updateMatrixWorld()
    invalidate()
  }'''
new_apply='''  const apply=(pose:Pose150)=>{
    const camera150j=activeCamera150j()
    camera150j.position.copy(pose.position)
    camera150j.quaternion.copy(pose.rotation)
    const controls=controls150()
    if(controls?.target)controls.target.copy(pose.target)
    const ortho=camera150j as THREE.OrthographicCamera
    if(ortho.isOrthographicCamera){ortho.zoom=pose.zoom;ortho.updateProjectionMatrix()}
    camera150j.updateMatrixWorld()
    invalidate()
  }'''
one(old_apply,new_apply,'dynamic camera application')

# 2 topPose and 2 snapshots are used (entry, reverse). Preserve existing geometry.
n=f.count('topPose150(camera,bounds,latest.current.aspect,latest.current.points)')
if n!=2:raise RuntimeError(f'150j topPose instances expected 2, found {n}')
f=f.replace('topPose150(camera,bounds,latest.current.aspect,latest.current.points)',
            'topPose150(activeCamera150j(),bounds,latest.current.aspect,latest.current.points)')
one('snapshot150(camera,controls,bird.target)',
    'snapshot150(activeCamera150j(),controls,bird.target)', 'reverse snapshot')
one('snapshot150(camera,controls,new THREE.Vector3())',
    'snapshot150(activeCamera150j(),controls,new THREE.Vector3())','entry snapshot')
one('''      const current=snapshot150(activeCamera150j(),controls,bird.target)
      queuedEntry.current=null''',
'''      const current=snapshot150(activeCamera150j(),controls,bird.target)
      flightCamera150j.current=activeCamera150j()
      queuedEntry.current=null''',
'reverse current camera')
one('''      const original=snapshot150(activeCamera150j(),controls,new THREE.Vector3())
      initialPose.current=original''',
'''      const original=snapshot150(activeCamera150j(),controls,new THREE.Vector3())
      flightCamera150j.current=activeCamera150j()
      initialPose.current=original''',
'entry current camera')
one('''      flight.current=null
      entryWaiting.current=false
    }
  // Camera and renderer identity''',
'''      flight.current=null
      flightCamera150j.current=null
      entryWaiting.current=false
    }
  // Camera and renderer identity''',
'cleanup instance reset')
one('''  },[camera,gl,getState])''',
'''  },[gl,getState])''','do not restart effect on camera change')

# Camera may still be replaced by Drei makeDefault after entering. Rebase the
# destination from that new actual camera only while it remains hidden by BP.
# Never change the camera maths once the visible flight has already started.
one('''    // Re-acquire controls if Drei registers them after the first frame.
    freezeOrbit150f()
    if(entryWaiting.current){''',
'''    // Re-acquire controls if Drei registers them after the first frame.
    freezeOrbit150f()
    const liveCamera150j=activeCamera150j()
    if(flightCamera150j.current!==liveCamera150j){
      if(entryWaiting.current||performance.now()<running.started){
        const bounds150j=planBounds150(latest.current.points,currentFrame150())
        running.end=snapshot150(liveCamera150j,controls150(),running.end.target)
        running.start=topPose150(liveCamera150j,bounds150j,latest.current.aspect,latest.current.points)
      }
      flightCamera150j.current=liveCamera150j
    }
    if(entryWaiting.current){
      // Make the real 3D start image stable BEFORE announcing readiness.
      apply(running.start)''',
'hold same top pose in readiness frames')

# Two WebGL frames after initial preparation before starting the overlay fade.
# This avoids announcing readiness from a frame rendered with the old camera.
one('''      if(entryWaitFrames150e.current>=1){''',
'''      if(entryWaitFrames150e.current>=2){''',
'multiple painted top frames')

# Holding the visible 3D camera during the 5s fade is intentionally explicit.
# At fade completion the flight begins from precisely the same pose, no jump.
one('''    const t=clamp150((performance.now()-running.started)/DURATION150,0,1)''',
'''    if(performance.now()<running.started){
      apply(running.start)
      return
    }
    const t=clamp150((performance.now()-running.started)/DURATION150,0,1)''',
'hold top during crossfade')

# Confirm no stale in-component camera variable remains; parameter signatures are fine.
if 'const camera=useThree(state=>state.camera)' in f or '[camera,gl,getState]' in f:
    raise RuntimeError('150j stale camera reference remains')
flight.write_text(f,'utf8')
print('PASS 150j: real R3F camera held at the same 3D top pose throughout 5s fade; camera swaps handled; flight unchanged')
STROM150J_PY

log "3) Apply camera-start stability fix to isolated source ..."
python3 -m py_compile "$RESOURCE_DIR/patch150j.py" >>"$DIAG_LOG" 2>&1 || fail "150j Python syntax failed"
STROM150J_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150j.py" >>"$DIAG_LOG" 2>&1 || fail "150j camera patch failed; GitHub and Stage unchanged"
log "4) TypeScript syntax and stable 3D start-pose audit ..."
STROM150J_SOURCE="$WORK_DIR/frontend/src" STROM150J_TS="$DEPENDENCIES/typescript" node <<'STROM150J_AUDIT' >>"$DIAG_LOG" 2>&1 || fail "150j AST/camera audit failed; GitHub and Stage unchanged"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150J_TS)
const root=process.env.STROM150J_SOURCE
for(const rel of ['App.tsx','components/CameraFlight150.tsx','components/cameraTransitions150.ts','components/Building3DWorkspace.tsx']){
 const source=fs.readFileSync(path.join(root,rel),'utf8')
 const ast=ts.createSourceFile(rel,source,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 if(ast.parseDiagnostics.length)throw Error(rel+': '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const css=fs.readFileSync(path.join(root,'styles.css'),'utf8')
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
assert(bridge.includes('export const ENTER_FADE150=5000'))
assert(bridge.includes('export const DURATION150=5000'))
assert(css.includes('transition:opacity 5000ms ease;'))
assert(flight.includes('STROM150J_ACTIVE_RENDER_CAMERA'))
assert(flight.includes('const activeCamera150j=()=>getState().camera'))
assert(!flight.includes('const camera=useThree(state=>state.camera)'))
assert(flight.includes('const camera150j=activeCamera150j()'))
assert(flight.includes('flightCamera150j.current!==liveCamera150j'))
assert(flight.includes('entryWaitFrames150e.current>=2'))
assert(flight.includes('if(performance.now()<running.started)'))
assert(flight.includes('apply(running.start)'))
assert(flight.includes('running.started=performance.now()+ENTER_FADE150'))
assert(flight.includes('rotation:a.rotation.clone().slerp(b.rotation,k)'))
assert(bridge.includes('DURATION150+1000'))
for(const marker of ['STROM150H_LANDSCAPE','topBasis150h','STROM150F_BLUEPRINT_AXES','orbitFrozen150f','freezeOrbit150f','unfreezeOrbit150f'])
 assert(flight.includes(marker),'Lost camera safeguard '+marker)
for(const marker of ['STROM150C_PRESERVE_BLUEPRINT','STROM150E_LOADING_GUARD'])
 assert(app.includes(marker),'Lost loader UI '+marker)
console.log('PASS 150j: dynamic render-camera tracking, stable top pose, 5s fade + flight, prior controls protection')
STROM150J_AUDIT
log "5) Full TypeScript/Vite build against existing Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150j TypeScript/Vite build failed before GitHub push"
log "5.1) Camera and transition runtime regression ..."
STROM150J_SOURCE="$WORK_DIR/frontend/src" STROM150J_TS="$DEPENDENCIES/typescript" node <<'STROM150J_TEST' >>"$DIAG_LOG" 2>&1 || fail "150j camera regression failed; GitHub and Stage unchanged"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150J_TS)
const src=process.env.STROM150J_SOURCE
const code=fs.readFileSync(path.join(src,'components/cameraTransitions150.ts'),'utf8')
const flight=fs.readFileSync(path.join(src,'components/CameraFlight150.tsx'),'utf8')
const result=ts.transpileModule(code,{fileName:'cameraTransitions150.ts',compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText
const moduleBridge={exports:{}},timeouts=[]
const fakeWindow={localStorage:{getItem:()=>null},setTimeout:(fn,ms)=>{timeouts.push(ms);return timeouts.length},clearTimeout:()=>{}}
new Function('module','exports','require','window','document',result)(moduleBridge,moduleBridge.exports,require,fakeWindow,{querySelector:()=>null})
const api=moduleBridge.exports
assert.equal(api.ENTER_FADE150,5000)
assert.equal(api.DURATION150,5000)
api.registerExit150(()=>{})
assert(api.requestExit150(()=>{}))
assert(timeouts.some(ms=>ms>=6000),'Reverse-flight timeout must not interrupt 5s flight')
assert.equal((flight.match(/apply\(running\.start\)/g)||[]).length,2,'must pin 3D start pose during readiness and fade')
assert.equal((flight.match(/topPose150\(activeCamera150j\(\),bounds,latest\.current\.aspect,latest\.current\.points\)/g)||[]).length,2,'both forward and reverse must use active render camera')
assert.equal((flight.match(/snapshot150\(activeCamera150j\(\),controls/g)||[]).length,2,'both flight snapshots must use active render camera')
console.log('PASS 150j runtime: 5s/5s, no reverse timeout, live camera and top pose pinned before fade')
STROM150J_TEST
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150J.md" <<'STROM150J_DOC'
# Update 150j – camera start pose fixed during crossfade
- Forward transition: hold the same active R3F camera at the intended bird's-eye pose throughout the Blueprint -> 3D crossfade.
- Handle delayed R3F camera registration without restarting the camera flight.
- Preserve 5,000ms fade, 5,000ms eased flight in both directions for visual diagnostics.
- Keep live Blueprint preview, spinner, geometry, pan/zoom settings and 3D OrbitControls intact.
- Fail-safe: isolated full TypeScript/Vite build before GitHub push, backup and deployment only to /strom-test/.
STROM150J_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150j Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150j Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150j frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150j test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150j deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
