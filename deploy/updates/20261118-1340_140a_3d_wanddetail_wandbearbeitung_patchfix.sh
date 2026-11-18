#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-1340_140a_3d_wanddetail_wandbearbeitung_patchfix"
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
COMMIT_MESSAGE="Update 140a: Wanddetail-Patch kompatibel mit aktueller Raum-/Wandobjektverwaltung"
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
  echo "2) Aktuellen Stage-Source + Update 140a nach GitHub pushen ..."
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

  echo "1.3) Update 140a auf Git-Source anwenden und Build pruefen ..."
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
  [ -n "$best" ] || fail "Kein kompatibles Node (Vite benoetigt Node 20.19+ oder 22.12+)."
  NODE_BIN_DIR="$(dirname "$best")"
  export PATH="$NODE_BIN_DIR:$PATH"
  hash -r 2>/dev/null || true
  log "Node: $best (v$best_v), npm: $(npm -v 2>/dev/null || echo fehlt)"
}

log "=== Update 140a / Wandbearbeitung direkt im echten 3D – robuster Patch ==="
log "Stage: $STAGE_DIR"
log "Produktion und bisheriges 3D-Volumen werden nicht veraendert."
log "Diagnose: $DIAG_LOG"
[ -f "$STAGE_DIR/frontend/src/building/solidGeometry.ts" ] || fail "Update 139 fehlt: solidGeometry.ts nicht gefunden."
[ -f "$STAGE_DIR/frontend/src/building/model.ts" ] || fail "Gebaeudemodell fehlt."
[ -f "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" ] || fail "3D-Renderer fehlt."
[ -f "$STAGE_DIR/frontend/src/App.tsx" ] || fail "App.tsx fehlt."
grep -q 'function SolidWallMeshes(' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "Update 139 fehlt: kein gemeinsames 3D-Wandvolumen."
grep -q 'legacyWallDetail' "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 139 fehlt: alte Wandbearbeitung nicht vorhanden."
grep -q 'function WallFrontOverlay(' "$STAGE_DIR/frontend/src/App.tsx" || fail "Bisherige Frontalansicht fehlt."
grep -q 'function WallObjectLibraryFloating(' "$STAGE_DIR/frontend/src/App.tsx" || fail "Bisherige Objektbibliothek fehlt."
if grep -q 'STROM140_3D_WALL_EDITOR' "$STAGE_DIR/frontend/src/App.tsx"; then fail "3D-Wandbearbeitung ist bereits eingespielt."; fi
select_node

log "1) Stage-Sicherung erstellen..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Nur isolierte Git-Arbeitskopie pruefen."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage-Backup fehlgeschlagen."
fi

log "2) Isolierte Arbeitskopie vorbereiten..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Source-Kopie fehlgeschlagen."
mkdir -p "$WORK_DIR/docs" "$WORK_DIR/frontend/src/building"
# Vite / TypeScript / Three use existing checked dependencies; avoid npm install.
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
[ -n "$DEPENDENCIES" ] || fail "Frontend-Dependencies fehlen (typescript/vite/three)."
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"

log "3) Wandflaechen anklickbar machen und bestehendes Popup einbinden..."
cat > "$WORK_DIR/.strom140_patch.py" <<'STROM140_PATCH'
#!/usr/bin/env python3
"""140a: tolerant wall editor patch against current Stage variants; keep 139 geometry."""
import os
import re
from pathlib import Path

root = Path(os.environ['STROM140_ROOT'])
app_path = root / 'frontend/src/App.tsx'
scene_path = root / 'frontend/src/components/Building3DWorkspace.tsx'
css_path = root / 'frontend/src/styles.css'
module_path = root / 'frontend/src/building/wallHitSelection.ts'

app = app_path.read_text(encoding='utf-8')
scene = scene_path.read_text(encoding='utf-8')
css = css_path.read_text(encoding='utf-8')


def one(text, before, after, description):
    n = text.count(before)
    if n != 1:
        raise RuntimeError(f'{description}: expected exactly one anchor; found {n}')
    return text.replace(before, after, 1)


def between(text, start, end, replacement, description):
    a = text.find(start)
    b = text.find(end, a + len(start)) if a >= 0 else -1
    if a < 0 or b < 0:
        raise RuntimeError(f'{description}: required block not found')
    return text[:a] + replacement + text[b:]

if 'STROM140_3D_WALL_EDITOR' in app or 'STROM140_3D_WALL_EDITOR' in scene:
    raise RuntimeError('140 is already applied; refusing duplicate patch')

assert "import { buildSolidSurface, nearestRoomForWallHit } from '../building/solidGeometry'" in scene, '139 geometry not found'
assert 'function SolidWallMeshes(' in scene, '139 unified wall mesh not found'
assert 'legacyWallDetail' in app, '139 wall detail routing not found'
assert 'function WallDetailEditor(' in app and 'function WallFrontOverlay(' in app and 'function WallObjectLibraryFloating(' in app, 'existing wall editing UI incomplete'

# Pure 2D / 3D selection resolver. It does NOT change solid mesh geometry.
module_path.parent.mkdir(parents=True, exist_ok=True)
module_path.write_text('''import type { PointM } from '../types'
import type { BuildingModel } from './model'

export type WallHitSelection3D = { roomId: string; edgeIndex: number }

/**
 * STROM140_3D_WALL_EDITOR: identify the specific Blueprint room edge whose
 * solid surface was clicked. The 3D wall is a single union mesh in 139, so it
 * cannot be identified from a mesh ID. Use the hit's real world X/Z point,
 * an edge-segment projection and a small preference for editable room sides.
 * This is a selection calculation only, not a new geometry representation.
 */
export function selectWallEdgeFrom3DHit(model: BuildingModel, hit: PointM): WallHitSelection3D | null {
  let chosen: WallHitSelection3D | null = null
  let best = Number.POSITIVE_INFINITY
  let nearest = Number.POSITIVE_INFINITY
  for (const room of model.rooms) {
    const vertices = room.vertices
    if (!vertices || vertices.length < 2) continue
    for (let edgeIndex = 0; edgeIndex < vertices.length; edgeIndex++) {
      const a = vertices[edgeIndex]
      const b = vertices[(edgeIndex + 1) % vertices.length]
      const vx = b.x - a.x
      const vy = b.y - a.y
      const len2 = vx * vx + vy * vy
      if (len2 < 0.0025) continue
      const raw = ((hit.x - a.x) * vx + (hit.y - a.y) * vy) / len2
      const t = Math.max(0, Math.min(1, raw))
      const px = a.x + t * vx
      const py = a.y + t * vy
      const gap = Math.hypot(hit.x - px, hit.y - py)
      // Select an actual wall segment, not a faraway edge at a corner.
      // A maximum gap accounts for unusually thick physical wall volumes.
      if (gap > 0.90) continue
      const endpointPenalty = raw < -0.02 || raw > 1.02 ? .3 : 0
      const score = gap + endpointPenalty + (room.kind === 'outer' ? .025 : 0)
      if (score < best) {
        best = score
        nearest = gap
        chosen = { roomId: room.id, edgeIndex }
      }
    }
  }
  if (nearest > 0.90) return null
  return chosen
}
''', encoding='utf-8')

# Scene: generic wall selection callback (only active for Wanddetail, never 3D Haus).
scene = one(scene,
    "import { buildSolidSurface, nearestRoomForWallHit } from '../building/solidGeometry'",
    "import { buildSolidSurface, nearestRoomForWallHit } from '../building/solidGeometry'\nimport { selectWallEdgeFrom3DHit, type WallHitSelection3D } from '../building/wallHitSelection'\nimport type { ReactNode } from 'react'",
    'scene imports')
scene = one(scene,
    "function SolidWallMeshes({ model, onSelectRoom, transparent }: {\n  model: BuildingModel\n  onSelectRoom: (id: string) => void\n  transparent: boolean\n}) {",
    "function SolidWallMeshes({ model, onSelectRoom, onSelectWall, transparent }: {\n  model: BuildingModel\n  onSelectRoom: (id: string) => void\n  onSelectWall?: (wall: WallHitSelection3D | null) => void\n  transparent: boolean\n}) {",
    'wall mesh props')
scene = one(scene,
    '''        const roomId = nearestRoomForWallHit(model, { x: event.point.x, y: event.point.z })
        if (roomId) onSelectRoom(roomId)''',
    '''        if (onSelectWall && event.delta > 5) return // 3D camera orbit, not a wall click
        const point = { x: event.point.x, y: event.point.z }
        // In Wanddetail: click a physical face to open its original wall editor.
        const hitWall = onSelectWall ? selectWallEdgeFrom3DHit(model, point) : null
        if (hitWall) {
          onSelectWall?.(hitWall)
          onSelectRoom(hitWall.roomId)
        } else {
          const roomId = nearestRoomForWallHit(model, point)
          if (roomId) onSelectRoom(roomId)
        }''', 'solid wall hit')
scene = one(scene,
    "function RealBuildingScene({ model, selectedRoomId, selectedDoorId, onSelectRoom, onSelectDoor, transparent }: {",
    "function RealBuildingScene({ model, selectedRoomId, selectedDoorId, onSelectRoom, onSelectDoor, onSelectWall, transparent }: {",
    'scene props destructuring')
scene = one(scene,
    '''  onSelectDoor: (id: string) => void
  transparent: boolean
}) {''',
    '''  onSelectDoor: (id: string) => void
  onSelectWall?: (wall: WallHitSelection3D | null) => void
  transparent: boolean
}) {''', 'scene prop types')
scene = one(scene,
    "onPointerMissed={() => { onSelectDoor(''); onSelectRoom('') }}",
    "onPointerMissed={() => { onSelectDoor(''); onSelectRoom(''); onSelectWall?.(null) }}",
    'clear selected wall on empty click')
scene = one(scene,
    '''          <FloorMesh key={room.id} room={room} selected={selectedRoomId === room.id} onSelect={() => { onSelectRoom(room.id); onSelectDoor('') }} />''',
    '''          <FloorMesh key={room.id} room={room} selected={selectedRoomId === room.id} onSelect={() => { onSelectRoom(room.id); onSelectDoor(''); onSelectWall?.(null) }} />''', 'floor selection')
scene = one(scene,
    '''          onSelectRoom={(id) => { onSelectRoom(id); onSelectDoor('') }}
          transparent={transparent}''',
    '''          onSelectRoom={(id) => { onSelectRoom(id); onSelectDoor('') }}
          onSelectWall={onSelectWall}
          transparent={transparent}''', 'wall selection callback')
scene = one(scene,
    '''              onSelect={() => { onSelectDoor(door.groupId); onSelectRoom(door.roomId) }}''',
    '''              onSelect={() => {
                onSelectDoor(door.groupId)
                onSelectRoom(door.roomId)
                onSelectWall?.({ roomId: door.roomId, edgeIndex: door.edgeIndex })
              }}''', 'door selection in wall detail')

scene = one(scene,
    "export default function Building3DWorkspace({ floor, rooms, selectedRoomId, onSelectRoom, onPersistRoom, onCaptureUndo, onBackToBlueprint, variant = 'house', onOpenLegacyWallDetail }: {",
    "export default function Building3DWorkspace({ floor, rooms, selectedRoomId, onSelectRoom, onPersistRoom, onCaptureUndo, onBackToBlueprint, variant = 'house', onOpenLegacyWallDetail, onSelectWall, wallEditor, objectsRevision }: {",
    'workspace props destructuring')
scene = one(scene,
    '''  variant?: 'house' | 'wall'
  onOpenLegacyWallDetail?: () => void
}) {''',
    '''  variant?: 'house' | 'wall'
  onOpenLegacyWallDetail?: () => void
  onSelectWall?: (wall: WallHitSelection3D | null) => void
  wallEditor?: ReactNode
  objectsRevision?: number
}) {''', 'workspace prop types')
scene = one(scene,
    '''  useEffect(() => { void reloadDoors() }, [floor.id])''',
    '''  useEffect(() => { void reloadDoors() }, [floor.id, objectsRevision])''',
    'reload 3d meshes after wall edits')
scene = one(scene,
    '''          <RealBuildingScene model={model} selectedRoomId={selectedRoomId} selectedDoorId={selectedDoorId} onSelectRoom={onSelectRoom} onSelectDoor={setSelectedDoorId} transparent={transparent} />''',
    '''          <RealBuildingScene model={model} selectedRoomId={selectedRoomId} selectedDoorId={selectedDoorId} onSelectRoom={onSelectRoom} onSelectDoor={setSelectedDoorId} onSelectWall={variant === 'wall' ? onSelectWall : undefined} transparent={transparent} />''',
    'real scene wire selected wall')
scene = one(scene,
    '          <div className="building3d-help">Linke Maustaste: drehen · Mausrad: zoomen · rechte Maustaste: verschieben · Klick: Raum oder Tuer waehlen</div>',
    "          <div className=\"building3d-help\">{variant === 'wall' ? 'Linke Maustaste: drehen · Mausrad: zoomen · rechte Maustaste: verschieben · Klick: Wand zum Bearbeiten auswaehlen' : 'Linke Maustaste: drehen · Mausrad: zoomen · rechte Maustaste: verschieben · Klick: Raum oder Tuer waehlen'}</div>",
    'Wanddetail help')
scene = one(scene,
    '''      <div className="building3d-status">''',
    '''      {variant === 'wall' && wallEditor}
      <div className="building3d-status">''',
    'popup in 3d layout')

# App: hold temporary Wanddetail selection and a model refresh counter. These
# do not affect other view modes, and the old dialog logic is reused as-is.
app = one(app,
    "  const [legacyWallDetail, setLegacyWallDetail] = useState(false)",
    "  const [legacyWallDetail, setLegacyWallDetail] = useState(false)\n  const [wall3DSelected, setWall3DSelected] = useState<WallSelection | null>(null) // STROM140_3D_WALL_EDITOR\n  const [wall3DRevision, setWall3DRevision] = useState(0)",
    'app states')
app = one(app,
    '''  useEffect(() => {
    roomsRef.current = rooms
  }, [rooms])''',
    '''  useEffect(() => {
    roomsRef.current = rooms
  }, [rooms])

  useEffect(() => {
    setWall3DSelected(null)
  }, [viewMode, floor?.id])''',
    'clear 3d selection on view/floor changes')

needle = '''                onOpenLegacyWallDetail={() => setLegacyWallDetail(true)}
              />'''
assert needle in app, 'Wanddetail WebGL bridge missing'
app = one(app, needle,
    '''                onOpenLegacyWallDetail={() => setLegacyWallDetail(true)}
                onSelectWall={setWall3DSelected}
                objectsRevision={wall3DRevision}
                wallEditor={wall3DSelected ? (
                  <WallDetailEditor
                    floor={floor}
                    rooms={rooms}
                    selectedRoomId={selectedRoomId}
                    onSelectRoom={setSelectedRoomId}
                    canUndo={undoStack.length > 0}
                    onUndo={undoLastAction}
                    headless
                    externalSelection={wall3DSelected}
                    onExternalClose={() => setWall3DSelected(null)}
                    onWallObjectsChanged={() => setWall3DRevision((v) => v + 1)}
                  />
                ) : undefined}
              />''', 'webgl wall editor bridge')

# Extend existing WallDetailEditor, not a duplicate popup/controller.
app = one(app,
    '''  canUndo,
  onUndo,
}: {
  floor: Floor
  rooms: Room[]
  selectedRoomId: string
  onSelectRoom: (id: string) => void
  canUndo: boolean
  onUndo: () => void
}) {''',
    '''  canUndo,
  onUndo,
  headless = false,
  externalSelection,
  onExternalClose,
  onWallObjectsChanged,
}: {
  floor: Floor
  rooms: Room[]
  selectedRoomId: string
  onSelectRoom: (id: string) => void
  canUndo: boolean
  onUndo: () => void
  headless?: boolean
  externalSelection?: WallSelection | null
  onExternalClose?: () => void
  onWallObjectsChanged?: () => void
}) {''', 'legacy wall editor props')

start = app.index('function WallDetailEditor(')
end = app.index('function WallDetailPropertiesTopBar(', start)
sub = app[start:end]

sub = one(sub,
    '  const [selectedWall, setSelectedWall] = useState<WallSelection | null>(null)',
    '''  const [selectedWall, setSelectedWall] = useState<WallSelection | null>(externalSelection ?? null)
  // Keep the existing Frontalansicht UI in sync with physical 3D wall clicks.
  useEffect(() => {
    if (headless) setSelectedWall(externalSelection ?? null)
  }, [headless, externalSelection?.roomId, externalSelection?.edgeIndex])''',
    'headless selection state')
# Avoid kicking off the old SVG startup animation or modifying viewport when in 3D mode.
sub = one(sub,
    '''  useEffect(() => {
    const nextLayers = loadFloorplanLayers(floor.id)''',
    '''  useEffect(() => {
    if (headless) { setIntroPhase('ready'); setIntroReady(true); return }
    const nextLayers = loadFloorplanLayers(floor.id)''',
    'skip legacy startup intro')
sub = one(sub,
    '''  }, [floor.id])

  useEffect(() => {
    const viewport = loadCanvasViewport(floor.id)''',
    '''  }, [floor.id, headless])

  useEffect(() => {
    if (headless) return
    const viewport = loadCanvasViewport(floor.id)''',
    'skip legacy canvas viewport')
sub = one(sub,
    '''    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') setSelectedWall(null)
    }''',
    '''    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') {
        setSelectedWall(null)
        if (headless) onExternalClose?.()
      }
    }''',
    'headless escape close')
sub = one(sub,
    '''  }, [])

  useEffect(() => {
    void reloadWallObjects()''',
    '''  }, [headless, onExternalClose])

  useEffect(() => {
    void reloadWallObjects()''',
    'headless escape deps')
# The wallDetailRooms line changed during the earlier staircase work. Old Stage
# excluded stair rooms; newer Stage may already use ALL rooms. Support both
# without changing the classic editor's existing filtering behavior.
room_pattern = re.compile(r"(?m)^  const wallDetailRooms = useMemo\(\(\) => (.+), \[rooms\]\);?$" )
room_matches = list(room_pattern.finditer(sub))
if len(room_matches) != 1:
    candidates = [line.strip() for line in sub.splitlines() if 'const wallDetailRooms' in line]
    raise RuntimeError(f'wallDetailRooms: unexpected Stage version. Found: {candidates}')
room_expression = room_matches[0].group(1)
if room_expression == 'rooms':
    # Already includes stair rooms, no need to touch the existing definition.
    print('140a: aktuelle Raumliste bereits unbeschraenkt; unveraendert')
else:
    # Preserve the classic editor's exact expression, but allow the 3D editor
    # to access every room/edge (including staircase rooms).
    original = room_matches[0].group(0)
    replacement = f'  const wallDetailRooms = useMemo(() => headless ? rooms : ({room_expression}), [rooms, headless])'
    sub = sub.replace(original, replacement, 1)
    print('140a: gefilterte Raumliste fuer 3D-Wandauswahl erweitert')

# Geometry, IDs and wall-object CRUD from earlier versions differ. In
# particular, updateWallObjectApi used to receive targetPatch but now can
# receive an object literal. Attach refresh to the API PROMISE instead of
# replacing its arguments or rewriting existing mapping logic.
def function_span(text: str, function_name: str):
    pattern = re.compile(r'(?m)^  (?:async )?function ' + re.escape(function_name) + r'\(')
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(f'{function_name}: expected function once, got {len(matches)}')
    begin = matches[0].start()
    next_fn = re.search(r'(?m)^  (?:async )?function [A-Za-z_][A-Za-z0-9_]*\(', text[matches[0].end():])
    end = (matches[0].end() + next_fn.start()) if next_fn else len(text)
    return begin, end


def add_success_refresh(text: str, function_name: str, optional: bool = False) -> str:
    if optional and not re.search(r'(?m)^  async function ' + re.escape(function_name) + r'\(', text):
        return text
    a, b = function_span(text, function_name)
    body = text[a:b]
    catch_pos = body.find('} catch (err) {')
    if catch_pos < 0:
        raise RuntimeError(f'{function_name}: try/catch not found')
    successful = body[:catch_pos]
    hits = list(re.finditer(r'(?m)^      await reloadWallObjects\(\)[ \t]*$', successful))
    if not hits:
        raise RuntimeError(f'{function_name}: success reload not found')
    hit = hits[-1]
    successful = successful[:hit.end()] + '\n      onWallObjectsChanged?.()' + successful[hit.end():]
    return text[:a] + successful + body[catch_pos:] + text[b:]

sub = add_success_refresh(sub, 'addWallObject')
# Existing complete-wall opening button is optional depending on the version.
sub = add_success_refresh(sub, 'toggleFullWallOpen', optional=True)


def add_api_refresh(text: str, function_name: str, api_name: str, error_phrase: str) -> str:
    a, b = function_span(text, function_name)
    body = text[a:b]
    # Match the original promise chain only; keep all its original arguments.
    needle = f".catch((err) => console.warn('{error_phrase}', err))"
    if body.count(needle) != 1 or body.count(api_name + '(') != 1:
        raise RuntimeError(f'{function_name}: unsupported API call/promise form')
    body = body.replace(needle, '.then(() => onWallObjectsChanged?.())' + needle, 1)
    return text[:a] + body + text[b:]

sub = add_api_refresh(sub, 'updateWallObject', 'updateWallObjectApi', 'Wandobjekt konnte nicht aktualisiert werden')
sub = add_api_refresh(sub, 'deleteWallObject', 'deleteWallObjectFromApi', 'Wandobjekt konnte nicht geloescht werden')

# Copy the popup JSX already used in the classic editor. Preserves any newer
# controls (including full-wall opening) without duplicating the implementation.
overlay_start = sub.find('        {selectedWall && selectedWallRoom && (', sub.find('<div className="canvas-card wall-detail-card">'))
overlay_end = sub.find('        <div className="canvas-scroll"', overlay_start)
if overlay_start < 0 or overlay_end < 0:
    raise RuntimeError('existing Frontalansicht/Objektbibliothek JSX not found')
existing_overlay = sub[overlay_start:overlay_end].rstrip()
if '<WallFrontOverlay' not in existing_overlay or '<WallObjectLibraryFloating' not in existing_overlay:
    raise RuntimeError('existing Frontalansicht/Objektbibliothek incomplete')
headless_overlay = existing_overlay.replace('motion={selectedWallMotion}', "motion={{ initialX: headlessPopupX, initialY: 72, startDx: 0, startDy: 0, startRotate: 0, startScale: 1 }}").replace(
    'onClose={() => setSelectedWall(null)}',
    'onClose={() => { setSelectedWall(null); onExternalClose?.() }}')
headless_overlay = headless_overlay.replace('baseX={selectedWallMotion?.initialX ?? 420} baseY={(selectedWallMotion?.initialY ?? 78) + 378}', 'baseX={headlessPopupX} baseY={450}')
# A separate early return *after* all hooks, before the existing render. This
# avoids mounting legacy SVG/canvas while retaining all legacy CRUD functions.
marker = '  const hintText = selectedWall\n'
assert sub.count(marker) == 1, 'legacy return marker not found'
insertion = '''  const headlessPopupX = typeof window === 'undefined' ? 420 : Math.max(8, Math.min(420, window.innerWidth - 640))
  if (headless) {
    return (
      <div className="building3d-wall-overlay-host" aria-label="Wandbearbeitung in echtem 3D">
'''+headless_overlay+'''
      </div>
    )
  }

'''
sub = one(sub,marker,insertion+marker,'render headless popup only')
app = app[:start] + sub + app[end:]

css += '''

/* STROM140_3D_WALL_EDITOR: old wall editor UI over the real WebGL model. */
.building3d-layout:has(.building3d-wall-overlay-host) { position: relative; }
.building3d-wall-overlay-host {
  position: absolute;
  z-index: 80;
  inset: 0;
  pointer-events: none;
  overflow: visible;
}
.building3d-wall-overlay-host .wall-front-overlay,
.building3d-wall-overlay-host .wall-object-library {
  pointer-events: auto;
}
.building3d-wall-overlay-host .wall-front-overlay {
  max-width: min(560px, calc(100% - 20px));
}
@media (max-width: 820px) {
  .building3d-wall-overlay-host .wall-front-overlay { width: calc(100% - 16px) !important; min-width: 0; }
}
'''

scene_path.write_text(scene, encoding='utf-8')
app_path.write_text(app, encoding='utf-8')
css_path.write_text(css, encoding='utf-8')
print('140a: 3D wall-face clicks connected to unchanged WallFrontOverlay and WallObjectLibraryFloating; building geometry untouched')
STROM140_PATCH
STROM140_ROOT="$WORK_DIR" python3 "$WORK_DIR/.strom140_patch.py" >>"$DIAG_LOG" 2>&1 || fail "Wanddetail-Patch fehlgeschlagen."
rm -f "$WORK_DIR/.strom140_patch.py"

cat > "$WORK_DIR/docs/3D_WANDBEARBEITUNG_INCREMENT_140a.md" <<'STROM140_DOC'
# STROM 140a – Wandauswahl im echten 3D-Wanddetail

- Das 3D-Wandvolumen von 139 bleibt unverändert; `solidGeometry.ts` und `model.ts` werden nicht gepatcht.
- `wallHitSelection.ts` ordnet einen 3D-Mesh-Treffer einer Raumkante im gemeinsamen Blueprint-Modell zu.
- Klick auf eine Wand im echten Wanddetail öffnet die *bestehende* Frontalansicht samt Objektbibliothek.
- Bisherige Funktionen zum Einsetzen, Verschieben, Skalieren und Löschen von Wandobjekten nutzen weiterhin die bisherigen APIs und die Wandgruppen.
- Nach erfolgreichem Speichern/Löschen liest der 3D-Renderer die aktualisierten API-Wandobjekte erneut, damit Öffnungen direkt sichtbar werden.
- Türgruppenauswahl im 3D-Modell bleibt nutzbar.
- In `3D Haus` findet weiterhin nur Raumauswahl statt; die Wand-Popups sind ausschließlich im Wanddetail aktiv.
- Der alte Wanddetail-Editor ist weiterhin über den vorhandenen Button erreichbar.
- Blueprint, 3D-Volumen, Etagenlayout, Datenbankschema und Produktionssystem werden nicht umgebaut.
STROM140_DOC

# Guard: no changes to solid wall geometry or canonical building model.
cmp -s "$STAGE_DIR/frontend/src/building/model.ts" "$WORK_DIR/frontend/src/building/model.ts" || fail "Unbeabsichtigte Aenderung am Gebaeudemodell."
cmp -s "$STAGE_DIR/frontend/src/building/solidGeometry.ts" "$WORK_DIR/frontend/src/building/solidGeometry.ts" || fail "Unbeabsichtigte Aenderung an der Wandvolumen-Geometrie."

log "4) TypeScript/Vite-Build in Arbeitskopie pruefen..."
(
  cd "$WORK_DIR/frontend"
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Frontend-Build fehlgeschlagen. Kein Git-Push/Stage-Deploy."

log "4.1) Auswahltests fuer verschiedene Wandkanten pruefen..."
export STROM140_HIT_MODULE="$WORK_DIR/frontend/src/building/wallHitSelection.ts"
export STROM140_TYPESCRIPT="$DEPENDENCIES/typescript"
node <<'STROM140_TEST' >>"$DIAG_LOG" 2>&1 || fail "Wandkanten-Auswahltest fehlgeschlagen. Kein Git-Push/Stage-Deploy."
'use strict';
const fs = require('fs');
const ts = require(process.env.STROM140_TYPESCRIPT);
const file = process.env.STROM140_HIT_MODULE;
const result = ts.transpileModule(fs.readFileSync(file,'utf8'), {
  fileName: file,
  reportDiagnostics: true,
  compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
});
if(result.diagnostics.some(d=>d.category===ts.DiagnosticCategory.Error)) throw new Error('TypeScript transpilation failed');
const mod={exports:{}};
new Function('module','exports',result.outputText)(mod,mod.exports);
const {selectWallEdgeFrom3DHit:hit}=mod.exports;
const rect=(x0,y0,x1,y1)=>[{x:x0,y:y0},{x:x1,y:y0},{x:x1,y:y1},{x:x0,y:y1}];
const model={rooms:[{id:'wohnen',kind:'room',vertices:rect(0,0,4,3)},{id:'neben',kind:'room',vertices:rect(4.28,0,7,3)}]};
const tests=[
  [{x:2,y:.04},'wohnen',0],
  [{x:3.98,y:1.5},'wohnen',1],
  [{x:2,y:2.98},'wohnen',2],
  [{x:.04,y:1.5},'wohnen',3],
  [{x:7.01,y:1.5},'neben',1],
  [{x:4.25,y:1.5},'neben',3],
];
for(const [point,id,edge] of tests){
 const r=hit(model,point);
 if(!r || r.roomId!==id || r.edgeIndex!==edge) throw Error(`Wall hit mismatch ${JSON.stringify(point)}: ${JSON.stringify(r)} vs ${id}/${edge}`);
}
if(hit(model,{x:100,y:100})!==null)throw Error('Faraway point must return null');
console.log('140a: 3D wall-edge selection tests PASS');
STROM140_TEST

log "5) Geprueften Source in Stage uebernehmen..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git'   "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage-Synchronisation fehlgeschlagen. Backup: $BACKUP_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Build und Auswahltests bestanden; kein Web-Deployment."
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
log "Update 140a erfolgreich. Test: https://home.moja.de/strom-test/"
log "  - Wanddetail: direkte Auswahl einzelner 3D-Wandflaechen."
log "  - Frontalansicht + Objektbibliothek wie bisher im neuen WebGL-Wanddetail."
log "  - Tueren/Fenster/Steckdosen einsetzen, aendern, loeschen."
log "  - Veraenderungen aktualisieren 3D-Modell aus derselben API."
log "  - 3D-Haus, Blueprint und das Wandvolumen bleiben unveraendert."
log "Backup: $BACKUP_DIR"
