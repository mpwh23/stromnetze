#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1145_150c_kameraflug_blueprint_hold"
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
COMMIT_MESSAGE="Update 150c: preserve Blueprint during loading, fade 250 ms and smooth 3D camera reverse"
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
  echo "2) Update 150c im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150c isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150c: live Blueprint loading hold, 250ms fade and stable 750ms camera flight ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
grep -Fq 'STROM150_CAMERA_BRIDGE' "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 150 prerequisite not found"
grep -Fq 'STROM150_CAMERA' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "Update 150 3D prerequisite missing"
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
RESOURCE_DIR="$WORK_DIR/150c_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150c.py" <<'STROM150C_PY'
#!/usr/bin/env python3
"""Incremental 150c atop 150: preserve original mounted Blueprint, fade when 3D renders."""
from pathlib import Path
import re

src = Path(__import__('os').environ['STROM150C_ROOT']) / 'frontend/src'
app = src / 'App.tsx'
css = src / 'styles.css'
scene = src / 'components/Building3DWorkspace.tsx'
bridge = src / 'components/cameraTransitions150.ts'
flight = src / 'components/CameraFlight150.tsx'
for p in (app, css, scene, bridge, flight):
    if not p.is_file():
        raise RuntimeError(f'150c missing: {p}')
a, c, s = [p.read_text('utf8') for p in (app,css,scene)]
if 'STROM150C_PRESERVE_BLUEPRINT' in a or 'STROM150C_PRESERVE_BLUEPRINT' in c:
    raise RuntimeError('150c already installed; double patch blocked')
if 'STROM150_CAMERA_BRIDGE' not in a or 'STROM150_CAMERA' not in s:
    raise RuntimeError('150c requires the installed version 150 camera transition')
if 'STROM150B_TRANSITION_OVERLAY' in a:
    raise RuntimeError('150b appears partly installed; unexpected prerequisite')

def exactly_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'150c {label}: expected 1 anchor, found {count}: {old[:70]}')
    return text.replace(old, new, 1)

# Keep the original FloorplanEditor mounted over the 3D view. No SVG serialization,
# remount, or different scroll position: it is the same genuine Blueprint DOM tree.
a = exactly_once(
    a,
    "import {queueEntry150,requestExit150} from './components/cameraTransitions150' // STROM150_CAMERA_BRIDGE",
    "import {queueEntry150,requestExit150,registerEnterReady150,ENTER_FADE150} from './components/cameraTransitions150' // STROM150_CAMERA_BRIDGE",
    'camera bridge import',
)

state_pattern = re.compile(r'(?m)^([ \t]*)const \[viewMode\s*,\s*setViewMode\] = useState<ViewMode>\([^\n]+\)\s*$')
matches = list(state_pattern.finditer(a))
if len(matches) != 1:
    raise RuntimeError(f'150c viewMode state: 1 expected, found {len(matches)}')
m = matches[0]
indent = m.group(1)
state = m.group(0)
addition = '''
  // STROM150C_PRESERVE_BLUEPRINT: keep original BP visible while the 3D canvas prepares.
  const [enterPreview150, setEnterPreview150] = useState<'loading'|'fading'|null>(null)
  const enterPreviewTimer150 = useRef<number|null>(null)
  useEffect(() => registerEnterReady150(() => {
    if (enterPreviewTimer150.current !== null) window.clearTimeout(enterPreviewTimer150.current)
    setEnterPreview150(current => current === 'loading' ? 'fading' : current)
    enterPreviewTimer150.current = window.setTimeout(() => {
      setEnterPreview150(null)
      enterPreviewTimer150.current = null
    }, ENTER_FADE150)
  }), [])
  useEffect(() => () => {
    if (enterPreviewTimer150.current !== null) window.clearTimeout(enterPreviewTimer150.current)
  }, [])'''
a = a[:m.start()] + state + addition + a[m.end():]

old_nav = """    if (viewMode === 'floorplan' && (mode === 'wall' || mode === 'threeD') && floor) {
      queueEntry150(mode, floor.id)
    }"""
new_nav = """    if (viewMode === 'floorplan' && (mode === 'wall' || mode === 'threeD') && floor) {
      if (enterPreviewTimer150.current !== null) window.clearTimeout(enterPreviewTimer150.current)
      setEnterPreview150('loading')
      queueEntry150(mode, floor.id)
    }"""
a = exactly_once(a, old_nav, new_nav, 'entry navigation')

# 3D and Blueprint mount concurrently only during a transition. The Blueprint DOM
# remains alive and retains its viewport, so the old image genuinely stays put.
old_cond = "{selectedObject && viewMode === 'floorplan' && floor && ("
new_cond = "{selectedObject && (viewMode === 'floorplan' || (enterPreview150 !== null && (viewMode === 'wall' || viewMode === 'threeD'))) && floor && ("
a = exactly_once(a,old_cond,new_cond,'FloorplanEditor lifetime')

old_workspace = '<section className="workspace">'
new_workspace = '<section className={`workspace ${enterPreview150 ? `strom150c-enter-${enterPreview150}` : ""}` }>'
a = exactly_once(a,old_workspace,new_workspace,'workspace class')

marker = "          {selectedObject && viewMode === 'floorplan' && !floor &&"
needle = "          {selectedObject && viewMode === 'wall' && floor && hasWallDetailAccess && ("
spinner = '''          {enterPreview150 === 'loading' && (viewMode === 'wall' || viewMode === 'threeD') && (
            <div className="strom150c-loader" role="status" aria-live="polite">
              <span className="strom150c-loader-ring" aria-hidden="true" />
              <span>{viewMode === 'wall' ? 'Wanddetail wird geladen…' : '3D-Haus wird geladen…'}</span>
            </div>
          )}
'''
a = exactly_once(a, needle, spinner + needle, 'loading overlay')

c += '''
/* STROM150C_PRESERVE_BLUEPRINT: live 2D DOM stays on top while 3D finishes its first frame. */
.workspace.strom150c-enter-loading,.workspace.strom150c-enter-fading {position:relative;isolation:isolate;}
.workspace.strom150c-enter-loading > .floorplan-layout,
.workspace.strom150c-enter-fading > .floorplan-layout {
 position:absolute;inset:0;width:100%;height:100%;max-height:100%;overflow:hidden;
 z-index:15;pointer-events:none;opacity:1;
}
.workspace.strom150c-enter-fading > .floorplan-layout {opacity:0;transition:opacity 250ms ease;}
.strom150c-loader {
 position:absolute;inset:0;z-index:20;pointer-events:none;display:flex;
 align-items:center;justify-content:center;flex-direction:column;gap:12px;
 color:#355274;background:rgba(247,249,252,.06);
 font-size:13px;font-weight:650;text-shadow:0 1px 2px #fff;
}
.strom150c-loader-ring {width:42px;height:42px;border:3px solid rgba(70,108,180,.24);border-top-color:#3b69b5;
 border-radius:50%;animation:strom150c-spin .85s linear infinite;box-shadow:0 1px 5px rgba(0,0,0,.06);}
@keyframes strom150c-spin{to{transform:rotate(360deg)}}
'''

# CameraFlight should advance after OrbitControls within the existing Canvas, so
# OrbitControls cannot overwrite the interpolated quaternion at the frame boundary.
needle = '<CameraFlight150 points={model.rooms.flatMap(room150 => room150.vertices)} />'
if s.count(needle) != 1:
    raise RuntimeError(f'150c CameraFlight mount expected once, got {s.count(needle)}')
orbit = re.search(r'<OrbitControls\b[^>]*\/>', s, re.S)
if orbit:
    s_no = s.replace(needle, '', 1)
    orbit = re.search(r'<OrbitControls\b[^>]*\/>', s_no, re.S)
    if not orbit:
        raise RuntimeError('150c could not identify OrbitControls after camera move')
    s = s_no[:orbit.end()] + '\n          {/* STROM150C_CAMERA_ORDER: flight overrides OrbitControls at end of frame */}\n          ' + needle + s_no[orbit.end():]
    print('PASS 150c camera rig scheduled after OrbitControls')
else:
    print('INFO 150c OrbitControls tag not matched; camera rig kept at original Canvas mount')

# Write only after every source anchor validates.
app.write_text(a,'utf8')
css.write_text(c,'utf8')
scene.write_text(s,'utf8')
print('PASS 150c: live Blueprint hold, loader, 250 ms fade and camera mount order')
STROM150C_PY
cat > "$RESOURCE_DIR/cameraTransitions150.ts" <<'STROM150C_BRIDGE_TS'
/** STROM150_CAMERA_BRIDGE: coordinate view navigation without delaying React rendering. */
export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number}
export type Mode150='wall'|'threeD'
export type Enter150={mode:Mode150;frame:BlueprintFrame150}
let pending150:Enter150|null=null
let current150:Enter150|null=null
let activeExit150:((done:()=>void)=>void)|null=null
let activeReady150:(()=>void)|null=null
let exitPending150=false
let readySent150=false
export const ENTER_FADE150=250
export const DURATION150=750

function storedLevel150(floorId:string):string{
  try {
    const raw=window.localStorage.getItem(`strom.floorplan.layers.${floorId}.active`)
    const value:unknown=JSON.parse(raw||'null')
    return typeof value==='string'?value:''
  }catch{return ''}
}
function viewFrame150(floorId:string):BlueprintFrame150{
  const result:BlueprintFrame150={floorId,levelId:storedLevel150(floorId),cx:0,cy:0,widthM:0,heightM:0}
  try {
    const svg=document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement|null
    const container=(svg?.closest('.canvas-scroll,.canvas-viewport,.canvas-scroll-area')||svg?.parentElement) as HTMLElement|null
    const matrix=svg?.getScreenCTM()
    const rect=container?.getBoundingClientRect()
    if(svg&&matrix&&rect&&rect.width>30&&rect.height>30){
      const center=svg.createSVGPoint();center.x=rect.left+rect.width/2;center.y=rect.top+rect.height/2
      const p=center.matrixTransform(matrix.inverse())
      result.cx=(p.x-670)/60;result.cy=(p.y-670)/60
      const pxPerUnit=Math.hypot(matrix.a,matrix.b)
      if(pxPerUnit>1e-5){result.widthM=rect.width/(60*pxPerUnit);result.heightM=rect.height/(60*pxPerUnit)}
    }
  }catch{/* fallback to model-room geometry if no live SVG was found */}
  return result
}
export function queueEntry150(mode:Mode150,floorId:string){
  pending150={mode,frame:viewFrame150(floorId)}
  current150=pending150
  exitPending150=false
  readySent150=false
}
export function consumeEntry150():Enter150|null{
  const value=pending150
  pending150=null
  return value
}
export function restoreEntry150(value:Enter150){if(!pending150)pending150=value}
export function currentFrame150():BlueprintFrame150|null{return current150?.frame||null}
export function registerEnterReady150(handler:()=>void):()=>void{
  activeReady150=handler
  return ()=>{if(activeReady150===handler)activeReady150=null}
}
export function notifyEnterReady150(){
  if(readySent150)return
  readySent150=true
  try {activeReady150?.()} catch {/* UI fade is optional */}
}
export function registerExit150(handler:(done:()=>void)=>void):()=>void{
  activeExit150=handler
  return ()=>{if(activeExit150===handler)activeExit150=null}
}
export function requestExit150(finish:()=>void):boolean{
  if(!activeExit150){pending150=null;current150=null;return false}
  if(exitPending150)return true
  exitPending150=true
  let completed=false
  const timeout=window.setTimeout(complete,1100)
  function complete(){if(completed)return;completed=true;window.clearTimeout(timeout);exitPending150=false;finish()}
  try {activeExit150(complete)}catch{complete()}
  return true
}
STROM150C_BRIDGE_TS
cat > "$RESOURCE_DIR/CameraFlight150.tsx" <<'STROM150C_FLIGHT_TSX'
import {useLayoutEffect,useMemo,useRef} from 'react'
import {useFrame,useThree} from '@react-three/fiber'
import * as THREE from 'three'
import {consumeEntry150,restoreEntry150,currentFrame150,registerExit150,DURATION150,ENTER_FADE150,notifyEnterReady150} from './cameraTransitions150'
import type {BlueprintFrame150} from './cameraTransitions150'

type P150={x:number;y:number}
type Control150={target?:THREE.Vector3;enabled?:boolean;update?:()=>void}
type Pose150={position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;zoom:number}
type Flight150={start:Pose150;end:Pose150;started:number;done?:()=>void;restoreControls?:boolean}
const easing150=(t:number)=>1-Math.pow(1-t,3)
const clamp150=(n:number,a:number,b:number)=>Math.min(b,Math.max(a,n))
const UP150=new THREE.Vector3(0,0,-1)

function planBounds150(points:readonly P150[],frame:BlueprintFrame150|null){
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity
  for(const p of points){if(!Number.isFinite(p.x)||!Number.isFinite(p.y))continue
    minX=Math.min(minX,p.x);maxX=Math.max(maxX,p.x);minY=Math.min(minY,p.y);maxY=Math.max(maxY,p.y)
  }
  if(!Number.isFinite(minX)){minX=-4;maxX=4;minY=-3;maxY=3}
  const cx=(minX+maxX)/2,cy=(minY+maxY)/2
  const width=Math.max(2,maxX-minX),height=Math.max(2,maxY-minY)
  if(frame&&frame.widthM>0.1&&frame.heightM>0.1&&frame.widthM<150&&frame.heightM<150){
    return {cx:frame.cx,cy:frame.cy,width:frame.widthM,height:frame.heightM}
  }
  return {cx,cy,width:width*1.14,height:height*1.14}
}
function lookQuat150(position:THREE.Vector3,target:THREE.Vector3){
  const view=new THREE.Matrix4().lookAt(position,target,UP150)
  return new THREE.Quaternion().setFromRotationMatrix(view)
}
function snapshot150(camera:THREE.Camera,control:Control150|null,target:THREE.Vector3):Pose150{
  const zoom=(camera as THREE.OrthographicCamera).zoom||1
  const actualTarget=control?.target?.clone()||target.clone()
  const position=camera.position.clone()
  return {position,rotation:lookQuat150(position,actualTarget),target:actualTarget,zoom}
}
function topPose150(camera:THREE.Camera,bounds:ReturnType<typeof planBounds150>,aspect:number):Pose150{
  const target=new THREE.Vector3(bounds.cx,0,bounds.cy)
  const zoom=Math.max(1,(camera as THREE.OrthographicCamera).zoom||1)
  let distance=12
  let newZoom=zoom
  if((camera as THREE.PerspectiveCamera).isPerspectiveCamera){
    const fov=THREE.MathUtils.degToRad((camera as THREE.PerspectiveCamera).fov||45)
    const tangent=Math.max(0.05,Math.tan(fov/2))
    distance=clamp150(Math.max(bounds.height/2/tangent,bounds.width/2/Math.max(0.3,aspect)/tangent),2,500)
  }else if((camera as THREE.OrthographicCamera).isOrthographicCamera){
    const ortho=camera as THREE.OrthographicCamera
    const viewWidth=Math.abs(ortho.right-ortho.left),viewHeight=Math.abs(ortho.top-ortho.bottom)
    newZoom=clamp150(Math.min(viewWidth/bounds.width,viewHeight/bounds.height),0.05,100)
    distance=Math.max(10,bounds.height*2,bounds.width*2)
  }
  const position=new THREE.Vector3(bounds.cx,distance,bounds.cy)
  return {position,rotation:lookQuat150(position,target),target,zoom:newZoom}
}

/** 750ms eased spatial camera motion; entering is held 250ms so the frozen Blueprint can fade into the loaded 3D start pose. */
export default function CameraFlight150({points}:{points:readonly P150[]}){
  const camera=useThree(state=>state.camera)
  const controls=useThree(state=>(state.controls||null) as Control150|null)
  const size=useThree(state=>state.size)
  const invalidate=useThree(state=>state.invalidate)
  const gl=useThree(state=>state.gl)
  const entryRenderFrame=useRef(0)
  const entryWaiting=useRef(false)
  const flight=useRef<Flight150|null>(null)
  const latest=useRef<{points:readonly P150[];aspect:number}>({points,aspect:Math.max(.3,size.width/Math.max(size.height,1))})
  latest.current={points,aspect:Math.max(.3,size.width/Math.max(size.height,1))}
  const fallback=useMemo(()=>new THREE.Vector3(0,0,0),[])

  const apply=(pose:Pose150)=>{
    camera.position.copy(pose.position)
    camera.quaternion.copy(pose.rotation)
    if(controls?.target)controls.target.copy(pose.target)
    const ortho=camera as THREE.OrthographicCamera
    if(ortho.isOrthographicCamera){ortho.zoom=pose.zoom;ortho.updateProjectionMatrix()}
    camera.updateMatrixWorld()
    invalidate()
  }
  useLayoutEffect(()=>{
    const previousControlsEnabled=controls?.enabled
    const original=snapshot150(camera,controls,fallback)
    const incoming=consumeEntry150()
    if(incoming){
      const bounds=planBounds150(latest.current.points,incoming.frame)
      const bird=topPose150(camera,bounds,latest.current.aspect)
      apply(bird)
      // First frame must be painted before Blueprint fades to the start camera pose.
      entryRenderFrame.current=gl.info.render.frame
      entryWaiting.current=true
      flight.current={start:bird,end:original,started:Number.POSITIVE_INFINITY,restoreControls:previousControlsEnabled}
      if(controls)controls.enabled=false
    }
    const unregister=registerExit150((done)=>{
      const bounds=planBounds150(latest.current.points,currentFrame150())
      const bird=topPose150(camera,bounds,latest.current.aspect)
      const current=snapshot150(camera,controls,bird.target)
      entryWaiting.current=false
      flight.current={start:current,end:bird,started:performance.now(),done,restoreControls:previousControlsEnabled}
      if(controls)controls.enabled=false
    })
    return ()=>{
      unregister()
      if(controls&&previousControlsEnabled!==undefined)controls.enabled=previousControlsEnabled
      if(incoming&&flight.current&&!flight.current.done){apply(original);restoreEntry150(incoming)}
      flight.current=null
    }
  // Keep the camera and controls bound to the same Canvas instance.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  },[camera,controls,gl])
  useFrame(()=>{
    const running=flight.current
    if(!running)return
    if(entryWaiting.current){
      // At least one complete R3F / Three.js render happened with the bird's-eye pose.
      if(gl.info.render.frame>entryRenderFrame.current){
        entryWaiting.current=false
        running.started=performance.now()+ENTER_FADE150
        notifyEnterReady150()
      }
      // Needed if the Canvas runs with frameloop='demand'.
      invalidate()
      return
    }
    const t=clamp150((performance.now()-running.started)/DURATION150,0,1)
    const k=easing150(t)
    const a=running.start,b=running.end
    const next:Pose150={position:a.position.clone().lerp(b.position,k),
      rotation:a.rotation.clone().slerp(b.rotation,k),target:a.target.clone().lerp(b.target,k),zoom:a.zoom+(b.zoom-a.zoom)*k}
    apply(next)
    if(t>=1){
      apply(b)
      flight.current=null
      if(running.done){
        // Reverse: leave OrbitControls disabled until the 3D Canvas unmounts.
        // Updating the controller here would snap the polar angle at the finish.
        running.done()
      }else if(controls){
        controls.enabled=running.restoreControls??true
        controls.update?.()
      }
    }
  })
  return null
}
STROM150C_FLIGHT_TSX

log "3) Apply incremental source changes transactionally ..."
python3 -m py_compile "$RESOURCE_DIR/patch150c.py" >>"$DIAG_LOG" 2>&1 || fail "150c Python syntax failed"
STROM150C_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150c.py" >>"$DIAG_LOG" 2>&1 || fail "150c source patch failed; GitHub and Stage unchanged"
cp "$RESOURCE_DIR/cameraTransitions150.ts" "$WORK_DIR/frontend/src/components/cameraTransitions150.ts"
cp "$RESOURCE_DIR/CameraFlight150.tsx" "$WORK_DIR/frontend/src/components/CameraFlight150.tsx"
log "4) Structural TS/TSX audit (no parse errors / duplicate JSX attributes) ..."
STROM150C_SOURCE="$WORK_DIR/frontend/src" STROM150C_TS="$DEPENDENCIES/typescript" node <<'STROM150C_AST' >>"$DIAG_LOG" 2>&1 || fail "150c AST audit failed; GitHub and Stage unchanged"
const fs=require('fs'),path=require('path'),ts=require(process.env.STROM150C_TS)
const root=process.env.STROM150C_SOURCE
let files=0
function visitDir(dir){for(const name of fs.readdirSync(dir)){
 const p=path.join(dir,name),stat=fs.statSync(p)
 if(stat.isDirectory()){if(!['node_modules','dist','.git'].includes(name))visitDir(p);continue}
 if(!/\.tsx?$/.test(name))continue
 const code=fs.readFileSync(p,'utf8'),ast=ts.createSourceFile(p,code,ts.ScriptTarget.Latest,true,name.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 if(ast.parseDiagnostics.length)throw Error(p+': '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
 function walk(node){if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node)){
   const seen=new Set();for(const prop of node.attributes.properties){if(!ts.isJsxAttribute(prop))continue
   const n=prop.name.getText(ast);if(seen.has(n))throw Error(p+' duplicate JSX attribute: '+n);seen.add(n)}
  }ts.forEachChild(node,walk)}walk(ast);files++
}}
visitDir(root)
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
if(!app.includes('STROM150C_PRESERVE_BLUEPRINT'))throw Error('live Blueprint preserve hook missing')
console.log('PASS AST:',files,'TS/TSX files; no parse or duplicate attribute errors')
STROM150C_AST

log "5) Full TypeScript and Vite build against real Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150c TypeScript/Vite build failed before GitHub push"
log "5.1) Camera transition regression tests ..."
STROM150C_SOURCE="$WORK_DIR/frontend/src" STROM150C_TS="$DEPENDENCIES/typescript" node <<'STROM150C_TEST' >>"$DIAG_LOG" 2>&1 || fail "150c regression failed"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150C_TS)
const root=process.env.STROM150C_SOURCE
const src=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const js=ts.transpileModule(src,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
const mockWindow={localStorage:{getItem:(k)=>k.endsWith('.active')?'"top"':null},setTimeout:()=>1,clearTimeout:()=>{}}
const mockDocument={querySelector:()=>null},m={exports:{}}
new Function('module','exports','require','window','document',js)(m,m.exports,require,mockWindow,mockDocument)
const b=m.exports
b.queueEntry150('threeD','house');assert(b.consumeEntry150().frame.levelId==='top')
assert.equal(b.DURATION150,750);assert.equal(b.ENTER_FADE150,250)
let ready=0;const unready=b.registerEnterReady150(()=>ready++)
b.notifyEnterReady150();b.notifyEnterReady150();assert.equal(ready,1);unready()
let exited=false;const unexit=b.registerExit150(done=>done())
assert(b.requestExit150(()=>{exited=true}));assert(exited);unexit()
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
assert(flight.includes('gl.info.render.frame>entryRenderFrame.current'))
assert(flight.includes('1-Math.pow(1-t,3)'))
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
assert(app.includes("(viewMode === 'floorplan' || (enterPreview150 !== null"))
console.log('PASS: first painted 3D frame, 250ms fade, 750ms ease-out, camera reverse finish')
STROM150C_TEST

rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150C.md" <<'STROM150C_DOC'
# Update 150c – plan-matched immersive camera transition
- Keeps the genuine, mounted Blueprint visible while the 3D Canvas initializes.
- Shows a spinner until at least one complete WebGL frame has been rendered.
- Cross-fades the existing Blueprint to the top-down 3D pose for 250 ms.
- Only then begins the original 750 ms cubic ease-out camera flight.
- Stabilizes the reverse camera flight and avoids a final OrbitControls snap.
- GitHub build, Stage and /strom-test/ only; no changes to /strom/ production.
STROM150C_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150c Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy to /strom-test/ only ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150c Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150c frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150c test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150c deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
