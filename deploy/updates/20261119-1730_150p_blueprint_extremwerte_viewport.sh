#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1730_150p_blueprint_extremwerte_viewport"
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
COMMIT_MESSAGE="Update 150p: measure visible Blueprint extrema in CSS pixels at handoff"
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
  echo "2) Update 150p im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150p isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150p: Blueprint extrema at navigation handoff (diagnostic only) ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
# This is a deliberate replacement of the 150l camera module, not a reinstallation of update 150.
grep -Fq 'STROM150O_PRE_NAV_SNAPSHOT' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "150p requires installed 150o. Existing stage is different; no files changed."
grep -Fq 'STROM150C_PRESERVE_BLUEPRINT' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150p requires the live Blueprint overlay introduced by 150c"
grep -Fq 'STROM150K_FAIL_CLOSED' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150p requires the safe fallback guard introduced by 150k"
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
RESOURCE_DIR="$WORK_DIR/150p_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150p.py" <<'STROM150P_PY'
#!/usr/bin/env python3
"""Add passive Blueprint-viewport extrema diagnostics to 150o bridge. No camera changes."""
from pathlib import Path
import os

root=Path(os.environ['STROM150P_ROOT'])/'frontend/src'
path=root/'components/cameraTransitions150.ts'
if not path.is_file():
    raise RuntimeError(f'150p missing bridge: {path}')
text=path.read_text('utf8')
if 'STROM150O_PRE_NAV_SNAPSHOT' not in text or 'screen150o?' not in text:
    raise RuntimeError('150p requires installed update 150o')
if 'STROM150P_BLUEPRINT_EXTENTS' in text:
    raise RuntimeError('150p already installed; do not patch twice')
anchor='export function queueEntry150(mode:Mode150,floorId:string){'
assert text.count(anchor)==1, f'150p queue-entry anchor not unique: {text.count(anchor)}'

extra=r'''// STROM150P_BLUEPRINT_EXTENTS: CSS-pixel positions of the actual rendered room polygons,
// sampled at the click BEFORE the Blueprint gets moved, faded or unmounted.
type Bounds150p = { minX:number;maxX:number;minY:number;maxY:number;count:number }
function measureVisibleRooms150p(svg:SVGSVGElement,includeGhost:boolean):Bounds150p|null{
  const polygons=Array.from(svg.querySelectorAll<SVGPolygonElement>('polygon.room'))
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity,count=0
  for(const polygon of polygons){
    if(!includeGhost && polygon.closest('.ghost-layer, .ghost-room-group'))continue
    // Invisible layers and rooms are excluded; no assumption that the whole drawing fits in the viewport.
    if(polygon.closest('[hidden]'))continue
    const transform=polygon.getScreenCTM()
    const vertices=polygon.points
    if(!transform||!vertices||!vertices.numberOfItems)continue
    for(let i=0;i<vertices.numberOfItems;i++){
      const point=vertices.getItem(i)
      const x=transform.a*point.x+transform.c*point.y+transform.e
      const y=transform.b*point.x+transform.d*point.y+transform.f
      if(!Number.isFinite(x)||!Number.isFinite(y))continue
      minX=Math.min(minX,x);maxX=Math.max(maxX,x)
      minY=Math.min(minY,y);maxY=Math.max(maxY,y);count++
    }
  }
  return count?{minX,maxX,minY,maxY,count}:null
}
function collectBlueprintExtents150p(mode:Mode150,floorId:string){
  const svg=document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement|null
  if(!svg)return
  const viewport=(svg.closest('.canvas-scroll')||svg.parentElement) as HTMLElement|null
  const workspace=svg.closest('.workspace') as HTMLElement|null
  const viewportRect=viewport?.getBoundingClientRect()
  if(!viewportRect||viewportRect.width<=1||viewportRect.height<=1)return
  const main=measureVisibleRooms150p(svg,false)
  const visibleIncludingGhost=measureVisibleRooms150p(svg,true)
  if(!main&&!visibleIncludingGhost)return
  const round=(v:number)=>Math.round(v*10)/10
  const describe=(bounds:Bounds150p|null,rect:DOMRect|null)=>{
    if(!bounds||!rect)return null
    const xMin=round(bounds.minX-rect.left),xMax=round(bounds.maxX-rect.left)
    const yMin=round(bounds.minY-rect.top),yMax=round(bounds.maxY-rect.top)
    return {
      xMinPx:xMin,xMaxPx:xMax,yMinPx:yMin,yMaxPx:yMax,
      widthPx:round(bounds.maxX-bounds.minX),heightPx:round(bounds.maxY-bounds.minY),
      points:bounds.count,
      outsidePx:{left:round(Math.max(0,-xMin)),right:round(Math.max(0,xMax-rect.width)),
        top:round(Math.max(0,-yMin)),bottom:round(Math.max(0,yMax-rect.height))},
    }
  }
  const active=main||visibleIncludingGhost
  const workspaceRect=workspace?.getBoundingClientRect()||null
  const data={
    version:'150p',phase:'vor Umschalten',mode,floorId,
    measuredAt:new Date().toISOString(),units:'CSS-Pixel',
    viewport:{selector:viewport?.className||'svg parent',screenLeft:round(viewportRect.left),
      screenTop:round(viewportRect.top),width:round(viewportRect.width),height:round(viewportRect.height)},
    drawing:describe(active,viewportRect),
    workspace:workspaceRect?{width:round(workspaceRect.width),height:round(workspaceRect.height),
      drawing:describe(active,workspaceRect)}:null,
    includingGhost:describe(visibleIncludingGhost,viewportRect),
  }
  try{window.localStorage.setItem('strom.camera150p.blueprintExtents',JSON.stringify(data))}catch{/* optional */}
  console.info('[STROM 150p] Blueprint-Koordinaten vor dem Wechsel',data)
  const d=data.drawing
  if(!d)return
  const panelId='strom-150p-viewport-geometry'
  let panel=document.getElementById(panelId)
  if(!panel){
    panel=document.createElement('pre')
    panel.id=panelId
    panel.setAttribute('role','status')
    panel.style.cssText='position:fixed;top:16px;right:16px;z-index:2147483647;pointer-events:none;'
      +'padding:12px 14px;border-radius:8px;background:rgba(18,32,54,.94);color:#fff;'
      +'box-shadow:0 3px 15px rgba(0,0,0,.25);font:12px/1.5 ui-monospace,monospace;'
      +'max-width:430px;white-space:pre-wrap;'
    document.body.appendChild(panel)
  }
  const o=d.outsidePx
  panel.textContent=`Blueprint → ${mode==='wall'?'Wanddetail':'3D-Haus'} · Messung vor Wechsel\n`
    +`Viewport: ${data.viewport.width} × ${data.viewport.height} px\n`
    +`Xmin: ${d.xMinPx} px  | Xmax: ${d.xMaxPx} px\n`
    +`Ymin: ${d.yMinPx} px  | Ymax: ${d.yMaxPx} px\n`
    +`Außerhalb L/R/O/U: ${o.left} / ${o.right} / ${o.top} / ${o.bottom} px\n`
    +`Arbeitsfläche: ${data.workspace?`${data.workspace.width} × ${data.workspace.height} px`:'nicht erfasst'}\n`
    +'Details: Browser-Konsole [STROM 150p]'
}

'''
needle=anchor+'\n'
text=text.replace(needle,extra+anchor+'\n  try{collectBlueprintExtents150p(mode,floorId)}catch(error){console.warn("[STROM 150p] Viewport-Messung fehlgeschlagen",error)}\n',1)
path.write_text(text,'utf8')
print('PASS 150p: click-time visible room extrema in viewport + workspace, console + overlay, camera modules unchanged')
STROM150P_PY
cat > "$RESOURCE_DIR/test_extrema.cjs" <<'STROM150P_TEST_JS'
'use strict'
const fs=require('fs'),assert=require('assert'),ts=require(process.env.STROM150P_TS||'typescript')
const src=process.env.STROM150P_BRIDGE
if(!src)throw Error('STROM150P_BRIDGE missing')
const text=fs.readFileSync(src,'utf8')
const ast=ts.createSourceFile(src,text,ts.ScriptTarget.Latest,true,ts.ScriptKind.TS)
if(ast.parseDiagnostics.length)throw Error(ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
assert(text.includes('STROM150P_BLUEPRINT_EXTENTS'),'150p marker')
assert(text.includes('STROM150O_PRE_NAV_SNAPSHOT'),'150o marker preserved')
assert(text.includes('ENTER_FADE150=5000')&&text.includes('DURATION150=5000'),'camera timings preserved')
const compiled=ts.transpileModule(text,{fileName:src,compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText
const data=new Map(),reports=[]
const rect={left:100,top:50,width:1000,height:600},workspaceRect={left:20,top:0,width:1400,height:900}
const matrix={a:2,b:0,c:0,d:2,e:-1000,f:-1000,inverse(){return {}}}
const viewport={className:'canvas-scroll',getBoundingClientRect(){return rect}}
const workspace={getBoundingClientRect(){return workspaceRect}}
const polygon={points:{numberOfItems:4,getItem(i){return [{x:670,y:670},{x:1270,y:670},{x:1270,y:1030},{x:670,y:1030}][i]}},getScreenCTM(){return matrix},closest(){return null}}
const svg={querySelectorAll(){return [polygon]},closest(selector){if(selector==='.workspace')return workspace;if(selector==='.canvas-scroll')return viewport;return null},getScreenCTM(){return matrix},parentElement:viewport,createSVGPoint(){return {x:0,y:0,matrixTransform(){return {x:700,y:600}}}}}
const document={querySelector(){return svg},getElementById(){return null},createElement(){return {id:'',style:{cssText:''},textContent:'',setAttribute(){}}},body:{appendChild(p){reports.push(p)}}}
const window={localStorage:{getItem(key){return data.get(key)||null},setItem(k,v){data.set(k,v)}},setTimeout(){return 7},clearTimeout(){}}
const bridgeExports={}
new Function('exports','module','window','document','console',compiled)(bridgeExports,{exports:bridgeExports},window,document,{info(){},warn(){},log(){}})
assert(bridgeExports.queueEntry150,'bridge exported queueEntry150')
bridgeExports.queueEntry150('threeD','floor_1')
const report=JSON.parse(data.get('strom.camera150p.blueprintExtents'))
assert(report)
assert.equal(report.drawing.xMinPx,240)
assert.equal(report.drawing.xMaxPx,1440)
assert.equal(report.drawing.yMinPx,290)
assert.equal(report.drawing.yMaxPx,1010)
assert.equal(report.drawing.outsidePx.right,440)
assert.equal(report.drawing.outsidePx.bottom,410)
assert.equal(report.drawing.outsidePx.left,0)
assert.equal(report.drawing.outsidePx.top,0)
assert.equal(report.workspace.drawing.xMinPx,320)
assert.equal(reports.length,1)
assert(reports[0].textContent.includes('Xmin: 240 px'))
console.log('PASS 150p: transformed rendered blueprint vertices, viewport extrema and offscreen lengths, workspace and panel')
STROM150P_TEST_JS
log "3) Instrument Blueprint handoff with pixel geometry measurement ..."
python3 -m py_compile "$RESOURCE_DIR/patch150p.py" >>"$DIAG_LOG" 2>&1 || fail "150p Python syntax failed"
STROM150P_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch150p.py" >>"$DIAG_LOG" 2>&1 || fail "150p patch failed; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build against existing Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150p TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Verify click-time SVG geometry and extrema calculations ..."
STROM150P_BRIDGE="$WORK_DIR/frontend/src/components/cameraTransitions150.ts" STROM150P_TS="$DEPENDENCIES/typescript" node "$RESOURCE_DIR/test_extrema.cjs" >>"$DIAG_LOG" 2>&1 || fail "150p extrema regression failed"
log "PASS: Blueprint extrema measured in CSS pixels at handoff; 3D camera and 5s+5s unchanged"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150P.md" <<'STROM150P_DOC'
# Stromnetze 150p – Blueprint Viewport Extrema (diagnostic only)
- At the click BEFORE switching to wall / 3D, measure actual rendered room polygons (SVG `polygon.room` points transformed through getScreenCTM).
- Report Xmin/Xmax/Ymin/Ymax in CSS pixels relative to visible Blueprint scroll viewport and workspace; negative values and values beyond viewport are retained.
- Exclude ghost floors for primary bounds; include separately for diagnostic comparison.
- Display a small passive overlay panel and log/store full measurements at localStorage key `strom.camera150p.blueprintExtents`.
- Keep existing 150o flight, camera, zoom, rotation, 5-second fade, 5-second motion, and production completely unchanged.
- Isolated TypeScript/Vite build, regression test, GitHub push before Stage and /strom-test/ update.
STROM150P_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git'  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150p Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150p Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150p frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150p test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150p deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
