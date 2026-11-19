#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1240_150f_blueprint_kamera_ausrichtung"
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
COMMIT_MESSAGE="Update 150f: fixed Blueprint X/Y camera axes, suppress orbit-controlled roll during 3D flights"
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
  echo "2) Update 150f im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150f isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150f: Blueprint-parallel 3D bird view with orbit lock during flights ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
grep -Fq 'STROM150E_NO_CONTROLS_WAIT' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || fail "150f requires successfully installed 150e"
grep -Fq 'STROM150E_LOADING_GUARD' "$STAGE_DIR/frontend/src/App.tsx" || fail "150f requires 150e loading-guard UI"
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
RESOURCE_DIR="$WORK_DIR/150f_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150f.py" <<'STROM150F_PY'
#!/usr/bin/env python3
"""150f incremental camera roll correction. No 3D geometry, data or UI modifications."""
from pathlib import Path
import os

root=Path(os.environ['STROM150F_ROOT'])/'frontend/src'
flight=root/'components/CameraFlight150.tsx'
bridge=root/'components/cameraTransitions150.ts'
app=root/'App.tsx'
for p in (flight,bridge,app):
    if not p.is_file():raise RuntimeError(f'150f file missing: {p}')
f=flight.read_text('utf8')
b=bridge.read_text('utf8')
a=app.read_text('utf8')
if 'STROM150F_BLUEPRINT_AXES' in f:raise RuntimeError('150f already installed')
for must in ('STROM150E_NO_CONTROLS_WAIT','const UP150=new THREE.Vector3(0,0,-1)','function topPose150(', 'const controls150=', 'function snapshot150('):
    if must not in f:raise RuntimeError(f'150f camera prerequisite missing: {must}')
if 'export const ENTER_FADE150=500' not in b or 'export const DURATION150=1500' not in b:
    raise RuntimeError('150f requires exactly 500ms fade and 1500ms flight')
if 'STROM150E_LOADING_GUARD' not in a:raise RuntimeError('150f UI prerequisite missing')

def one(old,new,label):
    global f
    n=f.count(old)
    if n!=1:raise RuntimeError(f'150f {label}: expected exactly 1 anchor; found {n}')
    f=f.replace(old,new,1)

# Matrix columns: camera screen-right = world +X; screen-up = world -Z;
# camera backward = world +Y.  This makes Blueprint Y-down = 3D Z-down.
one('const UP150=new THREE.Vector3(0,0,-1)', '''// STROM150F_BLUEPRINT_AXES: 2D screen X -> +3D X, 2D screen Y-down -> +3D Z.
const RIGHT150F=new THREE.Vector3(1,0,0)
const UP150F=new THREE.Vector3(0,0,-1)
const BACK150F=new THREE.Vector3(0,1,0)''','fixed orthogonal axes')
one('''  const topView=new THREE.Matrix4().lookAt(position,target,UP150)''',
    '''  // An explicit orthogonal basis avoids roll at the camera's polar singularity.
  const topView=new THREE.Matrix4().makeBasis(RIGHT150F,UP150F,BACK150F)''',
    'overhead camera orientation')

# OrbitControls may update the quaternion on EVERY render even when enabled=false.
# While flying, its update callback must be temporarily suspended; restore afterward.
one('''  const controls150=()=>((getState().controls||null) as Control150|null)''',
'''  const controls150=()=>((getState().controls||null) as Control150|null)
  const orbitFrozen150f=useRef<{control:Control150;update?:()=>void;enabled?:boolean}|null>(null)
  const unfreezeOrbit150f=()=>{
    const frozen=orbitFrozen150f.current
    if(!frozen)return
    if(frozen.update)frozen.control.update=frozen.update
    if(frozen.enabled!==undefined)frozen.control.enabled=frozen.enabled
    orbitFrozen150f.current=null
  }
  const freezeOrbit150f=()=>{
    const control=controls150()
    if(!control)return
    if(orbitFrozen150f.current?.control===control)return
    unfreezeOrbit150f()
    const previous={control,update:control.update,enabled:control.enabled}
    orbitFrozen150f.current=previous
    control.enabled=false
    if(control.update){
      try { control.update=()=>{} } catch { /* camera pose is reapplied after controls */ }
    }
  }''','orbit lock helpers')
one('''      if(controls)controls.enabled=false
      flight.current={start:current,end:bird,started:performance.now(),done,''',
    '''      freezeOrbit150f()
      flight.current={start:current,end:bird,started:performance.now(),done,''',
    'reverse orbit freeze')
one('''      unregister()
      const controls=controls150()''',
    '''      unregister()
      unfreezeOrbit150f()
      const controls=controls150()''',
    'unfreeze at unmount')
one('''      if(controls)controls.enabled=false
      apply(bird)''',
    '''      freezeOrbit150f()
      apply(bird)''',
    'entry orbit freeze')
one('''    const running=flight.current
    if(!running)return
    if(entryWaiting.current){''',
    '''    const running=flight.current
    if(!running)return
    // Re-acquire controls if Drei registers them after the first frame.
    freezeOrbit150f()
    if(entryWaiting.current){''',
    'late controls orbit freeze')
one('''        const controls=controls150()
        if(controls){
          // Synchronize orbit internals *before* restoring interaction.
          controls.update?.()
          apply(b)
          controls.enabled=running.restoreControls??true
        }''',
    '''        const controls=controls150()
        unfreezeOrbit150f()
        if(controls){
          // Reconcile controls at the exact original target/pose on entry completion.
          if(controls.target)controls.target.copy(b.target)
          controls.update?.()
          apply(b)
          controls.enabled=running.restoreControls??true
        }''',
    'restore orbit without roll on entry completion')

# Write only after every invariant has been checked.
flight.write_text(f,'utf8')
print('PASS 150f: fixed Blueprint X/Y axes and stopped OrbitControls roll during both camera flights')
STROM150F_PY
log "3) Apply incremental camera fix in isolated source ..."
python3 -m py_compile "$RESOURCE_DIR/patch150f.py" >>"$DIAG_LOG" 2>&1 || fail "150f Python syntax failed"
STROM150F_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150f.py" >>"$DIAG_LOG" 2>&1 || fail "150f patch failed; GitHub and Stage unchanged"
log "4) TypeScript TSX syntax and changed-module audit ..."
STROM150F_SOURCE="$WORK_DIR/frontend/src" STROM150F_TS="$DEPENDENCIES/typescript" node <<'STROM150F_AST' >>"$DIAG_LOG" 2>&1 || fail "150f TSX parse failed; GitHub and Stage unchanged"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150F_TS)
const root=process.env.STROM150F_SOURCE
let checked=0
for(const rel of ['App.tsx','components/CameraFlight150.tsx','components/cameraTransitions150.ts','components/Building3DWorkspace.tsx']){
 const text=fs.readFileSync(path.join(root,rel),'utf8')
 const tree=ts.createSourceFile(rel,text,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 if(tree.parseDiagnostics.length)throw Error(rel+': '+tree.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
 checked++
}
const f=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const b=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
assert(f.includes('STROM150F_BLUEPRINT_AXES'))
assert(f.includes('makeBasis(RIGHT150F,UP150F,BACK150F)'))
assert(!f.includes('lookAt(position,target,UP150)'))
assert(f.includes('orbitFrozen150f'))
assert(f.includes('unfreezeOrbit150f()'))
assert(f.includes('freezeOrbit150f()'))
assert(f.includes('entryWaitFrames150e.current>=1'))
assert(b.includes('ENTER_FADE150=500')&&b.includes('DURATION150=1500'))
// 2D plan right = +X in 3D; 2D plan down = +Z in 3D.
const right=[1,0,0],up=[0,0,-1],back=[0,1,0]
const dot=(a,b)=>a.reduce((n,x,i)=>n+x*b[i],0)
assert.equal(dot([1,0,0],right),1,'Blueprint right points right in camera')
assert.equal(dot([0,0,1],up),-1,'Blueprint down points down in camera')
assert.equal(dot(right,up),0);assert.equal(dot(right,back),0);assert.equal(dot(up,back),0)
console.log('PASS 150f:',checked,'TS/TSX modules parsed; orthogonal Blueprint axes confirmed')
STROM150F_AST
log "5) Full TypeScript/Vite build with real Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150f TypeScript/Vite build failed before GitHub push"
log "5.1) Runtime camera regression tests: entry, reverse and OrbitControls freeze ..."
STROM150F_SOURCE="$WORK_DIR/frontend/src" STROM150F_TS="$DEPENDENCIES/typescript" node <<'STROM150F_TEST' >>"$DIAG_LOG" 2>&1 || fail "150f camera regression failed; GitHub and Stage unchanged"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150F_TS)
const source=process.env.STROM150F_SOURCE
const flight=fs.readFileSync(path.join(source,'components/CameraFlight150.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(source,'components/cameraTransitions150.ts'),'utf8')
const transpile=(code,name)=>ts.transpileModule(code,{fileName:name,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}}).outputText
const moduleBridge={exports:{}},fakeWindow={localStorage:{getItem:()=>null},setTimeout:()=>1,clearTimeout:()=>{}}
new Function('module','exports','require','window','document',transpile(bridge,'cameraTransitions150.ts'))(moduleBridge,moduleBridge.exports,require,fakeWindow,{querySelector:()=>null})
const api=moduleBridge.exports
class V {constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}clone(){return new V(this.x,this.y,this.z)}copy(v){this.x=v.x;this.y=v.y;this.z=v.z;return this}lerp(v,k){this.x+=(v.x-this.x)*k;this.y+=(v.y-this.y)*k;this.z+=(v.z-this.z)*k;return this}}
class Q {constructor(v=0){this.v=v}clone(){return new Q(this.v)}copy(q){this.v=q.v;return this}setFromRotationMatrix(m){this.v=m.kind==='basis'?42:-90;return this}slerp(q,k){this.v+=(q.v-this.v)*k;return this}}
class M {makeBasis(r,u,b){assert.equal(r.x,1);assert.equal(u.z,-1);assert.equal(b.y,1);this.kind='basis';return this}}
const THREE={Vector3:V,Quaternion:Q,Matrix4:M,MathUtils:{degToRad:x=>x*Math.PI/180}}
let frame=null,now=1000,cleanup=null
const camera={position:new V(7,9,9),quaternion:new Q(4),fov:45,isPerspectiveCamera:true,isOrthographicCamera:false,updateMatrixWorld(){}}
let jumps=0,updates=0
const ctrl={target:new V(0,0,0),enabled:true,update(){updates++;camera.quaternion.v=-99;jumps++}}
const r3f={camera,controls:ctrl,size:{width:1000,height:600},invalidate(){},gl:{},get(){return r3f}}
const React={useRef:value=>({current:value}),useLayoutEffect:fn=>{cleanup=fn()}}
const Fiber={useThree:sel=>sel(r3f),useFrame:fn=>{frame=fn}}
const requireFlight=key=>key==='react'?React:key==='@react-three/fiber'?Fiber:key==='three'?THREE:key==='./cameraTransitions150'?api:(()=>{throw Error('unexpected module '+key)})()
const moduleFlight={exports:{}}
new Function('module','exports','require','performance',transpile(flight,'CameraFlight150.tsx'))(moduleFlight,moduleFlight.exports,requireFlight,{now:()=>now})
const defaultFlight=moduleFlight.exports.default
let ready=0
api.registerEnterReady150(()=>ready++)
api.queueEntry150('threeD','house')
defaultFlight({points:[{x:0,y:0},{x:10,y:5}]})
assert(frame,'frame callback installed')
frame();assert.equal(camera.quaternion.v,42,'first camera pose matches Blueprint axes');assert.equal(ctrl.enabled,false)
assert.equal(typeof ctrl.update,'function')
const updatesBefore=updates;ctrl.update();assert.equal(updates,updatesBefore,'orbit update frozen during flight')
frame();assert.equal(ready,1,'spinner releases after rendered frame')
now=3800;frame();assert.equal(ctrl.enabled,true,'orbit enabled after entry')
assert(updates>updatesBefore,'orbit update restored and synchronized')
let exitDone=0
api.requestExit150(()=>exitDone++)
assert.equal(ctrl.enabled,false)
ctrl.update();assert.equal(updates,updatesBefore+1,'orbit update frozen during reverse')
now=5500;frame();assert.equal(exitDone,1,'reverse flight completes')
cleanup?.();assert.equal(ctrl.enabled,true,'controls restored on unmount')
// Regression: a view with no registered OrbitControls must still become ready.
r3f.controls=null
camera.position.copy(new V(4,9,11));camera.quaternion.v=5
let noControlsReady=0
api.registerEnterReady150(()=>noControlsReady++)
api.queueEntry150('wall','house')
now=6000;defaultFlight({points:[{x:0,y:0},{x:8,y:4}]})
frame();assert.equal(camera.quaternion.v,42,'top view is still axis-aligned without controls')
frame();assert.equal(noControlsReady,1,'loading indicator releases without controls')
now=8200;frame();cleanup?.()
console.log('PASS runtime 150f: Blueprint axes, entry/reverse orbit freeze, late/missing controls, 500ms fade, 1500ms flight')
STROM150F_TEST
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150F.md" <<'STROM150F_DOC'
# Update 150f – Geometrisch korrekte Blueprint/3D-Ausrichtung
- Physikalisch eindeutige Draufsicht: Blueprint X horizontal wird Welt X horizontal, Blueprint Y nach unten wird Welt Z nach unten.
- Die 3D-Kamerasteuerung darf waehrend des Kamera-Flugs die Orientierung nicht zurueckdrehen; sie wird voruebergehend eingefroren.
- Kamerasteuerung nach dem Flug bzw. beim Unmount wiederherstellen; auch spaete Control-Registrierung moeglich.
- 500 ms Ueberblendung, 1500 ms Ease-out-Flug und vorhandener Ladekreis bleiben unveraendert.
- Keine Aenderung an 3D-Geometrie, Blueprint-Daten, CSS oder Icons.
- Isolierter Build vor GitHub-Push; ausschliesslich Stage und /strom-test/, Produktion /strom/ unberuehrt.
STROM150F_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150f Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy to /strom-test/ only ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150f Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150f frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150f test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150f deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
