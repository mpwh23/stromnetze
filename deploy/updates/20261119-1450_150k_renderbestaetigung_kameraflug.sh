#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1450_150k_renderbestaetigung_kameraflug"
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
COMMIT_MESSAGE="Update 150k: confirm rendered top camera before fade and camera flight"
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
  echo "2) Update 150k im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150k isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150k: loader -> confirmed render camera -> 5s fade -> 5s flight ==="
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
RESOURCE_DIR="$WORK_DIR/150k_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150k.py" <<'STROM150K_PY'
#!/usr/bin/env python3
"""STROM 150k: verified rendered 3D top-pose gate before starting fade.

Only edit CameraFlight150 and the legacy 9s App loader fallback; preserve
existing orientation, animation easing, 5s fade, 5s flight, and geometry.
"""
from pathlib import Path
import os

src = Path(os.environ['STROM150K_ROOT']) / 'frontend/src'
flight = src / 'components/CameraFlight150.tsx'
app = src / 'App.tsx'
bridge = src / 'components/cameraTransitions150.ts'
css = src / 'styles.css'
for path in (flight, app, bridge, css):
    if not path.is_file():
        raise RuntimeError(f'150k requires existing source: {path}')
f = flight.read_text('utf8')
a = app.read_text('utf8')
b = bridge.read_text('utf8')
c = css.read_text('utf8')
if 'STROM150K_AFTER_RENDER_GATE' in f or 'STROM150K_FAIL_CLOSED' in a:
    raise RuntimeError('150k already installed, refusing double-patch')
for needle in (
    'STROM150J_ACTIVE_RENDER_CAMERA',
    'entryWaitFrames150e.current>=2',
    'apply(running.start)',
    'freezeOrbit150f()',
    'topBasis150h',
    'running.started=performance.now()+ENTER_FADE150',
):
    if needle not in f:
        raise RuntimeError(f'150k expected installed 150j camera code: {needle}')
for needle in ('STROM150C_PRESERVE_BLUEPRINT', 'STROM150E_LOADING_GUARD', "setEnterPreview150(current => current === 'loading' ? 'fading' : current)"):
    if needle not in a:
        raise RuntimeError(f'150k expected installed 150e UI: {needle}')
if 'export const ENTER_FADE150=5000' not in b or 'export const DURATION150=5000' not in b:
    raise RuntimeError('150k only supports the requested 5s/5s diagnostic timing base')
if 'transition:opacity 5000ms ease;' not in c:
    raise RuntimeError('150k expected 5s Blueprint fade CSS')

def one(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise RuntimeError(f'150k {label}: exactly one anchor required, found {n}')
    return text.replace(old, new, 1)

# A WebGL mesh with disabled color/depth writes acts as a render sentinel.
# Its onAfterRender callback runs only after the renderer has painted THIS
# camera in THIS active Canvas, rather than merely after a useFrame tick.
f = one(f,
'''  const entryWaitFrames150e=useRef(0) // STROM150E_NO_CONTROLS_WAIT''',
'''  const entryWaitFrames150e=useRef(0) // STROM150E_NO_CONTROLS_WAIT: now counts confirmed WebGL renders
  const frameTick150k=useRef(0)
  const lastAckTick150k=useRef(-1)''', 'render-confirmation counters')

# Check the actual camera passed to THREE.Mesh.onAfterRender, not just the
# R3F camera state. Thus a camera swap, OrbitControls overwrite, or skipped
# render cannot release the Blueprint overlay too early.
callback = '''  // STROM150K_AFTER_RENDER_GATE: only a *rendered* and fully aligned top view may start the fade.
  const confirmRendered150k=(renderedCamera:THREE.Camera)=>{
    if(!entryWaiting.current)return
    const running=flight.current
    if(!running)return
    if(lastAckTick150k.current===frameTick150k.current)return
    const liveCamera=activeCamera150j()
    // Ignore shadow/auxiliary passes, which are rendered with another camera.
    if(renderedCamera!==liveCamera)return
    const qDot=Math.abs(renderedCamera.quaternion.dot(running.start.rotation))
    const cameraOrtho=renderedCamera as THREE.OrthographicCamera
    const zoomAligned=!cameraOrtho.isOrthographicCamera||Math.abs(cameraOrtho.zoom-running.start.zoom)<0.0001
    const aligned=renderedCamera.position.distanceTo(running.start.position)<0.0005 &&
      qDot>0.999999 && zoomAligned
    if(!aligned){entryWaitFrames150e.current=0;return}
    lastAckTick150k.current=frameTick150k.current
    entryWaitFrames150e.current++
    if(entryWaitFrames150e.current>=3){
      entryWaiting.current=false
      running.started=performance.now()+ENTER_FADE150
      notifyEnterReady150()
      invalidate()
    }
  }
'''
f = one(f,
'''  useLayoutEffect(()=>{
    // Consume once per Canvas mount''',
callback + '''  useLayoutEffect(()=>{
    // Consume once per Canvas mount''', 'post-render confirmation hook')

# On camera instance swaps while loading, restart confirmation: all three
# confirmed rendered frames must be from the same final camera.
f = one(f,
'''    if(flightCamera150j.current!==liveCamera150j){
      if(entryWaiting.current||performance.now()<running.started){''',
'''    if(flightCamera150j.current!==liveCamera150j){
      entryWaitFrames150e.current=0
      if(entryWaiting.current||performance.now()<running.started){''',
'camera switch invalidates previous confirmations')

# Prepare and apply before render, but do not start the fade inside useFrame:
# Three's mesh callback is the only place allowed to send the ready signal.
f = one(f,
'''    if(entryWaiting.current){
      // Make the real 3D start image stable BEFORE announcing readiness.
      apply(running.start)
      // The previous useFrame applied the top pose; one R3F render has now completed.
      // No renderer.info counters, which can be reset by React Three Fiber/Three.
      entryWaitFrames150e.current++
      if(entryWaitFrames150e.current>=2){
        entryWaiting.current=false
        running.started=performance.now()+ENTER_FADE150
        notifyEnterReady150()
      }
      invalidate()
      return
    }''',
'''    if(entryWaiting.current){
      // Keep the spinner and original Blueprint until 3 confirmed painted top frames.
      apply(running.start)
      invalidate()
      return
    }''',
'no early ready from useFrame')

f = one(f,
'''  useFrame(()=>{
    if(queuedEntry.current){''',
'''  useFrame(()=>{
    frameTick150k.current++
    if(queuedEntry.current){''',
'one painted frame confirmation per animation tick')

# Ensure a reliable proof even in demand-based R3F canvases. The render
# sentinel cannot be culled and writes no pixels. Its onAfterRender receives
# the camera used by the actual THREE renderer, not a guessed camera.
f = one(f,
'''  return null
}
''',
'''  return <mesh name="strom150k-render-sentinel" frustumCulled={false} renderOrder={1000000}
    onAfterRender={(_renderer,_scene,renderedCamera)=>confirmRendered150k(renderedCamera)}>
    <planeGeometry args={[0.001,0.001]} />
    <meshBasicMaterial colorWrite={false} depthWrite={false} depthTest={false} />
  </mesh>
}
''',
'render sentinel')

# No automatic 'fading' after 9s regardless of actual 3D readiness. After
# 30 seconds, return safely to BP with an error instead of revealing the
# wrong camera or spinning forever. The normal path remains event-driven.
start_marker = '  // STROM150E_LOADING_GUARD: defensive escape if 3D cannot report readiness.'
end_marker = '  }, [enterPreview150])'
start = a.index(start_marker)
end = a.index(end_marker, start) + len(end_marker)
old_guard = a[start:end]
for sentinel in ('9000', 'setEnterPreview', "'fading'"):
    if sentinel not in old_guard:
        raise RuntimeError('150k expected earlier 9s fade fallback guard')
new_guard = '''  // STROM150E_LOADING_GUARD / STROM150K_FAIL_CLOSED: never reveal unverified 3D after a timer.
  useEffect(() => {
    if (enterPreview150 !== 'loading') return
    const safety150k = window.setTimeout(() => {
      setError('3D-Kamera konnte nicht fertig vorbereitet werden. Bitte Ansicht erneut öffnen.')
      setEnterPreview150(null)
      setViewMode('floorplan')
    }, 30000)
    return () => window.clearTimeout(safety150k)
  }, [enterPreview150])'''
a = a[:start] + new_guard + a[end:]

# Protect against a remount while waiting, but retain all 150j cleanup.
flight.write_text(f, 'utf8')
app.write_text(a, 'utf8')
print('PASS 150k: Blueprint+loader -> aligned 3D camera -> 3 painted verified frames -> 5000ms fade -> 5000ms eased flight')
STROM150K_PY

log "3) Install render-confirmation barrier and fail-closed loader in isolated source ..."
python3 -m py_compile "$RESOURCE_DIR/patch150k.py" >>"$DIAG_LOG" 2>&1 || fail "150k Python syntax failed"
STROM150K_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150k.py" >>"$DIAG_LOG" 2>&1 || fail "150k camera patch failed; GitHub and Stage unchanged"
log "4) TypeScript syntax and render-phase audit ..."
STROM150K_SOURCE="$WORK_DIR/frontend/src" STROM150K_TS="$DEPENDENCIES/typescript" node <<'STROM150K_AUDIT' >>"$DIAG_LOG" 2>&1 || fail "150k AST/camera audit failed; GitHub and Stage unchanged"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150K_TS)
const root=process.env.STROM150K_SOURCE
for(const rel of ['App.tsx','components/CameraFlight150.tsx','components/cameraTransitions150.ts','components/Building3DWorkspace.tsx']){
 const file=path.join(root,rel),source=fs.readFileSync(file,'utf8')
 const ast=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 if(ast.parseDiagnostics.length)throw Error(rel+': '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
 function walk(node){if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node)){
   const seen=new Set();for(const prop of node.attributes.properties){if(!ts.isJsxAttribute(prop))continue;const k=prop.name.getText(ast);if(seen.has(k))throw Error(rel+': duplicate JSX prop '+k);seen.add(k)}
 }ts.forEachChild(node,walk)}walk(ast)
}
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const css=fs.readFileSync(path.join(root,'styles.css'),'utf8')
for(const marker of ['STROM150J_ACTIVE_RENDER_CAMERA','STROM150H_LANDSCAPE','topBasis150h','freezeOrbit150f','STROM150K_AFTER_RENDER_GATE','onAfterRender='])
  assert(flight.includes(marker),'missing camera safeguard '+marker)
assert(flight.includes('entryWaitFrames150e.current>=3'))
assert.equal((flight.match(/notifyEnterReady150\(\)/g)||[]).length,1,'3D ready can only be triggered after actual render')
assert(app.includes('STROM150C_PRESERVE_BLUEPRINT')&&app.includes('STROM150E_LOADING_GUARD'))
assert(app.includes('STROM150K_FAIL_CLOSED'))
assert(!app.includes('9000)'),'legacy forced fade must be removed')
assert(bridge.includes('export const ENTER_FADE150=5000'))
assert(bridge.includes('export const DURATION150=5000'))
assert(css.includes('transition:opacity 5000ms ease;'))
console.log('PASS 150k AST: 4 files parsed, render gate after 3 actual WebGL draws, no early fade, legacy controls + loader preserved')
STROM150K_AUDIT
log "5) Full TypeScript/Vite build against existing Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150k TypeScript/Vite build failed before GitHub push"
log "5.1) Actual render-camera confirmation and phase runtime regression ..."
STROM150K_SOURCE="$WORK_DIR/frontend/src" STROM150K_TS="$DEPENDENCIES/typescript" node <<'STROM150K_TEST' >>"$DIAG_LOG" 2>&1 || fail "150k camera regression failed; GitHub and Stage unchanged"
'use strict'
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150K_TS||'typescript')
const root=process.env.STROM150K_SOURCE||'/tmp/strom150reconstruct/frontend/src'
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const css=fs.readFileSync(path.join(root,'styles.css'),'utf8')
for(const rel of ['components/CameraFlight150.tsx','components/cameraTransitions150.ts']){
  const p=path.join(root,rel),s=fs.readFileSync(p,'utf8')
  const a=ts.createSourceFile(p,s,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
  assert.equal(a.parseDiagnostics.length,0,`TSX parsing of ${rel}: `+a.parseDiagnostics.map(x=>x.messageText))
}
assert(flight.includes('STROM150K_AFTER_RENDER_GATE'))
assert(flight.includes('frustumCulled={false}'))
assert(flight.includes('onAfterRender={'))
assert(flight.includes('entryWaitFrames150e.current>=3'))
assert.equal((flight.match(/notifyEnterReady150\(\)/g)||[]).length,1,'only confirmed onAfterRender may start fade')
assert(app.includes('STROM150K_FAIL_CLOSED'),'fail closed on loader timeout')
assert(app.includes('setViewMode(\'floorplan\')'),'timeout returns to blueprint')
assert(!app.includes('9000)'),'old forced fade fallback removed')
assert(bridge.includes('export const ENTER_FADE150=5000'))
assert(bridge.includes('export const DURATION150=5000'))
assert(css.includes('transition:opacity 5000ms ease;'))

const bridgeJs=ts.transpileModule(bridge,{fileName:'cameraTransitions150.ts',compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
let timeoutMs=0
const mockedWindow={localStorage:{getItem:()=>null},setTimeout:(fn,ms)=>{timeoutMs=ms;return 1},clearTimeout:()=>{}}
const bm={exports:{}}
new Function('module','exports','require','window','document',bridgeJs)(bm,bm.exports,require,mockedWindow,{querySelector:()=>null})
const bridgeApi=bm.exports
assert.equal(bridgeApi.DURATION150,5000)
assert.equal(bridgeApi.ENTER_FADE150,5000)
let ready=0
bridgeApi.registerEnterReady150(()=>ready++)
bridgeApi.queueEntry150('threeD','fixture-floor')

class V {
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
class M {makeBasis(){return this}}
const Three={Vector3:V,Quaternion:Q,Matrix4:M,MathUtils:{degToRad:d=>d*Math.PI/180}}
let frame=null, clock=1000,invalidates=0
const camera={position:new V(5,10,13),quaternion:new Q(1),isPerspectiveCamera:true,isOrthographicCamera:false,fov:45,zoom:1,updateMatrixWorld() {}}
const r3f={camera,get(){return r3f},size:{width:1200,height:700},gl:{},invalidate(){invalidates++},controls:null}
const React={useRef:initial=>({current:initial}),useLayoutEffect:fn=>fn()}
const Fiber={useThree:fn=>fn(r3f),useFrame:fn=>{frame=fn}}
const JsxRuntime={jsx:(type,props)=>({type,props}),jsxs:(type,props)=>({type,props})}
const flightJs=ts.transpileModule(flight,{fileName:'CameraFlight150.tsx',compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}}).outputText
const fm={exports:{}}
const imports=key=>key==='react'?React:key==='react/jsx-runtime'?JsxRuntime:key==='@react-three/fiber'?Fiber:key==='three'?Three:key==='./cameraTransitions150'?bridgeApi:(()=>{throw Error('Unexpected '+key)})()
new Function('module','exports','require','performance',flightJs)(fm,fm.exports,imports,{now:()=>clock})
const out=fm.exports.default({points:[{x:0,y:0},{x:11,y:0},{x:11,y:6},{x:0,y:6}]})
assert(out.type==='mesh' && typeof out.props.onAfterRender==='function','render confirmation mesh must exist')
assert(frame,'useFrame must register')
const confirm=(cam)=>out.props.onAfterRender({}, {}, cam)
frame()
assert.equal(ready,0,'spinner visible during camera preparation')
const top=camera.position.clone(),topQ=camera.quaternion.clone()
const shadowCamera={position:new V(200,200,200),quaternion:new Q(99),isOrthographicCamera:false}
confirm(shadowCamera)
assert.equal(ready,0,'shadow render must not start fade')
confirm(camera)
assert.equal(ready,0,'first painted top view not enough')
frame();confirm(camera)
assert.equal(ready,0,'second painted top view not enough')
frame()
assert.equal(ready,0,'third useFrame alone must not start fade')
confirm(camera)
assert.equal(ready,1,'third confirmed WebGL draw starts fade')
clock=5000;frame()
assert(top.distanceTo(camera.position)<0.00001 && camera.quaternion.dot(topQ)>0.99999,'must pin identical top pose throughout fade')
clock=6200;frame()
assert(top.distanceTo(camera.position)>0.00001,'flight starts smoothly only after 5000ms fade')
assert.equal(ready,1,'fade starts once')
assert(invalidates>0,'demand canvas receives invalidation')
bridgeApi.registerExit150(()=>{})
bridgeApi.requestExit150(()=>{})
assert(timeoutMs>=6000,'reverse flight must not be cut off by timeout')
console.log('PASS 150k simulated runtime: spinner -> 3 post-render correct-camera confirmations -> 5s fade held exactly -> 5s flight; wrong-camera draws ignored; reverse timeout safe')
STROM150K_TEST
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150K.md" <<'STROM150K_DOC'
# Update 150k - Verified camera render before Blueprint fade

- State machine: preserve the genuine Blueprint and spinner, prepare actual 3D top pose, confirm three WebGL render callbacks on the real active camera, then fade for 5s and fly for 5s (ease-out).
- A hidden THREE mesh (colorWrite/depthWrite disabled) confirms the camera actually used for rendering; shadow/auxiliary camera passes are ignored.
- Keep the 150j camera pose, Blueprint orientation, geometry, existing OrbitControls safeguards, and reverse flight behavior.
- Do not unconditionally start a fade after a timer. If the 3D view remains unready for 30s, return safely to Blueprint and show an error instead of revealing a wrong camera.
- Apply only with successful isolated TypeScript/Vite build and tests; update GitHub and /strom-test/ while leaving /strom/ intact.
STROM150K_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150k Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150k Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150k frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150k test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150k deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
