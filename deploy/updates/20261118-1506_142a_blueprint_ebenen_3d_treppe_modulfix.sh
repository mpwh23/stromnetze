#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-1506_142a_blueprint_ebenen_3d_treppe_modulfix"
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
COMMIT_MESSAGE="Update 142a: Blueprint-Ebenen/Geschosshoehen, echte 3D-Treppe, blaue Raumauswahl (Modulpfade korrigiert)"
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
  echo "2) Aktuellen Stage-Source + Update 142 nach GitHub pushen ..."
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

  echo "1.3) Update 142 auf Git-Source anwenden und Build pruefen ..."
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

log "=== Update 142 / Blueprint-Ebenen + Geschosshoehen + echte 3D-Treppe ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
log "Wandvolumen, Wandbearbeitung, Wandhover, Blueprint-Zeichenwerkzeuge werden beibehalten."
[ -f "$STAGE_DIR/frontend/src/building/solidGeometry.ts" ] || fail "Update 139 fehlt."
[ -f "$STAGE_DIR/frontend/src/building/wallHitSelection.ts" ] || fail "Update 140a fehlt."
[ -f "$STAGE_DIR/frontend/src/building/wallHoverGeometry.ts" ] || fail "Update 141a fehlt."
[ -f "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" ] || fail "3D-Renderer fehlt."
[ -f "$STAGE_DIR/frontend/src/App.tsx" ] || fail "Blueprint fehlt."
[ -f "$STAGE_DIR/frontend/src/styles.css" ] || fail "CSS fehlt."
select_node

log "0) Ebenen-Bestand pruefen (ohne Daten oder Einstellungen zu veraendern)..."
{
  echo '--- Blueprint-Ebenen / Quellstand ---'
  grep -n 'type FloorplanLayer\|type LayerVisibilityMode\|function renderStateForLayer\|function toggleLayerVisibility\|function moveLayerBefore\|function readStairLayoutElements' "$STAGE_DIR/frontend/src/App.tsx" || true
  echo '--- 3D-Funktionen ---'
  grep -n 'function FloorMesh\|function SolidWallMeshes\|function RealBuildingScene\|function Building3DWorkspace' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || true
} >>"$DIAG_LOG"

log "1) Stage-Sicherung erstellen..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Nur isolierte Git-Arbeitskopie pruefen."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage-Backup fehlgeschlagen."
fi

log "2) Isolierte Arbeitskopie vorbereiten..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Source-Kopie fehlgeschlagen."
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
[ -n "$DEPENDENCIES" ] || fail "Frontend-Abhaengigkeiten (typescript/vite/three) fehlen."
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"

log "3) 3D-Treppe, blaue Raumauswahl und Blueprint-Ebenen gezielt integrieren..."
cat > "$WORK_DIR/.strom142_blueprintLevels.ts" <<'STROM142_LEVELS'
import type { Floor, Room } from '../types'

/**
 * 142: Read the existing Blueprint layer storage format without changing keys.
 * This is a transitional adapter: no room or layer is duplicated for 3D.
 * Cross-browser DB persistence of layer metadata is a separate later migration.
 */
export type BlueprintLevelView = {
  id: string
  name: string
  heightM: number
  elevationM: number
  rooms: Room[]
  layerCount: number
}

export type KeyValueReader = { getItem(key: string): string | null }

const DEFAULT_LAYER_ID = 'layer-main'
const roundMm = (value: number) => Math.round(value * 1000) / 1000
const clampHeight = (height: number, fallback: number) => Number.isFinite(height) && height >= 0.1 && height <= 10 ? roundMm(height) : fallback

function readJson(storage: KeyValueReader, key: string): unknown {
  try {
    const raw = storage.getItem(key)
    return raw ? JSON.parse(raw) as unknown : null
  } catch {
    return null
  }
}

export function readActiveBlueprintLevel(floor: Floor, rooms: Room[], storage: KeyValueReader): BlueprintLevelView {
  const prefix = `strom.floorplan.layers.${floor.id}.`
  const storedLayers = readJson(storage, prefix + 'list')
  const fallbackHeightM = clampHeight(Number(floor.heightM), 2.5)
  const layers: Array<{ id: string; name: string; heightM: number }> = Array.isArray(storedLayers)
    ? storedLayers.flatMap((value: unknown, index: number) => {
      if (!value || typeof value !== 'object') return []
      const layer = value as Record<string, unknown>
      if (typeof layer.id !== 'string' || !layer.id) return []
      return [{
        id: layer.id,
        name: typeof layer.name === 'string' ? layer.name : `Ebene ${index + 1}`,
        heightM: clampHeight(Number(layer.heightM), fallbackHeightM),
      }]
    })
    : []
  if (!layers.length) layers.push({ id: DEFAULT_LAYER_ID, name: 'Ebene 1', heightM: fallbackHeightM })
  const activeId = readJson(storage, prefix + 'active')
  const activeIndex = layers.findIndex((layer) => layer.id === activeId)
  const index = activeIndex >= 0 ? activeIndex : 0
  const current = layers[index]
  const roomAssignmentsRaw = readJson(storage, prefix + 'roomAssignments')
  const assignments = roomAssignmentsRaw && typeof roomAssignmentsRaw === 'object' && !Array.isArray(roomAssignmentsRaw)
    ? roomAssignmentsRaw as Record<string, unknown>
    : {}
  return {
    id: current.id,
    name: current.name,
    heightM: current.heightM,
    elevationM: roundMm((Number(floor.elevationM) || 0) + layers.slice(0, index).reduce((sum, layer) => sum + layer.heightM, 0)),
    rooms: rooms.filter((room) => (typeof assignments[room.id] === 'string' ? assignments[room.id] : DEFAULT_LAYER_ID) === current.id),
    layerCount: layers.length,
  }
}

export function active3DFloor(floor: Floor, level: BlueprintLevelView): Floor {
  return { ...floor, heightM: level.heightM, elevationM: level.elevationM, name: `${floor.name} / ${level.name}` }
}
STROM142_LEVELS
cat > "$WORK_DIR/.strom142_stairs.ts" <<'STROM142_STAIRS'
import type { PointM, Room } from '../types'
import type { KeyValueReader } from './blueprintLevels'

/** Real tread footprints in metres, shared by the 3D scene and future 2D preview. */
export type Stair3DSurface = {
  key: string
  roomId: string
  points: PointM[]
  elevationM: number
  kind: 'landing' | 'step'
}

type StairKind = 'landing' | 'stair' | 'turn'
type StairElement = {
  id: string
  kind: StairKind
  xM: number
  yM: number
  widthM: number
  heightM: number
  rotationDeg: number
  steps: number
  mirrored: boolean
}

type StairEdgeAssignment = { kind?: string; edgeIndex?: number }

const dist = (a: PointM, b: PointM) => Math.hypot(a.x - b.x, a.y - b.y)
const center = (e: StairElement): PointM => ({ x: e.xM + e.widthM / 2, y: e.yM + e.heightM / 2 })
const avg = (a: PointM, b: PointM): PointM => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 })
const safeSteps = (e: StairElement) => Math.max(1, Math.min(128, Math.round(e.steps)))
const rectCorners = (e: StairElement) => ({ left: e.xM, right: e.xM + e.widthM, top: e.yM, bottom: e.yM + e.heightM })
const r3 = (x: number) => Math.round(x * 1000) / 1000

function readArray(storage: KeyValueReader, key: string): unknown[] {
  try {
    const raw = storage.getItem(key)
    const value: unknown = raw ? JSON.parse(raw) : []
    return Array.isArray(value) ? value : []
  } catch { return [] }
}

function loadStairElements(roomId: string, storage: KeyValueReader): StairElement[] {
  return readArray(storage, `strom-stair-layout:${roomId}`).flatMap((raw) => {
    if (!raw || typeof raw !== 'object') return []
    const e = raw as Record<string, unknown>
    if (e.kind !== 'stair' && e.kind !== 'turn' && e.kind !== 'landing') return []
    const xM = Number(e.xM), yM = Number(e.yM), widthM = Number(e.widthM), heightM = Number(e.heightM)
    if (![xM, yM, widthM, heightM].every(Number.isFinite) || widthM < 0.01 || heightM < 0.01) return []
    return [{
      id: String(e.id || `${e.kind}-${xM}-${yM}`), kind: e.kind, xM, yM, widthM, heightM,
      rotationDeg: Number(e.rotationDeg) || 0, steps: Number(e.steps) || 1, mirrored: Boolean(e.mirrored),
    }]
  })
}

function mapPoint(e: StairElement, unit: PointM): PointM {
  const rotation = ((Math.round(e.rotationDeg / 90) % 4) + 4) % 4
  const dx = unit.x - 0.5, dy = unit.y - 0.5
  const rotated = rotation === 1 ? { x: 0.5 + dy, y: 0.5 - dx }
    : rotation === 2 ? { x: 0.5 - dx, y: 0.5 - dy }
      : rotation === 3 ? { x: 0.5 - dy, y: 0.5 + dx } : unit
  return { x: e.xM + rotated.x * e.widthM, y: e.yM + rotated.y * e.heightM }
}

function arrow(e: StairElement): { start: PointM; end: PointM } {
  if (e.kind !== 'turn') return { start: mapPoint(e, { x: 0.5, y: 0.78 }), end: mapPoint(e, { x: 0.5, y: 0.22 }) }
  return e.mirrored
    ? { start: mapPoint(e, { x: 0.28, y: 0.84 }), end: mapPoint(e, { x: 0.76, y: 0.56 }) }
    : { start: mapPoint(e, { x: 0.72, y: 0.84 }), end: mapPoint(e, { x: 0.24, y: 0.56 }) }
}

function currentFloorOrigin(room: Room, storage: KeyValueReader): PointM {
  const assignments = readArray(storage, `strom-stair-edge-assignments:${room.id}`) as StairEdgeAssignment[]
  const entry = assignments.find((a) => a.kind === 'current-floor' && Number.isInteger(a.edgeIndex))
  if (entry && room.vertices.length > 1) {
    const i = ((Number(entry.edgeIndex) % room.vertices.length) + room.vertices.length) % room.vertices.length
    return avg(room.vertices[i], room.vertices[(i + 1) % room.vertices.length])
  }
  return room.vertices.length ? room.vertices.reduce((acc, p) => ({ x: acc.x + p.x / room.vertices.length, y: acc.y + p.y / room.vertices.length }), { x: 0, y: 0 }) : { x: 0, y: 0 }
}

function orderElements(room: Room, elements: StairElement[], storage: KeyValueReader): StairElement[] {
  const remain = [...elements]
  if (remain.length < 2) return remain
  const ordered: StairElement[] = []
  const entry = currentFloorOrigin(room, storage)
  remain.sort((a, b) => dist(entry, arrow(a).start) - dist(entry, arrow(b).start))
  ordered.push(remain.shift()!)
  while (remain.length) {
    const current = ordered[ordered.length - 1]
    const end = arrow(current).end
    const dx = end.x - arrow(current).start.x, dy = end.y - arrow(current).start.y
    const length = Math.hypot(dx, dy) || 1
    remain.sort((a, b) => {
      const score = (e: StairElement) => {
        const next = arrow(e)
        const displacement = { x: center(e).x - end.x, y: center(e).y - end.y }
        const backwards = Math.max(0, -(displacement.x * dx + displacement.y * dy) / length)
        return dist(end, next.start) + backwards * 2.5 + (dist(end, next.end) < dist(end, next.start) ? 0.25 : 0)
      }
      return score(a) - score(b)
    })
    ordered.push(remain.shift()!)
  }
  return ordered
}

function neighborOnRight(e: StairElement, elements: StairElement[]) {
  const straight = elements.filter((other) => other.id !== e.id && other.kind === 'stair')
  const candidates = straight.length ? straight : elements.filter((other) => other.id !== e.id)
  if (!candidates.length) return !e.mirrored
  candidates.sort((a, b) => dist(center(a), center(e)) - dist(center(b), center(e)))
  return center(candidates[0]).x > center(e).x
}

function rayRect(origin: PointM, rect: ReturnType<typeof rectCorners>, angle: number): PointM {
  const dx = Math.cos(angle), dy = Math.sin(angle)
  const options: Array<{ t: number; point: PointM }> = []
  const epsilon = 1e-8
  if (Math.abs(dx) > epsilon) {
    for (const x of [rect.left, rect.right]) {
      const t = (x - origin.x) / dx
      const y = origin.y + t * dy
      if (t > epsilon && y >= rect.top - epsilon && y <= rect.bottom + epsilon) options.push({ t, point: { x, y: Math.min(rect.bottom, Math.max(rect.top, y)) } })
    }
  }
  if (Math.abs(dy) > epsilon) {
    for (const y of [rect.top, rect.bottom]) {
      const t = (y - origin.y) / dy
      const x = origin.x + t * dx
      if (t > epsilon && x >= rect.left - epsilon && x <= rect.right + epsilon) options.push({ t, point: { x: Math.min(rect.right, Math.max(rect.left, x)), y } })
    }
  }
  options.sort((a, b) => a.t - b.t)
  return options[0]?.point ?? origin
}

/**
 * Returns non-overlapping tread footprints; step elevations run from 'Diese Etage'
 * along the already stored direction arrows. Does not alter the stored layout.
 */
export function buildStair3DSurfaces(rooms: Room[], floorHeightM: number, storage: KeyValueReader): Stair3DSurface[] {
  const surfaces: Stair3DSurface[] = []
  const safeHeight = Math.max(0.1, floorHeightM)
  for (const room of rooms) {
    const elements = loadStairElements(room.id, storage)
    if (!elements.length) continue
    const ordered = orderElements(room, elements, storage)
    const total = ordered.reduce((sum, e) => sum + (e.kind === 'landing' ? 0 : safeSteps(e)), 0)
    const rise = total > 0 ? safeHeight / total : 0
    let previousSteps = 0
    for (const e of ordered) {
      const r = rectCorners(e)
      if (e.kind === 'landing') {
        surfaces.push({
          key: `${room.id}:${e.id}:landing`, roomId: room.id, kind: 'landing', elevationM: r3(previousSteps * rise),
          points: [{ x: r.left, y: r.top }, { x: r.right, y: r.top }, { x: r.right, y: r.bottom }, { x: r.left, y: r.bottom }],
        })
        continue
      }
      const n = safeSteps(e)
      if (e.kind === 'stair') {
        const rotation = ((Math.round(e.rotationDeg / 90) % 4) + 4) % 4
        for (let i = 0; i < n; i += 1) {
          const t0 = i / n, t1 = (i + 1) / n
          let left = r.left, right = r.right, top = r.top, bottom = r.bottom
          if (rotation === 1) { left = r.right - e.widthM * t1; right = r.right - e.widthM * t0 }
          else if (rotation === 3) { left = r.left + e.widthM * t0; right = r.left + e.widthM * t1 }
          else if (rotation === 2) { top = r.top + e.heightM * t0; bottom = r.top + e.heightM * t1 }
          else { top = r.bottom - e.heightM * t1; bottom = r.bottom - e.heightM * t0 }
          surfaces.push({
            key: `${room.id}:${e.id}:step${i}`, roomId: room.id, kind: 'step', elevationM: r3((previousSteps + i + 1) * rise),
            points: [{ x: left, y: top }, { x: right, y: top }, { x: right, y: bottom }, { x: left, y: bottom }],
          })
        }
      } else {
        const onRight = neighborOnRight(e, ordered)
        const origin = onRight ? { x: r.right, y: r.bottom } : { x: r.left, y: r.bottom }
        const angleA = onRight ? Math.PI : -Math.PI / 2
        const angleB = onRight ? Math.PI * 1.5 : 0
        const startPoint = rayRect(origin, r, angleA)
        const endPoint = rayRect(origin, r, angleB)
        const dir = arrow(e)
        const reverse = dist(dir.start, endPoint) + dist(dir.end, startPoint) < dist(dir.start, startPoint) + dist(dir.end, endPoint)
        const startAngle = reverse ? angleB : angleA
        const endAngle = reverse ? angleA : angleB
        for (let i = 0; i < n; i += 1) {
          const p0 = rayRect(origin, r, startAngle + (endAngle - startAngle) * i / n)
          const p1 = rayRect(origin, r, startAngle + (endAngle - startAngle) * (i + 1) / n)
          const triangle = [origin, p0, p1]
          // Zero-size degenerate step surfaces must never enter Three.js.
          const area2 = Math.abs((p0.x - origin.x) * (p1.y - origin.y) - (p0.y - origin.y) * (p1.x - origin.x))
          if (area2 < 1e-8) continue
          surfaces.push({
            key: `${room.id}:${e.id}:turn${i}`, roomId: room.id, kind: 'step', elevationM: r3((previousSteps + i + 1) * rise), points: triangle,
          })
        }
      }
      previousSteps += n
    }
  }
  return surfaces
}
STROM142_STAIRS
cat > "$WORK_DIR/.strom142_patch.py" <<'STROM142_PATCH'
from pathlib import Path
import os
import re

root = Path(os.environ['STROM142_ROOT'])
module_source = Path(os.environ['STROM142_MODULE_DIR'])
app = root / 'frontend/src/App.tsx'
scene = root / 'frontend/src/components/Building3DWorkspace.tsx'
css = root / 'frontend/src/styles.css'
assert all(p.is_file() for p in (app, scene, css)), '142: current Stage files missing'
assert (root/'frontend/src/building/solidGeometry.ts').is_file(), '142 requires current 139 solid geometry'
assert (root/'frontend/src/building/wallHitSelection.ts').is_file(), '142 requires 140a wall clicks'
assert (root/'frontend/src/building/wallHoverGeometry.ts').is_file(), '142 requires 141a wall hover'

s = app.read_text(encoding='utf8')
c = scene.read_text(encoding='utf8')
style = css.read_text(encoding='utf8')
if 'STROM142_BLUEPRINT_LEVELS' in s or 'STROM142_STAIRS3D' in c:
    raise RuntimeError('Update 142 already present, refusing duplicate patch')


def exactly(text: str, old: str, new: str, reason: str):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'142: {reason}: expected 1 anchor, found {count}')
    return text.replace(old,new,1)

# Preserve existing keys/IDs to avoid losing older Blueprint layer data.
s = exactly(s,
    'type FloorplanLayer = { id: string; name: string; visible: boolean }',
    'type FloorplanLayer = { id: string; name: string; visible: boolean; heightM?: number }',
    'extend Blueprint layers non-destructively')

s = exactly(s,
    "      visible: item.visible !== false,\n    }))",
    "      visible: item.visible !== false,\n      heightM: Number.isFinite(Number(item.heightM)) && Number(item.heightM) >= 0.1 && Number(item.heightM) <= 10 ? round3(Number(item.heightM)) : undefined,\n    }))",
    'read existing layer heights without destroying names/visibility')

anchor = '''function loadLayerAssignments(floorId: string): Record<string, string> {'''
new_func = '''// STROM142_BLUEPRINT_LEVELS: retain the user's last visibility mode per Blueprint.
function loadLayerVisibilityMode(floorId: string): LayerVisibilityMode {
  const stored = safeReadJson<string | null>(layerStorageKey(floorId, 'visibilityMode'), null)
  return stored === 'active' || stored === 'adjacentGhostNoDims' || stored === 'adjacentGhostDims' || stored === 'allGhostNoDims'
    ? stored : 'active'
}

'''
s = exactly(s, anchor, new_func + anchor, 'load visibility mode')

s = exactly(s,
    "  const [layerVisibilityMode, setLayerVisibilityMode] = useState<LayerVisibilityMode>('active')",
    "  const [layerVisibilityMode, setLayerVisibilityMode] = useState<LayerVisibilityMode>(() => loadLayerVisibilityMode(floor.id))",
    'initialize saved visibility mode')

# Floor-change effect can otherwise overwrite new floor metadata with the old floor's state.
s = exactly(s,
    "    setLayerVisibilityMode('active')\n    setLayerDeleteRequestId('')",
    "    setLayerVisibilityMode(loadLayerVisibilityMode(floor.id))\n    setLayerDeleteRequestId('')",
    'restore previous visibility when switching floors')

save_anchor = '''  useEffect(() => {
    localStorage.setItem(layerStorageKey(floor.id, 'active'), JSON.stringify(activeLayerId))
  }, [floor.id, activeLayerId])'''
s = exactly(s, save_anchor, save_anchor + '''

  useEffect(() => {
    try { localStorage.setItem(layerStorageKey(floor.id, 'visibilityMode'), JSON.stringify(layerVisibilityMode)) }
    catch { /* Browser persistence may be disabled */ }
  }, [floor.id, layerVisibilityMode])''', 'persist mode')

# Do not erase room assignments during temporary async zero-room refreshes; newer room
# IDs still default to the currently active level, preserving the earlier workflow.
start = "    setRoomLayerAssignments((current) => {\n      const next: Record<string, string> = {}"
end = "  }, [rooms, layers, activeLayerId])"
pos = s.find(start)
end_pos = s.find(end, pos)
if pos == -1 or end_pos == -1 or s.count(start) != 1:
    raise RuntimeError('142: room-layer assignment reconciliation anchor changed')
original = s[pos:end_pos]
replacement = '''    setRoomLayerAssignments((current) => {
      const next: Record<string, string> = { ...current }
      let changed = false
      rooms.forEach((room) => {
        const stored = current[room.id]
        // Missing rooms are deliberately NOT purged while the API reloads.
        const mapped = stored && layerIds.has(stored)
          ? stored
          : (activeLayerId && layerIds.has(activeLayerId) ? activeLayerId : layers[0]?.id ?? defaultLayerId)
        if (mapped !== stored) { next[room.id] = mapped; changed = true }
      })
      return changed ? next : current
    })
'''
s = s[:pos] + replacement + s[end_pos:]

s = exactly(s,
    "    const layer: FloorplanLayer = { id: `layer-${Date.now()}`, name: finalName, visible: true }",
    "    const layer: FloorplanLayer = { id: `layer-${Date.now()}`, name: finalName, visible: true, heightM: activeLayer.heightM ?? floor.heightM }",
    'new level from stair editor gets height')
s = exactly(s,
    "    const layer: FloorplanLayer = { id: `layer-${Date.now()}`, name: `Ebene ${layers.length + 1}`, visible: true }",
    "    const layer: FloorplanLayer = { id: `layer-${Date.now()}`, name: `Ebene ${layers.length + 1}`, visible: true, heightM: activeLayer.heightM ?? floor.heightM }",
    'new level gets height')

# There is another selectLayer function in the legacy Wanddetail; modify only Blueprint.
selector_old = "  function selectLayer(id: string) {\n    setActiveLayerId(id)"
assert s.count(selector_old) in (1, 2), '142: unexpected selectLayer functions'
s = s.replace(selector_old,
    "  function selectLayer(id: string) {\n    setLayers((current) => current.map((layer) => layer.id === id && !layer.visible ? { ...layer, visible: true } : layer))\n    setActiveLayerId(id)", 1)

s = exactly(s,
    '''  function toggleLayerVisibility(id: string) {
    setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, visible: !layer.visible } : layer))
  }''',
    '''  function toggleLayerVisibility(id: string) {
    const target = layers.find((layer) => layer.id === id)
    if (!target) return
    // In 'only current' mode, clicking an inactive eye should SHOW the chosen
    // level, not silently flip its internal flag to false.
    if (id !== activeLayerId && layerVisibilityMode === 'active') {
      if (!target.visible) setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, visible: true } : layer))
      setLayerVisibilityMode('allGhostNoDims')
      return
    }
    setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, visible: !layer.visible } : layer))
  }

  function setLayerHeightM(id: string, millimetres: number) {
    if (!Number.isFinite(millimetres)) return
    const heightM = clamp(round3(millimetres / 1000), 0.1, 10)
    setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, heightM } : layer))
  }''',
    'fix visibility toggle and add per-level height')

s = exactly(s,
    "    if (active) return { visible: true, ghost: false, dimensions: true, interactive: true }",
    "    if (active) return { visible: layerVisible, ghost: false, dimensions: true, interactive: layerVisible }",
    'active-layer eye must control actual visibility')

# The toolbar visibility mode icon remains synchronized with the eye markers.
# Add height input to each row; blur/Enter commit allows full numeric editing.
layer_name_input = re.compile(r'''(                      <input\n                        aria-label="Ebenenname"[\s\S]*?                      />\n)(                      <button\n                        type="button"\n                        className="layer-grip")''')
if len(layer_name_input.findall(s)) != 1:
    raise RuntimeError('142: expected exactly one layer-name input + drag grip')
height_input = '''                      <label className="layer-height-control" title="Geschosshoehe dieser Ebene in Millimetern">
                        <span>Höhe (mm)</span>
                        <input
                          key={`${layer.id}-${Math.round((layer.heightM ?? floor.heightM) * 1000)}`}
                          aria-label={`Geschosshoehe ${layer.name} in Millimetern`}
                          type="number"
                          min="100"
                          max="10000"
                          step="10"
                          defaultValue={Math.round((layer.heightM ?? floor.heightM) * 1000)}
                          onMouseDown={(event) => event.stopPropagation()}
                          onClick={(event) => event.stopPropagation()}
                          onDragStart={(event) => event.preventDefault()}
                          onBlur={(event) => setLayerHeightM(layer.id, Number(event.currentTarget.value))}
                          onKeyDown={(event) => { if (event.key === 'Enter') event.currentTarget.blur() }}
                        />
                      </label>
'''
s = layer_name_input.sub(lambda m: m.group(1) + height_input + m.group(2), s, count=1)

# Blueprint 136 replaced the old menu glyph by StromIcon; retain whichever icon
# is present. Legacy Wanddetail has an independent menu and must not change.
layer_button_rx = re.compile(r'(<button type="button" title="Ebenen" onClick=\{\(\) => setLayersOpen\(\(current\) => !current\)\}>)' + r'([\s\S]*?)' + r'(\{activeLayer\.name\}</button>)')
layer_buttons = list(layer_button_rx.finditer(s))
if len(layer_buttons) not in (1, 2):
    raise RuntimeError(f'142: expected Blueprint layer button(s), found {len(layer_buttons)}')
m = layer_buttons[0]
button_content = m.group(2)
new_button = m.group(1).replace('title="Ebenen"','title="Ebenen und Geschosshoehen bearbeiten"') + button_content + '{activeLayer.name} · {Math.round((activeLayer.heightM ?? floor.heightM) * 1000)} mm</button>'
s = s[:m.start()] + new_button + s[m.end():]

# The FloorplanEditor must remount on a different API Floor ID; otherwise its
# persistence effects can write stale layer metadata into another floor.
s = exactly(s,
    '''            <FloorplanEditor
              floor={floor}''',
    '''            <FloorplanEditor
              key={floor.id}
              floor={floor}''',
    'per-floor independent layer states')

# ---------------------- 3D scene / selected blue rooms / stairs ----------------------
blue_floor = '''function FloorMesh({ room, selected, onSelect }: { room: BuildingRoom; selected: boolean; onSelect: () => void }) {
  const [hovered, setHovered] = useState(false)'''
c = exactly(c,
    '''function FloorMesh({ room, selected, onSelect }: { room: BuildingRoom; selected: boolean; onSelect: () => void }) {''',
    blue_floor,
    'blue room selection/hover')
c = exactly(c,
    '''position={[0, 0.015, 0]} onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); onSelect() }}''',
    '''position={[0, 0.015, 0]} onPointerOver={() => setHovered(true)} onPointerOut={() => setHovered(false)} onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); onSelect() }}''',
    'floor hover interaction')
c = exactly(c,
    '''<meshStandardMaterial color={selected ? '#d3e6ff' : room.kind === 'stair' ? '#f5e7fb' : '#e9edf2'} side={THREE.DoubleSide} roughness={0.87} />''',
    '''<meshStandardMaterial color={selected ? '#5797ec' : hovered ? '#a9cdfa' : room.kind === 'stair' ? '#e2ebf9' : '#e9edf2'} emissive={selected ? '#2563eb' : '#000000'} emissiveIntensity={selected ? 0.16 : 0} side={THREE.DoubleSide} roughness={0.87} />''',
    'floor selection material')

import_anchor = "import { buildBuildingModel, type BuildingModel, type BuildingRoom, type BuildingWall, type BuildingOpening } from '../building/model'"
c = exactly(c,import_anchor,import_anchor+"\nimport { active3DFloor, readActiveBlueprintLevel } from '../building/blueprintLevels'\nimport { buildStair3DSurfaces, type Stair3DSurface } from '../building/stair3d'", 'scene imports for new level and stair readers')

stair_component = '''// STROM142_STAIRS3D: extruded tread footprints derived from the existing
// Treppe-einzeichnen layout. This is true 3D geometry, not stacked SVG.
function StairSolid({ surface, selected, onSelect }: {
  surface: Stair3DSurface
  selected: boolean
  onSelect: () => void
}) {
  const geometry = useMemo(() => {
    const shape = new THREE.Shape()
    surface.points.forEach((point, index) => {
      if (index === 0) shape.moveTo(point.x, -point.y)
      else shape.lineTo(point.x, -point.y)
    })
    shape.closePath()
    const solid = new THREE.ExtrudeGeometry(shape, {
      depth: Math.max(0.014, surface.elevationM), bevelEnabled: false, steps: 1, curveSegments: 1,
    })
    solid.rotateX(-Math.PI / 2)
    solid.computeVertexNormals()
    return solid
  }, [surface])
  useEffect(() => () => geometry.dispose(), [geometry])
  return (
    <mesh
      geometry={geometry}
      position={[0, 0, 0]}
      onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); onSelect() }}
      castShadow
      receiveShadow
    >
      <meshStandardMaterial
        color={selected ? '#598fe4' : surface.kind === 'landing' ? '#c4d7ef' : '#9fbade'}
        roughness={0.78}
        metalness={0.03}
      />
    </mesh>
  )
}

'''
c = exactly(c, 'function DoorHandle({ door, wall, selected, onSelect }:', stair_component+'function DoorHandle({ door, wall, selected, onSelect }:', 'insert true-3D staircase mesh')

# RealBuildingScene is shared by 3D Haus and Wanddetail, so both get stairs.
c = exactly(c,
    '''function RealBuildingScene({ model, selectedRoomId, selectedDoorId, onSelectRoom, onSelectDoor, onSelectWall, transparent }: {''',
    '''function RealBuildingScene({ model, stairs, selectedRoomId, selectedDoorId, onSelectRoom, onSelectDoor, onSelectWall, transparent }: {''',
    'scene signature for stairs')
c = exactly(c,
    '''  model: BuildingModel
  selectedRoomId: string''',
    '''  model: BuildingModel
  stairs: Stair3DSurface[]
  selectedRoomId: string''',
    'scene type for stairs')

c = exactly(c,
    '''        <SolidWallMeshes
          model={model}''',
    '''        {stairs.map((surface) => (
          <StairSolid
            key={surface.key}
            surface={surface}
            selected={surface.roomId === selectedRoomId}
            onSelect={() => { onSelectRoom(surface.roomId); onSelectDoor(''); onSelectWall?.(null) }}
          />
        ))}
        <SolidWallMeshes
          model={model}''',
    'render staircase before shared solid walls')

old = '''  const model = useMemo(() => buildBuildingModel(floor, rooms, objects), [floor, rooms, objects])
  const selectedRoom = rooms.find((room) => room.id === selectedRoomId) ?? null'''
new = '''  const [levelRevision, setLevelRevision] = useState(0)
  useEffect(() => {
    const refresh = () => setLevelRevision((value) => value + 1)
    window.addEventListener('storage', refresh)
    window.addEventListener('strom:blueprint-levels-changed', refresh)
    return () => {
      window.removeEventListener('storage', refresh)
      window.removeEventListener('strom:blueprint-levels-changed', refresh)
    }
  }, [floor.id])
  // Same Blueprint layer IDs, room assignments, and heights are read by 3D.
  // No duplicate per-view geometry state; the local-storage adapter will be
  // replaced by an API-backed canonical level record in a later migration.
  const activeLevel = useMemo(() => readActiveBlueprintLevel(floor, rooms, window.localStorage), [floor, rooms, levelRevision])
  const levelFloor = useMemo(() => active3DFloor(floor, activeLevel), [floor, activeLevel])
  const model = useMemo(() => buildBuildingModel(levelFloor, activeLevel.rooms, objects), [levelFloor, activeLevel, objects])
  const stairs = useMemo(() => buildStair3DSurfaces(activeLevel.rooms, activeLevel.heightM, window.localStorage), [activeLevel, levelRevision])
  const selectedRoom = activeLevel.rooms.find((room) => room.id === selectedRoomId) ?? null'''
c = exactly(c,old,new,'bind 3D to active Blueprint layer')

c = exactly(c,
    '''<RealBuildingScene model={model} selectedRoomId={selectedRoomId}''',
    '''<RealBuildingScene model={model} stairs={stairs} selectedRoomId={selectedRoomId}''',
    'pass stair volumes to actual scene')

c = exactly(c,
    '''        <span>Etage: {model.floorName}</span>''',
    '''        <span>Etage: {activeLevel.name} · {Math.round(activeLevel.heightM * 1000)} mm</span>''',
    'show active level 3D')

c = exactly(c,
    '''<div className="building3d-status">Modell: {model.rooms.length} Raumkonturen, {model.walls.length} Wandkanten, {model.doors.length} Tuergruppen · Phase 1: nur eine Etage; Treppen, Dach und Geschossverbindungen folgen schrittweise.</div>''',
    '''<div className="building3d-status">Modell: {model.rooms.length} Raumkonturen, {model.walls.length} Wandkanten, {model.doors.length} Tuergruppen, {stairs.length} Stufen-/Absatzvolumen · Blueprint-Ebene: {activeLevel.name} von {activeLevel.layerCount}. Weitere Etagen werden spaeter gleichzeitig gestapelt.</div>''',
    'new scene status')

# 3D-only: do not touch the solid geometry implementation or working wall popup.
assert 'STROM141_WALL_HOVER' in c and 'STROM140_3D_WALL_EDITOR' in s, 'current wall editor or hover missing; abort'

style += '''

/* STROM142: restore layer panel layout while preserving ghost contour CSS */
.floorplan-layout .canvas-layer-menu .layer-row {
  grid-template-columns: 28px minmax(0, 1fr) 96px 28px !important;
  align-items: center;
}
.floorplan-layout .canvas-layer-menu .layer-height-control {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 2px;
  min-width: 0;
  font-size: 10px;
  font-weight: 600;
  color: #526581;
}
.floorplan-layout .canvas-layer-menu .layer-height-control input {
  width: 100%;
  min-width: 0;
  height: 25px;
  padding: 3px 4px;
  font-size: 12px;
  font-variant-numeric: tabular-nums;
  border: 1px solid #b6c7de;
  border-radius: 5px;
  background: white;
  color: #1f334b;
}
.floorplan-layout .canvas-layer-menu .layer-height-control input:focus { outline: 2px solid #60a5fa; }
.floorplan-layout .canvas-layer-menu .layer-menu-panel { min-width: 350px; max-width: min(420px, 95vw); }
'''

# Commit only after the whole patch is constructed and the safeguards pass.
(root/'frontend/src/building/blueprintLevels.ts').write_text((module_source/'.strom142_blueprintLevels.ts').read_text(encoding='utf8'),encoding='utf8')
(root/'frontend/src/building/stair3d.ts').write_text((module_source/'.strom142_stairs.ts').read_text(encoding='utf8'),encoding='utf8')
app.write_text(s,encoding='utf8')
scene.write_text(c,encoding='utf8')
css.write_text(style,encoding='utf8')
print('142: Blueprint layers (visibility, persistence, heights) + true 3D stairs + blue room selection patched.')
STROM142_PATCH
# Self-contained bundled modules must exist at exactly the paths opened by the
# Python patch (both names begin with a dot). Fail before mutating any source.
for bundled in .strom142_blueprintLevels.ts .strom142_stairs.ts .strom142_patch.py; do
  [ -s "$WORK_DIR/$bundled" ] || fail "142a: Hilfsdatei fehlt oder ist leer: $WORK_DIR/$bundled"
done
STROM142_ROOT="$WORK_DIR" STROM142_MODULE_DIR="$WORK_DIR" python3 "$WORK_DIR/.strom142_patch.py" >>"$DIAG_LOG" 2>&1 || fail "Blueprint/3D-Patch fehlgeschlagen. Kein Git-Push/Stage-Deploy."
rm -f "$WORK_DIR/.strom142_patch.py" "$WORK_DIR/.strom142_blueprintLevels.ts" "$WORK_DIR/.strom142_stairs.ts"

cat > "$WORK_DIR/docs/3D_BLUEPRINT_EBENEN_INCREMENT_142.md" <<'STROM142_DOC'
# Update 142 – Blueprint-Ebenen, Etagenhoehen, Raumauswahl und Treppen im echten 3D

## Bestandspruefung und Korrekturen
- Bisherige Ebene-IDs, Namen, Reihenfolge, Raumzuordnungen, Titelpositionen und gespeicherte Treppenlayouts bleiben bestehen.
- Vorhandene Blueprint-Modi: aktiv, Nachbarebenen als Ghost ohne/mit Bemassung und alle Ghost-Ebenen.
- Ghost-Bereiche: graue Konturen, 50 % Transparenz, ohne Flaechenfuellung und ohne Klick-Interaktion.
- Sichtbarkeitsmodus wird jetzt pro Floor beibehalten; ein Klick auf das Auge einer inaktiven Ebene wechselt in einen Modus, in dem diese auch sichtbar werden kann.
- Beim asynchronen Raum-Reload werden bestehende Raum-zu-Ebene-Zuordnungen nicht mehr vorzeitig geloescht.
- FloorplanEditor wird bei Wechsel der Backend-Floor-ID neu gestartet, damit keine alte Ebenenliste in eine neue Etage gespeichert wird.

## Geschosshoehen
- Pro Blueprint-Ebene ist eine eigene Hoehe in Millimetern im Ebenenmenue editierbar.
- Bestehende Ebenen ohne eigene Hoehe verwenden die Backend-Floor-Hoehe als Standard.
- Das 3D-Wandvolumen und die Treppenstufen der gewaehlten Ebene nutzen diese Hoehe; die Hoehen der unteren Ebenen bestimmen die absolute Lage.

## Echter 3D-Renderer
- Dieselbe React-Three-Fiber-Szene wird in 3D Haus und Wanddetail weiterverwendet.
- 3D zeigt nur die aktuell im Blueprint aktive Etage; Ghost-Ebenen werden nicht als ungewollt ueberlagerte Wandvolumen gerendert.
- Auswahl eines Raumbodens erscheint blau, auch beim Mouseover; bestehender Wandhover und Wand-Popup bleiben intakt.
- Geradlaeufige Treppen, Biegungen und Absatze werden als geschlossene 3D-Volumen aus bereits gespeicherten Treppenelementen gezeichnet.
- Treppen-Reihenfolge: Start an 'Diese Etage', dann Pfeile; Gesamtstufenhoehe = Etagenhoehe / Stufenanzahl.

## Bestehende Architekturgrenze
- Blueprint-Ebenen und Treppenlayouts liegen vorerst weiter in den vorhandenen Browser-localStorage-Schluesseln.
- Dadurch sind Ebenenhoehen und Layouts noch nicht automatisch zwischen verschiedenen Browsern synchron.
- Eine spaetere Datenbankmigration fuer Etagen und Treppen ist erforderlich, bevor alle Geschosse gleichzeitig als ein Gebaeude bearbeitet werden.
- Keine Datenbank- oder Backend-Aenderung und keine Migration in diesem Update.

## Unveraendert
- Volumenunion / massive Waende aus 139.
- Wandbearbeitung und Frontalansicht aus 140a.
- Wand-Mouseover aus 141a.
- Blueprint-Werkzeugleiste, Tueren, Bemaszung, SVG-Design, Geometrie und bestehende Daten.
STROM142_DOC

# Explicit regression guards for code we must never modify here.
for file in \
  frontend/src/building/model.ts \
  frontend/src/building/solidGeometry.ts \
  frontend/src/building/wallHitSelection.ts \
  frontend/src/building/wallHoverGeometry.ts \
  frontend/src/api.ts \
  frontend/src/types.ts; do
  cmp -s "$STAGE_DIR/$file" "$WORK_DIR/$file" || fail "Unbeabsichtigte Aenderung in $file."
done

log "4) Vollstaendigen TypeScript/Vite-Build pruefen..."
(
  cd "$WORK_DIR/frontend"
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Frontend-Build fehlgeschlagen. Kein Git-Push/Stage-Deploy."

log "4.1) Ebenen- und Stufen-Geometrie testen..."
export STROM142_TEST_ROOT="$WORK_DIR"
export STROM142_TS="$DEPENDENCIES/typescript"
node <<'STROM142_TEST' >>"$DIAG_LOG" 2>&1 || fail "Ebenen-/Stufentest fehlgeschlagen. Kein Git-Push/Stage-Deploy."
'use strict'
const fs = require('fs')
const ts = require(process.env.STROM142_TS)
const root = process.env.STROM142_TEST_ROOT
function load(file) {
  const source = fs.readFileSync(`${root}/frontend/src/building/${file}`, 'utf8')
  const output = ts.transpileModule(source, {
    fileName: file, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  })
  if (output.diagnostics?.some(d => d.category === ts.DiagnosticCategory.Error)) throw Error(`${file}: invalid TypeScript`)
  const mod = { exports: {} }
  new Function('module', 'exports', output.outputText)(mod, mod.exports)
  return mod.exports
}
const level = load('blueprintLevels.ts')
const stair = load('stair3d.ts')
const floor = { id: 'F1', name: 'Objekt', heightM: 2.5, elevationM: 0 }
const rooms = [
 { id: 'EG', floorId: 'F1', vertices: [{x:0,y:0},{x:5,y:0},{x:5,y:4},{x:0,y:4}] },
 { id: 'OG', floorId: 'F1', vertices: [{x:0,y:0},{x:5,y:0},{x:5,y:4},{x:0,y:4}] },
]
const data = {
  'strom.floorplan.layers.F1.list': JSON.stringify([{id:'layer-main',name:'EG',visible:true,heightM:2.5},{id:'layer-2',name:'OG',visible:true,heightM:2.9}]),
  'strom.floorplan.layers.F1.active': JSON.stringify('layer-2'),
  'strom.floorplan.layers.F1.roomAssignments': JSON.stringify({EG:'layer-main',OG:'layer-2'}),
  'strom-stair-layout:OG': JSON.stringify([
    {id:'straight',kind:'stair',xM:0.2,yM:0.3,widthM:1,heightM:2.8,steps:6,rotationDeg:0},
    {id:'bend',kind:'turn',xM:1.2,yM:0.3,widthM:2,heightM:2,steps:3,rotationDeg:0,mirrored:true},
  ]),
  'strom-stair-edge-assignments:OG': JSON.stringify([{kind:'current-floor',edgeIndex:3}]),
}
const storage = { getItem: key => data[key] || null }
const active = level.readActiveBlueprintLevel(floor, rooms, storage)
if (active.name !== 'OG' || active.heightM !== 2.9 || active.elevationM !== 2.5 || active.rooms.length !== 1 || active.rooms[0].id !== 'OG') throw Error('Active level wrong')
const modelFloor = level.active3DFloor(floor, active)
if (modelFloor.heightM !== 2.9 || modelFloor.elevationM !== 2.5) throw Error('Wrong 3D floor elevation')
const surfaces = stair.buildStair3DSurfaces(active.rooms, active.heightM, storage)
if (surfaces.length !== 9) throw Error('3D stair lost steps: ' + surfaces.length)
if (Math.abs(surfaces[surfaces.length - 1].elevationM - 2.9) > .005) throw Error('3D stair height does not match storey height')
for(const item of surfaces) {
  if(item.points.length < 3 || item.points.some(p => !Number.isFinite(p.x) || !Number.isFinite(p.y))) throw Error('Invalid stair polygon')
}
console.log('142 geometry tests PASS: per-layer heights, room assignments, floor elevation, 9 stair solids')
STROM142_TEST

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
log "Update 142 in Stage erfolgreich. Test: https://home.moja.de/strom-test/"
log "  - Wanddetail: Raumboden bei Hover/Auswahl blau, Wandhover unveraendert."
log "  - Wanddetail/3D Haus: Treppenlaeufe, Biegungen, Absaetze als echte 3D-Koerper."
log "  - Blueprint: Ebene je eigener Hoehe (mm), Ebenenmodi und Ghost-Sichtbarkeit."
log "  - 3D zeigt nur die aktive Blueprint-Ebene mit ihrer Geschosshoehe."
log "  - Historische Layer-IDs, Raumzuordnungen und Treppenlayouts bleiben erhalten."
log "  - Produktion bleibt unveraendert."
log "Backup: $BACKUP_DIR"
