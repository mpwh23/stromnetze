#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-2040_144a_blueprint_tueren_ebenen_wanddetail_patchfix"
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
COMMIT_MESSAGE="Update 144a: Blueprint door visibility, shared Wanddetail floor picker, wall-surface cleanup (robust hover detection)"
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
  echo "2) Aktuellen Stage-Source + Update 144a nach GitHub pushen ..."
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

  echo "1.3) Update 144a auf Git-Source anwenden und Build pruefen ..."
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
fail() {
  log ""
  log "FEHLER: $*"
  log "Diagnose: $DIAG_LOG"
  if [ -f "$DIAG_LOG" ]; then
    echo '--- Letzte Diagnosezeilen ---'
    tail -n 100 "$DIAG_LOG"
    echo '--- Ende Diagnose ---'
  fi
  exit 1
}
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
  for candidate in \
      /home/mpwh/.nvm/versions/node/*/bin/node \
      /root/.nvm/versions/node/*/bin/node \
      /usr/local/bin/node /usr/bin/node; do
    [ -x "$candidate" ] || continue
    version="$($candidate -p 'process.versions.node' 2>/dev/null || true)"
    node_supported "$version" || continue
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best_v" "$version" | sort -V | tail -n 1)" = "$version" ]; then
      best="$candidate"; best_v="$version"
    fi
  done
  [ -n "$best" ] || fail "Kein kompatibles Node fuer Vite gefunden."
  export PATH="$(dirname "$best"):$PATH"
  hash -r 2>/dev/null || true
  log "Node: $best (v$best_v), npm: $(npm -v 2>/dev/null || echo fehlt)"
}

log "=== Update 144a / Tueren je Ebene, 3D Ebenenwahl und Wandflaechenbereinigung ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
log "Produktion und Datenbank bleiben unveraendert. Dreieckbereinigung aendert keine Wandkoordinaten."
for required in \
  frontend/src/App.tsx \
  frontend/src/styles.css \
  frontend/src/components/StromIcon.tsx \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/building/stair3d.ts \
  frontend/src/building/stairVisibility143.ts \
  frontend/src/building/neighborSnap143.ts \
  frontend/src/building/model.ts \
  frontend/src/building/solidGeometry.ts \
  frontend/public/strom-icons-v7.svg; do
  [ -f "$STAGE_DIR/$required" ] || fail "144 benoetigt den funktionierenden Stand 143b und Design-v7: $required fehlt."
done
# Distinguish a deployment that never happened from a stale browser cache.
grep -q 'STROM143_CROSS_LEVEL_SNAP' "$STAGE_DIR/frontend/src/App.tsx" || fail "143b/143a nicht in Stage-Source vorhanden. Bitte nicht auf Verdacht updaten."
grep -q 'STROM143B_STAIR_AUDIT' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "143b 3D-Treppendarstellung fehlt in Stage-Source."
grep -q 'id="layers-neighbor"' "$STAGE_DIR/frontend/public/strom-icons-v7.svg" || fail "Designvorlage v7 enthaelt kein layers-neighbor Symbol."
select_node

log "1) Stage-Sicherung erstellen ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Git-Arbeitskopie; kein Backup noetig."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Backup fehlgeschlagen."
fi

log "2) Isolierte Arbeitskopie vorbereiten ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Arbeitskopie fehlgeschlagen."
mkdir -p "$WORK_DIR/frontend/src/building" "$WORK_DIR/docs"
rm -rf "$WORK_DIR/frontend/node_modules"
DEPENDENCIES=""
for candidate in \
  "$STAGE_DIR/frontend/node_modules" \
  "$PROD_DIR/frontend/node_modules" \
  /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -d "$candidate/typescript" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ]; then
    DEPENDENCIES="$candidate"; break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "Frontend-Abhaengigkeiten fehlen (typescript/vite/three)."
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"

log "3) Ebenenfilter, Wanddetail-Ebenenwahl und deduplizierte Wanddreiecke einbauen ..."
cat > "$WORK_DIR/.strom144_meshCleanup.ts" <<'STROM144_CLEANUP_TS'
/**
 * STROM144_MESH_CLEANUP
 * A wall is one unioned solid. Remove exactly coincident triangles before they
 * reach the GPU. No vertices are moved, no mesh dimensions or holes are changed.
 */
export type WallTriangleStats144 = {
  positions: number[]
  inputTriangles: number
  removedDuplicates: number
  removedDegenerate: number
}

export function cleanWallSurface144(source: ArrayLike<number>): WallTriangleStats144 {
  if (source.length % 9 !== 0) throw new Error('Wand-Mesh hat keine vollstaendigen Dreiecke')
  const positions: number[] = []
  const seen = new Set<string>()
  let removedDuplicates = 0
  let removedDegenerate = 0
  const key = (x: number, y: number, z: number) => `${Math.round(x * 1000000)}:${Math.round(y * 1000000)}:${Math.round(z * 1000000)}`
  for (let i = 0; i < source.length; i += 9) {
    const a = [Number(source[i]), Number(source[i + 1]), Number(source[i + 2])]
    const b = [Number(source[i + 3]), Number(source[i + 4]), Number(source[i + 5])]
    const c = [Number(source[i + 6]), Number(source[i + 7]), Number(source[i + 8])]
    if (![...a, ...b, ...c].every(Number.isFinite)) { removedDegenerate++; continue }
    const ux=b[0]-a[0], uy=b[1]-a[1], uz=b[2]-a[2]
    const vx=c[0]-a[0], vy=c[1]-a[1], vz=c[2]-a[2]
    const area2=Math.hypot(uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx)
    if (area2 < 1e-11) { removedDegenerate++; continue }
    const signature = [key(...a as [number,number,number]), key(...b as [number,number,number]), key(...c as [number,number,number])].sort().join('|')
    if (seen.has(signature)) { removedDuplicates++; continue }
    seen.add(signature)
    positions.push(...a, ...b, ...c)
  }
  return { positions, inputTriangles: source.length / 9, removedDuplicates, removedDegenerate }
}
STROM144_CLEANUP_TS

cat > "$WORK_DIR/.strom144_patch.py" <<'STROM144_PATCH_PY'
from pathlib import Path
import os
root=Path(os.environ['STROM144_ROOT'])
app=root/'frontend/src/App.tsx'
scene=root/'frontend/src/components/Building3DWorkspace.tsx'
levels=root/'frontend/src/building/blueprintLevels.ts'
css=root/'frontend/src/styles.css'
mesh=root/'frontend/src/building/meshCleanup144.ts'
for p in (app,scene,levels,css,root/'frontend/src/building/solidGeometry.ts',root/'frontend/src/components/StromIcon.tsx'):
    if not p.is_file(): raise RuntimeError(f'144 required current source missing: {p}')
s=app.read_text('utf8')
c=scene.read_text('utf8')
l=levels.read_text('utf8')
style=css.read_text('utf8')
if 'STROM144_BLUEPRINT_DOOR_LEVEL' in s or 'STROM144_LEVEL_PICKER' in c or mesh.is_file():
    raise RuntimeError('144 appears to be already applied, abort to prevent duplicate changes')
if 'STROM143B_DIRECT_GHOST' not in s or 'STROM143B_STAIR_AUDIT' not in c:
    raise RuntimeError('144 requires successfully deployed 143b; 143b markers not found')

def one(string,old,new,description):
    n=string.count(old)
    if n!=1: raise RuntimeError(f'144 {description}: expected one anchor, found {n}')
    return string.replace(old,new,1)

# Blueprint: render only door objects that belong to the currently editable
# layer. The drawing of neighboring room outlines remains untouched.
# Pass active layer rooms to the old connection helper, so a door pair cannot
# accidentally use a wall from another level at the same 2D coordinates.
old='''            <BlueprintWallObjectConnections wallObjects={blueprintWallObjects} rooms={rooms} />'''
new='''            {/* STROM144_BLUEPRINT_DOOR_LEVEL: doors are local to the active level, not ghost levels. */}
            <BlueprintWallObjectConnections
              wallObjects={blueprintWallObjects.filter((item) => (roomLayerAssignments[item.roomId] ?? defaultLayerId) === activeLayerId)}
              rooms={activeLayerRooms}
            />'''
s=one(s,old,new,'Blueprint door floor filtering')

# Reuse the EXACT layer ID and height metadata already saved by Blueprint.
# Selecting a layer in 3D updates the same 'active' storage key, never a second
# copy of the building or an independent 3D-layer selector.
l += '''

/** STROM144_LEVEL_OPTIONS: shared Blueprint layer selector for Wanddetail. */
export type BlueprintLevelOption144 = { id: string; name: string; heightM: number }
export function listBlueprintLevelOptions144(floor: Floor, storage: KeyValueReader): BlueprintLevelOption144[] {
  const raw = readJson(storage, `strom.floorplan.layers.${floor.id}.list`)
  const fallback = clampHeight(Number(floor.heightM), 2.5)
  const result: BlueprintLevelOption144[] = []
  if (Array.isArray(raw)) for (const item of raw as unknown[]) {
    if (!item || typeof item !== 'object') continue
    const entry = item as Record<string, unknown>
    if (typeof entry.id !== 'string' || !entry.id || result.some((level) => level.id === entry.id)) continue
    result.push({
      id: entry.id,
      name: typeof entry.name === 'string' && entry.name.trim() ? entry.name : `Ebene ${result.length + 1}`,
      heightM: clampHeight(Number(entry.heightM), fallback),
    })
  }
  return result.length ? result : [{ id: DEFAULT_LAYER_ID, name: 'Ebene 1', heightM: fallback }]
}

export function selectBlueprintLevel144(
  floor: Floor, id: string, storage: KeyValueReader & { setItem(key: string, value: string): void },
): boolean {
  if (!listBlueprintLevelOptions144(floor, storage).some((level) => level.id === id)) return false
  try {
    storage.setItem(`strom.floorplan.layers.${floor.id}.active`, JSON.stringify(id))
    return true
  } catch { return false }
}
'''

c=one(c,
    "import { active3DFloor, readActiveBlueprintLevel } from '../building/blueprintLevels'",
    "import { active3DFloor, readActiveBlueprintLevel, listBlueprintLevelOptions144, selectBlueprintLevel144 } from '../building/blueprintLevels'",
    'shared layer adapter import')
# SVG icon from the already installed design system.
c=one(c,
    "import { buildSolidSurface, nearestRoomForWallHit } from '../building/solidGeometry'",
    "import { buildSolidSurface, nearestRoomForWallHit } from '../building/solidGeometry'\nimport { cleanWallSurface144 } from '../building/meshCleanup144'\nimport StromIcon from './StromIcon'",
    'mesh cleaner and design-v7 icon imports')

# Apply mesh cleaning ONLY to the already unified physical wall surface, not
# the selection overlay or floor/stair geometry.
start=c.index('function SolidWallMeshes(')
end=c.index('function DoorHandle(',start)
wall=c[start:end]
# STROM141_WALL_HOVER is a comment BEFORE function SolidWallMeshes.
# The old 144 patch mistakenly looked for that marker INSIDE this function,
# so every correctly installed 141a version was falsely rejected.
# Check the marker in the full scene and the working wall-hover behavior in
# the actual function body instead. Never replace a non-matching renderer.
if 'STROM141_WALL_HOVER' not in c or not all(token in wall for token in (
    'onPointerMove={hoverAt}',
    'onPointerOut={() => setHovered(null)}',
    'onSelectWall',
    'geometry={geometry}',
    'new THREE.Float32BufferAttribute(surface.positions, 3)',
    'side={THREE.DoubleSide}',
)):
    raise RuntimeError('144a: working 141a wall hover/selection structure not found; no renderer changed')
wall=one(wall,
    'new THREE.Float32BufferAttribute(surface.positions, 3)',
    'new THREE.Float32BufferAttribute(cleanWallSurface144(surface.positions).positions, 3)',
    'unified wall duplicate triangle removal')
# The translucent DoubleSide material in Three.js renders both sides. This
# can make parts of thick walls appear darker although there is only one wall.
# Use front faces for translucent walls, preserve full opaque rendering and hover.
wall=one(wall,
    '''          side={THREE.DoubleSide}
        />''',
    '''          side={transparent ? THREE.FrontSide : THREE.DoubleSide}
          forceSinglePass={transparent}
        />''',
    'transparent wall double-pass reduction')
c=c[:start]+wall+c[end:]

# The 3D scene already has activeLevel, levelRevision and a same-tab custom
# storage event. Use the same reactive revision and do NOT remount Canvas.
active_line='''  const activeLevel = useMemo(() => readActiveBlueprintLevel(floor, rooms, window.localStorage), [floor, rooms, levelRevision])'''
addition='''  // STROM144_LEVEL_PICKER: identical layer list, names, heights and active ID as Blueprint.
  const levelOptions144 = useMemo(() => listBlueprintLevelOptions144(floor, window.localStorage), [floor, levelRevision])
  function chooseWallDetailLevel144(id: string) {
    if (!selectBlueprintLevel144(floor, id, window.localStorage)) {
      setMessage('Ebene konnte nicht ausgewaehlt werden.')
      return
    }
    onSelectRoom('')
    onSelectWall?.(null)
    setSelectedDoorId('')
    window.dispatchEvent(new Event('strom:blueprint-levels-changed'))
  }
'''
c=one(c,active_line,active_line+'\n'+addition,'3D shared layer options & onChange')
# Only Wanddetail gets the floor selector, 3D Haus toolbar is unchanged.
level_label='''        <span>Etage: {activeLevel.name} · {Math.round(activeLevel.heightM * 1000)} mm</span>'''
level_picker='''        {variant === 'wall' ? (
          <label className="building3d-level-picker144" title="Blueprint-Ebene im Wanddetail waehlen; verwendet dieselben gespeicherten Ebenen">
            <StromIcon name="layers-current" size={20} title="Ebenen aus Blueprint" />
            <span>Ebene</span>
            <select aria-label="Aktive Blueprint-Ebene im Wanddetail" value={activeLevel.id}
              onChange={(event) => chooseWallDetailLevel144(event.currentTarget.value)}>
              {levelOptions144.map((level) => (
                <option key={level.id} value={level.id}>{level.name} · {Math.round(level.heightM * 1000)} mm</option>
              ))}
            </select>
          </label>
        ) : (
          <span>Etage: {activeLevel.name} · {Math.round(activeLevel.heightM * 1000)} mm</span>
        )}'''
c=one(c,level_label,level_picker,'Wanddetail selector in existing toolbar')

# A tiny set of styles in Wanddetail only; the Blueprint layer panel is left intact.
style+='''
/* STROM144: shared Blueprint layer selector in the real 3D Wanddetail. */
.building3d-level-picker144 { display: inline-flex; align-items: center; gap: 7px; padding: 3px 8px; border: 1px solid #b7c5d9; border-radius: 7px; background: #fff; white-space: nowrap; }
.building3d-level-picker144 select { max-width: 240px; min-width: 125px; padding: 5px 7px; border: 1px solid #94a3b8; border-radius: 5px; background: #fff; color: #1e293b; font: inherit; }
.building3d-level-picker144 .strom-ui-icon { width: 20px; height: 20px; flex: none; }
.building3d-toolbar .building3d-level-picker144 span { margin-right: 0; color: #334155; }
'''

mesh.write_text(Path(os.environ['STROM144_MESH']).read_text('utf8'),'utf8')
app.write_text(s,'utf8')
scene.write_text(c,'utf8')
levels.write_text(l,'utf8')
css.write_text(style,'utf8')
print('144a: Blueprint doors filtered by active layer; Wanddetail floor selector shares Blueprint storage; physical wall triangles deduplicated, transparent front faces render single pass.')
STROM144_PATCH_PY

[ -s "$WORK_DIR/.strom144_meshCleanup.ts" ] || fail "144: eingebettetes Geometriemodul fehlt."
[ -s "$WORK_DIR/.strom144_patch.py" ] || fail "144: eingebetteter Patch fehlt."
STROM144_ROOT="$WORK_DIR" STROM144_MESH="$WORK_DIR/.strom144_meshCleanup.ts" \
  python3 "$WORK_DIR/.strom144_patch.py" >>"$DIAG_LOG" 2>&1 || fail "Quellpatch 144 fehlgeschlagen. Kein Git-Push/Stage-Deployment."
rm -f "$WORK_DIR/.strom144_meshCleanup.ts" "$WORK_DIR/.strom144_patch.py"

cat > "$WORK_DIR/docs/STROM_UPDATE_144A.md" <<'STROM144_DOC'
# STROM 144a - Blueprint door level, Wanddetail floor selection, triangle cleanup

- Blueprint: a door connection only uses wall objects belonging to the active Blueprint layer; ghost layers keep their room outlines but no other-level doors.
- Wanddetail: the existing 3D toolbar exposes a dropdown with the EXACT saved Blueprint levels and heights. Changing the level writes the same active-layer storage key and dispatches the pre-existing event.
- The complete wall geometry and doors/windows are still generated by 139 buildSolidSurface, unchanged. The 144 mesh cleaner drops only identical or degenerate wall triangles with a sub-millimeter hash. Transparency uses a single front-side pass to reduce apparent overlapping front/back surfaces; opaque surfaces and hover selection remain unchanged.
- No database migration, no change to stair geometry, snap behavior, Blueprint 2D drawing and 3D Haus controls, no promotion to production.
- Update 144a fixes a false anchor check: the 141a hover marker is outside SolidWallMeshes. The renderer is still matched structurally before modification.
- Important: layer metadata is still browser-local storage and cannot automatically synchronize between devices yet.
STROM144_DOC

log "4) TypeScript/Vite-Build in isolierter Arbeitskopie pruefen ..."
( cd "$WORK_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 \
  || fail "Frontend-Build fehlgeschlagen. Kein Git-Push/Stage-Deployment."

log "4.1) Ebenen-, Tuer- und 3D-Dreieck-Regressionstests ..."
export STROM144_ROOT="$WORK_DIR"
export STROM144_TYPESCRIPT="$DEPENDENCIES/typescript"
node <<'STROM144_TEST_JS' >>"$DIAG_LOG" 2>&1 || fail "Regressionspruefung 144 fehlgeschlagen. Kein Git-Push/Stage-Deployment."
'use strict'
const fs=require('fs'),ts=require(process.env.STROM144_TYPESCRIPT), root=process.env.STROM144_ROOT
function mod(file,requireMap={}){
 const input=fs.readFileSync(file,'utf8')
 const c=ts.transpileModule(input,{fileName:file,reportDiagnostics:true,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}})
 if(c.diagnostics?.some(d=>d.category===ts.DiagnosticCategory.Error))throw Error('TS syntax failure '+file)
 const x={exports:{}}
 new Function('module','exports','require',c.outputText)(x,x.exports,ref=>requireMap[ref] || {})
 return x.exports
}
const geo=mod(root+'/frontend/src/building/meshCleanup144.ts')
// Verify duplicates with either triangle orientation, plus a distinct face.
// Reversing the complete list of coordinates is NOT the same as reversing
// its winding: express all three vertex groups explicitly.
const tri=[0,0,0,1,0,0,0,1,0]
const opposite=[0,0,0,0,1,0,1,0,0]
const other=[0,0,0,0,0,1,1,0,0]
const degenerate=[0,0,0,0,0,0,0,0,0]
const c=geo.cleanWallSurface144([...tri,...tri,...opposite,...other,...degenerate])
if(c.inputTriangles!==5||c.removedDuplicates!==2||c.removedDegenerate!==1||c.positions.length!==18)throw Error('mesh cleaner: duplicate winding / degeneracy regression')
const room=(id)=>({id,vertices:[{x:0,y:0},{x:1,y:0},{x:1,y:1},{x:0,y:1}]})
const floor={id:'base',name:'Haus',heightM:2.6,elevationM:0}
const storageMap={
 'strom.floorplan.layers.base.list':JSON.stringify([{id:'layer-main',name:'EG',heightM:2.55},{id:'layer-2',name:'OG',heightM:2.91}]),
 'strom.floorplan.layers.base.active':JSON.stringify('layer-main'),
 'strom.floorplan.layers.base.roomAssignments':JSON.stringify({roomEG:'layer-main',roomOG:'layer-2'})
}
const st={getItem:k=>storageMap[k]||null,setItem:(k,v)=>storageMap[k]=v}
const levels=mod(root+'/frontend/src/building/blueprintLevels.ts')
const opts=levels.listBlueprintLevelOptions144(floor,st)
if(opts.length!==2||opts[1].heightM!==2.91||levels.readActiveBlueprintLevel(floor,[room('roomEG'),room('roomOG')],st).rooms.length!==1)throw Error('blueprint layer list incorrect')
if(!levels.selectBlueprintLevel144(floor,'layer-2',st))throw Error('cannot select existing layer')
const active=levels.readActiveBlueprintLevel(floor,[room('roomEG'),room('roomOG')],st)
if(active.id!=='layer-2'||active.rooms[0]?.id!=='roomOG')throw Error('Wanddetail and Blueprint do not share active layer')
if(levels.selectBlueprintLevel144(floor,'unknown-layer',st))throw Error('invalid layer selection allowed')
const app=fs.readFileSync(root+'/frontend/src/App.tsx','utf8')
const scene=fs.readFileSync(root+'/frontend/src/components/Building3DWorkspace.tsx','utf8')
if(!app.includes('STROM144_BLUEPRINT_DOOR_LEVEL')||!app.includes('rooms={activeLayerRooms}')||!app.includes('(roomLayerAssignments[item.roomId] ?? defaultLayerId) === activeLayerId'))throw Error('Blueprint doors not restricted to current level')
if(!scene.includes('STROM144_LEVEL_PICKER')||!scene.includes('variant === \'wall\' ? (')||!scene.includes('selectBlueprintLevel144')||!scene.includes('<StairSolid'))throw Error('wall-level picker broke existing stair scene')
if(!scene.includes('cleanWallSurface144(surface.positions)')||!scene.includes('forceSinglePass={transparent}'))throw Error('wall renderer not using safe surface cleanup')
console.log('PASS: doors confined to Blueprint layer; Wanddetail/Blueprint active-layer sync; duplicate mesh triangle elimination; existing 3D stair geometry still present.')
STROM144_TEST_JS

log "5) Geprueften Quellstand nach Stage uebernehmen ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage-Quellabgleich fehlgeschlagen. Backup: $BACKUP_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: TypeScript/Vite und Tests bestanden. Kein Web-Deploy."
  exit 0
fi

log "6) Stage-Frontend bauen und nach /strom-test/ deployen ..."
( cd "$STAGE_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 \
  || fail "Stage-Build fehlgeschlagen. Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Stage-Buildausgabe fehlt."
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 \
  || fail "Web-Deployment fehlgeschlagen. Backup: $BACKUP_DIR"

log ""
log "Update 144a erfolgreich auf Stage bereitgestellt: https://home.moja.de/strom-test/"
log "  - Blueprint zeigt keine fremden Tueren aus anderen Ebenen."
log "  - Wanddetail kann direkt zwischen vorhandenen Blueprint-Ebenen wechseln."
log "  - 3D-Wandmesh entfernt redundante Dreiecke; Transparenz rendert einfacher."
log "  - Treppen, Snapping, Wand-Popup und Produktion bleiben erhalten."
log "Backup: $BACKUP_DIR"
