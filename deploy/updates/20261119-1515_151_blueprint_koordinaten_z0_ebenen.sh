#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1515_151_blueprint_koordinaten_z0_ebenen"
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
COMMIT_MESSAGE="Update 151: canonical Blueprint XY/Z coordinates and selectable Z=0 reference level"
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
  echo "2) Update 151 im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 151 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 151: Blueprint coordinates and selectable Z=0 level ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/FloorSlab149.tsx frontend/src/components/CameraFlight150.tsx \
  frontend/src/components/cameraTransitions150.ts frontend/src/components/threeFloorExtrema150q.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "151 required source missing: $file"
done
grep -Fq 'STROM150Q_3D_FLOOR_EXTENTS' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "151 requires the current 150q diagnostic; Stage unchanged"
grep -Fq 'STROM150R_REAL_FLOOR_PROBE' "$STAGE_DIR/frontend/src/components/FloorSlab149.tsx" || \
  fail "151 requires installed 150r floor probes; Stage unchanged"
[ -s "$STAGE_DIR/frontend/src/components/cameraFloorMatch150r.ts" ] || \
  fail "151 requires 150r matching module; Stage unchanged"
grep -Fq 'STROM150P_BLUEPRINT_EXTENTS' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "151 requires measured Blueprint extents from 150p"
grep -Fq 'STROM150O_PRE_NAV_SNAPSHOT' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "151 requires existing camera snapshot"
grep -Fq 'export const ENTER_FADE150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "151 keeps 5 second fade"
grep -Fq 'export const DURATION150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "151 keeps 5 second flight"
select_node
log "1) Backup Stage source ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no live source backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
fi
log "2) Prepare completely isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "151 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "151 TypeScript/Vite/Three dependencies missing"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/151_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch151.py" <<'STROM151_PY'
#!/usr/bin/env python3
"""One transactional 151 upgrade of Stage source; never reapply old patches."""
from pathlib import Path
import os,re
root=Path(os.environ['STROM151_ROOT'])/'frontend/src'
app=root/'App.tsx'
css=root/'styles.css'
level=root/'building/blueprintLevels.ts'
stairs=root/'building/stairVisibility143.ts'
scene=root/'components/Building3DWorkspace.tsx'
roof=root/'components/RoofEditor148.tsx'
probe=root/'components/cameraFloorMatch150r.ts'
model=root/'building/coordinateReference151.ts'
for p in (app,css,level,stairs,scene,roof,probe):
    if not p.is_file():raise RuntimeError(f'151 required current source missing: {p.relative_to(root)}')
if model.exists():raise RuntimeError('151 coordinate reference already installed (do not run twice)')
texts={p:p.read_text('utf8') for p in (app,css,level,stairs,scene,roof,probe)}
if 'STROM151_COORDINATE_DATUM' in texts[app] or 'STROM151_COORDINATE_DATUM' in texts[css]:
    raise RuntimeError('151 already installed')
for key,value in (
    ('STROM149E_LEVEL_ROW',texts[css]),
    ('STROM149_LEVEL_GEOMETRY',texts[level]),
    ('STROM149_FLOOR_SLAB',texts[scene]),
    ('inheritRoofPlane149',texts[roof]),
    ('STROM150R_REAL_FLOOR_PROBE',texts[probe]),
):
    if key not in value:raise RuntimeError(f'151 requires deployed 149e/150r source marker {key}')

def one(text,old,new,label):
    n=text.count(old)
    if n!=1:raise RuntimeError(f'151 {label}: unique anchor required, found {n}')
    return text.replace(old,new,1)

def use_import(text,path,symbol):
    """Add one declaration without changing import style elsewhere."""
    if f'from \'{path}\'' in text and symbol in text:
        return text
    return f"import {{{symbol}}} from '{path}' // STROM151_COORDINATE_DATUM\n"+text

def drop_old_symbol(text,symbol,path):
    # Only drop an unused *named* import from a known module.
    if re.search(r'\b'+re.escape(symbol)+r'\s*\(',text):return text
    patt=re.compile(r"import\s*\{([^}]*)\}\s*from\s*['\"]"+re.escape(path)+r"['\"]")
    matches=list(patt.finditer(text))
    if len(matches)!=1:raise RuntimeError(f'151 unused import expected in {path}, got {len(matches)}')
    old=matches[0].group(0)
    names=[s.strip() for s in matches[0].group(1).split(',') if s.strip()]
    if symbol not in names:raise RuntimeError(f'151 {symbol} absent in import')
    names.remove(symbol)
    return text.replace(old,'import { '+', '.join(names)+" } from '"+path+"'",1) if names else text.replace(old,'',1)

# --- Blueprint level choice: radio-like Z=0 marker in the existing compact row. ---
a=texts[app]
a=use_import(a,'./building/coordinateReference151','readZeroLevel151,writeZeroLevel151,resolveZeroLevel151')
start=a.find('function FloorplanEditor(')
end=a.find('type StairEditorElementKind',start)
if start<0 or end<start:raise RuntimeError('151 Blueprint editor boundaries not found')
section=a[start:end]
state_anchor='  const [activeLayerId, setActiveLayerId] = useState<string>(() => loadActiveLayerId(floor.id, loadFloorplanLayers(floor.id)))'
section=one(section,state_anchor,state_anchor+'''
  // STROM151_COORDINATE_DATUM: the Blueprint level list selects architectural Z=0.
  const [zeroLevel151, setZeroLevel151] = useState<string>(() =>
    readZeroLevel151(floor.id,loadFloorplanLayers(floor.id),window.localStorage))
''','Blueprint datum state')
section=one(section,"    setLayers(nextLayers)\n    setActiveLayerId(",
  "    setLayers(nextLayers)\n    setZeroLevel151(readZeroLevel151(floor.id,nextLayers,window.localStorage))\n    setActiveLayerId(",
  'datum on floor change')
# Find only the Blueprint row; another layer menu in WallDetailEditor must not change.
row_anchor="className={`layer-row ${active ? 'active' : ''}"
row_start=section.find(row_anchor)
if row_start<0 or section.count(row_anchor)!=1:
    raise RuntimeError('151 Blueprint layer row not found uniquely')
button_anchor='<button type="button" className={`layer-eye'
button_at=section.find(button_anchor,row_start)
if button_at<0 or button_at-row_start>1100:
    raise RuntimeError('151 Blueprint layer eye/row not adjacent; Stage unchanged')
label='''<label className="layer-zero-marker151" title={layers.length===1 ? 'Einzige Ebene: automatisch Z=0' : 'Diese Ebene als Z=0 festlegen'}
                        onMouseDown={(event)=>event.stopPropagation()} onClick={(event)=>event.stopPropagation()}>
                        <input type="radio" name={`layer-zero151-${floor.id}`}
                          aria-label={`${layer.name} als Z=0-Ebene auswählen`}
                          checked={resolveZeroLevel151(layers,zeroLevel151)===layer.id}
                          disabled={layers.length===1}
                          onChange={()=>{writeZeroLevel151(floor.id,layer.id,window.localStorage);setZeroLevel151(layer.id)}} />
                        <span aria-hidden="true">0</span>
                      </label>
                      '''
section=section[:button_at]+label+section[button_at:]
# The menu includes a dedicated legend so the marker meaning is obvious.
menu_line='<div className="layer-list">'
section=one(section,menu_line,'''<div className="layer-zero-legend151" title="Die markierte Etage hat Z = 0 m; darüber positive, darunter negative Höhen.">
                  <span>Nullhöhe</span><strong>Z = 0</strong>
                </div>
              '''+menu_line,'Blueprint datum caption')
a=a[:start]+section+a[end:]
texts[app]=a

# --- Shared elevation calculation: all 3D storeys, stairs and roof planes use the
# SAME Blueprint datum. Preserve existing horizontal room vertices and dimensions. ---
substitutions=[
 (level,'./coordinateReference151',
  'levelElevations149(layers, Number(floor.elevationM)||0)[current.id]',
  'levelElevationsDatum151(layers,floor.id,window.localStorage)[current.id]','active Blueprint level elevation'),
 (stairs,'./coordinateReference151',
  'levelElevations149(levels,numeric(floor.elevationM,0))',
  'levelElevationsDatum151(levels,floor.id,storage)','stair and ghost levels'),
 (scene,'../building/coordinateReference151',
  'levelElevations149(levelOptions144,Number(floor.elevationM)||0)',
  'levelElevationsDatum151(levelOptions144,floor.id,window.localStorage)','3D controller floors'),
 (roof,'../building/coordinateReference151',
  'levelElevations149(layers)',
  'levelElevationsDatum151(layers,floorId,window.localStorage)','cross-floor roof inheritance'),
]
for p,imp,old,new,label in substitutions:
    t=texts[p]
    t=one(t,old,new,label)
    t=drop_old_symbol(t,'levelElevations149','./levelGeometry149' if p in (level,stairs) else '../building/levelGeometry149')
    t=use_import(t,imp,'levelElevationsDatum151')
    texts[p]=t

# --- Make the existing 150r probe use the same canonical X/Y/Z -> Three axis map.
# No camera, visual transforms, mesh topology, or flight timing are changed.
p=texts[probe]
p=one(p,'const world=new THREE.Vector3(point.x,0,point.y).applyMatrix4(obj.matrixWorld)',
 '''const xyz=blueprintToThree151({x:point.x,y:point.y,z:0})
      const world=new THREE.Vector3(xyz.x,xyz.y,xyz.z).applyMatrix4(obj.matrixWorld)''',
 '3D floor measurement canonical axes')
p=use_import(p,'../building/coordinateReference151','blueprintToThree151')
texts[probe]=p

# --- CSS: narrow, explicit one-line six-column layout, with radio marker. ---
css_append='''
/* STROM151_COORDINATE_DATUM: one canonical zero-height level without adding a second row. */
.canvas-layer-menu:not(.wall-layer-menu) .layer-menu-panel { min-width: min(385px, calc(100vw - 28px)); }
.canvas-layer-menu:not(.wall-layer-menu) .layer-row {
  grid-template-columns:26px 26px 26px minmax(52px,1fr) minmax(76px,84px) minmax(62px,68px) !important;
  grid-template-areas:"datum eye grip name height slab" !important;
}
.canvas-layer-menu:not(.wall-layer-menu) .layer-row > .layer-zero-marker151 {
  grid-area:datum;display:flex;flex-direction:column;align-items:center;justify-content:center;
  min-width:0;cursor:pointer;font-size:9px;line-height:1.1;color:#54719c;gap:2px;
}
.layer-zero-marker151 input[type="radio"] {appearance:auto;accent-color:#285eda;width:15px;height:15px;margin:0;cursor:pointer;}
.layer-zero-marker151 input[type="radio"]:disabled {opacity:1;cursor:default;}
.layer-zero-marker151 span {font-size:9px; font-weight:650;}
.layer-zero-legend151 {display:flex;align-items:center;justify-content:space-between;
  padding:3px 7px;font-size:11px;color:#526d95;}
.layer-zero-legend151 strong {color:#275dd1;}
'''
texts[css]=texts[css]+css_append

# Validate *all* replacements, then save into isolated working tree; live Stage
# is updated only after TypeScript/Vite build succeeds.
for p,t in texts.items():
    if p==app and t.count('STROM151_COORDINATE_DATUM')<2:raise RuntimeError('151 datum UI missing')
    if p==css and 'layer-zero-marker151' not in t:raise RuntimeError('151 datum CSS missing')
    if p!=css and not t.strip():raise RuntimeError(f'151 empty transformed file: {p}')
for p,t in texts.items():p.write_text(t,'utf8')
print('PASS 151: canonical Blueprint XY, selectable Z=0, all active 3D/stair/roof levels use same datum')
STROM151_PY
cat > "$RESOURCE_DIR/coordinateReference151.ts" <<'STROM151_TS'
import {levelElevations149, type Level149} from './levelGeometry149'

/** STROM151_COORDINATE_DATUM: Blueprint defines model coordinates in metres.
 * Architectural X/Y are plan axes, Z is height; Three.js renders them as X/Y(up)/Z.
 * No implicit scaling, rotation, camera offset or geometry recentering occurs here. */
export type BlueprintXYZ151={x:number;y:number;z:number}
export type ThreeXYZ151={x:number;y:number;z:number}
export const ZERO_LEVEL_KEY_SUFFIX151='zeroLevel151'
export const zeroLevelKey151=(floorId:string)=>`strom.floorplan.layers.${floorId}.${ZERO_LEVEL_KEY_SUFFIX151}`

export function resolveZeroLevel151<T extends Pick<Level149,'id'>>(levels:readonly T[],candidate:string|null|undefined):string{
  if(levels.length===0)return ''
  // Existing objects retain their old bottom-floor Z=0 until a different datum is chosen.
  return candidate&&levels.some(level=>level.id===candidate)?candidate:levels[levels.length-1].id
}
export function readZeroLevel151<T extends Pick<Level149,'id'>>(
  floorId:string, levels:readonly T[], storage:Pick<Storage,'getItem'>
):string{
  if(levels.length<=1)return levels[0]?.id??''
  try{
    const raw=storage.getItem(zeroLevelKey151(floorId))
    if(!raw)return resolveZeroLevel151(levels,null)
    // JSON string is canonical; tolerate legacy unquoted values when present.
    let saved:unknown=raw
    try{saved=JSON.parse(raw)}catch{/* no legacy data migration required */}
    return resolveZeroLevel151(levels,typeof saved==='string'?saved:null)
  }catch{return resolveZeroLevel151(levels,null)}
}
export function writeZeroLevel151(floorId:string,levelId:string,storage:Pick<Storage,'setItem'>):void{
  if(!floorId||!levelId)throw Error('Invalid zero-level selection')
  storage.setItem(zeroLevelKey151(floorId),JSON.stringify(levelId))
  if(typeof window!=='undefined'){
    window.dispatchEvent(new CustomEvent('strom:zero-level151',{detail:{floorId,levelId}}))
  }
}

/** Finished-floor elevations relative to selected Z=0, keeping every inter-floor
 * distance and slab thickness exactly as in 149. Negative values are valid. */
export function levelElevationsDatum151<T extends Level149>(
  levelsTopFirst:readonly T[],floorId:string,storage:Pick<Storage,'getItem'>
):Record<string,number>{
  if(levelsTopFirst.length===0)return {}
  const original=levelElevations149(levelsTopFirst,0)
  const zeroId=readZeroLevel151(floorId,levelsTopFirst,storage)
  const offset=original[zeroId]??0
  const result:Record<string,number>={}
  for(const level of levelsTopFirst){
    result[level.id]=Math.round((original[level.id]-offset)*1000)/1000
  }
  return result
}

/** Explicit 1:1 axis mapping; Blueprint X,Y,Z -> Three.js X,Y(up),Z(depth). */
export function blueprintToThree151(p:BlueprintXYZ151):ThreeXYZ151{
  return {x:p.x,y:p.z,z:p.y}
}
export function threeToBlueprint151(p:ThreeXYZ151):BlueprintXYZ151{
  return {x:p.x,y:p.z,z:p.y}
}
STROM151_TS
cat > "$RESOURCE_DIR/test151.cjs" <<'STROM151_TEST'
'use strict'
const fs=require('fs'),path=require('path'),assert=require('assert')
const ts=require(process.env.STROM151_TS)
const source=process.env.STROM151_SOURCE
for(const rel of ['App.tsx','building/coordinateReference151.ts','building/blueprintLevels.ts','building/stairVisibility143.ts','components/Building3DWorkspace.tsx','components/RoofEditor148.tsx','components/cameraFloorMatch150r.ts']){
 const file=path.join(source,rel),code=fs.readFileSync(file,'utf8')
 const ast=ts.createSourceFile(file,code,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 assert.equal(ast.parseDiagnostics.length,0,rel+': '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
const a=fs.readFileSync(path.join(source,'App.tsx'),'utf8')
const begin=a.indexOf('function FloorplanEditor('),finish=a.indexOf('type StairEditorElementKind',begin)
const floor=a.slice(begin,finish)
assert(floor.includes('layer-zero-marker151')&&floor.includes('type="radio"'))
assert(floor.includes('writeZeroLevel151')&&floor.includes('readZeroLevel151'))
const css=fs.readFileSync(path.join(source,'styles.css'),'utf8')
assert(css.includes('grid-template-areas:"datum eye grip name height slab"'))
const orig=fs.readFileSync(path.join(source,'building/levelGeometry149.ts'),'utf8')
const canon=fs.readFileSync(path.join(source,'building/coordinateReference151.ts'),'utf8')
function compile(code,name){const r=ts.transpileModule(code,{fileName:name,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},reportDiagnostics:true});assert.equal((r.diagnostics||[]).filter(x=>x.category===ts.DiagnosticCategory.Error).length,0);return r.outputText}
const m0={exports:{}}
new Function('require','module','exports',compile(orig,'levelGeometry149.ts'))(()=>{throw Error('bad import')},m0,m0.exports)
const m1={exports:{}}
const store=new Map()
const mockStorage={getItem:key=>store.get(key)||null,setItem:(k,v)=>store.set(k,v)}
new Function('require','module','exports',compile(canon,'coordinateReference151.ts'))(name=>{
 if(name==='./levelGeometry149')return m0.exports
 throw Error('unexpected import '+name)
},m1,m1.exports)
const c=m1.exports
const levels=[{id:'DG',heightM:2.4,slabThicknessM:.22},{id:'OG',heightM:2.5,slabThicknessM:.2},{id:'EG',heightM:2.6,slabThicknessM:.15}]
assert.equal(c.readZeroLevel151('a',levels,mockStorage),'EG')
assert.deepStrictEqual(c.levelElevationsDatum151(levels,'a',mockStorage),{EG:0,OG:2.8,DG:5.52})
c.writeZeroLevel151('a','OG',mockStorage)
assert.deepStrictEqual(c.levelElevationsDatum151(levels,'a',mockStorage),{EG:-2.8,OG:0,DG:2.72})
c.writeZeroLevel151('a','DG',mockStorage)
assert.deepStrictEqual(c.levelElevationsDatum151(levels,'a',mockStorage),{EG:-5.52,OG:-2.72,DG:0})
assert.equal(c.readZeroLevel151('b',[levels[0]],mockStorage),'DG')
c.writeZeroLevel151('b','OG',mockStorage)
assert.equal(c.readZeroLevel151('b',[levels[0]],mockStorage),'DG')
assert.deepStrictEqual(c.threeToBlueprint151(c.blueprintToThree151({x:12.345,y:-5.678,z:2.8})),{x:12.345,y:-5.678,z:2.8})
assert.equal(c.resolveZeroLevel151(levels,'missing'),'EG')
assert.equal(c.resolveZeroLevel151([],null),'')
const scene=fs.readFileSync(path.join(source,'components/Building3DWorkspace.tsx'),'utf8')
assert(scene.includes('levelElevationsDatum151('))
assert(fs.readFileSync(path.join(source,'building/stairVisibility143.ts'),'utf8').includes('levelElevationsDatum151('))
assert(fs.readFileSync(path.join(source,'components/RoofEditor148.tsx'),'utf8').includes('levelElevationsDatum151('))
console.log('PASS 151: Blueprint canonical plan, exact Z=0 level selection, shared 3D/stair/roof heights, round-trip axes')
STROM151_TEST

log "3) Add Blueprint Z=0 choice and unify level elevations ..."
python3 -m py_compile "$RESOURCE_DIR/patch151.py" >>"$DIAG_LOG" 2>&1 || fail "151 Python syntax failed"
STROM151_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch151.py" >>"$DIAG_LOG" 2>&1 || \
  fail "151 source patch failed; GitHub and Stage unchanged"
install -m 0644 "$RESOURCE_DIR/coordinateReference151.ts" \
  "$WORK_DIR/frontend/src/building/coordinateReference151.ts"
log "4) TypeScript, Vite and integrated frontend build ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "151 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Coordinate, Z=0 and TSX regression tests ..."
STROM151_SOURCE="$WORK_DIR/frontend/src" STROM151_TS="$DEPENDENCIES/typescript" \
  node "$RESOURCE_DIR/test151.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "151 coordinate regression failed; GitHub and Stage unchanged"
log "PASS 151: selected Blueprint Z=0, same elevations in 3D/stairs/roof, canonical plan XY"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_151.md" <<'STROM151_DOC'
# Stromnetze Update 151 — one canonical Blueprint coordinate system

- Canonical architectural coordinates: Blueprint X/Y (metres), level height Z (metres).
- Three.js render axes: world X=Blueprint X, world Y=height Z, world Z=Blueprint Y. Model room vertices, dimensions and ruler values are not rescaled or recentered.
- Each floorplan has exactly one selectable finished-floor Z=0 reference level in the Blueprint layer list.
- Single storey: its level automatically has Z=0. Multiple storeys: radio marker picks the level; defaults to bottom entry to preserve existing position until changed.
- All level elevations for 3D and stairs, Blueprint level options, and cross-level roof-plane inheritance share the same coordinate datum. Lower levels receive negative heights.
- The vertical zero reference is saved in browser localStorage per floor ID, consistent with existing level metadata storage. The database has not been migrated.
- Camera flight and its existing five-second diagnostic timings, loading indicator, and viewport overlays remain unchanged.
- Build and structural regression must pass before GitHub push and /strom-test/ deployment. Production is not updated.
STROM151_DOC
log "6) Transfer checked source to Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "151 Stage source transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY; no web deployment"
  exit 0
fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "151 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "151 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "151 /strom-test/ deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 151 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
