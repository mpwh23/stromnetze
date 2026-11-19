#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1510_150l_renderfreigabe_kameraflug"
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
COMMIT_MESSAGE="Update 150l: stable 3D frame readiness without render callback deadlock"
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
  echo "2) Update 150l im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150l isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150l: loader -> stable camera/paint -> 5s fade -> 5s flight ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
grep -Fq 'STROM150J_ACTIVE_RENDER_CAMERA' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || fail "150k requires successfully installed 150j"
grep -Fq 'STROM150E_LOADING_GUARD' "$STAGE_DIR/frontend/src/App.tsx" || fail "150k requires existing 150e loading-guard UI"
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
RESOURCE_DIR="$WORK_DIR/150l_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150l.py" <<'STROM150L_PY'
#!/usr/bin/env python3
"""150l: prevent spinner deadlock without prematurely revealing the 3D camera.

Replace 150k's render-sentinel-only gate by a three-R3F-frame camera
stability gate followed by two browser animation frames. This also works
when the invisible sentinel is not emitted by the renderer.
"""
from pathlib import Path
import os

src = Path(os.environ['STROM150L_ROOT']) / 'frontend/src'
flight = src / 'components/CameraFlight150.tsx'
app = src / 'App.tsx'
bridge = src / 'components/cameraTransitions150.ts'
css = src / 'styles.css'
for path in (flight, app, bridge, css):
    if not path.is_file():
        raise RuntimeError(f'150l source missing: {path}')
f = flight.read_text('utf8')
a = app.read_text('utf8')
b = bridge.read_text('utf8')
c = css.read_text('utf8')

if 'STROM150L_READY_HANDSHAKE' in f:
    raise RuntimeError('150l already installed; refusing double-patch')
for needle in (
    'STROM150K_AFTER_RENDER_GATE',
    'STROM150J_ACTIVE_RENDER_CAMERA',
    'entryWaitFrames150e.current>=3',
    'frameTick150k.current++',
    'strom150k-render-sentinel',
    'apply(running.start)',
    'topBasis150h',
    'freezeOrbit150f()',
    'notifyEnterReady150()',
):
    if needle not in f:
        raise RuntimeError(f'150l requires deployed 150k camera code: {needle}')
for needle, text in (
    ('STROM150K_FAIL_CLOSED', a),
    ('STROM150E_LOADING_GUARD', a),
    ('STROM150C_PRESERVE_BLUEPRINT', a),
    ('export const ENTER_FADE150=5000', b),
    ('export const DURATION150=5000', b),
    ('transition:opacity 5000ms ease;', c),
):
    if needle not in text:
        raise RuntimeError(f'150l expected deployed timing/loader base: {needle}')

def one(old, new, label):
    global f
    count = f.count(old)
    if count != 1:
        raise RuntimeError(f'150l {label}: one anchor expected, found {count}')
    f = f.replace(old, new, 1)

one('''  const entryWaitFrames150e=useRef(0) // STROM150E_NO_CONTROLS_WAIT: now counts confirmed WebGL renders
  const frameTick150k=useRef(0)
  const lastAckTick150k=useRef(-1)''',
'''  const entryWaitFrames150e=useRef(0) // STROM150L_FRAME_HANDSHAKE
  const readyRaf150l=useRef<number|null>(null)
  const readyScheduled150l=useRef(false)''', 'ready gate refs')

start = f.index('  // STROM150K_AFTER_RENDER_GATE:')
end = f.index('  useLayoutEffect(()=>{\n    // Consume once per Canvas mount', start)
old_callback = f[start:end]
if 'confirmRendered150k=' not in old_callback or 'notifyEnterReady150()' not in old_callback:
    raise RuntimeError('150l: render-only gate anchor ambiguous')
new_callback = '''  // STROM150L_READY_HANDSHAKE: three stable R3F camera frames + two browser
  // paint opportunities. No invisible mesh callbacks or unconditional fade timer.
  const scheduleReady150l=()=>{
    if(readyScheduled150l.current || !entryWaiting.current || !flight.current)return
    const preparedCamera=activeCamera150j()
    readyScheduled150l.current=true
    const confirm150l=()=>{
      readyRaf150l.current=null
      readyScheduled150l.current=false
      const running=flight.current
      if(!entryWaiting.current || !running)return
      const actualCamera=activeCamera150j()
      const cameraOrtho=actualCamera as THREE.OrthographicCamera
      const aligned=actualCamera===preparedCamera &&
        actualCamera.position.distanceTo(running.start.position)<0.0005 &&
        Math.abs(actualCamera.quaternion.dot(running.start.rotation))>0.999999 &&
        (!cameraOrtho.isOrthographicCamera || Math.abs(cameraOrtho.zoom-running.start.zoom)<0.0001)
      if(!aligned){
        entryWaitFrames150e.current=0
        invalidate()
        return
      }
      entryWaiting.current=false
      running.started=performance.now()+ENTER_FADE150
      notifyEnterReady150()
      invalidate()
    }
    readyRaf150l.current=window.requestAnimationFrame(()=>{
      readyRaf150l.current=window.requestAnimationFrame(confirm150l)
    })
  }
  useLayoutEffect(()=>()=>{
    if(readyRaf150l.current!==null)window.cancelAnimationFrame(readyRaf150l.current)
    readyRaf150l.current=null
    readyScheduled150l.current=false
  },[])
'''
f = f[:start] + new_callback + f[end:]

one('''    if(entryWaiting.current){
      // Keep the spinner and original Blueprint until 3 confirmed painted top frames.
      apply(running.start)
      invalidate()
      return
    }''',
'''    if(entryWaiting.current){
      // Hold the active 3D camera at the correct top pose while loading.
      apply(running.start)
      entryWaitFrames150e.current++
      if(entryWaitFrames150e.current>=3)scheduleReady150l()
      invalidate()
      return
    }''', 'stable frame gate')

one('''  useFrame(()=>{
    frameTick150k.current++
    if(queuedEntry.current){''',
'''  useFrame(()=>{
    if(queuedEntry.current){''', 'remove sentinel tick')

one('''  return <mesh name="strom150k-render-sentinel" frustumCulled={false} renderOrder={1000000}
    onAfterRender={(_renderer,_scene,renderedCamera)=>confirmRendered150k(renderedCamera)}>
    <planeGeometry args={[0.001,0.001]} />
    <meshBasicMaterial colorWrite={false} depthWrite={false} depthTest={false} />
  </mesh>
}''',
'''  return null
}''', 'remove unreliable renderer sentinel')

for absent in ('confirmRendered150k', 'lastAckTick150k', 'frameTick150k', 'strom150k-render-sentinel'):
    if absent in f:
        raise RuntimeError(f'150l obsolete render dependency still present: {absent}')
if f.count('notifyEnterReady150()') != 1:
    raise RuntimeError('150l: unexpected duplicate ready triggers')

flight.write_text(f, 'utf8')
print('PASS 150l: stable active camera frames -> two browser paints -> fade 5000ms -> flight 5000ms, no render-sentinel deadlock')
STROM150L_PY

log "3) Replace unreliable renderer sentinel with stable frame/paint handshake ..."
python3 -m py_compile "$RESOURCE_DIR/patch150l.py" >>"$DIAG_LOG" 2>&1 || fail "150l Python syntax failed"
STROM150L_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150l.py" >>"$DIAG_LOG" 2>&1 || fail "150l camera patch failed; GitHub and Stage unchanged"
log "4) TypeScript syntax and transition-phase audit ..."
STROM150L_SOURCE="$WORK_DIR/frontend/src" STROM150L_TS="$DEPENDENCIES/typescript" node <<'STROM150L_AUDIT' >>"$DIAG_LOG" 2>&1 || fail "150l AST/camera audit failed; GitHub and Stage unchanged"
'use strict'
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150L_TS)
const root=process.env.STROM150L_SOURCE
for(const rel of ['App.tsx','components/CameraFlight150.tsx','components/cameraTransitions150.ts','components/Building3DWorkspace.tsx']){
 const file=path.join(root,rel),txt=fs.readFileSync(file,'utf8')
 const ast=ts.createSourceFile(file,txt,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 assert.equal(ast.parseDiagnostics.length,0,rel+': '+ast.parseDiagnostics.map(x=>ts.flattenDiagnosticMessageText(x.messageText,' ')).join('; '))
}
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const css=fs.readFileSync(path.join(root,'styles.css'),'utf8')
for(const s of ['STROM150L_READY_HANDSHAKE','entryWaitFrames150e.current>=3','window.requestAnimationFrame','activeCamera150j()','apply(running.start)','freezeOrbit150f()','topBasis150h'])assert(flight.includes(s), 'Missing '+s)
for(const s of ['confirmRendered150k','strom150k-render-sentinel','frameTick150k','lastAckTick150k'])assert(!flight.includes(s), 'obsolete gate '+s)
assert.equal((flight.match(/notifyEnterReady150\(\)/g)||[]).length,1,'ready event exactly once in gate')
assert(app.includes('STROM150K_FAIL_CLOSED'),'loader fail-closed protection retained')
assert(bridge.includes('export const ENTER_FADE150=5000'),'5000ms fade retained')
assert(bridge.includes('export const DURATION150=5000'),'5000ms flight retained')
assert(css.includes('transition:opacity 5000ms ease;'),'5000ms CSS fade retained')
console.log('PASS 150l AST: 4 files; 3 stable frames + double requestAnimationFrame, no unrendered sentinel dependency')
STROM150L_AUDIT
log "5) Full TypeScript/Vite build against existing Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150l TypeScript/Vite build failed before GitHub push"
log "5.1) Canvas frame/paint release and phase runtime regression ..."
STROM150L_SOURCE="$WORK_DIR/frontend/src" STROM150L_TS="$DEPENDENCIES/typescript" node <<'STROM150L_TEST' >>"$DIAG_LOG" 2>&1 || fail "150l camera regression failed; GitHub and Stage unchanged"
'use strict'
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150L_TS)
const root=process.env.STROM150L_SOURCE
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const bridgeJs=ts.transpileModule(bridge,{fileName:'cameraTransitions150.ts',compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
let timeoutMs=0
const mockedBridgeWindow={localStorage:{getItem:()=>null},setTimeout:(fn,ms)=>{timeoutMs=ms;return 1},clearTimeout:()=>{}}
const bm={exports:{}}
new Function('module','exports','require','window','document',bridgeJs)(bm,bm.exports,require,mockedBridgeWindow,{querySelector:()=>null})
const api=bm.exports
assert.equal(api.ENTER_FADE150,5000)
assert.equal(api.DURATION150,5000)
let ready=0
api.registerEnterReady150(()=>ready++)
api.queueEntry150('threeD','fixture-floor')

class V{
 constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}
 clone(){return new V(this.x,this.y,this.z)}
 copy(v){this.x=v.x;this.y=v.y;this.z=v.z;return this}
 lerp(p,k){this.x+=(p.x-this.x)*k;this.y+=(p.y-this.y)*k;this.z+=(p.z-this.z)*k;return this}
 distanceTo(p){return Math.hypot(this.x-p.x,this.y-p.y,this.z-p.z)}
}
class Q{
 constructor(v=0){this.v=v}
 clone(){return new Q(this.v)}
 copy(q){this.v=q.v;return this}
 dot(q){return Math.abs(this.v-q.v)<1e-9?1:0}
 setFromRotationMatrix(){this.v=2;return this}
 slerp(q,k){this.v+=(q.v-this.v)*k;return this}
}
class M{makeBasis(){return this}}
const Three={Vector3:V,Quaternion:Q,Matrix4:M,MathUtils:{degToRad:d=>d*Math.PI/180}}
let frame=null,clock=1000,invalidates=0
const camera={position:new V(5,10,13),quaternion:new Q(1),isPerspectiveCamera:true,isOrthographicCamera:false,fov:45,zoom:1,updateMatrixWorld() {}}
const state={camera,get(){return state},size:{width:1200,height:700},gl:{},invalidate(){invalidates++},controls:null}
const React={useRef:initial=>({current:initial}),useLayoutEffect:fn=>fn()}
const Fiber={useThree:fn=>fn(state),useFrame:fn=>{frame=fn}}
let rafId=0,rafQueue=[]
const browser={
 requestAnimationFrame:fn=>{const id=++rafId;rafQueue.push({id,fn});return id},
 cancelAnimationFrame:id=>{rafQueue=rafQueue.filter(item=>item.id!==id)}
}
const runRaf=()=>{assert(rafQueue.length>0,'expected queued browser paint');const item=rafQueue.shift();item.fn()}
const flightJs=ts.transpileModule(flight,{fileName:'CameraFlight150.tsx',compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}}).outputText
const fm={exports:{}}
const imports=key=>key==='react'?React:key==='react/jsx-runtime'?{jsx:(t,p)=>({type:t,props:p})}:key==='@react-three/fiber'?Fiber:key==='three'?Three:key==='./cameraTransitions150'?api:(()=>{throw Error('Unexpected '+key)})()
new Function('module','exports','require','performance','window',flightJs)(fm,fm.exports,imports,{now:()=>clock},browser)
const output=fm.exports.default({points:[{x:0,y:0},{x:11,y:0},{x:11,y:6},{x:0,y:6}]})
assert.equal(output,null,'old hidden mesh sentinel removed')
assert(frame,'useFrame must register')
frame()
assert.equal(ready,0,'spinner visible during first camera setup')
const top=camera.position.clone(),topQ=camera.quaternion.clone()
frame();frame();frame()
assert.equal(ready,0,'three stable frames must not start fading before browser paint confirmation')
assert.equal(rafQueue.length,1,'first browser paint scheduled')
runRaf()
assert.equal(ready,0,'first browser paint must not start fade')
runRaf()
assert.equal(ready,1,'second browser paint releases fade')
clock=5000;frame()
assert(top.distanceTo(camera.position)<0.00001&&camera.quaternion.dot(topQ)>0.99999,'pose must remain fixed throughout fade')
clock=6200;frame()
assert(top.distanceTo(camera.position)>0.00001,'camera must begin flight only after full 5000ms fade')
assert.equal(ready,1,'ready notified exactly once')
assert(invalidates>0,'demand-driven Canvas invalidated')
api.registerExit150(()=>{})
api.requestExit150(()=>{})
assert(timeoutMs>=6000,'reverse flight timeout remains safe for 5s')
console.log('PASS 150l runtime: R3F camera hold -> 3 stable frames -> 2 browser paints -> 5s fade -> 5s flight; no deadlock on sentinel callback')
STROM150L_TEST
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150L.md" <<'STROM150L_DOC'
# Update 150l - stable frame handshake instead of missing WebGL sentinel

- Diagnoses and fixes a stuck loading spinner caused by relying only on hidden mesh `onAfterRender`.
- Keeps Blueprint and loading spinner visible until the active R3F camera has been aligned and held through three stable frame ticks and two browser paint opportunities.
- Then fades over 5 seconds before starting the 5-second ease-out camera flight.
- Preserves geometric orientation, both camera directions, and OrbitControls safeguards.
- If the 3D Canvas fails to initialize, the existing 30-second safety guard returns to Blueprint with an error rather than spinning forever.
- Runs in isolated Git checkout with strict TypeScript/Vite build and regression tests before GitHub push; deploys to /strom-test/ only.
STROM150L_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150l Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150l Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150l frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150l test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150l deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
