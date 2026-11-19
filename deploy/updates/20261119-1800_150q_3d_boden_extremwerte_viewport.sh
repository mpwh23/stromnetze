#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1800_150q_3d_boden_extremwerte_viewport"
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
COMMIT_MESSAGE="Update 150q: project 3D floor footprint extrema into Blueprint viewport at fade start"
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
  echo "2) Update 150q im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150q isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150q: compare Blueprint and 3D floor viewport extents ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
# This is a deliberate replacement of the 150l camera module, not a reinstallation of update 150.
grep -Fq 'STROM150P_BLUEPRINT_EXTENTS' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "150q requires installed 150p. Stage unchanged."
grep -Fq 'STROM150C_PRESERVE_BLUEPRINT' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150q requires the live Blueprint overlay"
grep -Fq 'STROM150K_FAIL_CLOSED' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150q requires the safe fallback guard"
grep -Fq 'export const ENTER_FADE150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "150q expects 5000ms fade"
grep -Fq 'export const DURATION150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "150q expects 5000ms flight"
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
RESOURCE_DIR="$WORK_DIR/150q_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150q.py" <<'STROM150Q_PY'
#!/usr/bin/env python3
"""Add a passive 3D floor-footprint projection at exactly the start of the fade."""
from pathlib import Path
import os
root=Path(os.environ['STROM150Q_ROOT'])/'frontend/src'
flight=root/'components/CameraFlight150.tsx'
bridge=root/'components/cameraTransitions150.ts'
if not flight.is_file() or not bridge.is_file():
    raise RuntimeError('150q camera files missing')
f=flight.read_text('utf8');b=bridge.read_text('utf8')
if 'STROM150Q_3D_FLOOR_EXTENTS' in f:
    raise RuntimeError('150q already installed')
for req in ('STROM150N_BP_SCREEN_CALIBRATION','STROM150N_NO_END_JUMP','notifyEnterReady150()'):
    if req not in f:raise RuntimeError(f'150q requires current 150n/150o flight: {req}')
if 'STROM150P_BLUEPRINT_EXTENTS' not in b:
    raise RuntimeError('150q requires Blueprint bounds measurements from 150p')
old="import type { BlueprintFrame150, Enter150 } from './cameraTransitions150'"
if f.count(old)!=1: raise RuntimeError('150q flight import not unique')
f=f.replace(old,old+"\nimport { captureThreeFloorExtrema150q } from './threeFloorExtrema150q' // STROM150Q_3D_FLOOR_EXTENTS",1)
# Ensure the 3D probe samples AFTER camera position was applied and BEFORE the fade is released.
old='''        notifyEnterReady150()'''
new='''        // STROM150Q_3D_FLOOR_EXTENTS: actual 3D camera projection at the start of the fade.
        // This diagnostic never changes camera/controls or delays the animation.
        try {
          captureThreeFloorExtrema150q(pointsRef.current, state.camera, state.gl.domElement, 0)
        } catch (error) { console.warn('[STROM 150q] 3D-Boden-Messung fehlgeschlagen', error) }
        notifyEnterReady150()'''
if f.count(old)!=1:raise RuntimeError(f'150q fade-notification anchor expected once; found {f.count(old)}')
f=f.replace(old,new,1)
# Only source under the active 3D scene is changed; Blueprint sampling remains identical.
flight.write_text(f,'utf8')
print('PASS 150q: diagnostic 3D projection registered immediately before fade; camera unchanged')
STROM150Q_PY
cat > "$RESOURCE_DIR/threeFloorExtrema150q.ts" <<'STROM150Q_TS'
import * as THREE from 'three'

/** STROM150Q_3D_FLOOR_EXTENTS: project the actual active 3D model room-footprint
 * coordinates (X,Z at finished-floor Y=0) using the camera that will render
 * the first frame of the fade. No temporary camera or changed viewport. */
export type FloorPoint150q = {x:number;y:number}
export type Extrema150q = {
  xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number
  widthPx:number;heightPx:number;points:number
  outsidePx:{left:number;right:number;top:number;bottom:number}
}
export type FloorSnapshot150q = {
  version:'150q'; phase:'Beginn der 3D-Blende';measuredAt:string
  units:'CSS-Pixel';reference:string;floorY:number
  viewport:{screenLeft:number;screenTop:number;width:number;height:number}
  canvas:{screenLeft:number;screenTop:number;width:number;height:number}
  floor:Extrema150q; deltaToBlueprint:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}|null
}
type BlueprintReference150q={
  viewport:{screenLeft:number;screenTop:number;width:number;height:number}
  drawing?:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}|null
}
const round150q=(v:number)=>Math.round(v*10)/10

export function captureThreeFloorExtrema150q(
  points:readonly FloorPoint150q[],camera:THREE.Camera,canvas:HTMLCanvasElement,floorY:number,
):FloorSnapshot150q|null{
  let reference:BlueprintReference150q|null=null
  try{
    const raw=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(raw)reference=JSON.parse(raw) as BlueprintReference150q
  }catch{/* use canvas as backup reference */}
  const bounds=canvas.getBoundingClientRect()
  if(bounds.width<1||bounds.height<1||!Number.isFinite(bounds.left)||!Number.isFinite(bounds.top))return null
  const bpView=reference?.viewport
  const left=Number.isFinite(bpView?.screenLeft)?bpView!.screenLeft:bounds.left
  const top=Number.isFinite(bpView?.screenTop)?bpView!.screenTop:bounds.top
  const width=Number.isFinite(bpView?.width)&&bpView!.width>0?bpView!.width:bounds.width
  const height=Number.isFinite(bpView?.height)&&bpView!.height>0?bpView!.height:bounds.height
  let xMin=Infinity,xMax=-Infinity,yMin=Infinity,yMax=-Infinity,count=0
  const probe=new THREE.Vector3()
  for(const point of points){
    if(!Number.isFinite(point.x)||!Number.isFinite(point.y))continue
    // Real 3D scene maps Blueprint X/Y to world X/Z; the floor is world Y=0.
    probe.set(point.x,floorY,point.y).project(camera)
    if(!Number.isFinite(probe.x)||!Number.isFinite(probe.y)||!Number.isFinite(probe.z))continue
    const x=bounds.left+(probe.x+1)*bounds.width/2-left
    const y=bounds.top+(1-probe.y)*bounds.height/2-top
    xMin=Math.min(xMin,x);xMax=Math.max(xMax,x)
    yMin=Math.min(yMin,y);yMax=Math.max(yMax,y)
    count++
  }
  if(count===0)return null
  const floor:Extrema150q={
    xMinPx:round150q(xMin),xMaxPx:round150q(xMax),
    yMinPx:round150q(yMin),yMaxPx:round150q(yMax),
    widthPx:round150q(xMax-xMin),heightPx:round150q(yMax-yMin),points:count,
    outsidePx:{left:round150q(Math.max(0,-xMin)),right:round150q(Math.max(0,xMax-width)),
      top:round150q(Math.max(0,-yMin)),bottom:round150q(Math.max(0,yMax-height))},
  }
  const drawing=reference?.drawing
  const deltaToBlueprint=drawing&&[drawing.xMinPx,drawing.xMaxPx,drawing.yMinPx,drawing.yMaxPx].every(Number.isFinite)?{
    xMinPx:round150q(floor.xMinPx-drawing.xMinPx),xMaxPx:round150q(floor.xMaxPx-drawing.xMaxPx),
    yMinPx:round150q(floor.yMinPx-drawing.yMinPx),yMaxPx:round150q(floor.yMaxPx-drawing.yMaxPx),
  }:null
  const result:FloorSnapshot150q={
    version:'150q',phase:'Beginn der 3D-Blende',measuredAt:new Date().toISOString(),units:'CSS-Pixel',
    reference:bpView?'Blueprint-Viewport (0,0)':'3D-Canvas (0,0), BP-Referenz fehlt',floorY,
    viewport:{screenLeft:round150q(left),screenTop:round150q(top),width:round150q(width),height:round150q(height)},
    canvas:{screenLeft:round150q(bounds.left),screenTop:round150q(bounds.top),width:round150q(bounds.width),height:round150q(bounds.height)},
    floor,deltaToBlueprint,
  }
  try{window.localStorage.setItem('strom.camera150q.floorExtents',JSON.stringify(result))}catch{/*optional*/}
  console.info('[STROM 150q] 3D-Bodenfläche bei Beginn der Blende',result)
  const panel=document.getElementById('strom-150p-viewport-geometry')
  if(panel){
    const existing=document.getElementById('strom-150q-floor-values')
    existing?.remove()
    const subsection=document.createElement('span')
    subsection.id='strom-150q-floor-values'
    subsection.style.cssText='display:block;margin-top:8px;color:#78e6f1;font-weight:650;'
    subsection.textContent='3D-Bodenfläche · Blendenbeginn (cyan)\n'
      +`Xmin: ${floor.xMinPx} px  | Xmax: ${floor.xMaxPx} px\n`
      +`Ymin: ${floor.yMinPx} px  | Ymax: ${floor.yMaxPx} px\n`
      +(deltaToBlueprint?`Δ zu BP Xmin/Xmax: ${deltaToBlueprint.xMinPx} / ${deltaToBlueprint.xMaxPx} px\n`
        +`Δ zu BP Ymin/Ymax: ${deltaToBlueprint.yMinPx} / ${deltaToBlueprint.yMaxPx} px\n`:'')
      +`Bodenpunkte: ${count} · Ursprung: ${result.reference}\n`
    // Place colored values directly beneath the existing Blueprint X/Y extrema.
    const node=panel.firstChild
    const raw=node?.textContent||''
    const yRow=raw.indexOf('Ymin: ')
    const rowEnd=yRow>=0?raw.indexOf('\n',yRow):-1
    if(node?.nodeType===3&&typeof (node as Text).splitText==='function'&&rowEnd>=0){
      const following=(node as Text).splitText(rowEnd+1)
      panel.insertBefore(subsection,following)
    }else panel.appendChild(subsection)
  }
  return result
}
STROM150Q_TS
cat > "$RESOURCE_DIR/test_floor_extrema.cjs" <<'STROM150Q_TEST_JS'
'use strict'
const fs=require('fs'),assert=require('assert'),path=require('path')
const ts=require(process.env.STROM150Q_TS)
const three=require(process.env.STROM150Q_THREE)
const source=process.env.STROM150Q_SOURCE
const flight=fs.readFileSync(process.env.STROM150Q_FLIGHT,'utf8')
const code=fs.readFileSync(source,'utf8')
const ast=ts.createSourceFile(source,code,ts.ScriptTarget.Latest,true,ts.ScriptKind.TS)
assert.equal(ast.parseDiagnostics.length,0,'helper TS parses')
const fast=ts.createSourceFile('CameraFlight150.tsx',flight,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
assert.equal(fast.parseDiagnostics.length,0,'flight TSX parses')
assert.equal((flight.match(/captureThreeFloorExtrema150q\(/g)||[]).length,1,'exactly one 3D diagnostic at fade')
assert(flight.indexOf('captureThreeFloorExtrema150q(')<flight.indexOf('notifyEnterReady150()'),'sample before fade')
const js=ts.transpileModule(code,{fileName:source,compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText
const storage=new Map()
storage.set('strom.camera150p.blueprintExtents',JSON.stringify({
  viewport:{screenLeft:100,screenTop:50,width:800,height:600},
  drawing:{xMinPx:130,xMaxPx:600,yMinPx:80,yMaxPx:480},
}))
let created=null
const panel={appendChild(node){created=node}}
const document={getElementById(id){return id==='strom-150p-viewport-geometry'?panel:null},createElement(){return {id:'',style:{cssText:''},textContent:''}}}
const window={localStorage:{getItem(k){return storage.get(k)||null},setItem(k,v){storage.set(k,v)}}}
const testModule={exports:{}}
const req=id=>id==='three'?three:(()=>{throw Error('Unexpected import: '+id)})()
new Function('require','module','exports','document','window','console',js)(req,testModule,testModule.exports,document,window,{info(){}})
const camera=new three.OrthographicCamera(-4,4,3,-3,0.1,100)
camera.position.set(0,10,0)
camera.up.set(0,0,-1)
camera.lookAt(0,0,0)
camera.updateProjectionMatrix()
camera.updateMatrixWorld(true)
const canvas={getBoundingClientRect(){return {left:100,top:50,width:800,height:600}}}
const points=[{x:-2,y:-1},{x:3,y:-1},{x:3,y:2},{x:-2,y:2}]
const result=testModule.exports.captureThreeFloorExtrema150q(points,camera,canvas,0)
assert(result,'3D bounds captured')
assert.equal(result.floor.xMinPx,200)
assert.equal(result.floor.xMaxPx,700)
assert.equal(result.floor.yMinPx,200)
assert.equal(result.floor.yMaxPx,500)
assert.equal(result.deltaToBlueprint.xMinPx,70)
assert.equal(result.deltaToBlueprint.xMaxPx,100)
assert.equal(created.style.cssText.includes('#78e6f1'),true,'3D values cyan')
assert(created.textContent.includes('Ymin: 200 px  | Ymax: 500 px'))
assert(JSON.parse(storage.get('strom.camera150q.floorExtents')).floor.points===4)
console.log('PASS 150q: actual orthographic 3D projection, same BP viewport coordinate space, color overlay, deltas, browser storage')
STROM150Q_TEST_JS
log "3) 3D-Footprint-Diagnose am Beginn der Blende installieren ..."
python3 -m py_compile "$RESOURCE_DIR/patch150q.py" >>"$DIAG_LOG" 2>&1 || fail "150q Python syntax failed"
STROM150Q_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150q.py" >>"$DIAG_LOG" 2>&1 || fail "150q patch failed; GitHub and Stage unchanged"
install -m 0644 "$RESOURCE_DIR/threeFloorExtrema150q.ts" "$WORK_DIR/frontend/src/components/threeFloorExtrema150q.ts"
log "4) TypeScript/Vite build against real Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150q TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) 3D-Projektionsregression mit Three.js ..."
STROM150Q_SOURCE="$WORK_DIR/frontend/src/components/threeFloorExtrema150q.ts" \
STROM150Q_FLIGHT="$WORK_DIR/frontend/src/components/CameraFlight150.tsx" \
STROM150Q_TS="$DEPENDENCIES/typescript" STROM150Q_THREE="$DEPENDENCIES/three" \
node "$RESOURCE_DIR/test_floor_extrema.cjs" >>"$DIAG_LOG" 2>&1 || fail "150q 3D extrema regression failed"
log "PASS 150q: projected 3D floor footprint at fade start, visible in cyan beneath Blueprint bounds"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150Q.md" <<'STROM150Q_DOC'
# Stromnetze 150q – Three-dimensional floor viewport extents (diagnostic)
- Keep existing 150p measurements, overlay and browser-console logging unchanged.
- At the entry fade start, use the actual R3F camera and live canvas DOM rectangle to project all selected model room-footprint vertices at 3D finished-floor Y=0 (X/Z plane).
- Convert projected positions to CSS pixels referenced to the exact saved Blueprint viewport origin, including offscreen positions.
- Append distinctly cyan Xmin/Xmax/Ymin/Ymax and coordinate differences to the 150p overlay. Also store JSON under `strom.camera150q.floorExtents` and log to browser console.
- Do not change 3D geometry, camera settings, controls, 5000 ms fade/flight or return flight.
- Build and test in isolated checkout, push GitHub first, stage then deploy only /strom-test/.
STROM150Q_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150q Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150q Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150q frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150q test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150q deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"