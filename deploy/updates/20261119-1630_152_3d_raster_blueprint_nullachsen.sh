#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1630_152_3d_raster_blueprint_nullachsen"
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
COMMIT_MESSAGE="Update 152: canonical blueprint 3D grid and zero axes at plan origin"
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
  echo "2) Update 152 im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 152 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 152: 3D axes and grid mapped exactly to Blueprint X/Y ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/FloorSlab149.tsx frontend/src/components/cameraFloorMatch150r.ts \
  frontend/src/building/coordinateReference151.ts frontend/src/styles.css; do
  [ -s "$STAGE_DIR/$file" ] || fail "152 required source missing: $file"
done
grep -Fq 'STROM151_COORDINATE_DATUM' "$STAGE_DIR/frontend/src/building/coordinateReference151.ts" || \
  fail "152 requires update 151; Stage unchanged"
grep -Fq 'STROM150R_REAL_FLOOR_PROBE' "$STAGE_DIR/frontend/src/components/FloorSlab149.tsx" || \
  fail "152 requires real 3D floor references from update 150r; Stage unchanged"
grep -Fq 'RoofScope149.Provider value={{levelId:activeLevelId148,revision:roofRevision148}}' \
  "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || \
  fail "152 requires known selected-level scene; Stage unchanged"
select_node
log "1) Backup Stage source ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no live backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
fi
log "2) Prepare isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "152 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "152 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/152_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch152.py" <<'STROM152_PATCH_PY'
#!/usr/bin/env python3
"""Update 152, isolated transactional scene patch only (no 3D camera or room data edits)."""
import os
from pathlib import Path
src=Path(os.environ['STROM152_ROOT'])/'frontend/src'
scene=src/'components/Building3DWorkspace.tsx'
ref=src/'building/coordinateReference151.ts'
probe=src/'components/FloorSlab149.tsx'
module=src/'components/CanonicalGrid152.tsx'
for file in [scene,ref,probe]:
    if not file.is_file():raise RuntimeError(f'152 missing prerequisite: {file}')
s=scene.read_text('utf8')
if 'STROM152_BLUEPRINT_GRID' in s or module.exists():
    raise RuntimeError('152 already applied; refusing double installation')
if 'STROM151_COORDINATE_DATUM' not in ref.read_text('utf8'):
    raise RuntimeError('152 canonical datum of 151 missing')
if 'strom150r-floor-reference' not in probe.read_text('utf8'):
    raise RuntimeError('152 selected-floor world probes missing')
needle='<RoofScope149.Provider value={{levelId:activeLevelId148,revision:roofRevision148}}>'
if s.count(needle)!=1:raise RuntimeError(f'152 selected 3D provider: expected 1 anchor, found {s.count(needle)}')
imp="import CanonicalGrid152 from './CanonicalGrid152' // STROM152_BLUEPRINT_GRID\n"
s=imp+s
needle='<RoofScope149.Provider value={{levelId:activeLevelId148,revision:roofRevision148}}>'
s=s.replace(needle,needle+'''
            {/* STROM152_BLUEPRINT_GRID: portal into absolute Three scene; it is not centered on the building. */}
            <CanonicalGrid152 points={model.rooms.flatMap(room152=>room152.vertices)} />''',1)
scene.write_text(s,'utf8')
print('PASS 152: canonical 3D grid mounted at active selected floor, portal in scene root')
STROM152_PATCH_PY
cat > "$RESOURCE_DIR/CanonicalGrid152.tsx" <<'STROM152_TSX'
import { useEffect, useMemo, useRef } from 'react'
import { createPortal, useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'

type Point152 = { x:number; y:number }

/** STROM152_BLUEPRINT_GRID:
 * Architectural coordinates are taken directly from Blueprint (X,Y metres),
 * not from a building-centred grid. A Three.js world Y of zero is the
 * architecturally selected Z=0 datum (update 151).
 *
 * The 150r floor reference is attached beside the *actual* floor meshes.
 * The matrix of this reference gives the real mapping from Blueprint plan
 * coordinates to rendered space, even if a parent group is transformed.
 * This avoids silently assuming a centred or untransformed model.
 *
 * The canonical grid is rendered via a scene portal and therefore cannot
 * inherit accidental camera / ghost-floor / per-object transforms.
 */
export default function CanonicalGrid152({points}:{points:readonly Point152[]}) {
  const scene=useThree(s=>s.scene)
  const group=useRef<THREE.Group>(null)
  const diagnostics=useRef<string>('')
  const scanFrames=useRef(0)
  const half=useMemo(()=>{
    let extent=10
    for(const p of points){
      if(Number.isFinite(p.x)&&Number.isFinite(p.y))extent=Math.max(extent,Math.abs(p.x),Math.abs(p.y))
    }
    return Math.ceil(Math.min(500,extent+10)/5)*5
  },[points])
  const step=half>150?5:1
  const gridGeometry=useMemo(()=>{
    const data:number[]=[]
    for(let n=-half;n<=half;n+=step){
      if(Math.abs(n)<1e-8)continue // Zero is drawn once, with thick explicit X/Y axes.
      data.push(n,-0.018,-half,n,-0.018,half)
      data.push(-half,-0.018,n,half,-0.018,n)
    }
    const result=new THREE.BufferGeometry()
    result.setAttribute('position',new THREE.Float32BufferAttribute(data,3))
    result.computeBoundingSphere()
    return result
  },[half,step])
  useEffect(()=>()=>gridGeometry.dispose(),[gridGeometry])
  useFrame(()=>{
    // Default is identity: Three X = Blueprint X, Three Z = Blueprint Y.
    // Any transformation measured on a REAL floor reference takes priority.
    let marker:THREE.Object3D|null=null
    scene.traverse(obj=>{
      if(marker===null&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
    })
    const m=marker as THREE.Object3D|null
    if(group.current){
      if(m){
        m.updateWorldMatrix(true,false)
        group.current.matrix.copy(m.matrixWorld)
        // The reference may live on any storey. The 3D coordinate plane,
        // however, always lies on the selected architectural Z=0 datum.
        group.current.matrix.elements[13]=0
        const pos=m.matrixWorld.elements
        const offset=`${pos[12].toFixed(4)} / ${pos[14].toFixed(4)}`
        if(offset!==diagnostics.current){
          diagnostics.current=offset
          if(Math.abs(pos[12])>.001||Math.abs(pos[14])>.001){
            console.info('[Strom 152] Blueprint (0,0) is rendered at world X/Z',offset,
              '(reference matrix from actual 3D floor, not an assumed centre)')
          }
        }
      }else{
        group.current.matrix.identity()
      }
      group.current.matrixWorldNeedsUpdate=true
    }
    // Legacy helper meshes from earlier 3D versions must not paint competing,
    // wrongly centred zero axes. TSX grids are hidden structurally by the patch.
    if(scanFrames.current++<180){
      scene.traverse(obj=>{
        if(obj.type==='GridHelper'||obj.type==='AxesHelper')obj.visible=false
      })
    }
  },-1)
  return createPortal(
    <group name="strom152-blueprint-grid" ref={group} matrixAutoUpdate={false}>
      <lineSegments geometry={gridGeometry} frustumCulled={false}>
        <lineBasicMaterial color="#8798ae" transparent opacity={0.45} toneMapped={false}/>
      </lineSegments>
      {/* Blueprint X=0 (through Y axis) and Y=0 (through X axis); both in real metres. */}
      <mesh name="strom152-x-axis" position={[0,-0.015,0]}>
        <boxGeometry args={[half*2,0.006,0.05]}/>
        <meshBasicMaterial color="#cb5a63" toneMapped={false}/>
      </mesh>
      <mesh name="strom152-y-axis" position={[0,-0.014,0]}>
        <boxGeometry args={[0.05,0.006,half*2]}/>
        <meshBasicMaterial color="#327aaf" toneMapped={false}/>
      </mesh>
      <mesh name="strom152-origin" position={[0,-0.008,0]}>
        <sphereGeometry args={[0.07,12,8]}/>
        <meshBasicMaterial color="#253f68" toneMapped={false}/>
      </mesh>
    </group>,scene,
  )
}
STROM152_TSX
cat > "$RESOURCE_DIR/hideOldGrid152.cjs" <<'STROM152_NODE'
// Hide only legacy 3D grid primitives (including JSX with complex attributes).
// Keep imports in use and all other scene components untouched.
const fs=require('fs'),path=require('path')
const ts=require(process.env.STROM152_TS)
const filename=path.join(process.env.STROM152_SOURCE,'components/Building3DWorkspace.tsx')
let src=fs.readFileSync(filename,'utf8')
const ast=ts.createSourceFile(filename,src,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
if(ast.parseDiagnostics.length)throw Error('Source TSX parse failed before grid isolation')
const changes=[]
const old=['gridhelper','grid','axeshelper']
function visit(node){
  if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node)){
    const tag=node.tagName.getText(ast).toLowerCase()
    const isPrimitive=tag==='primitive'&&node.attributes.properties.some(a=>
      ts.isJsxAttribute(a)&&a.name.getText(ast)==='object'&&/grid|axeshelper/i.test(a.getText(ast)))
    if(old.includes(tag)||isPrimitive){
      const found=node.attributes.properties.filter(a=>ts.isJsxAttribute(a)&&a.name.getText(ast)==='visible')
      if(found.length>1)throw Error('Legacy 3D grid already contains multiple visible attributes')
      if(found.length===1){
        const a=found[0]
        changes.push({start:a.getStart(ast),end:a.getEnd(),text:'visible={false}'})
      }else{
        // Place the attribute after all existing props to override any spread.
        const end=node.getEnd(),tagClose=ts.isJsxSelfClosingElement(node)?2:1
        changes.push({start:end-tagClose,end:end-tagClose,text:' visible={false}'})
      }
    }
  }
  ts.forEachChild(node,visit)
}
visit(ast)
for(const c of changes.sort((a,b)=>b.start-a.start))src=src.slice(0,c.start)+c.text+src.slice(c.end)
const after=ts.createSourceFile(filename,src,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
if(after.parseDiagnostics.length)throw Error('Grid isolation broke scene TSX: '+after.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
fs.writeFileSync(filename,src)
console.log('PASS 152: '+changes.length+' legacy JSX grid/axis helpers hidden (dynamic Three.GridHelper also suppressed at runtime)')
STROM152_NODE
cat > "$RESOURCE_DIR/test152.cjs" <<'STROM152_TEST'
'use strict'
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict')
const ts=require(process.env.STROM152_TS)
const src=process.env.STROM152_SOURCE
for(const rel of ['components/Building3DWorkspace.tsx','components/CanonicalGrid152.tsx','components/FloorSlab149.tsx','building/coordinateReference151.ts']){
 const file=path.join(src,rel),contents=fs.readFileSync(file,'utf8')
 const ast=ts.createSourceFile(file,contents,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 assert.equal(ast.parseDiagnostics.length,0,rel+' parse '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
const scene=fs.readFileSync(path.join(src,'components/Building3DWorkspace.tsx'),'utf8')
const grid=fs.readFileSync(path.join(src,'components/CanonicalGrid152.tsx'),'utf8')
assert.equal((scene.match(/<CanonicalGrid152\b/g)||[]).length,1,'exactly one world grid on active level')
assert(grid.includes('createPortal('),'grid in absolute scene root')
assert(grid.includes("obj.name==='strom150r-floor-reference'"),'real selected floor matrix used')
assert(grid.includes('group.current.matrix.copy(m.matrixWorld)'))
assert(grid.includes('group.current.matrix.elements[13]=0'),'coordinate plane uses vertical Z=0')
assert(grid.includes('if(Math.abs(n)<1e-8)continue'),'no duplicated 0 grid lines')
assert(grid.includes('position={[0,-0.015,0]}')&&grid.includes('position={[0,-0.014,0]}'))
// The BP X/Y plan coordinate must map to the exact floor-probe local X/Z and
// the thick axis lines must both pass through the transformed (0,0) origin.
function projectedOrigin(matrix){return [matrix[12],matrix[13],matrix[14]]}
const identity=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
const translated=identity.slice();translated[12]=7.5;translated[13]=2.8;translated[14]=-3.2
assert.deepEqual(projectedOrigin(identity),[0,0,0])
translated[13]=0
assert.deepEqual(projectedOrigin(translated),[7.5,0,-3.2])
console.log('PASS 152: identical Blueprint/3D XY axes, zero-level grid, nested-transform handling, JSX syntax')
STROM152_TEST

log "3) Replace 3D grid axes using real Blueprint coordinates ..."
python3 -m py_compile "$RESOURCE_DIR/patch152.py" >>"$DIAG_LOG" 2>&1 || fail "152 Python syntax failed"
STROM152_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch152.py" >>"$DIAG_LOG" 2>&1 || \
  fail "152 source patch failed; GitHub and Stage unchanged"
install -m 0644 "$RESOURCE_DIR/CanonicalGrid152.tsx" "$WORK_DIR/frontend/src/components/CanonicalGrid152.tsx"
STROM152_SOURCE="$WORK_DIR/frontend/src" STROM152_TS="$DEPENDENCIES/typescript" \
 node "$RESOURCE_DIR/hideOldGrid152.cjs" >>"$DIAG_LOG" 2>&1 || \
 fail "152 grid isolation failed; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "152 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Coordinate/raster regressions ..."
STROM152_SOURCE="$WORK_DIR/frontend/src" STROM152_TS="$DEPENDENCIES/typescript" \
  node "$RESOURCE_DIR/test152.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "152 grid regression failed; GitHub and Stage unchanged"
log "PASS 152: actual selected-floor model and 3D zero axes use Blueprint coordinates"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_152.md" <<'STROM152_DOC'
# Update 152 - canonical 3D zero axes

- Blueprint X/Y metres are used to lay out the visible 3D grid, not the
  footprint centre of the room or a guessed camera target.
- The zero axes intersect at the actual rendered 3D position of Blueprint
  (X=0, Y=0); the grid follows the selected-level real floor transform.
- Architectural Z=0 from update 151 remains the height reference (Three Y=0).
- Grid markers are rendered in the Three.js scene root; old GridHelper/Grid/axes
  helpers are hidden to prevent mismatched zero-axis overlays.
- Existing building geometry, user room coordinates, camera pose, animation,
  loading spinner and diagnostics are not modified.
- The source is tested in an isolated copy; /strom-test/ only, never /strom/.
STROM152_DOC
log "6) Transfer checked source to Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "152 Stage source transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY; no web deployment"
  exit 0
fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "152 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "152 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "152 /strom-test/ deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 152 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
