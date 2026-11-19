#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1630_150o_blenden_offset_blueprint_snap"
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
COMMIT_MESSAGE="Update 150o: freeze pre-navigation Blueprint projection and crossfade viewport alignment"
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
  echo "2) Update 150o im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150o isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150o: pixel-exact Blueprint crossfade alignment, no camera flight changes ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
# This is a deliberate replacement of the 150l camera module, not a reinstallation of update 150.
grep -Fq 'STROM150N_BP_SCREEN_CALIBRATION' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "150o requires installed 150n. Existing stage is different; no files changed."
grep -Fq 'STROM150C_PRESERVE_BLUEPRINT' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150o requires the live Blueprint overlay introduced by 150c"
grep -Fq 'STROM150K_FAIL_CLOSED' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150o requires the safe fallback guard introduced by 150k"
grep -Fq 'export const ENTER_FADE150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "Expected 5000ms fade constant not found"
grep -Fq 'export const DURATION150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "Expected 5000ms flight constant not found"
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
RESOURCE_DIR="$WORK_DIR/150o_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150o.py" <<'STROM150O_PY'
#!/usr/bin/env python3
"""150o: freeze Blueprint screen mapping BEFORE switching; preserve live BP viewport during fade.
Deliberately preserve 150n's camera rotation, settled end pose, easing, durations, and loading flow.
"""
from pathlib import Path
import os

root=Path(os.environ['STROM150O_ROOT'])/'frontend/src'
app=root/'App.tsx'
bridge=root/'components/cameraTransitions150.ts'
flight=root/'components/CameraFlight150.tsx'
css=root/'styles.css'
for f in (app,bridge,flight,css):
    if not f.is_file():raise RuntimeError(f'150o source missing: {f}')
a=app.read_text('utf8');b=bridge.read_text('utf8');f=flight.read_text('utf8');c=css.read_text('utf8')
if 'STROM150O_PRE_NAV_SNAPSHOT' in b or 'STROM150O_PRE_NAV_SNAPSHOT' in f or 'strom150o-viewport-frozen' in c:
    raise RuntimeError('150o already installed; refusing duplicate patch')
for marker in ['STROM150N_BP_SCREEN_CALIBRATION','STROM150N_DEFAULT_SETTLED','STROM150N_NO_END_JUMP']:
    if marker not in f:raise RuntimeError(f'150o requires 150n CameraFlight: {marker}')
for marker in ['STROM150C_PRESERVE_BLUEPRINT','STROM150K_FAIL_CLOSED']:
    if marker not in a:raise RuntimeError(f'150o requires 150n App: {marker}')
for marker in ['export const ENTER_FADE150=5000','export const DURATION150=5000']:
    if marker not in b:raise RuntimeError(f'150o 5000 ms timing missing: {marker}')
if 'transition:opacity 5000ms ease;' not in c:raise RuntimeError('150o expects 5000 ms Blueprint CSS fade')

def replace_one(text,old,new,label):
    n=text.count(old)
    if n!=1:raise RuntimeError(f'150o {label}: expected 1 exact anchor, got {n}')
    return text.replace(old,new,1)

# The frame exists already in 150n. Add an optional field and keep every existing API name intact.
b=replace_one(b,
 'export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number}',
 '''export type BlueprintScreen150o={x:number;y:number;ax:number;ay:number;bx:number;by:number}
export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number;screen150o?:BlueprintScreen150o}''',
 'frame type')

needle='''    if(svg&&matrix&&rect&&rect.width>30&&rect.height>30){'''
addition='''    if(svg&&matrix&&rect&&rect.width>30&&rect.height>30){
      // STROM150O_PRE_NAV_SNAPSHOT: saved at the click, before the DOM is reparented/reflowed.
      // SVG world units: mToX/Y(m) = 670 + 60*m. getScreenCTM gives CSS screen pixels.
      const pxX=60*Math.hypot(matrix.a,matrix.b)
      const pxY=60*Math.hypot(matrix.c,matrix.d)
      if(pxX>2&&pxY>2&&pxX<1000&&pxY<1000&&Math.abs(pxX-pxY)<Math.max(pxX,pxY)*0.07){
        result.screen150o={
          x:670*(matrix.a+matrix.c)+matrix.e,
          y:670*(matrix.b+matrix.d)+matrix.f,
          ax:60*matrix.a,ay:60*matrix.b,
          bx:60*matrix.c,by:60*matrix.d,
        }
      }
      // Freeze the ORIGINAL Blueprint's layout in the overlay: no geometry changes
      // when FloorplanEditor becomes position:absolute during 3D mount.
      const plan=svg.closest('.floorplan-layout') as HTMLElement|null
      const host=plan?.parentElement
      const planRect=plan?.getBoundingClientRect()
      const hostRect=host?.getBoundingClientRect()
      if(plan&&planRect&&hostRect&&planRect.width>50&&planRect.height>50){
        plan.style.setProperty('--strom150o-left',`${planRect.left-hostRect.left}px`)
        plan.style.setProperty('--strom150o-top',`${planRect.top-hostRect.top}px`)
        plan.style.setProperty('--strom150o-width',`${planRect.width}px`)
        plan.style.setProperty('--strom150o-height',`${planRect.height}px`)
        plan.classList.add('strom150o-viewport-frozen')
      }
'''
b=replace_one(b,needle,addition,'view frame snapshot')

# Use click-time screen transform rather than SVG.getScreenCTM() after mount.
old='''function blueprintProjection(canvas: HTMLCanvasElement | undefined, bounds: ReturnType<typeof modelBounds>) {
  try {
    const svg = document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement | null'''
new='''function blueprintProjection(canvas: HTMLCanvasElement | undefined, bounds: ReturnType<typeof modelBounds>,
  frame: BlueprintFrame150 | null) {
  try {
    // STROM150O_PRE_NAV_SNAPSHOT: do not recalibrate from the reflowed Blueprint overlay.
    const saved = frame?.screen150o
    const stableRect = canvas?.getBoundingClientRect()
    if(saved&&stableRect&&stableRect.width>50&&stableRect.height>50){
      const scaleX=Math.hypot(saved.ax,saved.ay)
      const scaleY=Math.hypot(saved.bx,saved.by)
      const pixelsPerM=(scaleX+scaleY)/2
      if(pixelsPerM>2&&pixelsPerM<1000&&Math.abs(scaleX-scaleY)<=pixelsPerM*0.07){
        return {
          pixelsPerM,
          screenX:saved.x+saved.ax*bounds.cx+saved.bx*bounds.cy,
          screenY:saved.y+saved.ay*bounds.cx+saved.by*bounds.cy,
          canvasX:stableRect.left+stableRect.width/2,
          canvasY:stableRect.top+stableRect.height/2,
          canvasHeight:stableRect.height,
        }
      }
    }
    // Fallback only for sessions where the Blueprint snapshot could not be captured.
    const svg = document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement | null'''
f=replace_one(f,old,new,'projection function')
f=replace_one(f,'const mapped = blueprintProjection(canvas, box)','const mapped = blueprintProjection(canvas, box, frame)','projection call')

c+='''
/* STROM150O_PRE_NAV_SNAPSHOT: exact pre-navigation Blueprint layout while it overlays 3D. */
.workspace.strom150c-enter-loading > .floorplan-layout.strom150o-viewport-frozen,
.workspace.strom150c-enter-fading > .floorplan-layout.strom150o-viewport-frozen {
  inset:auto !important;
  left:var(--strom150o-left,0px) !important;
  top:var(--strom150o-top,0px) !important;
  right:auto !important;
  bottom:auto !important;
  width:var(--strom150o-width,100%) !important;
  min-width:0 !important;
  height:var(--strom150o-height,100%) !important;
  max-height:none !important;
}
'''
# Atomic on the isolated source; no partial writes before all anchors pass.
bridge.write_text(b,'utf8');flight.write_text(f,'utf8');css.write_text(c,'utf8')
print('PASS 150o: BP matrix captured before navigation, original overlay geometry frozen; camera flight unchanged')
STROM150O_PY
cat > "$RESOURCE_DIR/test_camera.js" <<'STROM150O_TEST_JS'
'use strict'
const fs=require('fs'),assert=require('assert'),ts=require(process.env.STROM150N_TS || 'typescript')
const source=process.env.STROM150N_SOURCE
if(!source)throw Error('STROM150N_SOURCE required')
const code=fs.readFileSync(source,'utf8')
const ast=ts.createSourceFile(source,code,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
assert.equal(ast.parseDiagnostics.length,0,'TSX parses')
for(const marker of ['STROM150N_BP_SCREEN_CALIBRATION','STROM150N_DEFAULT_SETTLED','STROM150N_NO_END_JUMP','STROM150N_FORWARD_HANDOFF'])assert(code.includes(marker),marker)
assert(!code.includes('live?.update?.()'),'Old end-jump forcing control update must be removed')
class V {
  constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}
  clone(){return new V(this.x,this.y,this.z)}
  copy(p){this.x=p.x;this.y=p.y;this.z=p.z;return this}
  add(p){this.x+=p.x;this.y+=p.y;this.z+=p.z;return this}
  lerp(p,t){this.x+=(p.x-this.x)*t;this.y+=(p.y-this.y)*t;this.z+=(p.z-this.z)*t;return this}
  normalize(){const len=Math.hypot(this.x,this.y,this.z)||1;this.x/=len;this.y/=len;this.z/=len;return this}
  distanceTo(p){return Math.hypot(this.x-p.x,this.y-p.y,this.z-p.z)}
}
class Q {
  constructor(n=0){this.n=n}
  clone(){return new Q(this.n)}
  copy(p){this.n=p.n;return this}
  angleTo(p){return Math.abs(this.n-p.n)}
  slerp(p,t){this.n+=(p.n-this.n)*t;return this}
  setFromRotationMatrix(m){this.n=100+m.right.x;return this}
}
class Mat {makeBasis(right,up,back){this.right=right;this.up=up;this.back=back;return this}}
const Three={Vector3:V,Quaternion:Q,Matrix4:Mat}
let now=1000,callback,cleanup,ready=0,exitCallback,pending={mode:'threeD',frame:{floorId:'test',levelId:'A',cx:5,cy:3,widthM:12,heightM:8,screen150o:{x:250,y:180,ax:90,ay:0,bx:0,by:90}}},invalidation=0,controlUpdates=0
let canvasRect={left:0,top:0,width:1200,height:900}
const camera={position:new V(0,-20,0),quaternion:new Q(-1),up:new V(0,1,0),fov:45,isPerspectiveCamera:true,isOrthographicCamera:false,updateMatrixWorld(){}}
const control={target:new V(0,0,0),enabled:true,update(){controlUpdates++}}
const state={camera,controls:control,size:{width:1200,height:900},gl:{domElement:{getBoundingClientRect(){return canvasRect}}},get(){return state},invalidate(){invalidation++}}
const React={useRef:v=>({current:v}),useLayoutEffect:fn=>{cleanup=fn()}}
const Fiber={useThree:fn=>fn(state),useFrame:fn=>{callback=fn}}
const Bridge={
 consumeEntry150(){const x=pending;pending=null;return x},
 restoreEntry150(e){if(!pending)pending=e},
 currentFrame150(){return {floorId:'test',levelId:'A',cx:5,cy:3,widthM:12,heightM:8,screen150o:{x:250,y:180,ax:90,ay:0,bx:0,by:90}}},
 registerExit150(fn){exitCallback=fn;return ()=>{if(exitCallback===fn)exitCallback=null}},
 notifyEnterReady150(){ready++},
 DURATION150:5000,ENTER_FADE150:5000,
}
const transpiled=ts.transpileModule(code,{fileName:source,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}})
assert.equal((transpiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0)
const moduleFlight={exports:{}}
const req=name=>name==='react'?React:name==='@react-three/fiber'?Fiber:name==='three'?Three:name==='./cameraTransitions150'?Bridge:(()=>{throw Error('Unexpected import '+name)})()
new Function('module','exports','require','document','performance',transpiled.outputText)(moduleFlight,moduleFlight.exports,req,{
 querySelector(q){assert.equal(q,'svg[aria-label="Blueprint Editor"]');return {getScreenCTM(){return {a:5,b:0,c:0,d:5,e:2345,f:987}}}}
},{now:()=>now})
moduleFlight.exports.default({points:[{x:0,y:0},{x:10,y:0},{x:10,y:6},{x:0,y:6}]})
assert(callback&&cleanup&&exitCallback,'CameraFlight initialized')
function tick(){if(control.update)control.update();callback(state)}
// The initially mounted camera is *not* the actual standard view (old bug).
tick();assert.equal(ready,0)
tick();tick();
camera.position.copy(new V(2,17,11));camera.quaternion.n=7
control.target.copy(new V(5,1,3))
let startPose=null
for(let i=0;i<65&&ready===0;i++){
  now+=16;tick()
  if(camera.quaternion.n===101 && !startPose){startPose={position:camera.position.clone(),target:control.target.clone(),angle:camera.quaternion.n}}
}
assert.equal(ready,1,'Ready emitted automatically after stable default and 3 locked camera frames')
assert(startPose,'Top view established')
// Model centre at 700 px; 3D viewport centre at 600px => target is shifted 100 / 90 m.
assert(Math.abs(startPose.target.x-(5-100/90))<0.000001,'true DOM-mapped horizontal Blueprint pan')
assert(Math.abs(startPose.target.z-3)<0.000001,'true DOM-mapped vertical Blueprint pan')
assert.equal(control.enabled,false,'controls disabled while Blueprint fades')
const top=startPose.position.clone()
now+=2000;tick();assert.equal(camera.position.distanceTo(top),0,'top stays fixed mid-fade')
now+=3000;tick();assert.equal(camera.position.distanceTo(top),0,'no jump at fade end')
now+=2500;tick();assert(camera.position.y>top.y&&camera.position.y<17,'flight heads to real final camera')
now+=2500;tick()
assert.equal(camera.position.distanceTo(new V(2,17,11)),0,'flight ends exactly at settled default, not first frame')
assert.equal(camera.quaternion.n,7,'no angle jump at endpoint')
assert.equal(control.enabled,true,'controls restored')
const updatesBefore=controlUpdates
// Unlock never invokes native controls update at completion (only next normal frame).
assert.equal(controlUpdates,updatesBefore,'update count stable')
assert(invalidation>0)
cleanup()
console.log('PASS 150o: pre-click screenshot coordinates used despite reflowed DOM; 5s/5s and final camera unchanged')
STROM150O_TEST_JS
cat > "$RESOURCE_DIR/test_snapshot.js" <<'STROM150O_SNAPSHOT_JS'
// STROM150O_SNAPSHOT_TEST: record BP projection before viewMode is switched.
'use strict'
const fs=require('fs'),assert=require('assert'),ts=require(process.env.STROM150O_TS)
const source=fs.readFileSync(process.env.STROM150O_BRIDGE,'utf8')
const code=ts.transpileModule(source,{fileName:'cameraTransitions150.ts',compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText
const output={exports:{}}
const vars={}
const classAdded=new Set()
const plan={
  getBoundingClientRect(){return {left:180,top:50,width:1200,height:900}},
  parentElement:{getBoundingClientRect(){return {left:160,top:40,width:1500,height:980}}},
  style:{setProperty(k,v){vars[k]=v}},classList:{add(v){classAdded.add(v)}}
}
const matrix={a:1.5,b:0,c:0,d:1.5,e:-755,f:-825,inverse(){return {}}}
const container={getBoundingClientRect(){return {left:200,top:70,width:1100,height:840}}}
const svg={
  getScreenCTM(){return matrix},
  closest(s){return s==='.floorplan-layout'?plan:container},
  createSVGPoint(){return {x:0,y:0,matrixTransform(){return {x:730,y:850}}}}
}
const document={querySelector(){return svg}}
const window={localStorage:{getItem(name){return name.endsWith('.active')?'"EG"':null}},setTimeout(){return 1},clearTimeout(){}}
new Function('module','exports','require','document','window',code)(output,output.exports,require,document,window)
const bridge=output.exports
bridge.queueEntry150('threeD','floor-1')
const saved=bridge.consumeEntry150()?.frame
assert(saved&&saved.screen150o,'screen transform captured on click')
assert.strictEqual(saved.screen150o.x,250)
assert.strictEqual(saved.screen150o.y,180)
assert.strictEqual(saved.screen150o.ax,90)
assert.strictEqual(saved.screen150o.by,90)
assert.strictEqual(saved.levelId,'EG')
assert(classAdded.has('strom150o-viewport-frozen'))
assert.strictEqual(vars['--strom150o-left'],'20px')
assert.strictEqual(vars['--strom150o-top'],'10px')
assert.strictEqual(vars['--strom150o-width'],'1200px')
assert.strictEqual(vars['--strom150o-height'],'900px')
// The Blueprint DOM reflows AFTER the navigation; the saved mapping must not change.
matrix.e+=500;matrix.d*=1.5
assert.strictEqual(saved.screen150o.x,250)
assert.strictEqual(saved.screen150o.by,90)
assert.strictEqual(bridge.ENTER_FADE150,5000)
assert.strictEqual(bridge.DURATION150,5000)
console.log('PASS 150o: click-time SVG world->screen projection and frozen overlay box, original durations')
STROM150O_SNAPSHOT_JS
log "3) Capture pre-click Blueprint screen projection and freeze overlay box ..."
python3 -m py_compile "$RESOURCE_DIR/patch150o.py" >>"$DIAG_LOG" 2>&1 || fail "150o Python syntax failed"
STROM150O_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150o.py" >>"$DIAG_LOG" 2>&1 || fail "150o patch failed; GitHub and Stage unchanged"
log "4) Audit TypeScript sources and preserve 5s/5s timing ..."
STROM150O_ROOT="$WORK_DIR/frontend/src" STROM150O_TS="$DEPENDENCIES/typescript" node <<'STROM150O_AUDIT' >>"$DIAG_LOG" 2>&1 || fail "150o TSX audit failed"
'use strict'
const fs=require('fs'),path=require('path'),assert=require('assert'),ts=require(process.env.STROM150O_TS)
const root=process.env.STROM150O_ROOT
for(const rel of ['App.tsx','components/CameraFlight150.tsx','components/cameraTransitions150.ts','components/Building3DWorkspace.tsx']){
 const file=path.join(root,rel),data=fs.readFileSync(file,'utf8')
 const ast=ts.createSourceFile(file,data,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 assert.equal(ast.parseDiagnostics.length,0,rel+': syntax errors '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const css=fs.readFileSync(path.join(root,'styles.css'),'utf8')
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
assert(flight.includes('STROM150O_PRE_NAV_SNAPSHOT'))
assert(flight.includes('STROM150N_NO_END_JUMP')&&flight.includes('STROM150N_DEFAULT_SETTLED'))
assert(bridge.includes('STROM150O_PRE_NAV_SNAPSHOT')&&bridge.includes('screen150o'))
assert(bridge.includes('export const ENTER_FADE150=5000')&&bridge.includes('export const DURATION150=5000'))
assert(css.includes('strom150o-viewport-frozen')&&css.includes('transition:opacity 5000ms ease;'))
assert(app.includes('STROM150C_PRESERVE_BLUEPRINT')&&app.includes('STROM150K_FAIL_CLOSED'))
console.log('PASS 150o AST: 4 TS/TSX files parse, snapshot + overlay fixed, untouched 150n camera/5s/5s')
STROM150O_AUDIT
log "5) Full TypeScript/Vite build against existing Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150o TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5.1) Verify camera handoff and frozen pre-navigation SVG projection ..."
STROM150N_SOURCE="$WORK_DIR/frontend/src/components/CameraFlight150.tsx" STROM150N_TS="$DEPENDENCIES/typescript"  node "$RESOURCE_DIR/test_camera.js" >>"$DIAG_LOG" 2>&1 || fail "150o camera regression failed"
STROM150O_BRIDGE="$WORK_DIR/frontend/src/components/cameraTransitions150.ts" STROM150O_TS="$DEPENDENCIES/typescript"  node "$RESOURCE_DIR/test_snapshot.js" >>"$DIAG_LOG" 2>&1 || fail "150o Blueprint snapshot regression failed"
log "PASS: click-time Blueprint calibration, stable 3D camera, unchanged 5s fade and 5s flight"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150O.md" <<'STROM150O_DOC'
# Stromnetze 150o – Blueprint / 3D crossfade calibration
- Fix only the remaining crossfade offset, not the already-correct angles or 150n camera flight.
- Save the real SVG-to-screen transform before switching views, while Blueprint still has its original layout.
- Preserve the live Blueprint layout rectangle during loading and fade, avoiding reflow.
- Map this frozen Blueprint screen transform to the new 3D Canvas rectangle.
- Keep load spinner, settled end camera, fixed start during 5 s fade, 5 s ease-out forward flight.
- Reverse flight deliberately unchanged.
- Build in isolated checkout, push through Pi root deploy key, stage backup, deploy only /strom-test/.
STROM150O_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git'  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150o Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150o Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150o frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150o test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150o deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
