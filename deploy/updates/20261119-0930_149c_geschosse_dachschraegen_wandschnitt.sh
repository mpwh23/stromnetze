#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-0930_149c_geschosse_dachschraegen_wandschnitt"
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
COMMIT_MESSAGE="Update 149c: ordered floors, slab depths, editable and cloned roofs, 3D roof wall cuts"
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
  echo "2) Update 149c im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  # Cleanup of the exact stale root-owned temp directory left by 132f.
  rm -rf /tmp/20260908-1025_132f_strom_wanddetail_node20_buildfix_work 2>/dev/null || true

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

  echo "1.3) Update 149c isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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
fail() { log ""; log "ERROR: $*"; log "Diagnostics: $DIAG_LOG"; if [ -f "$DIAG_LOG" ]; then echo '--- Last diagnostic lines ---'; tail -n 120 "$DIAG_LOG"; fi; exit 1; }
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
log "=== Update 149c: Blueprint level ordering, slab thickness, roofs and true wall trim ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/RoofEditor148.tsx frontend/src/building/roofSlopes148.ts \
  frontend/src/building/stairLinks148.ts frontend/src/building/stairVisibility143.ts \
  frontend/src/building/blueprintLevels.ts frontend/src/building/solidGeometry.ts \
  frontend/src/building/wallSurface145.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "Missing current source (148c expected): $file"
done
for marker in STROM148_ROOF_EDIT STROM147_STAIR_DIRECTIONS; do
  grep -Fq "$marker" "$STAGE_DIR/frontend/src/App.tsx" || fail "Please deploy 148c first: marker missing: $marker"
done
grep -Fq 'STROM148_ROOF_3D' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "Please deploy 148c first: true 3D roof renderer missing"
select_node
log "1) Backup current Stage source ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PATCH_ONLY: isolated Git checkout, no source backup"; else cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"; fi
log "2) Prepare fully isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ]; then DEPENDENCIES="$candidate";break; fi
done
[ -n "$DEPENDENCIES" ] || fail "Existing dependencies (typescript/vite/three) unavailable"
rm -rf -- "$WORK_DIR/frontend/node_modules"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
mkdir -p "$WORK_DIR/docs" "$WORK_DIR/strom149_resources"
RESOURCE_DIR="$WORK_DIR/strom149_resources"
cat > "$RESOURCE_DIR/patch149.py" <<'STROM149_ASSET_PATCH149_PY'
#!/usr/bin/env python3
"""STROM 149. All source rewrites are staged in memory and written only after structural validation."""
from pathlib import Path
import os,re
root=Path(os.environ['STROM149_ROOT'])
modules=Path(os.environ['STROM149_MODULES'])
src=root/'frontend/src'
app=src/'App.tsx'; scene=src/'components/Building3DWorkspace.tsx';css=src/'styles.css';levels=src/'building/blueprintLevels.ts';stair=src/'building/stairVisibility143.ts';links=src/'building/stairLinks148.ts';roof=src/'building/roofSlopes148.ts'; editor=src/'components/RoofEditor148.tsx'
required=[app,scene,css,levels,stair,links,roof,editor,src/'building/solidGeometry.ts',src/'building/wallSurface145.ts']
for p in required:
 if not p.is_file():raise RuntimeError(f'149: Quelldatei fehlt: {p}')
for name in ('levelGeometry149.ts','roofCut149.ts','FloorSlab149.tsx','RoofEditor148.tsx','roofSlopes148.ts'):
 if not (modules/name).is_file():raise RuntimeError(f'149: Ressource fehlt {name}')
a=app.read_text('utf8');s=scene.read_text('utf8');c=css.read_text('utf8');l=levels.read_text('utf8');t=stair.read_text('utf8');q=links.read_text('utf8')
if 'STROM149_LEVEL_GEOMETRY' in l or 'STROM149_ROOF_DRAG' in a or 'STROM149_CUT_WALL' in s:raise RuntimeError('149: bereits installiert, nicht doppelt anwenden')
for mark in ('STROM148_ROOF_EDIT','stairPortals148','roofSlopes148','function FloorplanEditor('):
 if mark not in a:raise RuntimeError(f'149: Blueprint-Version 148c Voraussetzung fehlt: {mark}')
for mark in ('STROM148_ROOF_3D','STROM146_ALL_LEVELS','extraLevels146.map(','function SolidWallMeshes(','function RealBuildingScene('):
 if mark not in s:raise RuntimeError(f'149: 3D-Version 148c Voraussetzung fehlt: {mark}')
for mark in ('listBlueprintLevelOptions144','readActiveBlueprintLevel','elevationM: roundMm('):
 if mark not in l:raise RuntimeError(f'149: Ebenenstand erwartet: {mark}')

def one(text,old,new,label):
 n=text.count(old)
 if n!=1:raise RuntimeError(f'149 {label}: Anker {old[:100]!r} genau einmal erwartet; {n} gefunden')
 return text.replace(old,new,1)
def replace_between(text,start,end,fn,label):
 if text.count(start)!=1:raise RuntimeError(f'149 {label}: Startanker nicht eindeutig: {start!r}')
 i=text.index(start);j=text.find(end,i)
 if j<0:raise RuntimeError(f'149 {label}: Endanker fehlt: {end!r}')
 return text[:i]+fn(text[i:j])+text[j:]

# ----- Shared floor elevations: list TOP item is physically TOP storey -----
l=one(l,"import type { Floor, Room } from '../types'", "import type { Floor, Room } from '../types'\n// STROM149_LEVEL_GEOMETRY: top-to-bottom list, floor slab below each finished floor.\nimport { levelElevations149, cleanSlab149 } from './levelGeometry149'",'level geometry import')
l=one(l,'  heightM: number\n  elevationM: number', '  heightM: number\n  slabThicknessM: number\n  elevationM: number','active level type')
l=one(l,'const layers: Array<{ id: string; name: string; heightM: number }>', 'const layers: Array<{ id: string; name: string; heightM: number; slabThicknessM: number }>','layer parse type')
l=one(l,'heightM: clampHeight(Number(layer.heightM), fallbackHeightM),','heightM: clampHeight(Number(layer.heightM), fallbackHeightM),\n        slabThicknessM: cleanSlab149(layer.slabThicknessM),','parse level thickness')
l=one(l,"{ id: DEFAULT_LAYER_ID, name: 'Ebene 1', heightM: fallbackHeightM }","{ id: DEFAULT_LAYER_ID, name: 'Ebene 1', heightM: fallbackHeightM, slabThicknessM: 0 }",'level fallback')
l=one(l,'    heightM: current.heightM,','    heightM: current.heightM,\n    slabThicknessM: current.slabThicknessM,','active return slab')
old='elevationM: roundMm((Number(floor.elevationM) || 0) + layers.slice(0, index).reduce((sum, layer) => sum + layer.heightM, 0))'
l=one(l,old,'elevationM: levelElevations149(layers, Number(floor.elevationM)||0)[current.id]','active elevation correct order')
l=one(l,'export type BlueprintLevelOption144 = { id: string; name: string; heightM: number }','export type BlueprintLevelOption144 = { id: string; name: string; heightM: number; slabThicknessM: number }','shared level options type')
l=one(l,'heightM: clampHeight(Number(entry.heightM), fallback),','heightM: clampHeight(Number(entry.heightM), fallback),\n      slabThicknessM: cleanSlab149(entry.slabThicknessM),','shared level slab')
l=one(l,"{ id: DEFAULT_LAYER_ID, name: 'Ebene 1', heightM: fallback }","{ id: DEFAULT_LAYER_ID, name: 'Ebene 1', heightM: fallback, slabThicknessM: 0 }",'shared fallback')

# ----- Stair heights and ghost placement from the SAME floor elevation model -----
t=one(t,"import { buildStair3DSurfaces, type Stair3DSurface } from './stair3d'", "import { buildStair3DSurfaces, type Stair3DSurface } from './stair3d'\nimport { levelElevations149, stairRise149, cleanSlab149 } from './levelGeometry149'",'stair imports')
t=one(t,'return [{ id: entry.id, heightM: heightM(entry.heightM, fallback) }]','return [{ id: entry.id, heightM: heightM(entry.heightM, fallback), slabThicknessM: cleanSlab149(entry.slabThicknessM) }]','stair level data')
t=one(t,"levels.push({ id: 'layer-main', heightM: fallback })", "levels.push({ id: 'layer-main', heightM: fallback, slabThicknessM: 0 })",'stair fallback')
t=one(t,'  let levelBottom = numeric(floor.elevationM, 0)','  const elevations149 = levelElevations149(levels,numeric(floor.elevationM,0))','stair level heights')
t=one(t,'    const offset = Math.round((levelBottom - activeLevel.elevationM) * 1000) / 1000','    const offset = Math.round((elevations149[level.id] - activeLevel.elevationM) * 1000) / 1000','ghost stairs offsets')
t=one(t,'buildStair3DSurfaces(levelRooms, level.heightM, storage)','buildStair3DSurfaces(levelRooms, stairRise149(levels,level.id), storage)','stairs floor-to-floor rise')
t=one(t,'    levelBottom += level.heightM\n','', 'no ascending-order accumulation')

# ----- Stair portals: topmost Blueprint item is now highest storey -----
q=one(q,"(direction==='up' && sourceIndex+1===targetIndex)||(direction==='down'&&sourceIndex-1===targetIndex)",
  "(direction==='up' && sourceIndex-1===targetIndex)||(direction==='down'&&sourceIndex+1===targetIndex)",
  'stairwell arrival floor relative to list order')

# ----- Blueprint: save editable slab thickness; directly drag roof line/end handles -----
a=one(a,"import RoofEditor148 from './components/RoofEditor148'", "import RoofEditor148 from './components/RoofEditor148'\nimport type { PointerEvent as RoofPointer149 } from 'react'\nimport { cleanSlab149, dragRoofLine149 } from './building/levelGeometry149'",'app imports')
# Only extend the first type FloorplanLayer, not other unrelated layer models.
rx=r'(?m)^type FloorplanLayer = \{[^\n]+\}'
matches=list(re.finditer(rx,a))
if len(matches)!=1:raise RuntimeError(f'149: FloorplanLayer Typ genau einmal erwartet; {len(matches)}')
changed=matches[0].group(0)
if 'heightM?: number' not in changed:raise RuntimeError('149: FloorplanLayer.heightM fehlt')
a=a[:matches[0].start()]+changed[:-1]+'; slabThicknessM?: number }'+a[matches[0].end():]
# Loaded layer metadata must survive editing and local storage round-trips.
layer_height_pattern=r'(?m)^(\s*heightM: Number\.isFinite\(Number\(item\.heightM\)\)[^\n]+\n)'
a,n=re.subn(layer_height_pattern,lambda m:m.group(1)+re.match(r'\s*',m.group(1)).group(0)+'slabThicknessM: cleanSlab149(item.slabThicknessM),\n',a,count=1)
if n!=1:raise RuntimeError('149: gespeicherte Layer-Höhe wurde verändert')
# New levels default to 0 mm to avoid shifting any existing model on first launch.
a,n=re.subn(r'(const layer: FloorplanLayer = \{[^\n]*heightM: activeLayer\.heightM \?\? floor\.heightM)(\s*\})',r'\1, slabThicknessM: 0\2',a)
if n not in (2,):raise RuntimeError(f'149: erwartete zwei neue Ebenentypen, gefunden: {n}')
def patch_floor_editor(e):
  old='  function setLayerHeightM(id: string, millimetres: number) {'
  e=one(e,old,"""  // STROM149: Bodenplatte gehört zur Etage, deren fertige Bodenhöhe der 3D-Datumspunkt ist.
  function setLayerSlab149(id: string, millimetres: number) {
    if (!Number.isFinite(millimetres)) return
    const slabThicknessM = cleanSlab149(Math.max(0,Math.min(1500,millimetres))/1000)
    setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, slabThicknessM } : layer))
  }

"""+old,'slab setter')
  m=re.search(r'(?s)<label className="layer-height-control"[^>]*>.*?</label>',e)
  if not m:raise RuntimeError('149: editierbarer Geschosshoehen-Dialog fehlt')
  slab='''<label className="layer-height-control layer-slab-control149" title="Bodendicke der Etage unterhalb des fertigen Fußbodens, in Millimetern">
    <span>Bodendicke (mm)</span>
    <input key={`${layer.id}-slab-${Math.round((layer.slabThicknessM ?? 0)*1000)}`}
      aria-label={`Bodendicke ${layer.name} in Millimetern`} type="number" min="0" max="1500" step="10"
      defaultValue={Math.round((layer.slabThicknessM ?? 0)*1000)}
      onMouseDown={event=>event.stopPropagation()} onClick={event=>event.stopPropagation()}
      onDragStart={event=>event.preventDefault()}
      onBlur={event=>setLayerSlab149(layer.id,Number(event.currentTarget.value))}
      onKeyDown={event=>{if(event.key==='Enter')event.currentTarget.blur()}}
    />
  </label>'''
  e=e[:m.end()]+'\n'+slab+e[m.end():]
  hook='  const [roofSlopes148, setRoofSlopes148] = useState<RoofSlope148[]>(() => readRoofSlopes148(floor.id, window.localStorage))'
  e=one(e,hook,hook+'''
  const roofDrag149 = useRef<{id:string;mode:'move'|'start'|'end';initial:RoofSlope148;origin:PointM}|null>(null)
  const roofLive149 = useRef<RoofSlope148[]>([])
''','roof drag refs')
  sel='  const selectedRoom = rooms.find((room) => room.id === selectedRoomId) ?? null'
  helpers='''  // STROM149_ROOF_DRAG: SVG-pointer-captured geometric editing, one 2D/3D store.
  function pointerToMeters149(event: RoofPointer149<SVGElement>):PointM|null {
    const svg=event.currentTarget.ownerSVGElement
    const transform=svg?.getScreenCTM()
    if(!svg||!transform)return null
    const pt=svg.createSVGPoint();pt.x=event.clientX;pt.y=event.clientY
    const local=pt.matrixTransform(transform.inverse())
    const px=mToX(1)-mToX(0),py=mToY(1)-mToY(0)
    return Math.abs(px)>1e-9&&Math.abs(py)>1e-9?{x:(local.x-mToX(0))/px,y:(local.y-mToY(0))/py}:null
  }
  function beginRoofDrag149(event:RoofPointer149<SVGElement>,roof:RoofSlope148,mode:'move'|'start'|'end') {
    if(event.button!==0)return
    const pos=pointerToMeters149(event)
    if(!pos)return
    event.preventDefault();event.stopPropagation()
    roofDrag149.current={id:roof.id,mode,initial:roof,origin:pos}
    roofLive149.current=roofSlopes148
    event.currentTarget.setPointerCapture(event.pointerId)
    setSelectedRoof148(roof.id);onSelectRoom(roof.roomId)
  }
  function moveRoofDrag149(event:RoofPointer149<SVGElement>) {
    const active=roofDrag149.current,pos=pointerToMeters149(event)
    if(!active||!pos)return
    event.stopPropagation()
    const dx=pos.x-active.origin.x,dy=pos.y-active.origin.y
    const next=dragRoofLine149(active.initial,active.mode,dx,dy)
    roofLive149.current=roofLive149.current.map(item=>item.id===active.id?next:item)
    setRoofSlopes148(roofLive149.current)
  }
  function endRoofDrag149(event:RoofPointer149<SVGElement>) {
    if(!roofDrag149.current)return
    event.preventDefault();event.stopPropagation()
    roofDrag149.current=null
    try {saveRoofSlopes148(floor.id,roofLive149.current)}
    catch(error){onError(error instanceof Error?error.message:String(error))}
  }

'''
  e=one(e,sel,helpers+sel,'roof drag handlers')
  # 149c: Insert props BEFORE the real closing '>' of the roof <g> opening tag.
  # 148c may put '>' on the same line, or after several existing attributes.
  # Blindly appending after the first line produces invalid JSX in the first case.
  roof_start=re.compile(r'(?m)^([ \t]*)return <g key=\{roof\.id\} className=\{`strom-roof-line148[^\n]*')
  matches=list(roof_start.finditer(e))
  if len(matches)!=1:raise RuntimeError(f'149c: roof JSX selector exactly once expected, {len(matches)}')
  matched=matches[0]
  indent=matched.group(1)
  tag_start=e.find('<g ',matched.start(),matched.end())
  if tag_start<0:raise RuntimeError('149c: roof JSX opening <g> not found')
  braces=0
  quoted=None
  escaped=False
  tag_end=-1
  for index in range(tag_start,len(e)):
    ch=e[index]
    if quoted:
      if escaped:escaped=False
      elif ch=='\\':escaped=True
      elif ch==quoted:quoted=None
    elif ch in ('"',"'",'`'):quoted=ch
    elif ch=='{':braces+=1
    elif ch=='}':
      braces-=1
      if braces<0:raise RuntimeError('149c: unbalanced roof JSX braces')
    elif ch=='>' and braces==0:
      tag_end=index
      break
  if tag_end<0 or tag_end-tag_start>12000:raise RuntimeError('149c: cannot locate closing roof <g> opening tag')
  if any(attr in e[tag_start:tag_end] for attr in ('onPointerDown=', 'onPointerMove=', 'onPointerUp=', 'onPointerCancel=')):
    raise RuntimeError('149c: roof <g> already has pointer handlers; refuse to duplicate')
  roof_props=('\n'+indent+"  onPointerDown={event=>beginRoofDrag149(event,roof,'move')}"
              +'\n'+indent+"  onPointerMove={moveRoofDrag149} onPointerUp={endRoofDrag149} onPointerCancel={endRoofDrag149}")
  e=e[:tag_end]+roof_props+e[tag_end:]
  line='''<line x1={mToX(roof.start.x)} y1={mToY(roof.start.y)} x2={mToX(roof.end.x)} y2={mToY(roof.end.y)}/>'''
  replacement=line+'''
                {selectedRoof148===roof.id&&<>
                  <circle className="strom-roof-handle149" cx={mToX(roof.start.x)} cy={mToY(roof.start.y)} r={8/zoom}
                    onPointerDown={event=>beginRoofDrag149(event,roof,'start')}><title>Startpunkt der Dachlinie drehen oder verschieben</title></circle>
                  <circle className="strom-roof-handle149" cx={mToX(roof.end.x)} cy={mToY(roof.end.y)} r={8/zoom}
                    onPointerDown={event=>beginRoofDrag149(event,roof,'end')}><title>Endpunkt der Dachlinie drehen oder verschieben</title></circle>
                </>}'''
  e=one(e,line,replacement,'roof endpoint grips')
  return e
a=replace_between(a,'function FloorplanEditor(', 'type StairEditorElementKind',patch_floor_editor,'blueprint editor')

# ----- true 3D: floor-to-floor elevations + actual slab volumes + roof-cut wall faces -----
s=one(s,"import RoofMeshes148 from './RoofMeshes148'", "import RoofMeshes148 from './RoofMeshes148'\nimport FloorSlab149 from './FloorSlab149'\nimport { clipSolidWalls149 } from '../building/roofCut149'\nimport { readRoofSlopes148 } from '../building/roofSlopes148'\nimport { levelElevations149, stairRise149, readSlabThickness149 } from '../building/levelGeometry149'\nimport { createContext, useContext } from 'react'",'3d imports')
s=one(s,'function SolidWallMeshes(','''// STROM149_CUT_WALL: the current floor and ghost floor resolve roofs independently.
const RoofScope149 = createContext({levelId:'',revision:0})
function SolidWallMeshes(''','wall scope')
def wall_component(w):
  # 149c: Scope every replacement to the ONE memo that builds the physical
  # wall surface. SolidWallMeshes contains multiple geometry memo hooks in 148c.
  # Replacing the first hook or all [model] dependency arrays is not safe.
  memo_anchor='  const geometry = useMemo(() => {'
  surface_anchor='    const surface = buildSolidSurface(model)'
  end_anchor='  }, [model])'
  if w.count(surface_anchor)!=1:
    raise RuntimeError(f'149c wall: expected one buildSolidSurface(model), found {w.count(surface_anchor)}')
  at=w.index(surface_anchor)
  start=w.rfind(memo_anchor,0,at)
  if start<0:raise RuntimeError('149c wall: geometry memo before physical solid surface missing')
  end=w.find(end_anchor,at)
  if end<0:raise RuntimeError('149c wall: physical solid surface memo [model] closing anchor missing')
  end+=len(end_anchor)
  physical=w[start:end]
  if physical.count(memo_anchor)!=1 or physical.count(surface_anchor)!=1:
    raise RuntimeError('149c wall: physical solid surface memo is not uniquely delimited')
  physical=one(physical,memo_anchor, '''  const roofScope149 = useContext(RoofScope149)
  const geometry = useMemo(() => {''','physical roof wall memo hook')
  physical=one(physical,surface_anchor, '''    const surface = buildSolidSurface(model)
    const slopes149 = readRoofSlopes148(model.floorId,window.localStorage).filter(item=>item.levelId===roofScope149.levelId)
    const clipped149 = slopes149.length ? clipSolidWalls149(model,surface.positions,slopes149) : surface.positions''','clip current physical wall geometry')
  physical=one(physical,'repairWallSurface145(surface.positions)','repairWallSurface145(clipped149)','repair clipped roof cut and cap overlaps')
  physical=one(physical,end_anchor,'  }, [model,roofScope149.levelId,roofScope149.revision])','refresh roofs on edit')
  print(f'149c wall: selected physical wall memo out of {w.count(memo_anchor)} geometry memos')
  return w[:start]+physical+w[end:]
s=replace_between(s,'function SolidWallMeshes(', 'function DoorHandle(', wall_component,'wall renderer')
# The scene uses one selected floor group and a ghost-level group. Keep all existing selection callbacks untouched.
def scene_component(chunk):
  # Read the slab thickness from the same Blueprint metadata used for room elevation.
  needle='  const distance = Math.max(8, cameraModel146.spanM * 1.2, cameraModel146.floorHeightM * 1.35)'
  chunk=one(chunk,needle,'''  const activeSlab149 = readSlabThickness149(model.floorId,activeLevelId148,window.localStorage)
'''+needle,'active floor slab')
  matches=list(re.finditer(r'<SolidWallMeshes\b[\s\S]*?\/>',chunk))
  if len(matches)!=2:raise RuntimeError(f'149: erwartet zwei 3D-Wandrenderer (aktiv + extra), gefunden {len(matches)}')
  for idx,m in reversed(list(enumerate(matches))):
    layer='activeLevelId148' if idx==0 else 'entry146.id'
    wrapper='<RoofScope149.Provider value={{levelId:'+layer+',revision:roofRevision148}}>'+m.group(0)+'</RoofScope149.Provider>'
    chunk=chunk[:m.start()]+wrapper+chunk[m.end():]
  # Add floor slabs as extra meshes without touching room picking or overriding floor colors.
  # Insert floor slabs as siblings, preserving original 2D room and door JSX.
  active_matches=list(re.finditer(r'(?m)^([ \t]*)\{model\.walls\.flatMap\(\(wall\) => wall\.openings',chunk))
  if len(active_matches)!=1:raise RuntimeError(f'149: active door block unique expected; {len(active_matches)}')
  active=active_matches[0]
  pad=active.group(1)
  slab=pad+'''{/* STROM149_FLOOR_SLAB: physical thickness below each finished room floor. */}
'''+pad+'''{model.rooms.map(room149=><FloorSlab149 key={`slab149-${room149.id}`} room={room149} thicknessM={activeSlab149} />)}
'''
  chunk=chunk[:active.start()]+slab+chunk[active.start():]
  extra_matches=list(re.finditer(r'(?m)^([ \t]*)\{entry146\.stairs\.map\(',chunk))
  if len(extra_matches)!=1:raise RuntimeError(f'149: extra stair block unique expected; {len(extra_matches)}')
  extra_match=extra_matches[0]
  pad=extra_match.group(1)
  extra=pad+'''{entry146.model.rooms.map(room149=><FloorSlab149 key={`slab149-${room149.id}`} room={room149}
'''+pad+'''  thicknessM={readSlabThickness149(entry146.model.floorId,entry146.id,window.localStorage)} />)}
'''
  chunk=chunk[:extra_match.start()]+extra+chunk[extra_match.start():]
  return chunk
s=replace_between(s,'function RealBuildingScene(', 'function DoorForm(', scene_component,'scene geometry')
# Replace only controller's floor accumulation, never the room/door API.
s=one(s,'    let elevation146 = Number(floor.elevationM) || 0','    const elevation149 = levelElevations149(levelOptions144,Number(floor.elevationM)||0)','controller floor elevations')
s=one(s,'elevationM: elevation146, heightM: item146.heightM','elevationM: elevation149[item146.id], heightM: item146.heightM','3D floor world order')
s=one(s,'      elevation146 += item146.heightM\n','', 'no inverse stacking')
s=one(s,'buildStair3DSurfaces(floorRooms146, item146.heightM, window.localStorage)','buildStair3DSurfaces(floorRooms146, stairRise149(levelOptions144,item146.id), window.localStorage)','3D stair rise')
s=one(s,'? idx146 * 1.15 : 0','? (levelOptions144.length-1-idx146) * 1.15 : 0','3D offset follows physical order')

c+='''
/* STROM149: clear end handles, movable roof plane, slab property and reference editor. */
.strom-roof-line148 .strom-roof-handle149 { fill:#fff;stroke:#245fb8;stroke-width:2;cursor:crosshair;pointer-events:all; }
.strom-roof-line148.selected { cursor:move; touch-action:none; }
.layer-slab-control149 { border-top:1px dashed #d7e1ed;padding-top:5px; }
.strom-roof-reference149 {display:flex;flex-direction:column;gap:6px;border:1px solid #d6e1f0;border-radius:8px;padding:8px;}
.strom-roof-reference149 legend {font-size:12px;font-weight:650;color:#405674;padding:0 4px;}
.strom-roof-reference149 select {width:100%;max-width:100%;min-height:31px;border:1px solid #b7c8df;border-radius:5px;background:white;color:#234;}
.strom-roof-reference149 button {min-height:31px;border:1px solid #a4bcdf;border-radius:5px;background:#e8f0fd;color:#234f93;cursor:pointer;}
.strom-roof-reference149 button:disabled {opacity:.5;cursor:default;}
'''
# Check entire patch in memory before any write. Existing roof data files remain, with only validation expanded for real-world cross-floor slope inheritance.
replace={app:a,scene:s,css:c,levels:l,stair:t,links:q,roof:(modules/'roofSlopes148.ts').read_text('utf8'),editor:(modules/'RoofEditor148.tsx').read_text('utf8')}
for p in (src/'building/levelGeometry149.ts',src/'building/roofCut149.ts',src/'components/FloorSlab149.tsx'):
 if p.exists():raise RuntimeError(f'149: neues Modul existiert bereits: {p}')
for p,text in replace.items():p.write_text(text,encoding='utf8')
for name,subdir in [('levelGeometry149.ts','building'),('roofCut149.ts','building'),('FloorSlab149.tsx','components')]:
 (src/subdir/name).write_text((modules/name).read_text('utf8'),encoding='utf8')
print('PASS 149: physical floor order and slab thickness, stair elevations, cross-floor roof planes, roof drag/rotation and 3D solid wall clipping installed')
STROM149_ASSET_PATCH149_PY
cat > "$RESOURCE_DIR/levelGeometry149.ts" <<'STROM149_ASSET_LEVELGEOMETRY149_TS'
/** The Blueprint list is TOP first. Elevations are measured at finished-floor level. */
export type Level149 = {id:string; heightM:number; slabThicknessM?:number}
export const FLOOR_SLAB_DEFAULT149 = 0
export function cleanSlab149(value:unknown):number {
  const n = typeof value==='number'?value:Number(value)
  return Number.isFinite(n)&&n>=0&&n<=1.5?Math.round(n*1000)/1000:FLOOR_SLAB_DEFAULT149
}
export function levelElevations149<T extends Level149>(levelsTopFirst:readonly T[],baseM=0):Record<string,number> {
  const result:Record<string,number>={}
  let height=Number.isFinite(baseM)?baseM:0
  for(let i=levelsTopFirst.length-1;i>=0;i--){
    if(i<levelsTopFirst.length-1) height+=cleanSlab149(levelsTopFirst[i].slabThicknessM)
    result[levelsTopFirst[i].id]=Math.round(height*1000)/1000
    height+=levelsTopFirst[i].heightM
  }
  return result
}
/** Stairs reach the upper level's finished-floor level, including that upper level's slab. */
export function stairRise149<T extends Level149>(levels:readonly T[],currentLevelId:string):number {
  const index=levels.findIndex(item=>item.id===currentLevelId)
  if(index<0)return 0
  return levels[index].heightM + (index>0?cleanSlab149(levels[index-1].slabThicknessM):0)
}
export function levelHeight149<T extends Level149>(levels:readonly T[],levelId:string,baseM=0):number {
  return levelElevations149(levels,baseM)[levelId]??baseM
}
export type RoofPlaneCopy149={start:{x:number;y:number};end:{x:number;y:number};startHeightM:number;directionDeg:number;pitchDeg:number}
/** Preserve world-space z(x,y)=z0 + tan(pitch)*dot(p - start, direction), even across floors. */
export function inheritRoofPlane149<T extends RoofPlaneCopy149>(source:T, newStart:{x:number;y:number},newEnd:{x:number;y:number},srcLevelZ:number,targetLevelZ:number):T {
  const r=source.directionDeg*Math.PI/180
  const run=(newStart.x-source.start.x)*Math.cos(r)+(newStart.y-source.start.y)*Math.sin(r)
  const height=srcLevelZ+source.startHeightM+run*Math.tan(source.pitchDeg*Math.PI/180)-targetLevelZ
  return {...source,start:{...newStart},end:{...newEnd},startHeightM:Math.round(height*1000)/1000}
}
/** Shift a 2D start line or turn its endpoint; an endpoint turn also rotates the roof's rise direction. */
export function dragRoofLine149<T extends RoofPlaneCopy149>(roof:T,mode:'move'|'start'|'end',dx:number,dy:number):T {
  if(mode==='move')return {...roof,start:{x:roof.start.x+dx,y:roof.start.y+dy},end:{x:roof.end.x+dx,y:roof.end.y+dy}}
  const start=mode==='start'?{x:roof.start.x+dx,y:roof.start.y+dy}:roof.start
  const end=mode==='end'?{x:roof.end.x+dx,y:roof.end.y+dy}:roof.end
  if(Math.hypot(end.x-start.x,end.y-start.y)<0.1)return roof
  const a=Math.atan2(roof.end.y-roof.start.y,roof.end.x-roof.start.x)
  const b=Math.atan2(end.y-start.y,end.x-start.x)
  return {...roof,start:{...start},end:{...end},directionDeg:((roof.directionDeg+(b-a)*180/Math.PI)%360+360)%360}
}
export function readSlabThickness149(floorId:string,levelId:string,storage:Pick<Storage,'getItem'>):number {
  try {
    const raw:unknown=JSON.parse(storage.getItem(`strom.floorplan.layers.${floorId}.list`)||'[]')
    if(!Array.isArray(raw))return 0
    const found=raw.find((r:unknown)=>r&&typeof r==='object'&&(r as {id?:unknown}).id===levelId)
    return found&&typeof found==='object'?cleanSlab149((found as {slabThicknessM?:unknown}).slabThicknessM):0
  }catch{return 0}
}
STROM149_ASSET_LEVELGEOMETRY149_TS
cat > "$RESOURCE_DIR/roofCut149.ts" <<'STROM149_ASSET_ROOFCUT149_TS'
import type {PointM} from '../types'
import type {BuildingModel, BuildingWall} from './model'
import {wallSolidPieces} from './model'
import type {RoofSlope148} from './roofSlopes148'
import {roofHeight148} from './roofSlopes148'

/** Clip the physical WALL boundary, not the room floors, against the lowest roof plane
 * of its adjoining rooms. All coordinates are local to the finished floor.
 * The original watertight merged wall triangles and door/window voids are retained. */
type V3={x:number;y:number;z:number}
type Sector={polygon:PointM[];roof:RoofSlope148; wallId:string}
const EPS=1e-8
const area=(p:PointM[])=>p.reduce((a,v,i)=>{const w=p[(i+1)%p.length];return a+v.x*w.y-w.x*v.y},0)/2
const add3=(a:V3,b:V3,t:number):V3=>({x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t,z:a.z+(b.z-a.z)*t})
const add2=(a:PointM,b:PointM,t:number):PointM=>({x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t})
function split3(p:V3[],f:(v:V3)=>number):[V3[],V3[]] {
  const values=p.map(f)
  if(values.every(v=>v<=EPS))return [p,[]]
  if(values.every(v=>v>=-EPS))return [[],p]
  const half=(inside:boolean):V3[]=>{
    const out:V3[]=[]
    for(let i=0;i<p.length;i++){
      const a=p[i],b=p[(i+1)%p.length],da=values[i],db=values[(i+1)%p.length]
      const hit=inside?da<=EPS:da>=-EPS
      if(hit)out.push(a)
      if((da<-EPS&&db>EPS)||(da>EPS&&db<-EPS))out.push(add3(a,b,da/(da-db)))
    }
    return out
  }
  return [half(true),half(false)]
}

function clip2(poly:PointM[],fn:(p:PointM)=>number):PointM[] {
  if(!poly.length)return []
  const result:PointM[]=[]
  for(let i=0;i<poly.length;i++){
    const a=poly[i],b=poly[(i+1)%poly.length],da=fn(a),db=fn(b)
    if(da<=EPS)result.push(a)
    if((da< -EPS && db>EPS)||(da>EPS&&db< -EPS))result.push(add2(a,b,da/(da-db)))
  }
  return result
}
function emit(poly:V3[],out:number[],reverse=false){
  if(poly.length<3)return
  for(let i=1;i<poly.length-1;i++){
    const triangle=reverse?[poly[0],poly[i+1],poly[i]]:[poly[0],poly[i],poly[i+1]]
    const a=triangle[0],b=triangle[1],c=triangle[2]
    const ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z
    if(Math.hypot(uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx)<1e-9)continue
    for(const v of triangle)out.push(v.x,v.y,v.z)
  }
}
function wallRect149(w:BuildingWall,from:number,to:number):PointM[] {
  const dx=(w.end.x-w.start.x)/w.lengthM,dz=(w.end.y-w.start.y)/w.lengthM
  const ox=-dz*w.thicknessM/2,oz=dx*w.thicknessM/2
  return [
    {x:w.start.x+dx*from+ox,y:w.start.y+dz*from+oz},
    {x:w.start.x+dx*to+ox,y:w.start.y+dz*to+oz},
    {x:w.start.x+dx*to-ox,y:w.start.y+dz*to-oz},
    {x:w.start.x+dx*from-ox,y:w.start.y+dz*from-oz},
  ]
}
/** One convex roof-dominance zone across each physical wall footprint, including the outside half. */
function regions149(model:BuildingModel,roofs:RoofSlope148[]):Sector[] {
  const out:Sector[]=[]
  for(const w of model.walls){
    if(w.lengthM<0.001||w.thicknessM<0.001)continue
    const ids=new Set([w.roomId,...(w.roomIds||[])])
    const possible=roofs.filter(r=>ids.has(r.roomId))
    if(!possible.length)continue
    const footprint=wallRect149(w,0,w.lengthM)
    for(let i=0;i<possible.length;i++){
      const roof=possible[i];let poly=footprint
      for(let j=0;j<possible.length;j++)if(i!==j){
        const other=possible[j],bias=i>j?0.000001:-0.000001
        poly=clip2(poly,p=>roofHeight148(roof,p)-roofHeight148(other,p)+bias)
      }
      if(poly.length>=3&&Math.abs(area(poly))>1e-9&&Math.min(...poly.map(p=>roofHeight148(roof,p)))<model.floorHeightM-1e-6){
        out.push({polygon:poly,roof,wallId:w.id})
      }
    }
  }
  return out
}
/** True triangle intersection. Re-triangulates at all wall/roof and slope/slope crossing lines. */
export function clipSolidWalls149(model:BuildingModel,positions:readonly number[],roofs:RoofSlope148[]):number[] {
  if(!roofs.length)return [...positions]
  const regions=regions149(model,roofs)
  if(!regions.length)return [...positions]
  const output:number[]=[]
  for(let n=0;n+8<positions.length;n+=9){
    let pending:V3[][]=[[{x:positions[n],y:positions[n+1],z:positions[n+2]},
      {x:positions[n+3],y:positions[n+4],z:positions[n+5]},
      {x:positions[n+6],y:positions[n+7],z:positions[n+8]}]]
    // Partition by all roof-influenced wall footprint sectors; no duplicated faces.
    for(const region of regions){
      const bbox=region.polygon
      const minx=Math.min(...bbox.map(v=>v.x))-EPS,maxx=Math.max(...bbox.map(v=>v.x))+EPS
      const minz=Math.min(...bbox.map(v=>v.y))-EPS,maxz=Math.max(...bbox.map(v=>v.y))+EPS
      const later:V3[][]=[]
      for(const polygon of pending){
        if(Math.max(...polygon.map(v=>v.x))<minx||Math.min(...polygon.map(v=>v.x))>maxx||
          Math.max(...polygon.map(v=>v.z))<minz||Math.min(...polygon.map(v=>v.z))>maxz){later.push(polygon);continue}
        let inside=polygon
        const outside:V3[][]=[]
        const sign=area(region.polygon)>=0?1:-1
        for(let e=0;e<region.polygon.length && inside.length>=3;e++){
          const a=region.polygon[e],b=region.polygon[(e+1)%region.polygon.length]
          const [inPoly,outPoly]=split3(inside,v=>-sign*((b.x-a.x)*(v.z-a.y)-(b.y-a.y)*(v.x-a.x)))
          if(outPoly.length>=3)outside.push(outPoly)
          inside=inPoly
        }
        later.push(...outside)
        if(inside.length>=3){
          const [keep]=split3(inside,v=>v.y-roofHeight148(region.roof,{x:v.x,y:v.z}))
          if(keep.length>=3)later.push(keep)
        }
      }
      pending=later
    }
    pending.forEach(p=>emit(p,output))
  }
  // Generate the cut surface (roof cap) only where a wall contains material at that altitude.
  // wallSolidPieces excludes all existing door and window voids.
  for(const wall of model.walls){
    const zones=regions.filter(r=>r.wallId===wall.id)
    if(!zones.length)continue
    for(const part of wallSolidPieces(wall)){
      const rect=wallRect149(wall,part.fromM,part.toM)
      for(const region of zones){
        let poly=rect
        const sign=area(region.polygon)>=0?1:-1
        for(let i=0;i<region.polygon.length;i++){
          const a=region.polygon[i],b=region.polygon[(i+1)%region.polygon.length]
          poly=clip2(poly,p=>-sign*((b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)))
        }
        poly=clip2(poly,p=>part.bottomM-roofHeight148(region.roof,p))
        poly=clip2(poly,p=>roofHeight148(region.roof,p)-(part.topM-0.000001))
        if(poly.length<3||Math.abs(area(poly))<1e-9)continue
        const isCCW=area(poly)>0
        const vertices=poly.map(p=>({x:p.x,y:roofHeight148(region.roof,p),z:p.y}))
        emit(vertices,output,isCCW)
      }
    }
  }
  return output
}
STROM149_ASSET_ROOFCUT149_TS
cat > "$RESOURCE_DIR/FloorSlab149.tsx" <<'STROM149_ASSET_FLOORSLAB149_TSX'
import { useMemo } from 'react'
import * as THREE from 'three'
import type { BuildingRoom } from '../building/model'

/** The finished floor stays at local Y=0. The structural floor extends DOWN by the level's slab thickness. */
export default function FloorSlab149({room,thicknessM}:{room:BuildingRoom;thicknessM:number}) {
  const shape=useMemo(()=>{
    const s=new THREE.Shape()
    room.vertices.forEach((p,i)=>{if(i===0)s.moveTo(p.x,-p.y);else s.lineTo(p.x,-p.y)})
    s.closePath();return s
  },[room.vertices])
  // Stairwells must remain open: a full floor plate here would block the 3D stairs.
  if(room.kind==='outer'||room.kind==='stair'||!Number.isFinite(thicknessM)||thicknessM<0.001)return null
  return <mesh rotation={[-Math.PI/2,0,0]} position={[0,-thicknessM,0]} receiveShadow>
    <extrudeGeometry args={[shape,{depth:thicknessM,bevelEnabled:false,steps:1}]} />
    <meshStandardMaterial color="#aebdce" roughness={0.93} side={THREE.DoubleSide}/>
  </mesh>
}
STROM149_ASSET_FLOORSLAB149_TSX
cat > "$RESOURCE_DIR/RoofEditor148.tsx" <<'STROM149_ASSET_ROOFEDITOR148_TSX'
import { useEffect, useState, type ChangeEvent } from 'react'
import { readRoofSlopes148, saveRoofSlopes148, ROOF_EVENT148, type RoofSlope148 } from '../building/roofSlopes148'
import { cleanSlab149, levelElevations149, inheritRoofPlane149 } from '../building/levelGeometry149'

const dirs=[{value:0,label:'→ Osten / rechts'},{value:90,label:'↓ Süden / unten'},{value:180,label:'← Westen / links'},{value:270,label:'↑ Norden / oben'}]
const value=(num:number)=>Number.isFinite(num)?num:0
export default function RoofEditor148({floorId,roofId,onClose,onChanged}: {
  floorId:string;roofId:string;onClose:()=>void;onChanged?:()=>void
}) {
  const [draft,setDraft]=useState<RoofSlope148|null>(null)
  const [notice,setNotice]=useState('')
  const [sourceRoofId149,setSourceRoofId149]=useState('')
  useEffect(()=>{
    setDraft(readRoofSlopes148(floorId,window.localStorage).find(item=>item.id===roofId)??null)
    setNotice('')
  },[floorId,roofId])
  useEffect(()=>{
    const refresh=()=>setDraft(readRoofSlopes148(floorId,window.localStorage).find(item=>item.id===roofId)??null)
    window.addEventListener(ROOF_EVENT148,refresh)
    return ()=>window.removeEventListener(ROOF_EVENT148,refresh)
  },[floorId,roofId])
  if(!draft)return null
  const patch=(next:Partial<RoofSlope148>)=>setDraft(current=>current?{...current,...next}:current)
  const numeric=(label:string,n:number,step:number,min:number,max:number,update:(val:number)=>void,unit:string)=>
    <label className="strom-roof-field148" key={label}>{label}
      <span><input type="number" value={Number(n.toFixed(3))} min={min} max={max} step={step}
        title={`${label} ${unit}`} onChange={(e:ChangeEvent<HTMLInputElement>)=>update(value(Number(e.target.value)))} />{unit}</span>
    </label>
  // 149: the same mathematical world-space roof plane can be reused across rooms and storeys.
  const otherRoofs149=readRoofSlopes148(floorId,window.localStorage).filter(item=>item.id!==draft.id)
  function inherit149(){
    // Event handlers are closures: React state may become null after the render.
    // Explicitly narrow draft here, not only in the component render body.
    if (!draft) return
    const source=otherRoofs149.find(item=>item.id===sourceRoofId149)
    if(!source){setNotice('Bitte eine bestehende Dachschräge auswählen.');return}
    let layers:Array<{id:string;name:string;heightM:number;slabThicknessM:number}>=[]
    try {
      const raw:unknown=JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floorId}.list`)||'[]')
      if(Array.isArray(raw))layers=raw.flatMap((v:unknown)=>{
        if(!v||typeof v!=='object')return []
        const item=v as Record<string,unknown>
        if(typeof item.id!=='string'||!Number.isFinite(Number(item.heightM)))return []
        return [{id:item.id,name:String(item.name||item.id),heightM:Number(item.heightM),slabThicknessM:cleanSlab149(item.slabThicknessM)}]
      })
    }catch{/* invalid legacy storage is treated as missing */}
    if(!layers.some(item=>item.id===source.levelId)||!layers.some(item=>item.id===draft.levelId)){
      setNotice('Die gespeicherten Ebenenhöhen sind unvollständig. Bitte Ebenen im Blueprint prüfen.');return
    }
    const elevations=levelElevations149(layers)
    const inherited=inheritRoofPlane149(source,draft.start,draft.end,elevations[source.levelId],elevations[draft.levelId])
    setDraft({...draft,directionDeg:inherited.directionDeg,pitchDeg:inherited.pitchDeg,startHeightM:inherited.startHeightM})
    setNotice('Dachebene übernommen. Ihre absolute Höhe und Neigung stimmen mit der Vorlage überein. Zum Übernehmen speichern.')
  }
  function save() {
    if(!draft)return
    try {
      const list=readRoofSlopes148(floorId,window.localStorage)
      const position=list.findIndex(item=>item.id===draft.id)
      if(position<0)throw Error('Dachschräge nicht mehr vorhanden.')
      list[position]=draft
      saveRoofSlopes148(floorId,list)
      setNotice('Dachschräge gespeichert und in 2D/3D aktualisiert.')
      onChanged?.()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  function remove() {
    if(!draft)return
    try {
      const list=readRoofSlopes148(floorId,window.localStorage).filter(item=>item.id!==draft.id)
      saveRoofSlopes148(floorId,list)
      onChanged?.();onClose()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  return <section className="strom-roof-editor148" aria-label="Dachschräge bearbeiten">
    <header><strong>Dachschräge · Eigenschaften</strong><button type="button" title="Schließen" onClick={onClose}>×</button></header>
    {numeric('Neigung',draft.pitchDeg,1,0,65,v=>patch({pitchDeg:v}),'°')}
    {numeric('Beginnhöhe',Math.round(draft.startHeightM*1000),50,-15000,15000,v=>patch({startHeightM:v/1000}),'mm')}
    <label className="strom-roof-field148">Steigungsrichtung
      <select title="Ausrichtung der ansteigenden Dachfläche" value={dirs.some(d=>d.value===draft.directionDeg)?draft.directionDeg:'custom'}
        onChange={(e:ChangeEvent<HTMLSelectElement>)=>{if(e.target.value!=='custom')patch({directionDeg:Number(e.target.value)})}}>
        {dirs.map(d=><option key={d.value} value={d.value}>{d.label}</option>)}
        <option value="custom">Frei / Winkel</option>
      </select>
    </label>
    {numeric('Ausrichtung als Winkel',draft.directionDeg,1,0,359,v=>patch({directionDeg:v}),'°')}
    <fieldset className="strom-roof-reference149" aria-label="Bestehende Dachfläche übernehmen">
      <legend>Dachebene aus vorhandener Schräge übernehmen</legend>
      <select title="Vorlage aus beliebiger Blueprint-Ebene auswählen" aria-label="Vorhandene Dachschräge" value={sourceRoofId149}
        onChange={event=>setSourceRoofId149(event.currentTarget.value)}>
        <option value="">Vorhandene Schräge wählen …</option>
        {otherRoofs149.map(item=><option key={item.id} value={item.id}>
          {item.levelId} · {item.roomId} · {item.pitchDeg}°
        </option>)}
      </select>
      <button type="button" disabled={!sourceRoofId149} onClick={inherit149} title="Gleiche geometrische Dachebene auch über Etagen hinweg übernehmen">Ebene übernehmen</button>
    </fieldset>
    <details open><summary>Position der Startlinie (mm) – im Blueprint auch ziehbar</summary>
      {numeric('Start X',draft.start.x*1000,50,-100000,100000,v=>patch({start:{...draft.start,x:v/1000}}),'mm')}
      {numeric('Start Y',draft.start.y*1000,50,-100000,100000,v=>patch({start:{...draft.start,y:v/1000}}),'mm')}
      {numeric('Ende X',draft.end.x*1000,50,-100000,100000,v=>patch({end:{...draft.end,x:v/1000}}),'mm')}
      {numeric('Ende Y',draft.end.y*1000,50,-100000,100000,v=>patch({end:{...draft.end,y:v/1000}}),'mm')}
    </details>
    <div className="strom-roof-actions148"><button type="button" onClick={save} title="Änderungen in Blueprint, Wanddetail und 3D Haus übernehmen">Speichern</button>
      <button type="button" onClick={remove} title="Diese Dachschräge löschen; andere Schrägen im Raum bleiben erhalten">Löschen</button></div>
    {notice&&<p role="status">{notice}</p>}
  </section>
}
STROM149_ASSET_ROOFEDITOR148_TSX
cat > "$RESOURCE_DIR/roofSlopes148.ts" <<'STROM149_ASSET_ROOFSLOPES148_TS'
import type { PointM, Room } from '../types'

/** STROM148: one physical roof-slope record, shared by Blueprint and both true-3D views. */
export type RoofSlope148 = {
  id: string
  roomId: string
  levelId: string
  start: PointM
  end: PointM
  /** Degrees clockwise from +X on the Blueprint (0=right, 90=down). */
  directionDeg: number
  pitchDeg: number
  /** Height above the floor of the roof's own level (metres). */
  startHeightM: number
}
export const ROOF_EVENT148 = 'strom:roof-slopes-changed148'
export const roofKey148 = (floorId: string) => `strom.floorplan.roofSlopes148.${floorId}`

function validPoint(point: unknown): point is PointM {
  if (!point || typeof point !== 'object') return false
  const p = point as Record<string, unknown>
  return typeof p.x === 'number' && Number.isFinite(p.x) && typeof p.y === 'number' && Number.isFinite(p.y)
}
export function normalizeSlope148(v: unknown): RoofSlope148 | null {
  if (!v || typeof v !== 'object') return null
  const r = v as Record<string, unknown>
  if (typeof r.id !== 'string' || !r.id || typeof r.roomId !== 'string' || !r.roomId ||
      typeof r.levelId !== 'string' || !r.levelId || !validPoint(r.start) || !validPoint(r.end)) return null
  const pitchDeg = Number(r.pitchDeg), startHeightM = Number(r.startHeightM), directionDeg = Number(r.directionDeg)
  if (![pitchDeg, startHeightM, directionDeg].every(Number.isFinite) ||
      pitchDeg < 0 || pitchDeg > 65 || startHeightM < -15 || startHeightM > 15 ||
      Math.hypot(r.end.x-r.start.x, r.end.y-r.start.y) < 0.03) return null
  return {id:r.id,roomId:r.roomId,levelId:r.levelId,start:{...r.start},end:{...r.end},
    directionDeg: ((directionDeg%360)+360)%360, pitchDeg, startHeightM}
}
export function readRoofSlopes148(floorId: string, store: Pick<Storage,'getItem'>): RoofSlope148[] {
  try {
    const value: unknown = JSON.parse(store.getItem(roofKey148(floorId)) || '[]')
    if (!Array.isArray(value)) return []
    const used = new Set<string>()
    return value.flatMap((entry: unknown) => {
      const roof = normalizeSlope148(entry)
      if (!roof || used.has(roof.id)) return []
      used.add(roof.id)
      return [roof]
    })
  } catch { return [] }
}
export function saveRoofSlopes148(floorId: string, list: RoofSlope148[]) {
  if (typeof window === 'undefined') return
  const valid = list.map(normalizeSlope148)
  if (valid.some((roof) => !roof)) throw Error('Dachschräge: ungültige Geometrie oder Parameter.')
  window.localStorage.setItem(roofKey148(floorId), JSON.stringify(valid))
  window.dispatchEvent(new CustomEvent(ROOF_EVENT148, { detail: {floorId} }))
}
export function angleVector148(angle: number): PointM {
  const rad = angle*Math.PI/180
  return {x:Math.cos(rad), y:Math.sin(rad)}
}
export function roofHeight148(roof: RoofSlope148, p: PointM): number {
  const axis = angleVector148(roof.directionDeg)
  const run = (p.x-roof.start.x)*axis.x + (p.y-roof.start.y)*axis.y
  return roof.startHeightM + run * Math.tan(roof.pitchDeg*Math.PI/180)
}
/** Choose the inward-facing normal for a line drawn on a room boundary. */
export function inwardRoofAngle148(start: PointM, end: PointM, vertices: PointM[]): number {
  const centroid = vertices.reduce((s,p)=>({x:s.x+p.x/vertices.length,y:s.y+p.y/vertices.length}),{x:0,y:0})
  const vx=end.x-start.x, vy=end.y-start.y
  const n1={x:-vy,y:vx}
  const mid={x:(start.x+end.x)/2,y:(start.y+end.y)/2}
  const dot=n1.x*(centroid.x-mid.x)+n1.y*(centroid.y-mid.y)
  const n=dot>=0?n1:{x:-n1.x,y:-n1.y}
  return Math.round(((Math.atan2(n.y,n.x)*180/Math.PI)%360+360)%360)
}
export function nearestRoomEdge148(point: PointM, vertices: PointM[], toleranceM = 0.3): PointM {
  let best:PointM=point, bestD=toleranceM
  for(let i=0;i<vertices.length;i++) {
    const a=vertices[i],b=vertices[(i+1)%vertices.length]
    const dx=b.x-a.x,dy=b.y-a.y, denom=dx*dx+dy*dy
    if (denom<1e-12) continue
    const t=Math.max(0,Math.min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/denom))
    const projected={x:a.x+t*dx,y:a.y+t*dy}
    const d=Math.hypot(projected.x-point.x,projected.y-point.y)
    if (d<bestD) {bestD=d;best=projected}
  }
  return best
}
export function roofsForRoom148(rooms: Room[], slopes: RoofSlope148[], roomId: string, levelId: string) {
  return rooms.some(r=>r.id===roomId) ? slopes.filter(r=>r.roomId===roomId && r.levelId===levelId) : []
}
STROM149_ASSET_ROOFSLOPES148_TS

log "3) Validate all bundled resources and apply one transactional patch ..."
for resource in patch149.py levelGeometry149.ts roofCut149.ts FloorSlab149.tsx RoofEditor148.tsx roofSlopes148.ts; do
  [ -s "$RESOURCE_DIR/$resource" ] || fail "Missing bundled resource: $resource"
done
python3 -m py_compile "$RESOURCE_DIR/patch149.py" >>"$DIAG_LOG" 2>&1 || fail "Patch Python syntax failed"
STROM149_ROOT="$WORK_DIR" STROM149_MODULES="$RESOURCE_DIR" \
  python3 "$RESOURCE_DIR/patch149.py" >>"$DIAG_LOG" 2>&1 || fail "Patch149 failed; GitHub and Stage unchanged"
log "4) Structural TSX audit / duplicate attributes before build ..."
STROM149_SOURCE="$WORK_DIR/frontend/src" STROM149_TS="$DEPENDENCIES/typescript" node <<'STROM149_AST_AUDIT' >>"$DIAG_LOG" 2>&1 || fail "TypeScript AST check failed"
const fs=require('fs'),path=require('path'),ts=require(process.env.STROM149_TS),root=process.env.STROM149_SOURCE
const items=['App.tsx','components/Building3DWorkspace.tsx','components/FloorSlab149.tsx',
 'components/RoofEditor148.tsx','building/roofCut149.ts','building/levelGeometry149.ts',
 'building/roofSlopes148.ts','building/blueprintLevels.ts','building/stairVisibility143.ts','building/stairLinks148.ts']
let checked=0
for (const rel of items){
 const file=path.join(root,rel),text=fs.readFileSync(file,'utf8');const ast=ts.createSourceFile(file,text,ts.ScriptTarget.Latest,true,rel.endsWith('tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 if(ast.parseDiagnostics.length)throw Error(rel+' parse: '+ast.parseDiagnostics.map(x=>ts.flattenDiagnosticMessageText(x.messageText,' ')).join('; '))
 const walk=node=>{
  if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node)){
   const found=new Set();for(const prop of node.attributes.properties){if(!ts.isJsxAttribute(prop))continue;const key=prop.name.getText(ast);if(found.has(key))throw Error(rel+': duplicated JSX prop '+key);found.add(key)}
  }
  ts.forEachChild(node,walk)
 }
 walk(ast);checked++
}
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8'),s=fs.readFileSync(path.join(root,'components/Building3DWorkspace.tsx'),'utf8')
for(const marker of ['STROM148_ROOF_EDIT','STROM149_ROOF_DRAG','STROM144_BLUEPRINT_DOOR_LEVEL'])if(!app.includes(marker))throw Error('Missing Blueprint marker '+marker)
for(const marker of ['STROM149_CUT_WALL','clipSolidWalls149','STROM141_WALL_HOVER','STROM146_ALL_LEVELS'])if(!s.includes(marker))throw Error('Missing 3D marker '+marker)
console.log('PASS AST:',checked,'TS/TSX files, no duplicate JSX attrs; existing Blueprints/3D markers preserved')
STROM149_AST_AUDIT
log "5) Full TypeScript and Vite build against real Stage dependencies ..."
( cd "$WORK_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "TypeScript/Vite build failed before GitHub push"
log "5.1) Level, stair and roof-wall geometry regression tests ..."
STROM149_SOURCE="$WORK_DIR/frontend/src" STROM149_TS="$DEPENDENCIES/typescript" node <<'STROM149_TEST' >>"$DIAG_LOG" 2>&1 || fail "Geometry/regression test failed before GitHub push"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM149_TS),root=process.env.STROM149_SOURCE
function load(file,mocks={}){
 const text=fs.readFileSync(path.join(root,file),'utf8')
 const res=ts.transpileModule(text,{fileName:file,reportDiagnostics:true,compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}})
 if(res.diagnostics?.some(d=>d.category===ts.DiagnosticCategory.Error))throw Error('TS parse '+file)
 const m={exports:{}};new Function('module','exports','require',res.outputText)(m,m.exports,(id)=>mocks[id]||{})
 return m.exports
}
const geo=load('building/levelGeometry149.ts')
const levels=[{id:'DG',heightM:2.4,slabThicknessM:.22},{id:'OG',heightM:2.5,slabThicknessM:.2},{id:'EG',heightM:2.6,slabThicknessM:.15}]
assert.deepStrictEqual(geo.levelElevations149(levels),{EG:0,OG:2.8,DG:5.52})
assert(Math.abs(geo.stairRise149(levels,'EG')-2.8)<1e-8)
assert(Math.abs(geo.stairRise149(levels,'OG')-2.72)<1e-8)
const roof={id:'r',roomId:'r1',levelId:'EG',start:{x:0,y:0},end:{x:0,y:4},directionDeg:0,pitchDeg:30,startHeightM:.8}
const inherited=geo.inheritRoofPlane149(roof,{x:2,y:0},{x:2,y:4},0,2.8)
assert(Math.abs(inherited.startHeightM-(.8+2*Math.tan(Math.PI/6)-2.8))<.001)
assert.strictEqual(geo.dragRoofLine149(roof,'move',1,2).start.x,1)
const model={walls:[{id:'wall1',roomId:'r1',roomIds:['r1'],start:{x:0,y:0},end:{x:4,y:0},lengthM:4,thicknessM:.4}],floorHeightM:2.6}
const roofModule=load('building/roofSlopes148.ts')
const cutter=load('building/roofCut149.ts',{'./model':{wallSolidPieces:w=>[{fromM:0,toM:w.lengthM,bottomM:0,topM:2.6}]},'./roofSlopes148':roofModule})
let triangles=[];const pushQuad=(a,b,c,d)=>triangles.push(...a,...b,...c,...a,...c,...d)
const xz=[[0,-.2],[4,-.2],[4,.2],[0,.2]],B=xz.map(([x,z])=>[x,0,z]),T=xz.map(([x,z])=>[x,2.6,z]);pushQuad(B[0],B[1],B[2],B[3]);pushQuad(T[3],T[2],T[1],T[0]);for(let i=0;i<4;i++){let j=(i+1)%4;pushQuad(B[i],T[i],T[j],B[j])}
const other={...roof,id:'r2',start:{x:4,y:0},directionDeg:180}
for(const roofs of [[roof],[roof,other]]){
 const result=cutter.clipSolidWalls149(model,triangles,roofs)
 assert(result.length>0&&result.length%9===0)
 for(let i=0;i<result.length;i+=3){const x=result[i],y=result[i+1],z=result[i+2];const limit=Math.min(...roofs.map(r=>roofModule.roofHeight148(r,{x,y:z})))
   if(y>limit+0.00001)throw Error('Triangle above roof wall cut: '+JSON.stringify([x,y,z,limit]))}
}
console.log('PASS geometry: top-first levels, slab rise, cross-level same world plane, 1/2 roof wall cuts')
STROM149_TEST
rm -rf -- "$RESOURCE_DIR"
cat > "$WORK_DIR/docs/STROM_UPDATE_149.md" <<'STROM149_DOC'
# STROM update 149c

- Blueprint level list is top-first and 3D elevations match that physical ordering.
- Clear room height (heightM) and the under-floor slab thickness (slabThicknessM) are separate values.
- Floor thickness defaults to 0 mm for existing stored levels, preventing unintended shifts; user can edit up to 1500 mm.
- Upper-floor slab thickness is included in the stair rise from the lower floor.
- Slabs are rendered as extruded volumes below finished floor levels.
- Roof slopes remain confined to one room when initially drawn. Different pitches and directions in a room are supported.
- Blueprint roof start line is selectable, movable and endpoint-rotatable. An existing plane from any level can be inherited, including the world-space absolute height.
- 3D walls are physically surface-clipped by roof planes from adjacent rooms, with section caps computed from solid wall pieces (doors/windows excluded).
- The original geometry builder, room/door API and production deployment remain unchanged.
- Browser-local layer and roof metadata is not yet synchronized across devices; DB persistence remains a later independent migration.
STROM149_DOC
log "6) Transfer checked source to Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage source sync failed; backup at $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PATCH_ONLY passed: nothing deployed to web"; exit 0; fi
log "7) Rebuild Stage and deploy only to /strom-test/ ..."
( cd "$STAGE_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "Stage rebuild failed; backup at $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Missing frontend/dist"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Web test deploy failed; backup at $BACKUP_DIR"
log "SUCCESS: 149c deployed to https://home.moja.de/strom-test/"
log "Production unchanged. Stage backup: $BACKUP_DIR"
