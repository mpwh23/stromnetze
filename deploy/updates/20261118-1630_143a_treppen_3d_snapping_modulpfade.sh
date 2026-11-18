#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-1630_143a_treppen_3d_snapping_modulpfade"
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
COMMIT_MESSAGE="Update 143a: Fix bundled 3D staircase and cross-level snapping module paths"
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
  echo "2) Aktuellen Stage-Source + Update 143a nach GitHub pushen ..."
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

  echo "1.3) Update 143a auf Git-Source anwenden und Build pruefen ..."
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

log "=== Update 143a / 3D-Treppen und optionales Ebenen-Snapping ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
log "Bewaehrte Volumenwaende, Wandbearbeitung, Kameras und Blueprint-Layer werden beibehalten."
for required in \
  frontend/src/building/stair3d.ts \
  frontend/src/building/blueprintLevels.ts \
  frontend/src/building/solidGeometry.ts \
  frontend/src/building/wallHoverGeometry.ts \
  frontend/src/building/wallHitSelection.ts \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/StromIcon.tsx \
  frontend/src/App.tsx \
  frontend/src/styles.css; do
  [ -f "$STAGE_DIR/$required" ] || fail "Erwartete Stage-Datei fehlt: $required (Update 142a/136 erforderlich)."
done
select_node

log "1) Stage-Sicherung erstellen ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolierte Git-Arbeitskopie, keine Stage-Sicherung erforderlich."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage-Backup fehlgeschlagen."
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
[ -n "$DEPENDENCIES" ] || fail "Frontend-Abhaengigkeiten typescript/vite/three fehlen."
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"

log "3) 3D-Treppen aus gespeicherten Ebenen lesen und Nachbarebenen-Snapping integrieren ..."
cat > "$WORK_DIR/.strom143_neighborSnap143.ts" <<'STROM143_NEIGHBOR_TS'
import type { PointM } from '../types'

/** Read-only anchors (metres) from rooms on visible Blueprint layers. */
export type NeighborSnapTarget = { vertices: PointM[] }
export type SnapHandle143 = 'left' | 'right' | 'top' | 'bottom'
const LIMIT = 0.18
const rounded = (value: number) => Math.round(value * 1000) / 1000
function bounds(vertices: PointM[]) {
  if (!vertices.length) return null
  return {
    minX: Math.min(...vertices.map((p) => p.x)), maxX: Math.max(...vertices.map((p) => p.x)),
    minY: Math.min(...vertices.map((p) => p.y)), maxY: Math.max(...vertices.map((p) => p.y)),
  }
}
function nearest(value: number, candidates: number[]): number {
  let best = value, score = LIMIT
  for (const target of candidates) {
    const error = Math.abs(target - value)
    if (error < score - 1e-8) { score = error; best = target }
  }
  return rounded(best)
}
function segmentProjection(point: PointM, a: PointM, b: PointM) {
  const dx = b.x-a.x, dy = b.y-a.y
  const length = dx*dx + dy*dy
  const t = length > 1e-12 ? Math.max(0, Math.min(1, ((point.x-a.x)*dx+(point.y-a.y)*dy)/length)) : 0
  return { x: a.x + t*dx, y: a.y + t*dy }
}

/**
 * Point/vertex creation: snap to nearby exact corners or polygon edges,
 * including oblique walls. No snap across an unrelated distant room.
 */
export function snapPointToVisibleRooms143(point: PointM, targets: NeighborSnapTarget[], wallM: number): PointM {
  if (!targets.length) return point
  let closest = point, distance = LIMIT
  for (const target of targets) {
    for (let i=0; i<target.vertices.length; i++) {
      const a=target.vertices[i], b=target.vertices[(i+1)%target.vertices.length]
      for (const p of [a, segmentProjection(point,a,b)]) {
        const d=Math.hypot(p.x-point.x,p.y-point.y)
        if (d < distance - 1e-8) { closest=p; distance=d }
      }
    }
  }
  if (closest !== point) return { x: rounded(closest.x), y: rounded(closest.y) }
  // The user-specified W is an optional wall-to-wall clearance, not a global grid.
  const clearance = Math.min(0.6, Math.max(0, wallM))
  if (clearance < 0.001) return point
  let best=point, score=LIMIT
  for (const target of targets) {
    for (let i=0; i<target.vertices.length; i++) {
      const a=target.vertices[i], b=target.vertices[(i+1)%target.vertices.length]
      const dx=b.x-a.x, dy=b.y-a.y, length=Math.hypot(dx,dy)
      if (length < 1e-8) continue
      const normal={x:-dy/length,y:dx/length}
      for (const sign of [-1,1]) {
        const p=segmentProjection(point,{x:a.x+sign*normal.x*clearance,y:a.y+sign*normal.y*clearance},{x:b.x+sign*normal.x*clearance,y:b.y+sign*normal.y*clearance})
        const d=Math.hypot(p.x-point.x,p.y-point.y)
        if (d<score-1e-8) {score=d;best=p}
      }
    }
  }
  return best===point ? point : {x:rounded(best.x),y:rounded(best.y)}
}

/** Snap only the dragged rectangle edge; leave its opposite edge untouched. */
export function snapRectangleHandle143(vertices: PointM[], handle: SnapHandle143, targets: NeighborSnapTarget[], wallM: number): PointM[] {
  const b = bounds(vertices)
  if (!b || !targets.length) return vertices
  const vertical = handle === 'left' || handle === 'right'
  const current = handle === 'left' ? b.minX : handle === 'right' ? b.maxX : handle === 'top' ? b.minY : b.maxY
  const wall = Math.max(0, Math.min(0.6,wallM))
  const candidates: number[] = []
  for (const target of targets) {
    const other=bounds(target.vertices)
    if (!other) continue
    // Do not snap to a room on the far side of the canvas.
    const overlap = vertical
      ? b.minY <= other.maxY + LIMIT && b.maxY >= other.minY - LIMIT
      : b.minX <= other.maxX + LIMIT && b.maxX >= other.minX - LIMIT
    if (!overlap) continue
    const coords = vertical ? [other.minX,other.maxX] : [other.minY,other.maxY]
    for (const value of coords) candidates.push(value, value-wall, value+wall)
    for (const p of target.vertices) candidates.push(vertical ? p.x : p.y)
  }
  const snapped = nearest(current,candidates)
  if (Math.abs(snapped-current) < 0.0005) return vertices
  const next = { ...b }
  if (handle==='left') next.minX=Math.min(next.maxX-0.1,snapped)
  else if (handle==='right') next.maxX=Math.max(next.minX+0.1,snapped)
  else if (handle==='top') next.minY=Math.min(next.maxY-0.1,snapped)
  else next.maxY=Math.max(next.minY+0.1,snapped)
  return [
    {x:rounded(next.minX),y:rounded(next.minY)}, {x:rounded(next.maxX),y:rounded(next.minY)},
    {x:rounded(next.maxX),y:rounded(next.maxY)}, {x:rounded(next.minX),y:rounded(next.maxY)},
  ]
}
STROM143_NEIGHBOR_TS
cat > "$WORK_DIR/.strom143_stairVisibility143.ts" <<'STROM143_STAIRS_TS'
import type { Floor, Room } from '../types'
import type { BlueprintLevelView, KeyValueReader } from './blueprintLevels'
import { buildStair3DSurfaces, type Stair3DSurface } from './stair3d'

export type PlacedStairSurface143 = Stair3DSurface & {
  /** Offset relative to the currently rendered level, applied by the 3D group. */
  levelOffsetM: number
  levelId: string
}
export type StairSceneData143 = { surfaces: PlacedStairSurface143[]; savedLayouts: number; activeLayouts: number }

function readJson(storage: KeyValueReader, key: string): unknown {
  try { const raw = storage.getItem(key); return raw ? JSON.parse(raw) as unknown : null } catch { return null }
}
const numeric = (value: unknown, fallback: number) => typeof value === 'number' && Number.isFinite(value) ? value : fallback
const heightM = (value: unknown, fallback: number) => {
  const n = numeric(value, NaN)
  return Number.isFinite(n) && n >= 0.1 && n <= 10 ? n : fallback
}

/**
 * 143: staircase layouts live under the staircase ROOM id, not the active 3D
 * filtered room list. Enumerate every existing Blueprint level and preserve
 * its physical elevation, so stairs assigned to other levels are not lost.
 * This is a read-only adapter; no migration or localStorage writes.
 */
export function build3DStairsAcrossLevels143(floor: Floor, rooms: Room[], activeLevel: BlueprintLevelView, storage: KeyValueReader): StairSceneData143 {
  const prefix = `strom.floorplan.layers.${floor.id}.`
  const rawLayers = readJson(storage, prefix + 'list')
  const fallback = heightM(floor.heightM, 2.5)
  const levels = Array.isArray(rawLayers)
    ? rawLayers.flatMap((item: unknown) => {
      if (!item || typeof item !== 'object') return []
      const entry = item as Record<string, unknown>
      if (typeof entry.id !== 'string' || !entry.id) return []
      return [{ id: entry.id, heightM: heightM(entry.heightM, fallback) }]
    }) : []
  if (!levels.length) levels.push({ id: 'layer-main', heightM: fallback })
  const roomAssignmentsRaw = readJson(storage, prefix + 'roomAssignments')
  const assignments = roomAssignmentsRaw && typeof roomAssignmentsRaw === 'object' && !Array.isArray(roomAssignmentsRaw)
    ? roomAssignmentsRaw as Record<string, unknown> : {}
  const activeRoomIds = new Set(activeLevel.rooms.map((room) => room.id))
  const groups = new Map(levels.map((level) => [level.id, [] as Room[]]))
  let savedLayouts = 0
  let activeLayouts = 0
  for (const room of rooms) {
    const layout = readJson(storage, `strom-stair-layout:${room.id}`)
    if (!Array.isArray(layout) || !layout.some((item) => item && typeof item === 'object' && ['stair', 'turn', 'landing'].includes((item as Record<string, unknown>).kind as string))) continue
    savedLayouts++
    if (activeRoomIds.has(room.id)) activeLayouts++
    const levelId = typeof assignments[room.id] === 'string' && groups.has(assignments[room.id] as string)
      ? assignments[room.id] as string : activeRoomIds.has(room.id) ? activeLevel.id : 'layer-main'
    const group = groups.get(levelId) ?? groups.get(levels[0].id)
    group?.push(room)
  }
  const surfaces: PlacedStairSurface143[] = []
  let levelBottom = numeric(floor.elevationM, 0)
  for (const level of levels) {
    const offset = Math.round((levelBottom - activeLevel.elevationM) * 1000) / 1000
    const levelRooms = groups.get(level.id) ?? []
    for (const surface of buildStair3DSurfaces(levelRooms, level.heightM, storage)) {
      surfaces.push({ ...surface, levelId: level.id, levelOffsetM: offset })
    }
    levelBottom += level.heightM
  }
  return { surfaces, savedLayouts, activeLayouts }
}
STROM143_STAIRS_TS
cat > "$WORK_DIR/.strom143_patch.py" <<'STROM143_PY_PATCH'
from pathlib import Path
import os, re
root=Path(os.environ['STROM143_ROOT'])
modules=Path(os.environ['STROM143_MODULES'])
# Ensure bundled helper names agree with the shell heredoc output names.
for file in ('.strom143_neighborSnap143.ts', '.strom143_stairVisibility143.ts'):
    if not (modules / file).is_file():
        raise RuntimeError(f'143a: embedded helper file missing: {modules / file}')
app=root/'frontend/src/App.tsx'
scene=root/'frontend/src/components/Building3DWorkspace.tsx'
css=root/'frontend/src/styles.css'
for path in (app, scene, css, root/'frontend/src/building/stair3d.ts', root/'frontend/src/building/blueprintLevels.ts'):
    assert path.is_file(), '143: requires current 142a source: '+str(path)
s=app.read_text(encoding='utf8'); c=scene.read_text(encoding='utf8'); styles=css.read_text(encoding='utf8')
assert 'STROM142_STAIRS3D' in c and 'STROM142_BLUEPRINT_LEVELS' in s, '143: 142a missing'
assert 'STROM143_CROSS_LEVEL_SNAP' not in s and 'STROM143_STAIRS_FIX' not in c, '143 already installed'
assert 'StromIcon' in s and 'STROM141_WALL_HOVER' in c, '143 requires SVG icons and hover wall-editor'

def one(text, old, new, reason):
    count = text.count(old)
    if count != 1: raise RuntimeError(f'143: {reason}: expected exactly one anchor, got {count}')
    return text.replace(old,new,1)

# Add pure helper imports only to App/3D; existing 139 solid geometry unmodified.
s=one(s, "import StromIcon from './components/StromIcon'", "import StromIcon from './components/StromIcon'\nimport { snapPointToVisibleRooms143, snapRectangleHandle143 } from './building/neighborSnap143'", 'Blueprint import')
s=one(s,"  const [snapEnabled, setSnapEnabled] = useState(true)", "  const [snapEnabled, setSnapEnabled] = useState(true)\n  // STROM143_CROSS_LEVEL_SNAP: opt-in; keep the original snapping as the default.\n  const [snapVisibleNeighbors143, setSnapVisibleNeighbors143] = useState<boolean>(() => safeReadJson<boolean>(layerStorageKey(floor.id, 'snapVisibleNeighbors143'), false))", 'state in blueprint editor')

# Preserve current tabs and stair editor storage, inform mounted 3D on same-tab updates.
s=one(s, "function writeStairLayoutElements(roomId: string, elements: StairEditorElement[]) {", "function writeStairLayoutElements(roomId: string, elements: StairEditorElement[]) {", 'stair layout persistence anchor')
s=one(s, "    window.localStorage.setItem(stairLayoutStorageKey(roomId), JSON.stringify(elements))", "    window.localStorage.setItem(stairLayoutStorageKey(roomId), JSON.stringify(elements))\n    window.dispatchEvent(new Event('strom:blueprint-levels-changed'))", 'notify stair layout edits')
s=one(s, "    window.localStorage.setItem(stairEdgeAssignmentsStorageKey(roomId), JSON.stringify(assignments))", "    window.localStorage.setItem(stairEdgeAssignmentsStorageKey(roomId), JSON.stringify(assignments))\n    window.dispatchEvent(new Event('strom:blueprint-levels-changed'))", 'notify stair edge edits')

# Restrict subsequent edits to FloorplanEditor, not similarly named handlers in classic Wanddetail.
start=s.find('function FloorplanEditor(')
end=s.find('type StairEditorElementKind', start)
if start<0 or end<start: raise RuntimeError('143: FloorplanEditor code range not recognized')
e=s[start:end]

persistence='''  useEffect(() => {
    localStorage.setItem(layerStorageKey(floor.id, 'roomAssignments'), JSON.stringify(roomLayerAssignments))
  }, [floor.id, roomLayerAssignments])'''
persistence_new=persistence+'''

  useEffect(() => {
    // The toggle is independent of the main snap switch, and per-floor persistent.
    try { localStorage.setItem(layerStorageKey(floor.id, 'snapVisibleNeighbors143'), JSON.stringify(snapVisibleNeighbors143)) }
    catch { /* private browsing may disable localStorage */ }
  }, [floor.id, snapVisibleNeighbors143])

  useEffect(() => {
    // "storage" does not fire in the same tab: keep 3D in sync via explicit event.
    window.dispatchEvent(new Event('strom:blueprint-levels-changed'))
  }, [floor.id, layers, activeLayerId, roomLayerAssignments])'''
e=one(e,persistence,persistence_new,'layer assignments effect and same-tab sync')

# Read only CURRENTLY VISIBLE ghost levels, never hidden levels or their geometry.
active_anchor='''  const activeLayerRooms = useMemo(
    () => rooms.filter((room) => (roomLayerAssignments[room.id] ?? defaultLayerId) === activeLayerId),
    [rooms, roomLayerAssignments, activeLayerId],
  )'''
helper='''

  function visibleNeighborSnapTargets143(excludeIds: string[] = []) {
    if (!snapEnabled || !snapVisibleNeighbors143) return []
    const excluded = new Set(excludeIds)
    return rooms
      .filter((room) => !excluded.has(room.id))
      .filter((room) => {
        const levelId = roomLayerAssignments[room.id] ?? defaultLayerId
        const state = renderStateForLayer(levelId)
        return levelId !== activeLayerId && state.visible && state.ghost
      })
      .map((room) => ({ room, vertices: room.vertices }))
  }

  function allSnapTargets143(excludeIds: string[] = []) {
    const excluded = new Set(excludeIds)
    const ownLayer = rooms.filter((room) => !excluded.has(room.id) && (roomLayerAssignments[room.id] ?? defaultLayerId) === activeLayerId)
      .map((room) => ({ room, vertices: room.vertices }))
    return [...ownLayer, ...visibleNeighborSnapTargets143(excludeIds)]
  }

  function pointSnap143(point: PointM): PointM {
    if (!snapEnabled || !snapVisibleNeighbors143) return point
    const targets = allSnapTargets143()
    return snapPointToVisibleRooms143(point, targets, snapWallThicknessM)
  }
'''
e=one(e,active_anchor,active_anchor+helper,'active layer target selection')

# Blueprinted UI uses the installed 136 SVG sprite; no new font-based icon.
toolbar_needle='''          <label className="snap-control" title="Objekte beim Verschieben andocken">'''
ui='''          <label className="snap-control strom-neighbor-snap143" title="An sichtbaren Nachbarebenen einrasten (Ein/Aus)" data-tooltip="Snapping an sichtbaren Nachbarebenen" aria-label="Snapping an sichtbaren Nachbarebenen aktivieren oder deaktivieren">
            <input type="checkbox" checked={snapVisibleNeighbors143} onChange={(event) => setSnapVisibleNeighbors143(event.target.checked)} />
            <StromIcon name="layers-neighbor" title="Einrasten an sichtbaren Nachbarebenen" />
            <span>Nachbarebenen</span>
          </label>
'''
e=one(e,toolbar_needle,ui+toolbar_needle,'neighbor snap toggle in SVG blueprint toolbar')

# 1. Translate a single room: original same-layer snapping remains; append visible ghosts when enabled.
for dragged in ('roomDrag.roomId','rectHandleDrag.roomId'):
    old=f"rooms.filter((room) => room.id !== {dragged} && (roomLayerAssignments[room.id] ?? defaultLayerId) === activeLayerId).map((room) => ({{ room, vertices: room.vertices }}))"
    replacement=f"allSnapTargets143([{dragged}])"
    e=one(e,old,replacement,f'snap targets for {dragged}')

# 2. Resize: the earlier function translated the whole rectangle, which moves its opposite side.
# Keep the original behaviour when the new switch is OFF; when ON, snap the moved side only.
original_rect='''      if (snapEnabled) {
        nextVertices = snapVerticesToRooms(
          nextVertices,
          allSnapTargets143([rectHandleDrag.roomId]),
          snapWallThicknessM,
          null,
        )
      }'''
modified_rect='''      if (snapEnabled) {
        if (snapVisibleNeighbors143) {
          nextVertices = snapRectangleHandle143(nextVertices, rectHandleDrag.handle, allSnapTargets143([rectHandleDrag.roomId]), snapWallThicknessM)
        } else {
          nextVertices = snapVerticesToRooms(nextVertices, allSnapTargets143([rectHandleDrag.roomId]), snapWallThicknessM, null)
        }
      }'''
e=one(e,original_rect,modified_rect,'rectangle resize moving edge')

# 3. Multi-select / outer-wall group movement: adjust the *entire* group consistently.
old_group='''      groupDrag.originals.forEach(({ room, vertices }) => {
        nextPreview[room.id] = vertices.map((vertex) => clampPoint({ x: round3(vertex.x + drag.dx), y: round3(vertex.y + drag.dy) }))
      })
      setGroupPreview(nextPreview)'''
new_group='''      groupDrag.originals.forEach(({ room, vertices }) => {
        nextPreview[room.id] = vertices.map((vertex) => clampPoint({ x: round3(vertex.x + drag.dx), y: round3(vertex.y + drag.dy) }))
      })
      if (snapEnabled && snapVisibleNeighbors143) {
        const groupIds = groupDrag.originals.map(({ room }) => room.id)
        const vertices = Object.values(nextPreview).flat()
        const aligned = snapVerticesToRooms(vertices, allSnapTargets143(groupIds), snapWallThicknessM, drag.axis)
        if (vertices.length && aligned.length) {
          const dx = aligned[0].x - vertices[0].x, dy = aligned[0].y - vertices[0].y
          if (Math.abs(dx) > 0.0001 || Math.abs(dy) > 0.0001) {
            for (const roomId of groupIds) nextPreview[roomId] = nextPreview[roomId].map((p) => clampPoint({ x: round3(p.x + dx), y: round3(p.y + dy) }))
          }
        }
      }
      setGroupPreview(nextPreview)'''
e=one(e,old_group,new_group,'group drag')

# 4. Polygon edge and vertex drags: only extend to neighbors when switch is ON.
old_edge='''      const nextVertices = polygonEdgeDrag.originalVertices.map((vertex, index) => {
        const moves = index === polygonEdgeDrag.indexA || index === polygonEdgeDrag.indexB
        return moves ? clampPoint({ x: round2(vertex.x + drag.dx), y: round2(vertex.y + drag.dy) }) : vertex
      })
      setRoomPreview({ roomId: polygonEdgeDrag.roomId, vertices: nextVertices })'''
new_edge='''      let nextVertices = polygonEdgeDrag.originalVertices.map((vertex, index) => {
        const moves = index === polygonEdgeDrag.indexA || index === polygonEdgeDrag.indexB
        return moves ? clampPoint({ x: round2(vertex.x + drag.dx), y: round2(vertex.y + drag.dy) }) : vertex
      })
      if (snapEnabled && snapVisibleNeighbors143) {
        const before = nextVertices[polygonEdgeDrag.indexA]
        const aligned = snapPointToVisibleRooms143(before, allSnapTargets143([polygonEdgeDrag.roomId]), snapWallThicknessM)
        nextVertices = nextVertices.map((p, i) => i === polygonEdgeDrag.indexA || i === polygonEdgeDrag.indexB
          ? clampPoint({ x: round3(p.x + aligned.x - before.x), y: round3(p.y + aligned.y - before.y) }) : p)
      }
      setRoomPreview({ roomId: polygonEdgeDrag.roomId, vertices: nextVertices })'''
e=one(e,old_edge,new_edge,'polygon edge drag')
old_vertex='''      const nextVertices = room.vertices.map((vertex, index) => index === vertexDrag.index ? point : vertex)
      setRoomPreview({ roomId: vertexDrag.roomId, vertices: nextVertices })'''
new_vertex='''      const alignedPoint = snapEnabled && snapVisibleNeighbors143
        ? snapPointToVisibleRooms143(point, allSnapTargets143([vertexDrag.roomId]), snapWallThicknessM) : point
      const nextVertices = room.vertices.map((vertex, index) => index === vertexDrag.index ? alignedPoint : vertex)
      setRoomPreview({ roomId: vertexDrag.roomId, vertices: nextVertices })'''
e=one(e,old_vertex,new_vertex,'polygon vertex drag')

# 5. Draw rectangles/new rooms: snap displayed preview AND stored last point.
start_fn=e.find('  function handleCanvasClick(event: ReactMouseEvent<SVGSVGElement>) {')
end_fn=e.find('  function handleCanvasDoubleClick(',start_fn)
if start_fn<0 or end_fn<0: raise RuntimeError('143: canvas click handler not found')
click=e[start_fn:end_fn]
click=one(click,'''    if (tool === 'rectangle' || tool === 'outerwall') {
      if (!rectDraft) {
        setRectDraft({ start: point, end: point })
      } else {
        const nextRect = normalizeRect(rectDraft.start, point)''','''    if (tool === 'rectangle' || tool === 'outerwall') {
      const snappedPoint = pointSnap143(point)
      if (!rectDraft) {
        setRectDraft({ start: snappedPoint, end: snappedPoint })
      } else {
        const nextRect = normalizeRect(rectDraft.start, snappedPoint)''','rectangle creation click')
click=one(click,'''      const rawPoint = point''','''      const rawPoint = event.shiftKey ? point : pointSnap143(point)''','polygon new corner')
e=e[:start_fn]+click+e[end_fn:]

# Live rectangle preview; ghost lines remain non-interactive, only coordinates are read.
e=one(e,'''    if ((tool === 'rectangle' || tool === 'outerwall') && rectDraft) {
      setRectDraft({ ...rectDraft, end: point })''','''    if ((tool === 'rectangle' || tool === 'outerwall') && rectDraft) {
      setRectDraft({ ...rectDraft, end: pointSnap143(point) })''','rectangle preview while drawing')

# Show polygon preview snaps too when allowed; preserve Shift 45-degree constraint.
e=one(e,'''    setCursorPoint(point)
    if (!point) return''','''    setCursorPoint(point && tool === 'polygon' && !event.shiftKey ? pointSnap143(point) : point)
    if (!point) return''','polygon draft hover')

s=s[:start]+e+s[end:]

# Scene: recover saved staircase layouts across the stored layers, not only
# activeLevel.rooms, and place them at their physical elevations.
c=one(c, "import { buildStair3DSurfaces, type Stair3DSurface } from '../building/stair3d'",
    "// STROM143_STAIRS_FIX: share the exact saved room layouts across 3D views.\nimport { build3DStairsAcrossLevels143, type PlacedStairSurface143 } from '../building/stairVisibility143'", '3D stair source import')
c=one(c,'''  surface: Stair3DSurface
  selected: boolean''','''  surface: PlacedStairSurface143
  selected: boolean''','StairSolid prop type')
c=one(c,'''  stairs: Stair3DSurface[]''','''  stairs: PlacedStairSurface143[]''','scene prop type')
c=one(c,'''      position={[0, 0, 0]}
      onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); onSelect() }}''','''      position={[0, surface.levelOffsetM, 0]}
      onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); if (Math.abs(surface.levelOffsetM) < 0.001) onSelect() }}''','stair level elevation and nonactive select')
c=one(c,'''        color={selected ? '#598fe4' : surface.kind === 'landing' ? '#c4d7ef' : '#9fbade'}
        roughness={0.78}''','''        color={selected ? '#598fe4' : surface.kind === 'landing' ? '#c4d7ef' : '#9fbade'}
        transparent={Math.abs(surface.levelOffsetM) > 0.001}
        opacity={Math.abs(surface.levelOffsetM) > 0.001 ? 0.48 : 1}
        depthWrite={Math.abs(surface.levelOffsetM) <= 0.001}
        side={THREE.DoubleSide}
        roughness={0.78}''','stair ghost view on other levels')
# Inserted module surfaces for all levels - keep one scene for wall detail and house.
c=one(c,'''  const stairs = useMemo(() => buildStair3DSurfaces(activeLevel.rooms, activeLevel.heightM, window.localStorage), [activeLevel, levelRevision])''','''  const stairData143 = useMemo(() => build3DStairsAcrossLevels143(floor, rooms, activeLevel, window.localStorage), [floor, rooms, activeLevel, levelRevision])
  const stairs = stairData143.surfaces''','read actual room-keyed staircase layouts')
c=one(c,'''{stairs.length} Stufen-/Absatzvolumen · Blueprint-Ebene''','''{stairs.length} Stufen-/Absatzvolumen aus {stairData143.savedLayouts} gespeicherten Treppenlayouts ({stairData143.activeLayouts} auf aktiver Ebene) · Blueprint-Ebene''','debug staircase inventory without logging private room coordinates')

# Per-level stair meshes remain distinct. Existing wall geometry, door selection,
# camera and wall-edit popup are untouched.
assert 'STROM140_3D_WALL_EDITOR' in s and 'STROM141_WALL_HOVER' in c, '143: wall editor regressions detected'
(root/'frontend/src/building/neighborSnap143.ts').write_text((modules/'.strom143_neighborSnap143.ts').read_text(encoding='utf8'),encoding='utf8')
(root/'frontend/src/building/stairVisibility143.ts').write_text((modules/'.strom143_stairVisibility143.ts').read_text(encoding='utf8'),encoding='utf8')
app.write_text(s,encoding='utf8')
scene.write_text(c,encoding='utf8')
css.write_text(styles + '''
/* STROM143: snapping against visible Blueprint ghost levels, opt-in. */
.floorplan-layout .strom-neighbor-snap143 { display: inline-flex; align-items: center; gap: 4px; white-space: nowrap; font-size: 11px; }
.floorplan-layout .strom-neighbor-snap143 .strom-ui-icon { width: 18px; height: 18px; }
.floorplan-layout .strom-neighbor-snap143 span { font-weight: 500; }
''',encoding='utf8')
print('143: added read-only multi-level stair adapter and optional visible-neighbor snapping (2D); wall volume unchanged.')
STROM143_PY_PATCH
for bundled in .strom143_neighborSnap143.ts .strom143_stairVisibility143.ts .strom143_patch.py; do
  [ -s "$WORK_DIR/$bundled" ] || fail "143: Hilfsdatei leer oder fehlt: $bundled"
done
STROM143_ROOT="$WORK_DIR" STROM143_MODULES="$WORK_DIR" python3 "$WORK_DIR/.strom143_patch.py" >>"$DIAG_LOG" 2>&1 || fail "143-Quellpatch fehlgeschlagen. Kein Git-Push/Stage-Deployment."
rm -f "$WORK_DIR/.strom143_neighborSnap143.ts" "$WORK_DIR/.strom143_stairVisibility143.ts" "$WORK_DIR/.strom143_patch.py"

cat > "$WORK_DIR/docs/BLUEPRINT_3D_UPDATE_143.md" <<'STROM143_DOC'
# STROM Update 143 - Staircases and cross-level snapping

- 3D Haus and Wanddetail continue to use the exact same React Three Fiber scene.
- Read stair layouts under their original `strom-stair-layout:<roomId>` keys. Load them for each retained Blueprint level, not just the active room-filtered level.
- Staircase elevations respect per-level heights; stairs from other levels are drawn translucently. No database or localStorage migration.
- A non-zero count of stored staircase layouts is shown in the 3D status bar for diagnosis.
- Layer assignment data remain read-only in the new adapter.
- New Blueprint toggle "Nachbarebenen": off by default, stored independently per Floor ID in `strom.floorplan.layers.<floorId>.snapVisibleNeighbors143`.
- When enabled AND ordinary snapping is enabled: visible ghost levels may be used as snap anchors for creation, room movement, group movement and resize operations.
- Hidden/filtered levels never serve as snap anchors; ghosts remain non-selectable and are not changed.
- All existing wall volume, wall editor popup, camera, doors and database data remain unchanged.
STROM143_DOC

# Invariants: never touch the consolidated geometry, existing API or database.
for file in \
  frontend/src/building/model.ts \
  frontend/src/building/solidGeometry.ts \
  frontend/src/building/wallHitSelection.ts \
  frontend/src/building/wallHoverGeometry.ts \
  frontend/src/building/stair3d.ts \
  frontend/src/building/blueprintLevels.ts \
  frontend/src/api.ts \
  frontend/src/types.ts; do
  cmp -s "$STAGE_DIR/$file" "$WORK_DIR/$file" || fail "Versehentliche Aenderung an: $file."
done

log "4) Vollstaendigen TypeScript-/Vite-Build in Arbeitskopie pruefen ..."
(
  cd "$WORK_DIR/frontend"
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Frontend-Build fehlgeschlagen. Kein Git-Push/Stage-Deployment."

log "4.1) Treppen-Zuordnung, Etagenhoehen und Snapping testen ..."
export STROM143_TEST_ROOT="$WORK_DIR"
export STROM143_TS="$DEPENDENCIES/typescript"
node <<'STROM143_TEST_JS' >>"$DIAG_LOG" 2>&1 || fail "143-Regressionspruefung fehlgeschlagen. Kein Git-Push/Stage-Deployment."
'use strict'
const fs = require('fs')
const ts = require(process.env.STROM143_TS)
const root = process.env.STROM143_TEST_ROOT
const cache = {}
function load(name) {
  if (cache[name]) return cache[name]
  const full = `${root}/frontend/src/building/${name}`
  const output = ts.transpileModule(fs.readFileSync(full, 'utf8'), {
    fileName: name, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  })
  if (output.diagnostics?.some(d => d.category === ts.DiagnosticCategory.Error)) throw Error(`${name}: invalid TypeScript`)
  const mod = { exports: {} }
  new Function('module', 'exports', 'require', output.outputText)(mod, mod.exports, (path) => {
    const target = path.split('/').pop() + '.ts'
    if (!['stair3d.ts', 'blueprintLevels.ts'].includes(target)) throw Error('Unexpected import: ' + path)
    return load(target)
  })
  cache[name] = mod.exports
  return mod.exports
}
const snap = load('neighborSnap143.ts')
const stair = load('stairVisibility143.ts')
const p0 = {x:1.89,y:2.05}
const targets = [{vertices:[{x:2,y:1},{x:4,y:1},{x:4,y:3},{x:2,y:3}]}]
const near=snap.snapPointToVisibleRooms143(p0, targets, 0)
if (near.x !== 2 || near.y !== 2.05) throw Error('Ghost snap point failed: '+JSON.stringify(near))
const far=snap.snapPointToVisibleRooms143(p0, [], 0)
if (JSON.stringify(far)!==JSON.stringify(p0)) throw Error('Hidden ghost changed the point')
const distant=snap.snapPointToVisibleRooms143({x:2.05,y:18},targets,0)
if (distant.x!==2.05 || distant.y!==18) throw Error('Snapped to an unrelated distant room')
const angled=snap.snapPointToVisibleRooms143({x:1.04,y:1.11},[{vertices:[{x:0,y:0},{x:2,y:2},{x:0,y:2}]}],0)
if (Math.abs(angled.x-angled.y)>0.002) throw Error('Diagonal ghost edge is not supported')
const rect=[{x:1,y:1},{x:1.89,y:1},{x:1.89,y:2},{x:1,y:2}]
const resized=snap.snapRectangleHandle143(rect,'right',targets,0)
if (resized[0].x!==1 || resized[1].x!==2 || resized[2].x!==2) throw Error('Rectangle opposite edge moved')
const floor={id:'F1', name:'Haus', heightM:2.5, elevationM:0}
const rooms=[
 {id:'R0', floorId:'F1', vertices:[{x:0,y:0},{x:5,y:0},{x:5,y:4},{x:0,y:4}]},
 {id:'R1', floorId:'F1', vertices:[{x:0,y:0},{x:5,y:0},{x:5,y:4},{x:0,y:4}]},
]
const data={
 'strom.floorplan.layers.F1.list':JSON.stringify([{id:'layer-main',heightM:2.6},{id:'level-two',heightM:2.9}]),
 'strom.floorplan.layers.F1.roomAssignments':JSON.stringify({R0:'layer-main',R1:'level-two'}),
 'strom-stair-layout:R1':JSON.stringify([{id:'T1',kind:'stair',xM:1,yM:1,widthM:1,heightM:3,rotationDeg:0,steps:6}]),
 'strom-stair-edge-assignments:R1':JSON.stringify([{kind:'current-floor',edgeIndex:0}]),
}
const reader={getItem:k=>data[k]||null}
const active0={id:'layer-main',name:'EG',heightM:2.6,elevationM:0,rooms:[rooms[0]],layerCount:2}
const other=stair.build3DStairsAcrossLevels143(floor,rooms,active0,reader)
if (other.surfaces.length!==6 || other.savedLayouts!==1 || other.activeLayouts!==0) throw Error('Stair layout missing from neighbor: '+JSON.stringify(other))
if (other.surfaces.some(s=>s.levelOffsetM!==2.6)) throw Error('Stair world floor height wrong')
const active1={id:'level-two',name:'OG',heightM:2.9,elevationM:2.6,rooms:[rooms[1]],layerCount:2}
const current=stair.build3DStairsAcrossLevels143(floor,rooms,active1,reader)
if (current.surfaces.length!==6 || current.activeLayouts!==1 || current.surfaces.some(s=>s.levelOffsetM!==0)) throw Error('Stair for active floor missing')
if (Math.abs(current.surfaces.at(-1).elevationM-2.9)>0.01) throw Error('Stair top not equal to storey height')
console.log('PASS: visible/hidden snap, resize opposite side, stair layout on inactive and active levels, per-floor elevations, 6 steps.')
STROM143_TEST_JS

log "4.2) Verifizierte Bereiche (keine Datenbankmigration):"
log "     - Treppen in Wanddetail und 3D Haus, auch wenn sie einer anderen Blueprint-Ebene zugeordnet sind."
log "     - Snapping an eingeblendeten Nachbarebenen optional, standardmaessig ausgeschaltet."
log "5) Geprueften Source in Stage uebernehmen..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage-Synchronisation fehlgeschlagen. Backup: $BACKUP_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Build und 3D-/Ebenentests bestanden; kein Web-Deployment."
  exit 0
fi

log "6) Stage bauen und unter /strom-test/ bereitstellen..."
(
  cd "$STAGE_DIR/frontend"
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Stage-Build fehlgeschlagen. Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Stage-Frontend dist fehlt."
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Web-Deploy fehlgeschlagen. Backup: $BACKUP_DIR"

log ""
log "Update 143a in Stage erfolgreich. Test: https://home.moja.de/strom-test/"
log "  - Wanddetail/3D Haus: Treppen aus vorhandenen Treppenlayouts auf allen Blueprint-Ebenen."
log "  - Blueprint: Nachbarebenen-Snapping schaltbar in der Werkzeugleiste."
log "  - Blueprint: Ebene je eigener Hoehe (mm), Ebenenmodi und Ghost-Sichtbarkeit."
log "  - 3D zeigt nur die aktive Blueprint-Ebene mit ihrer Geschosshoehe."
log "  - Historische Layer-IDs, Raumzuordnungen und Treppenlayouts bleiben erhalten."
log "  - Produktion bleibt unveraendert."
log "Backup: $BACKUP_DIR"
