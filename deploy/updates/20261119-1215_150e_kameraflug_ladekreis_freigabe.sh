#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1215_150e_kameraflug_ladekreis_freigabe"
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
COMMIT_MESSAGE="Update 150e: release 3D loading without OrbitControls registration, protect 500ms fade and 1500ms flight"
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
  echo "2) Update 150e im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150e isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150e: unblock loading, keep 500ms fade and 1500ms camera flight ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
grep -Fq 'STROM150_CAMERA_BRIDGE' "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 150 prerequisite not found"
grep -Fq 'STROM150_CAMERA' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "Update 150 3D prerequisite missing"
grep -Fq 'STROM150C_PRESERVE_BLUEPRINT' "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 150c prerequisite not found"
grep -Fq 'STROM150D_CAMERA_FIX' "$STAGE_DIR/frontend/src/styles.css" || fail "Update 150d prerequisite not found"
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
RESOURCE_DIR="$WORK_DIR/150e_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150e.py" <<'STROM150E_PY'
#!/usr/bin/env python3
# Update 150e: unblock indefinite 3D loading without replacing existing camera system.
from pathlib import Path
import os
src=Path(os.environ['STROM150E_ROOT'])/'frontend/src'
app=src/'App.tsx'
css=src/'styles.css'
flight=src/'components/CameraFlight150.tsx'
bridge=src/'components/cameraTransitions150.ts'
for f in (app,css,flight,bridge):
    if not f.is_file():raise RuntimeError(f'150e missing source: {f}')
a=app.read_text('utf8'); f=flight.read_text('utf8'); c=css.read_text('utf8'); b=bridge.read_text('utf8')
if 'STROM150E_LOADING_GUARD' in a or 'STROM150E_NO_CONTROLS_WAIT' in f:
    raise RuntimeError('150e already applied; refusing duplicate patch')
if 'STROM150C_PRESERVE_BLUEPRINT' not in a or 'STROM150D_CAMERA_FIX' not in c:
    raise RuntimeError('150e requires successfully installed 150d')
if 'export const ENTER_FADE150=500' not in b or 'export const DURATION150=1500' not in b:
    raise RuntimeError('150e requires 500ms fade and 1500ms flight from 150d')

def once(source, old, new, label):
    n=source.count(old)
    if n!=1:raise RuntimeError(f'150e {label}: expected 1 anchor, found {n}')
    return source.replace(old,new,1)

# Key fix: many 3D views do not install OrbitControls into R3F state immediately
# (and some have no such controller). The camera flight must not wait for it.
f=once(f, '  const entryRenderFrame=useRef(0)',
       '  const entryWaitFrames150e=useRef(0) // STROM150E_NO_CONTROLS_WAIT', 'entry frame ref')
f=once(f, '''      const controls=controls150()
      if(!controls){invalidate();return}
      const incoming=queuedEntry.current''',
       '''      const controls=controls150()
      // OrbitControls may register late or not exist. Camera flight still begins.
      const incoming=queuedEntry.current''', 'remove indefinite controls wait')
f=once(f, '      initialControlsEnabled.current=controls.enabled',
       '      initialControlsEnabled.current=controls?.enabled', 'optional control state')
f=once(f, '      controls.enabled=false\n      apply(bird)',
       '      if(controls)controls.enabled=false\n      apply(bird)', 'optional control disable')
f=once(f, '''      entryRenderFrame.current=gl.info.render.frame
      entryWaiting.current=true''',
       '''      entryWaitFrames150e.current=0
      entryWaiting.current=true''', 'first frame activation')
f=once(f, '''      if(gl.info.render.frame>entryRenderFrame.current){
        entryWaiting.current=false''',
       '''      // The previous useFrame applied the top pose; one R3F render has now completed.
      // No renderer.info counters, which can be reset by React Three Fiber/Three.
      entryWaitFrames150e.current++
      if(entryWaitFrames150e.current>=1){
        entryWaiting.current=false''', 'first frame readiness')

# Secondary safety: if a canvas genuinely cannot mount, never trap the user
# in a permanent spinner. The normal case signals readiness after one WebGL frame.
app_anchor='  const enterPreviewTimer150 = useRef<number|null>(null)'
app_guard='''  // STROM150E_LOADING_GUARD: defensive escape if 3D cannot report readiness.
  useEffect(() => {
    if (enterPreview150 !== 'loading') return
    const safety150e = window.setTimeout(() => {
      setEnterPreview150(current => current === 'loading' ? 'fading' : current)
      if (enterPreviewTimer150.current !== null) window.clearTimeout(enterPreviewTimer150.current)
      enterPreviewTimer150.current = window.setTimeout(() => {
        setEnterPreview150(null)
        enterPreviewTimer150.current = null
      }, ENTER_FADE150)
    }, 9000)
    return () => window.clearTimeout(safety150e)
  }, [enterPreview150])'''
a=once(a,app_anchor,app_anchor+'\n'+app_guard,'loading guard')

# Transactional source writes only after all checks pass.
app.write_text(a,'utf8'); flight.write_text(f,'utf8')
print('PASS 150e: no indefinite OrbitControls wait; ready after first painted 3D top pose; 9s safety guard')
STROM150E_PY
log "3) Apply incremental patch to isolated source ..."
python3 -m py_compile "$RESOURCE_DIR/patch150e.py" >>"$DIAG_LOG" 2>&1 || fail "150e Python syntax failed"
STROM150E_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150e.py" >>"$DIAG_LOG" 2>&1 || fail "150e patch failed; GitHub and Stage unchanged"
log "4) Full TypeScript AST audit and duplicate JSX check ..."
STROM150E_SOURCE="$WORK_DIR/frontend/src" STROM150E_TS="$DEPENDENCIES/typescript" node <<'STROM150E_AST' >>"$DIAG_LOG" 2>&1 || fail "150e AST audit failed; GitHub and Stage unchanged"
const fs=require('fs'),path=require('path'),ts=require(process.env.STROM150E_TS)
const root=process.env.STROM150E_SOURCE
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
STROM150E_AST
log "5) Full TypeScript/Vite build against existing Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150e TypeScript/Vite build failed before GitHub push"
log "5.1) Camera transition regression tests ..."
STROM150E_SOURCE="$WORK_DIR/frontend/src" STROM150E_TS="$DEPENDENCIES/typescript" node <<'STROM150E_TEST' >>"$DIAG_LOG" 2>&1 || fail "150e regression tests failed; GitHub and Stage unchanged"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150E_TS)
const root=process.env.STROM150E_SOURCE
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const css=fs.readFileSync(path.join(root,'styles.css'),'utf8')
assert(bridge.includes('export const ENTER_FADE150=500'))
assert(bridge.includes('export const DURATION150=1500'))
assert(app.includes('STROM150C_PRESERVE_BLUEPRINT'))
assert(app.includes('STROM150E_LOADING_GUARD'))
assert(app.includes('9000'))
assert(css.includes('strom150c-loader-ring'))
assert(css.includes('transition:opacity 500ms ease'))
assert(flight.includes('STROM150E_NO_CONTROLS_WAIT'))
assert(!flight.includes('if(!controls){invalidate();return}'),'controls must not gate entry')
assert(flight.includes('initialControlsEnabled.current=controls?.enabled'))
assert(flight.includes('if(controls)controls.enabled=false'))
assert(flight.includes('entryWaitFrames150e.current>=1'))
assert(!flight.includes('gl.info.render.frame>entryRenderFrame.current'),'unreliable render counter gate is removed')
assert(flight.includes('notifyEnterReady150()'))
assert(flight.includes('1-Math.pow(1-t,3)'))
assert(flight.includes('rotation:a.rotation.clone().slerp(b.rotation,k)'))
const js=ts.transpileModule(bridge,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
let timeout=0
const mockWindow={localStorage:{getItem:()=>null},setTimeout:(_,ms)=>{timeout=ms;return 1},clearTimeout:()=>{}}
const m={exports:{}}
new Function('module','exports','require','window','document',js)(m,m.exports,require,mockWindow,{querySelector:()=>null})
const api=m.exports
let ready=0
const unsub=api.registerEnterReady150(()=>ready++)
api.queueEntry150('threeD','house')
assert(api.consumeEntry150())
api.notifyEnterReady150();api.notifyEnterReady150()
assert.equal(ready,1)
unsub()
let completed=0
const unexit=api.registerExit150(done=>done())
assert(api.requestExit150(()=>completed++))
assert.equal(completed,1)
assert(timeout>=api.DURATION150+500)
unexit()
// Mock a Canvas with no OrbitControls: the main failure mode in 150d.
class V150 {constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}clone(){return new V150(this.x,this.y,this.z)}copy(p){this.x=p.x;this.y=p.y;this.z=p.z;return this}lerp(p,k){this.x+=(p.x-this.x)*k;this.y+=(p.y-this.y)*k;this.z+=(p.z-this.z)*k;return this}}
class Q150 {constructor(v=0){this.v=v}clone(){return new Q150(this.v)}copy(p){this.v=p.v;return this}setFromRotationMatrix(){this.v=2;return this}slerp(p,k){this.v+=(p.v-this.v)*k;return this}}
class M150 {lookAt(){return this}}
const fakeThree150={Vector3:V150,Quaternion:Q150,Matrix4:M150,MathUtils:{degToRad:x=>x*Math.PI/180}}
let frameCallback150=null,clock150=1000
const r3f150={camera:{position:new V150(6,9,10),quaternion:new Q150(1),fov:45,isPerspectiveCamera:true,isOrthographicCamera:false,updateMatrixWorld(){}},controls:null,
 size:{width:900,height:600},invalidate(){},gl:{},get(){return r3f150}}
const fakeReact150={useRef:value=>({current:value}),useLayoutEffect:fn=>fn()}
const fakeFiber150={useThree:selector=>selector(r3f150),useFrame:fn=>{frameCallback150=fn}}
const flightJS150=ts.transpileModule(flight,{fileName:'CameraFlight150.tsx',compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
const module150={exports:{}}
const require150=key=>key==='react'?fakeReact150:key==='@react-three/fiber'?fakeFiber150:key==='three'?fakeThree150:key==='./cameraTransitions150'?api:(()=>{throw Error('unexpected module '+key)})()
new Function('module','exports','require','performance',flightJS150)(module150,module150.exports,require150,{now:()=>clock150})
let noControlReady=0
const unreadyNoControl=api.registerEnterReady150(()=>noControlReady++)
api.queueEntry150('wall','house')
module150.exports.default({points:[{x:0,y:0},{x:3,y:3}]})
assert(frameCallback150,'CameraFlight must register useFrame')
frameCallback150()
assert.equal(noControlReady,0,'first frame applies top-down pose')
frameCallback150()
assert.equal(noControlReady,1,'second frame must release spinner without OrbitControls')
clock150=3200;frameCallback150()
clock150=3600;frameCallback150()
assert.equal(noControlReady,1,'readiness emitted once')
unreadyNoControl()
console.log('PASS runtime 150e: no OrbitControls, two R3F frames, spinner freed, camera flight completed')

console.log('PASS 150e: no controls deadlock, first-frame ready, 500 ms fade, 1500 ms easing, 9s safety guard, reverse callbacks')
STROM150E_TEST

rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150E.md" <<'STROM150E_DOC'
# Update 150e – Kameraflug ohne blockierenden Ladekreis
- Fix: enter camera flight does not wait for R3F OrbitControls to register.
- Detect completed first WebGL frame using the next R3F useFrame callback, independent of renderer info counters.
- Keep live Blueprint and loading spinner, then cross-fade for 500 ms and ease-out camera fly for 1500 ms.
- 9-second defensive guard prevents an infinite loading overlay if canvas readiness cannot be reported.
- Reverse flight, camera quaternion preservation and existing 3D controls remain unchanged.
- Isolated GitHub build, Stage update, /strom-test/ only; production /strom/ untouched.
STROM150E_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150e Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy to /strom-test/ only ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150e Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150e frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150e test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150e deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
