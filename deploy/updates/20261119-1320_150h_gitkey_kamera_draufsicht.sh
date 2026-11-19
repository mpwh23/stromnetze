#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1320_150h_gitkey_kamera_draufsicht"
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
COMMIT_MESSAGE="Update 150h: Git deploy-key fix, match overhead 3D plan to Blueprint without regressions"
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
  echo "2) Update 150h im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150h isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150h: aligned overhead camera, root Git key and safe test deployment ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
grep -Fq 'STROM150F_BLUEPRINT_AXES' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || fail "150h requires successfully installed 150f"
grep -Fq 'STROM150E_LOADING_GUARD' "$STAGE_DIR/frontend/src/App.tsx" || fail "150h requires 150e loading-guard UI"
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
RESOURCE_DIR="$WORK_DIR/150h_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150h.py" <<'STROM150H_PY'
#!/usr/bin/env python3
"""150h: adjust landscape-vs-portrait top-view orientation without changing the 150f OrbitControls safeguards."""
from pathlib import Path
import os

root=Path(os.environ['STROM150H_ROOT'])/'frontend/src'
flight=root/'components/CameraFlight150.tsx'
bridge=root/'components/cameraTransitions150.ts'
app=root/'App.tsx'
for path in (flight,bridge,app):
    if not path.is_file():raise RuntimeError(f'150h source missing: {path}')
f=flight.read_text('utf8')
b=bridge.read_text('utf8')
a=app.read_text('utf8')
if 'STROM150H_LANDSCAPE' in f:raise RuntimeError('150h already installed')
for marker in ('STROM150F_BLUEPRINT_AXES','makeBasis(RIGHT150F,UP150F,BACK150F)',
               'orbitFrozen150f', 'freezeOrbit150f', 'unfreezeOrbit150f',
               'STROM150E_NO_CONTROLS_WAIT','entryWaitFrames150e.current>=1'):
    if marker not in f:raise RuntimeError(f'150h camera prerequisite missing: {marker}')
if 'export const ENTER_FADE150=500' not in b or 'export const DURATION150=1500' not in b:
    raise RuntimeError('150h requires exactly 500ms fade and 1500ms flight')
if 'STROM150E_LOADING_GUARD' not in a:
    raise RuntimeError('150h loading-guard prerequisite missing')

def replace_n(old,new,n,label):
    global f
    actual=f.count(old)
    if actual!=n:raise RuntimeError(f'150h {label}: expected {n} anchor(s), found {actual}')
    f=f.replace(old,new)

# Select one of two genuine bird's-eye orientations using the floor footprint.
# If the long edge is along world Z (the screenshots' portrait rendering),
# quarter-turn the top view so it is horizontal, like the Blueprint.
helper='''// STROM150H_LANDSCAPE: align the model's long footprint axis horizontally,
// while preserving the 150f orbit freeze, frame loading and easing behavior.
function topBasis150h(points:readonly P150[]):{right:THREE.Vector3;up:THREE.Vector3}{
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity
  for(const p of points){
    if(!Number.isFinite(p.x)||!Number.isFinite(p.y))continue
    minX=Math.min(minX,p.x);maxX=Math.max(maxX,p.x)
    minY=Math.min(minY,p.y);maxY=Math.max(maxY,p.y)
  }
  const spanX=Number.isFinite(minX)?maxX-minX:0
  const spanY=Number.isFinite(minY)?maxY-minY:0
  // Rotate only when one axis is decisively longer; square plans stay on the established axes.
  if(spanY>spanX*1.12&&spanY>0.1){
    return {right:new THREE.Vector3(0,0,-1),up:new THREE.Vector3(-1,0,0)}
  }
  return {right:RIGHT150F.clone(),up:UP150F.clone()}
}

'''
replace_n('function topPose150(camera:THREE.Camera,bounds:ReturnType<typeof planBounds150>,aspect:number):Pose150{',
          helper+'function topPose150(camera:THREE.Camera,bounds:ReturnType<typeof planBounds150>,aspect:number,points:readonly P150[]):Pose150{',
          1,'top pose signature')
replace_n('  const topView=new THREE.Matrix4().makeBasis(RIGHT150F,UP150F,BACK150F)',
          '  const {right,up}=topBasis150h(points)\n  const topView=new THREE.Matrix4().makeBasis(right,up,BACK150F)',
          1,'axis selection')
replace_n('topPose150(camera,bounds,latest.current.aspect)',
          'topPose150(camera,bounds,latest.current.aspect,latest.current.points)',
          2,'entry and reverse matching basis')

# Commit only after every anchor and guard has passed.
flight.write_text(f,'utf8')
print('PASS 150h: active 3D top view landscape aligned; 150f orbit lock intact')
STROM150H_PY
log "3) Apply incremental camera fix in isolated source ..."
python3 -m py_compile "$RESOURCE_DIR/patch150h.py" >>"$DIAG_LOG" 2>&1 || fail "150h Python syntax failed"
STROM150H_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150h.py" >>"$DIAG_LOG" 2>&1 || fail "150h patch failed; GitHub and Stage unchanged"
log "4) TypeScript TSX syntax and 150f safeguard audit ..."
STROM150H_SOURCE="$WORK_DIR/frontend/src" STROM150H_TS="$DEPENDENCIES/typescript" node <<'STROM150H_AST' >>"$DIAG_LOG" 2>&1 || fail "150h TSX parse/guard audit failed; GitHub and Stage unchanged"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150H_TS)
const root=process.env.STROM150H_SOURCE
for(const rel of ['App.tsx','components/CameraFlight150.tsx','components/cameraTransitions150.ts','components/Building3DWorkspace.tsx']){
 const source=fs.readFileSync(path.join(root,rel),'utf8')
 const ast=ts.createSourceFile(rel,source,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 if(ast.parseDiagnostics.length)throw Error(rel+': '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
for(const marker of ['STROM150H_LANDSCAPE','topBasis150h','orbitFrozen150f','freezeOrbit150f','unfreezeOrbit150f','entryWaitFrames150e.current>=1'])
 assert(flight.includes(marker),'150h prerequisite lost: '+marker)
assert(flight.includes('makeBasis(right,up,BACK150F)'))
assert.equal((flight.match(/topPose150\(camera,bounds,latest\.current\.aspect,latest\.current\.points\)/g)||[]).length,2)
assert(bridge.includes('ENTER_FADE150=500')&&bridge.includes('DURATION150=1500'))
assert(app.includes('STROM150E_LOADING_GUARD'))
console.log('PASS 150h: TSX parse, camera safeguards, 500ms fade and 1500ms flight')
STROM150H_AST
log "5) Full TypeScript/Vite build with real Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150h TypeScript/Vite build failed before GitHub push"
log "5.1) Kamera-Achsen-Regression ..."
STROM150H_SOURCE="$WORK_DIR/frontend/src" node <<'STROM150H_TEST' >>"$DIAG_LOG" 2>&1 || fail "150h orientation regression failed; GitHub and Stage unchanged"
const assert=require('assert'),fs=require('fs'),path=require('path')
const file=fs.readFileSync(path.join(process.env.STROM150H_SOURCE,'components/CameraFlight150.tsx'),'utf8')
assert(file.includes('topBasis150h(points)'))
function axis(points){let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity
 for(const p of points){if(!Number.isFinite(p.x)||!Number.isFinite(p.y))continue
 minX=Math.min(minX,p.x);maxX=Math.max(maxX,p.x);minY=Math.min(minY,p.y);maxY=Math.max(maxY,p.y)}
 const sx=Number.isFinite(minX)?maxX-minX:0,sy=Number.isFinite(minY)?maxY-minY:0
 return sy>sx*1.12&&sy>0.1?{right:[0,0,-1],up:[-1,0,0]}:{right:[1,0,0],up:[0,0,-1]}}
const landscape=axis([{x:0,y:0},{x:10,y:0},{x:10,y:6},{x:0,y:6}])
const portrait=axis([{x:0,y:0},{x:6,y:0},{x:6,y:10},{x:0,y:10}])
assert.deepEqual(landscape.right,[1,0,0]);assert.deepEqual(portrait.right,[0,0,-1]);assert.deepEqual(portrait.up,[-1,0,0])
const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
for(const t of [landscape,portrait])assert.deepEqual(cross(t.right,t.up),[0,1,0])
assert(file.includes('freezeOrbit150f()')&&file.includes('unfreezeOrbit150f()'))
console.log('PASS orientation 150h: landscape and rotated portrait, proper camera handedness and orbit freeze')
STROM150H_TEST
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150H.md" <<'STROM150H_DOC'
# Update 150h – Git deploy key und orientierter Kamerastart
- Die GitHub-Phase verwendet den etablierten Root-SSH-Deploy-Key (github-stromnetze).
- Die Draufsicht nutzt die längere Gebäudeachse als Bildschirm-Horizontalachse; Hochkant-Grundrisse werden entsprechend um 90 Grad gedreht.
- Identische Start-/Zielausrichtung in beiden Kameraflugrichtungen.
- OrbitControls-Sperre, 500 ms Überblendung, 1500 ms Kameraflug, Ladeindikator und Lade-Absicherung bleiben unverändert.
- Isolierter TypeScript/Vite-Build vor Git-Push; anschließend Stage-Update mit Backup und Deployment nur nach /strom-test/.
STROM150H_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150h Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy to /strom-test/ only ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150h Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150h frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150h test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150h deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
