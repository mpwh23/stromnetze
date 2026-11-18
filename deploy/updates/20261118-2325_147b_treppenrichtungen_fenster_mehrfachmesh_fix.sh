#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-2325_147b_treppenrichtungen_fenster_mehrfachmesh_fix"
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
COMMIT_MESSAGE="Update 147b: stairwell up/down, window cross removal, AST stair JSX wrapper"
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
  echo "2) Update 147b im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 147b isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 147b / Fenster ohne Kreuz; Treppenrichtungen; AST-basierte Mehrfach-Mesh-Pruefung ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
log "Produktion, Raumkonturen, Wandoberflaechen, Tueren, Stockwerkhoehen unveraendert."
for file in \
  frontend/src/App.tsx \
  frontend/src/styles.css \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/building/stairVisibility143.ts \
  frontend/src/building/stair3d.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "147 benoetigt aktuelle STROM-Stage: $file fehlt"
done
for marker in STROM146_ZOOM wall-front-window-mullion146; do
  grep -q "$marker" "$STAGE_DIR/frontend/src/App.tsx" || fail "147 benoetigt erfolgreiches Update 146a ($marker fehlt)"
done
for marker in STROM146_ALL_LEVELS 'function StairSolid(' 'STROM141_WALL_HOVER'; do
  grep -qF "$marker" "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "147: 3D Stand inkonsistent, erwartet: $marker"
done
select_node

log "1) Stage-Vorabpruefung und Backup ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolierte Git-Arbeitskopie; kein Stage-Backup."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Backup fehlgeschlagen. Stage bleibt unveraendert."
fi

log "2) Arbeitskopie vorbereiten ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >> "$DIAG_LOG" 2>&1 || fail "Arbeitskopie fehlgeschlagen"
mkdir -p "$WORK_DIR/frontend/src/building" "$WORK_DIR/docs"
rm -rf "$WORK_DIR/frontend/node_modules"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ]; then
    DEPENDENCIES="$candidate"; break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "147: TypeScript/Vite/Three.js fehlen im Stage-/Produktiv-Frontend."
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"

log "3) Fenster und Treppenrichtung auf isolierten Quellstand anwenden ..."
cat > "$WORK_DIR/.strom147_stairOverlay.ts" <<'STROM147_HELPER_TS'
import type { PointM } from '../types'

/** A stair well can contain two independent, geometrically coincident stair rooms. */
export type StairDirection147 = 'up' | 'down'
export type StairOverlay147 = { id: string; vertices: PointM[] }
export type StairDirectionStore147 = { getItem(key: string): string | null; setItem(key: string, value: string): void }
export const stairDirectionKey147 = (floorId: string) => `strom.floorplan.layers.${floorId}.stairDirections147`

export function readStairDirections147(floorId: string, storage: Pick<StairDirectionStore147, 'getItem'>): Record<string, StairDirection147> {
  try {
    const raw = storage.getItem(stairDirectionKey147(floorId))
    const value: unknown = raw ? JSON.parse(raw) : null
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
    const result: Record<string, StairDirection147> = {}
    for (const [id, direction] of Object.entries(value)) {
      if (direction === 'up' || direction === 'down') result[id] = direction
    }
    return result
  } catch { return {} }
}

export function sameStairFootprint147(a: Pick<StairOverlay147, 'vertices'>, b: Pick<StairOverlay147, 'vertices'>): boolean {
  if (!Array.isArray(a.vertices) || !Array.isArray(b.vertices) || a.vertices.length < 3 || a.vertices.length !== b.vertices.length) return false
  const pack = (pts: PointM[]) => pts.map((p) => `${Math.round(p.x * 1000)}:${Math.round(p.y * 1000)}`).sort()
  const av = pack(a.vertices), bv = pack(b.vertices)
  return av.every((value, i) => value === bv[i])
}

STROM147_HELPER_TS
cat > "$WORK_DIR/.strom147_patch.py" <<'STROM147_PATCH_PY'
#!/usr/bin/env python3
"""STROM147; narrow scoped transformations; all anchors asserted before write."""
from pathlib import Path
import os

root=Path(os.environ['STROM147_ROOT'])
app=root/'frontend/src/App.tsx'
scene=root/'frontend/src/components/Building3DWorkspace.tsx'
visibility=root/'frontend/src/building/stairVisibility143.ts'
css=root/'frontend/src/styles.css'
module=Path(os.environ['STROM147_MODULE'])
output=root/'frontend/src/building/stairOverlay147.ts'
for path in (app,scene,visibility,css,module):
    if not path.is_file(): raise RuntimeError(f'147: required source absent: {path}')
a=app.read_text(encoding='utf8')
s=scene.read_text(encoding='utf8')
v=visibility.read_text(encoding='utf8')
c=css.read_text(encoding='utf8')
if 'STROM147_STAIR_DIRECTIONS' in a or 'STROM147_DOWN_SCENE' in s or output.exists():
    raise RuntimeError('147: partially or fully applied already; nothing will be changed')
for marker in ('STROM146_ZOOM','function FloorplanEditor(', 'function WallFrontPlacedObject(', 'wall-front-window-mullion146', 'function StairLayoutPanel('):
    if marker not in a: raise RuntimeError(f'147: expected stage 146a App.tsx; missing {marker}')
for marker in ('function StairSolid(', 'STROM146_ALL_LEVELS', 'PlacedStairSurface143'):
    if marker not in s: raise RuntimeError(f'147: expected stage 146a 3D; missing {marker}')
for marker in ('build3DStairsAcrossLevels143(', 'for (const surface of buildStair3DSurfaces(', 'levelOffsetM: offset'):
    if marker not in v: raise RuntimeError(f'147: expected stairVisibility143 helper; missing {marker}')

def once(source, old, new, label):
    count=source.count(old)
    if count!=1: raise RuntimeError(f'147 {label}: expected 1 anchor, got {count}; abort before any writes')
    return source.replace(old,new,1)

def between(source, begin, end, label):
    if source.count(begin)!=1 or source.count(end)!=1:
        raise RuntimeError(f'147 {label}: unexpected top-level function boundary (begin={source.count(begin)}, end={source.count(end)})')
    start=source.index(begin); stop=source.index(end,start)
    return start,stop,source[start:stop]

# 1) Windows: remove ONLY mullions and transoms from the last 146a front view.
p0,p1,front=between(a,'function WallFrontPlacedObject(', 'function WallObjectLibraryFloating(', 'front view')
front=once(front, '<title>Fenster – Rahmen mit Glas und Mittelsprosse</title>', '<title>Fenster – Frontalansicht ohne Fensterkreuz</title>', 'window title')
front=once(front, '        <line className="wall-front-window-mullion146" x1={cx} y1={top + frame} x2={cx} y2={top + h - frame} />\n', '', 'vertical mullion')
front=once(front, '        {w > h * 1.3 && <line className="wall-front-window-transom146" x1={left + frame} y1={cy} x2={left + w - frame} y2={cy} />}\n', '', 'horizontal transom')
a=a[:p0]+front+a[p1:]

# 2) Import pure stair-overlay helpers in a stable top-level import block.
insert_before='function FloorplanEditor('
# An import is at module scope and placed just before the first App import is not safe;
# add beside the v146 snap module which has a known exact import in the 146a stage.
import146="import { snapRectEdge146, snapTranslatedEdge146 } from './building/edgeSnap146'"
a=once(a,import146,import146+"\nimport { readStairDirections147, sameStairFootprint147, stairDirectionKey147, type StairDirection147 } from './building/stairOverlay147'",'stair overlay import')

p0,p1,editor=between(a,'function FloorplanEditor(', 'type StairEditorElementKind', 'Blueprint editor')
selected='  const selectedRoom = rooms.find((room) => room.id === selectedRoomId) ?? null'
editor=once(editor,selected,selected+'''
  // STROM147_STAIR_DIRECTIONS: one physical location, two independent stair-room records.
  const stairRoomsHere147 = selectedRoom && isStairRoom(selectedRoom)
    ? rooms.filter((room) => isStairRoom(room)
      && (roomLayerAssignments[room.id] ?? defaultLayerId) === (roomLayerAssignments[selectedRoom.id] ?? defaultLayerId)
      && sameStairFootprint147(room, selectedRoom))
    : []
  const stairUp147 = stairRoomsHere147.find((room) => stairDirections147[room.id] === 'up') ?? null
  const stairDown147 = stairRoomsHere147.find((room) => stairDirections147[room.id] === 'down') ?? null
  const selectedStairDirection147 = selectedRoom ? stairDirections147[selectedRoom.id] : undefined
''', 'selected stair room derivations')

state='  const [stairPanelOpen, setStairPanelOpen] = useState(false)'
editor=once(editor,state,'''  const [stairDirections147, setStairDirections147] = useState<Record<string, StairDirection147>>(
    () => readStairDirections147(floor.id, window.localStorage))
'''+state, 'stair-direction state')

# Keep persisted mapping tied to the floor when switching building objects.
needle='  const selectedRoom = rooms.find((room) => room.id === selectedRoomId) ?? null'
# Place effect BEFORE selectedRoom rather than after to maintain hook order unconditionally.
effect='''  useEffect(() => {
    setStairDirections147(readStairDirections147(floor.id, window.localStorage))
  }, [floor.id])

'''
editor=once(editor,needle,effect+needle,'stair direction persistence floor switch')

# Event handlers in the Blueprint function, before the existing stair-editor confirmation.
needle='  async function finishRectangle('
if needle not in editor: raise RuntimeError('147: Blueprint new-room function is unavailable')
handlers='''  function storeStairDirections147(next: Record<string, StairDirection147>) {
    // Existing level assignments and stair element storage remain unchanged.
    try {
      window.localStorage.setItem(stairDirectionKey147(floor.id), JSON.stringify(next))
      setStairDirections147(next)
      window.dispatchEvent(new Event('strom:blueprint-levels-changed'))
    } catch (err) { onError(`Treppenrichtung konnte nicht gespeichert werden: ${String(err)}`) }
  }

  function chooseStairDirection147(direction: StairDirection147) {
    if (!selectedRoom || !isStairRoom(selectedRoom)) return
    const other = direction === 'up' ? stairUp147 : stairDown147
    if (other) { onSelectRoom(other.id); return }
    const currentDirection = stairDirections147[selectedRoom.id]
    const matchingUnassigned = stairRoomsHere147.find((room) => room.id !== selectedRoom.id && !stairDirections147[room.id])
    if (currentDirection && currentDirection !== direction && matchingUnassigned) {
      storeStairDirections147({ ...stairDirections147, [matchingUnassigned.id]: direction })
      onSelectRoom(matchingUnassigned.id)
      return
    }
    const next: Record<string, StairDirection147> = { ...stairDirections147, [selectedRoom.id]: direction }
    if (!currentDirection && matchingUnassigned) next[matchingUnassigned.id] = direction === 'up' ? 'down' : 'up'
    storeStairDirections147(next)
    onSelectRoom(selectedRoom.id)
  }

  async function createOtherStair147() {
    if (!selectedRoom || !isStairRoom(selectedRoom) || !selectedStairDirection147) return
    if (stairRoomsHere147.length > 1 || (stairUp147 && stairDown147)) return
    const opposite: StairDirection147 = selectedStairDirection147 === 'up' ? 'down' : 'up'
    try {
      onError(null)
      onCaptureUndoSnapshot()
      // RoomType=stair: the existing solid-wall builder excludes stair rooms.
      // Do not duplicate the physical walls or the existing stair layout data.
      const created = await createRoom({
        floorId: floor.id,
        name: `${selectedRoom.name} (${opposite === 'up' ? 'aufwärts' : 'abwärts'})`,
        shapeType: selectedRoom.shapeType,
        roomType: 'stair',
        wallThicknessM: selectedRoom.wallThicknessM,
        vertices: selectedRoom.vertices.map((point) => ({ ...point })),
      })
      setRoomLayerAssignments((current) => ({ ...current, [created.id]: activeLayerId }))
      storeStairDirections147({ ...stairDirections147, [created.id]: opposite })
      setStairPanelOpen(false)
      await onReload()
      onSelectRoom(created.id)
    } catch (err) { onError(err instanceof Error ? err.message : String(err)) }
  }

'''
editor=once(editor,needle,handlers+needle,'stair direction handlers')

# Keep new floating panel ONLY in the Blueprint canvas card, not in Wanddetail/3D Haus.
needle='        <CanvasRulers zoom={zoom} scrollLeft={scrollPosition.left} scrollTop={scrollPosition.top} />'
ui='''        {selectedRoom && isStairRoom(selectedRoom) && (roomLayerAssignments[selectedRoom.id] ?? defaultLayerId) === activeLayerId && (
          <div className="strom-stair-direction-floating147" aria-label="Treppenraumrichtung">
            <div className="strom-stair-direction-title147">Treppenraum · Richtung</div>
            <div className="strom-stair-direction-actions147">
              <button type="button" className={selectedStairDirection147 === 'up' ? 'active' : ''}
                title="Aufwärts: führt von dieser Ebene zur nächsthöheren"
                aria-pressed={selectedStairDirection147 === 'up'}
                onClick={() => chooseStairDirection147('up')}><StromIcon name="stair-run" title="Aufwärts" size={18} /> Aufwärts</button>
              <button type="button" className={selectedStairDirection147 === 'down' ? 'active' : ''}
                title="Abwärts: führt von dieser Ebene zur nächsttieferen"
                aria-pressed={selectedStairDirection147 === 'down'}
                onClick={() => chooseStairDirection147('down')}><StromIcon name="stair-run" title="Abwärts" size={18} className="strom-stair-down-icon147" /> Abwärts</button>
            </div>
            {!selectedStairDirection147 && <small>Richtung für diesen Treppenraum zuerst festlegen</small>}
            {selectedStairDirection147 && stairRoomsHere147.length === 1 && (
              <button type="button" className="strom-stair-create147" title="Zweiten unabhängigen Treppenraum auf derselben Grundfläche erstellen; vorhandene Stufen nicht kopieren"
                onClick={() => void createOtherStair147()}><StromIcon name="new-object" title="Gegenrichtung anlegen" size={18} /> Gegenrichtung anlegen</button>
            )}
            {stairRoomsHere147.length > 2 && <small>Hinweis: Mehr als zwei überlappende Treppenräume gefunden</small>}
            {stairRoomsHere147.length === 2 && <small>Aufwärts: {stairUp147 ? 'vorhanden' : 'offen'} · Abwärts: {stairDown147 ? 'vorhanden' : 'offen'}</small>}
          </div>
        )}
'''
editor=once(editor,needle,ui+needle,'floating stair direction chooser')
a=a[:p0]+editor+a[p1:]

# 3) Existing 3D staircase meshes use upward extrusions; mirror the SAME
# geometry vertically (without modifying stored steps) for a down staircase.
p0,p1,stair=between(s,'function StairSolid(', 'function SceneControls(', '3D stair mesh')
if 'surface: PlacedStairSurface143' not in stair: raise RuntimeError('147: stair mesh no longer has PlacedStairSurface143 surface')
# STROM147B: Select the top-level JSX return of StairSolid via the
# TypeScript parser, not by counting <mesh> tags. The real scene has more
# than one mesh; both belong in one reflected group.
import subprocess
stair_wrapper_js = r"""
'use strict'
const fs = require('node:fs')
const ts = require(process.env.STROM147_TS_DIR)
const source = fs.readFileSync(0, 'utf8')
const sf = ts.createSourceFile('StairSolid.tsx', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
if (sf.parseDiagnostics.length) throw Error('StairSolid JSX invalid before patch: ' + sf.parseDiagnostics.map(d => ts.flattenDiagnosticMessageText(d.messageText, ' ')).join('; '))
const found = sf.statements.filter(n => ts.isFunctionDeclaration(n) && n.name?.text === 'StairSolid')
if (found.length !== 1 || !found[0].body) throw Error(`StairSolid function count: ${found.length}`)
const fn = found[0]
const isJsx = n => ts.isJsxElement(n) || ts.isJsxFragment(n) || ts.isJsxSelfClosingElement(n)
function unwrap(n) { while (n && ts.isParenthesizedExpression(n)) n = n.expression; return n }
const roots = fn.body.statements.filter(ts.isReturnStatement).map(n => unwrap(n.expression)).filter(n => n && isJsx(n))
if (roots.length !== 1) throw Error(`Expected one top-level JSX return in StairSolid, found ${roots.length}`)
const jsx = roots[0]
if (source.includes('STROM147_DOWN_SCENE')) throw Error('StairSolid direction group already applied')
const start = jsx.getStart(sf)
const end = jsx.getEnd()
if (start >= end) throw Error('Invalid StairSolid JSX offsets')
const edits = [
  { pos: end, insert: '\n    </group>' },
  { pos: start, insert: '<group scale={[1, surface.direction147 === \'down\' ? -1 : 1, 1]}>\n      {/* STROM147_DOWN_SCENE: wraps all existing stair meshes; no geometry changes. */}\n      ' },
]
let meshCount = 0
let materialCount = 0
function walk(n) {
  if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
    const tag = n.tagName.getText(sf)
    if (tag === 'mesh') meshCount++
    if (/^mesh(?:Standard|Physical|Lambert|Phong|Basic|Toon|Normal|Depth|Matcap)Material$/.test(tag)) {
      materialCount++
      const sides = n.attributes.properties.filter(p => ts.isJsxAttribute(p) && p.name.getText(sf) === 'side')
      if (sides.length > 1) throw Error(`${tag} already has duplicate side attribute`)
      if (!sides.length) edits.push({ pos: n.tagName.getEnd(), insert: ' side={THREE.DoubleSide}' })
    }
  }
  ts.forEachChild(n, walk)
}
walk(jsx)
if (meshCount < 1) throw Error('No stair mesh found inside the returned JSX')
let result = source
for (const e of edits.sort((a, b) => b.pos - a.pos)) result = result.slice(0, e.pos) + e.insert + result.slice(e.pos)
const check = ts.createSourceFile('StairSolid-after.tsx', result, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
if (check.parseDiagnostics.length) throw Error('StairSolid JSX invalid after patch: ' + check.parseDiagnostics.map(d => ts.flattenDiagnosticMessageText(d.messageText, ' ')).join('; '))
console.error(`AST validated: ${meshCount} mesh JSX elements, ${materialCount} material elements; one wrapper group`)
process.stdout.write(result)
"""
result = subprocess.run(['node', '-e', stair_wrapper_js], input=stair, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
if result.returncode != 0:
    raise RuntimeError('147b: TypeScript AST wrapping failed: ' + result.stderr.strip()[-3000:])
if 'STROM147_DOWN_SCENE' not in result.stdout:
    raise RuntimeError('147b: AST wrapping produced no direction group')
print('147b stair JSX: ' + result.stderr.strip())
stair = result.stdout

s=s[:p0]+stair+s[p1:]

# 3b) 3D Haus "Alle Etagen" renders its own additional floor groups. Ensure
# those extra stair solids carry the same up/down direction as the active floor.
s=once(s,"import { buildStair3DSurfaces } from '../building/stair3d'",
    "import { buildStair3DSurfaces } from '../building/stair3d'\nimport { readStairDirections147 } from '../building/stairOverlay147'",
    'stair direction reader in 3D house')
s=once(s,"    let elevation146 = Number(floor.elevationM) || 0",
    "    const directions147 = readStairDirections147(floor.id, window.localStorage)\n    let elevation146 = Number(floor.elevationM) || 0",
    'one direction lookup for all 3D house levels')
s=once(s,"          ...surface146, levelId: item146.id, levelOffsetM: 0,",
    "          ...surface146, levelId: item146.id, levelOffsetM: 0, direction147: directions147[surface146.roomId] === 'down' ? 'down' : 'up',",
    'extra storey stair direction')

# 4) Reading the direction is a read-only addition to the existing per-layer stair adapter.
v=once(v,'  levelId: string\n}', '  levelId: string\n  direction147?: \'up\' | \'down\'\n}', 'stair surface direction field')
needle="  const rawLayers = readJson(storage, prefix + 'list')"
v=once(v,needle,needle+'''
  const rawDirections147 = readJson(storage, prefix + 'stairDirections147')
  const directions147 = rawDirections147 && typeof rawDirections147 === 'object' && !Array.isArray(rawDirections147)
    ? rawDirections147 as Record<string, unknown> : {}
''','stair direction read')
needle='      surfaces.push({ ...surface, levelId: level.id, levelOffsetM: offset })'
v=once(v,needle,"      surfaces.push({ ...surface, levelId: level.id, levelOffsetM: offset, direction147: directions147[surface.roomId] === 'down' ? 'down' : 'up' })",'apply physical stair direction')

c+='''
/* STROM147: compact floating stair direction chooser in the Blueprint only. */
.canvas-card { position: relative; }
.strom-stair-direction-floating147 {
  position: absolute; top: 64px; left: 18px; z-index: 45;
  display: flex; flex-direction: column; gap: 8px;
  width: max-content; max-width: min(340px, calc(100% - 35px));
  padding: 12px; border: 1px solid #b8c9e7; border-radius: 12px;
  background: rgba(255,255,255,.97); color: #243955;
  box-shadow: 0 7px 25px rgba(30,51,88,.14);
}
.strom-stair-direction-title147 { font-weight: 800; font-size: 12px; letter-spacing: .025em; }
.strom-stair-direction-actions147 { display: flex; flex-wrap: wrap; gap: 5px; }
.strom-stair-direction-actions147 button, .strom-stair-create147 {
  display:inline-flex; align-items:center; gap:6px;
  border: 1px solid #b4c8e4; border-radius: 8px; background: #f3f7ff;
  padding: 8px 11px; color: #234467; cursor: pointer; font-weight: 650;
}
.strom-stair-direction-actions147 button.active { background: #275ec6; border-color: #275ec6; color: #fff; }
.strom-stair-create147 { background: #e5efff; }
.strom-stair-down-icon147 { transform: rotate(180deg); }
.strom-stair-direction-floating147 small { color: #62738d; font-size: 11px; }
'''
# Only write after all scoped replacements and precondition checks succeed.
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(module.read_text(encoding='utf8'), encoding='utf8')
app.write_text(a,encoding='utf8')
scene.write_text(s,encoding='utf8')
visibility.write_text(v,encoding='utf8')
css.write_text(c,encoding='utf8')
print('147: clean windows, independently selectable up/down stair wells, optional second stair room, 3D downward stair transform')

STROM147_PATCH_PY
# Regression 142/143: compare the exact filename generated with the one consumed.
for p in "$WORK_DIR/.strom147_stairOverlay.ts" "$WORK_DIR/.strom147_patch.py"; do
  [ -s "$p" ] || fail "147 eingebettete Patch-Datei fehlt: $p"
done
python3 -m py_compile "$WORK_DIR/.strom147_patch.py" >> "$DIAG_LOG" 2>&1 || fail "147 Python-Syntax fehlerhaft"
STROM147_ROOT="$WORK_DIR" STROM147_MODULE="$WORK_DIR/.strom147_stairOverlay.ts" \
  STROM147_TS_DIR="$DEPENDENCIES/typescript" python3 "$WORK_DIR/.strom147_patch.py" >> "$DIAG_LOG" 2>&1 || fail "147b Quellpatch fehlgeschlagen. Kein Git-Push / kein Stage-Deployment."
rm -f "$WORK_DIR/.strom147_patch.py" "$WORK_DIR/.strom147_stairOverlay.ts"

cat > "$WORK_DIR/docs/STROM_UPDATE_147.md" <<'STROM147_DOC'
# STROM Update 147b – Fenster, gepaarte Treppenraeume (JSX-Korrektur)
- Die Frontansicht im Wanddetail zeigt das bestehende Fenster mit Rahmen, Glas und Fensterbank, aber ohne Mittel- oder Quersprosse. Tueren und Bibliotheks-Icons bleiben unveraendert.
- Blueprint: Bei Auswahl eines Treppenraums wird eine kleine schwebende Richtungswahl angezeigt. Zuerst Aufwaerts/Abwaerts festlegen; anschliessend Gegenrichtung anlegen.
- Der zweite Treppenraum ist ein eigenes Raumobjekt mit der exakt gleichen Kontur. `roomType=stair` wird im massiven Wandsolid bereits gesondert behandelt. Sein Treppenlayout beginnt leer und ist unabhaengig editierbar.
- Die UI ermittelt das Treppenpaar aus derselben Ebene und deckungsgleichen Konturen. Aufwaerts/Abwaerts waehlen das jeweilige Raumobjekt aus.
- Die Richtung liegt vorerst im gleichen Browser-Storage-Adapter wie die Blueprint-Ebenen: `strom.floorplan.layers.<floorId>.stairDirections147`. Kein Datenbank-Umbau.
- 3D: Aufwaerts-Treppen unveraendert, Abwaerts-Treppen werden durch eine umschliessende 3D-Gruppe an der Geschossgrundebene gespiegelt. Vorhandene Mesh-Attribute bleiben unveraendert. Keine Geometrie-/Wandmutation. Vor Build werden alle JSX-Attribute auf Duplikate geprueft.
- Dachschraegen sind Gegenstand eines SEPARATEN Entwurfs und werden mit diesem Script NICHT im Projekt gespeichert oder dargestellt.
STROM147_DOC

log "3.1) TSX-Vorabpruefung: doppelte JSX-Attribute, JSX-Syntax und 3D-Treppengruppierung ..."
export STROM147_TS_DIR="$DEPENDENCIES/typescript"
export STROM147_TSCHECK_DIR="$WORK_DIR/frontend/src"
node <<'STROM147A_VALIDATE_JSX' >> "$DIAG_LOG" 2>&1 || fail "147b: JSX-Vorabpruefung fehlgeschlagen, kein Git-Push/Stage-Deployment."
'use strict'
const fs=require('node:fs')
const ts=require(process.env.STROM147_TS_DIR)
const root=process.env.STROM147_TSCHECK_DIR
let count=0
for (const file of ['App.tsx','components/Building3DWorkspace.tsx']) {
  const content=fs.readFileSync(`${root}/${file}`,'utf8')
  const sf=ts.createSourceFile(file,content,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
  if(sf.parseDiagnostics.length) throw Error(file+': '+sf.parseDiagnostics.map(d=>`${d.code} ${ts.flattenDiagnosticMessageText(d.messageText,' ')}`).join('; '))
  function walk(node) {
    if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node)) {
      const used=new Map()
      for(const attr of node.attributes.properties) {
        if(!ts.isJsxAttribute(attr)) continue
        const name=attr.name.getText(sf)
        if(used.has(name)) {
          const pos=sf.getLineAndCharacterOfPosition(attr.getStart(sf))
          throw Error(`${file}:${pos.line+1}:${pos.character+1}: doppeltes JSX-Attribut ${name} (erstes Vorkommen: ${used.get(name)})`)
        }
        used.set(name,sf.getLineAndCharacterOfPosition(attr.getStart(sf)).line+1)
        count++
      }
    }
    ts.forEachChild(node,walk)
  }
  walk(sf)
  if(file.endsWith('Building3DWorkspace.tsx')) {
    if(!content.includes('STROM147_DOWN_SCENE') || !/\<group scale=\{\[1, surface\.direction147 === 'down' \? -1 : 1, 1\]\}/.test(content)) {
      throw Error('3D-Treppen-Spiegelung in separater Gruppe fehlt')
    }
  }
}
console.log(`PASS: ${count} JSX-Attribute ohne Duplikate, beide TSX-Dateien syntaktisch valide, Down-Stair in eigener 3D-Gruppe`)
STROM147A_VALIDATE_JSX

log "4) TypeScript/Vite komplett pruefen (vor Git-Push) ..."
( cd "$WORK_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >> "$DIAG_LOG" 2>&1 \
  || fail "147 Frontend Build/TypeScript fehlgeschlagen; nichts wurde gepusht."

log "4.1) Regressionstests (Treppenrichtung, zwei gleiche Konturen, Fenster, 3D) ..."
export STROM147_WORK_DIR="$WORK_DIR"
export STROM147_TS="$DEPENDENCIES/typescript"
node <<'STROM147_TEST_JS' >> "$DIAG_LOG" 2>&1 || fail "147 Regressionstests fehlgeschlagen; kein Git-Push."
'use strict'
const assert=require('node:assert/strict');const fs=require('node:fs');const ts=require(process.env.STROM147_TS)
const root=process.env.STROM147_WORK_DIR+'/frontend/src/'
const app=fs.readFileSync(root+'App.tsx','utf8');const scene=fs.readFileSync(root+'components/Building3DWorkspace.tsx','utf8')
const visibility=fs.readFileSync(root+'building/stairVisibility143.ts','utf8'); const helper=fs.readFileSync(root+'building/stairOverlay147.ts','utf8')
for(const file of ['App.tsx','components/Building3DWorkspace.tsx','building/stairOverlay147.ts','building/stairVisibility143.ts']) {
  const name=root+file
  const t=ts.transpileModule(fs.readFileSync(name,'utf8'),{fileName:name,reportDiagnostics:true,compilerOptions:{module:ts.ModuleKind.ESNext,jsx:ts.JsxEmit.ReactJSX,target:ts.ScriptTarget.ES2020}})
  const problems=(t.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error)
  assert.equal(problems.length,0,file+': '+problems.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')))
}
assert.match(app,/STROM147_STAIR_DIRECTIONS/)
assert.match(app,/Gegenrichtung anlegen/)
assert.match(app,/createRoom\(\{\s*floorId: floor.id,[\s\S]*?roomType: 'stair'/)
assert.match(app,/stairRoomsHere147\.find\(/)
assert(!app.includes('className="wall-front-window-mullion146"'))
assert(!app.includes('className="wall-front-window-transom146"'))
assert.match(app,/wall-front-window-glass146/)
assert.match(scene,/STROM147_DOWN_SCENE/)
assert.match(scene,/<group scale=\{\[1, surface\.direction147 === 'down' \? -1 : 1, 1\]\}>/)
assert.match(visibility,/direction147: directions147\[surface\.roomId\]/)
const transpiled=ts.transpileModule(helper,{fileName:'stairOverlay147.ts',compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText
const mod={exports:{}};new Function('module','exports',transpiled)(mod,mod.exports)
const {sameStairFootprint147,readStairDirections147,stairDirectionKey147}=mod.exports
const a={vertices:[{x:0,y:0},{x:2,y:0},{x:2,y:3},{x:0,y:3}]}
const same={vertices:[{x:2,y:3},{x:0,y:3},{x:0,y:0},{x:2,y:0}]}
const diff={vertices:[{x:0,y:0},{x:2.02,y:0},{x:2,y:3},{x:0,y:3}]}
assert(sameStairFootprint147(a,same));assert(!sameStairFootprint147(a,diff))
const storage={getItem(k){return k===stairDirectionKey147('floor1')?JSON.stringify({r1:'up',r2:'down',corrupt:'other'}):null}}
assert.deepEqual(readStairDirections147('floor1',storage),{r1:'up',r2:'down'})
assert.deepEqual(readStairDirections147('missing',storage),{})
console.log('PASS: semantic helpers, 0.001m footprint matching, room pair, window no cross, 3d group transform, TSX syntax')
STROM147_TEST_JS

log "5) Gepruefte Quelldateien in Stage-Arbeitskopie uebernehmen ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >> "$DIAG_LOG" 2>&1 || fail "147 Stage-Quellkopie fehlgeschlagen. Backup: $BACKUP_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Patch, voller Build und Regressionstests bestanden. Kein Live-Deployment."
  exit 0
fi

log "6) Stage erneut bauen und nur /strom-test/ veroeffentlichen ..."
( cd "$STAGE_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >> "$DIAG_LOG" 2>&1 \
  || fail "147 Stage-Build fehlgeschlagen. Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "147: Stage dist fehlt. Backup: $BACKUP_DIR"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >> "$DIAG_LOG" 2>&1 \
  || fail "147: Web-Deployment fehlgeschlagen. Backup: $BACKUP_DIR"
log ""
log "147 erfolgreich auf https://home.moja.de/strom-test/"
log "Wanddetail-Fenster ohne Kreuz; Treppenwahl im Blueprint und Spiegelung abwaerts in 3D."
log "Produktion und Dachgeometrie unveraendert."
