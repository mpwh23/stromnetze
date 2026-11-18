#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-1220_138_3d_wandkoerper_statt_doppelwaende"
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
COMMIT_MESSAGE="Update 138: Geschlossene physische Wandkoerper ohne doppelte Wandkanten"
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
  echo "2) Aktuellen Stage-Source + Update 138 nach GitHub pushen ..."
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

  echo "1.2) Aktuellen, bereits getesteten Stage-Source in das Git-Checkout synchronisieren ..."
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

  echo "1.3) Update 138 auf Git-Source anwenden und Build pruefen ..."
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

log "=== Update 138 / echte geschlossene Wandkoerper ==="
log "Stage: $STAGE_DIR"
log "Produktion wird nicht veraendert."
log "Diagnose: $DIAG_LOG"
[ -f "$STAGE_DIR/frontend/src/building/model.ts" ] || fail "Update 137 ist im Stage-Source noch nicht vorhanden (model.ts fehlt)."
[ -f "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" ] || fail "Building3DWorkspace.tsx fehlt."
[ -f "$STAGE_DIR/frontend/package.json" ] || fail "Frontend package.json fehlt."
grep -q 'export function wallSolidPieces' "$STAGE_DIR/frontend/src/building/model.ts" || fail "Unerwartete Modellversion; Abbruch ohne Patch."
select_node

log "1) Vorhandene Stage sichern..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Quelle wird in einer isolierten Git-Kopie geprueft."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage-Backup fehlgeschlagen."
fi

log "2) Isolierte Arbeitskopie vorbereiten..."
rsync -a \
  --exclude='/frontend/node_modules' \
  --exclude='/frontend/dist' \
  --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Quellkopie fehlgeschlagen."
mkdir -p "$WORK_DIR/frontend/src/building" "$WORK_DIR/docs"
# Node modules are accessed read-only for tsc/vite; no npm install and no
# writes to production or stage dependencies are performed.
if [ -L "$WORK_DIR/frontend/node_modules" ]; then rm -f "$WORK_DIR/frontend/node_modules"; fi
if [ -d "$WORK_DIR/frontend/node_modules" ]; then rm -rf "$WORK_DIR/frontend/node_modules"; fi
DEPENDENCIES=""
for candidate in \
  "$STAGE_DIR/frontend/node_modules" \
  "$PROD_DIR/frontend/node_modules" \
  /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -d "$candidate/typescript" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ]; then
    DEPENDENCIES="$candidate"
    break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "Keine Frontend-Abhaengigkeiten von Update 137 gefunden."
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"

log "3) Wandmodell durch physische, geschlossene Wandkoerper ersetzen..."
cat > "$WORK_DIR/frontend/src/building/model.ts" <<'STROM138_MODEL'
import type { Floor, PointM, Room, WallObject } from '../types'

/**
 * 137: Common building geometry consumed by Blueprint and the WebGL scene.
 * Coordinates are metres; Blueprint X/Y maps to WebGL X/Z, and WebGL Y is elevation.
 * These are derived view objects; Rooms and WallObjects in the Go API remain the
 * authoritative records. No independent 3D geometry is persisted.
 */
export type BuildingOpening = {
  id: string
  groupId: string
  type: 'door' | 'window'
  roomId: string
  edgeIndex: number
  centerM: number
  widthM: number
  sillM: number
  heightM: number
}

export type BuildingWall = {
  id: string
  roomId: string
  edgeIndex: number
  start: PointM
  end: PointM
  lengthM: number
  thicknessM: number
  heightM: number
  outerWall: boolean
  roomIds?: string[]
  openings: BuildingOpening[]
}

export type BuildingRoom = {
  id: string
  name: string
  vertices: PointM[]
  kind: 'room' | 'stair' | 'outer'
}

export type BuildingModel = {
  floorId: string
  floorName: string
  floorHeightM: number
  floorElevationM: number
  rooms: BuildingRoom[]
  walls: BuildingWall[]
  doors: BuildingOpening[]
  center: PointM
  spanM: number
}

export type WallSolidPiece = {
  fromM: number
  toM: number
  bottomM: number
  topM: number
}

const minSizeM = 0.005
const roundMm = (value: number) => Math.round(value * 1000) / 1000
const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, value))
const distance = (a: PointM, b: PointM) => Math.hypot(b.x - a.x, b.y - a.y)

function wallOpeningFromApi(item: WallObject, lengthM: number, heightM: number): BuildingOpening {
  const widthM = clamp(item.w * lengthM, minSizeM, lengthM)
  const topOriginY = Number(item.y)
  const height = clamp(Number(item.h) * heightM, minSizeM, heightM)
  const sill = item.objectType === 'door' ? 0 : clamp((1 - topOriginY - item.h / 2) * heightM, 0, heightM - height)
  return {
    id: item.id,
    groupId: item.groupId || item.id,
    type: item.objectType as 'door' | 'window',
    roomId: item.roomId,
    edgeIndex: item.edgeIndex,
    centerM: clamp(item.x * lengthM, 0, lengthM),
    widthM,
    sillM: sill,
    heightM: height,
  }
}

/**
 * 138: A physical wall may be described by two opposite Blueprint room edges.
 * The edges are wall references, not independent blocks. Normalized parallel
 * edge bands are assembled into ONE solid wall prism per longitudinal slice.
 *
 * The canonical records remain Room and WallObject in the API. No database
 * changes and no independent 3D geometry are persisted.
 */
type WallFaceCandidate = {
  wall: BuildingWall
  tangent: PointM
  normal: PointM
  normalOffsetM: number
  minT: number
  maxT: number
  interiorSide: number
}

const dot = (a: PointM, b: PointM) => a.x * b.x + a.y * b.y
const signedArea2 = (points: PointM[]) => points.reduce((sum, point, index) => {
  const next = points[(index + 1) % points.length]
  return sum + point.x * next.y - next.x * point.y
}, 0)

function faceCandidate(wall: BuildingWall, room: Room): WallFaceCandidate {
  const vx = wall.end.x - wall.start.x
  const vy = wall.end.y - wall.start.y
  // A canonical direction makes anti-parallel room edges comparable.
  const sign = vx > 0.000001 || (Math.abs(vx) <= 0.000001 && vy >= 0) ? 1 : -1
  const tangent = { x: sign * vx / wall.lengthM, y: sign * vy / wall.lengthM }
  const normal = { x: -tangent.y, y: tangent.x }
  const t0 = dot(tangent, wall.start)
  const t1 = dot(tangent, wall.end)
  const polygonSide = signedArea2(room.vertices) >= 0 ? 1 : -1
  return {
    wall,
    tangent,
    normal,
    normalOffsetM: dot(normal, wall.start),
    minT: Math.min(t0, t1),
    maxT: Math.max(t0, t1),
    interiorSide: polygonSide * sign,
  }
}

function physicalWallFacesCompatible(a: WallFaceCandidate, b: WallFaceCandidate): boolean {
  if (dot(a.tangent, b.tangent) < 0.9995) return false
  const normalGap = Math.abs(dot(a.normal, b.wall.start) - a.normalOffsetM)
  const maxGap = Math.max(0.22, Math.min(0.52, 0.15 + 0.8 * (a.wall.thicknessM + b.wall.thicknessM)))
  if (normalGap > maxGap) return false
  const b0 = dot(a.tangent, b.wall.start)
  const b1 = dot(a.tangent, b.wall.end)
  const overlap = Math.min(a.maxT, Math.max(b0, b1)) - Math.max(a.minT, Math.min(b0, b1))
  if (overlap < Math.min(0.06, Math.min(a.wall.lengthM, b.wall.lengthM) * 0.2)) return false
  if (normalGap < 0.012) return true
  // Never consume both sides of a narrow room as one wall.
  if (a.wall.roomId === b.wall.roomId) return false
  // Interior sides of neighboring rooms must face away from the partition.
  // An explicitly drawn outer wall is the outside boundary, not a room.
  return a.wall.outerWall || b.wall.outerWall || a.interiorSide !== b.interiorSide
}

function groupPhysicalWallFaces(candidates: WallFaceCandidate[]): WallFaceCandidate[][] {
  const groups: WallFaceCandidate[][] = []
  const sorted = [...candidates].sort((a, b) => b.wall.lengthM - a.wall.lengthM)
  for (const candidate of sorted) {
    let destination: WallFaceCandidate[] | undefined
    let bestGap = Number.POSITIVE_INFINITY
    for (const group of groups) {
      const anchor = group[0]
      const offsets = [...group, candidate].map((face) => dot(anchor.normal, face.wall.start))
      if (Math.max(...offsets) - Math.min(...offsets) > 0.52) continue
      const compatible = group.filter((face) => physicalWallFacesCompatible(face, candidate))
      if (!compatible.length) continue
      const gap = Math.min(...compatible.map((face) => Math.abs(dot(face.normal, candidate.wall.start) - face.normalOffsetM)))
      if (gap < bestGap) { destination = group; bestGap = gap }
    }
    if (destination) destination.push(candidate)
    else groups.push([candidate])
  }
  return groups
}

function projectOpeningT(candidate: WallFaceCandidate, opening: BuildingOpening, tangent: PointM): number {
  const fraction = opening.centerM / Math.max(minSizeM, candidate.wall.lengthM)
  const point = {
    x: candidate.wall.start.x + (candidate.wall.end.x - candidate.wall.start.x) * fraction,
    y: candidate.wall.start.y + (candidate.wall.end.y - candidate.wall.start.y) * fraction,
  }
  return dot(point, tangent)
}

function pickWallFace(candidates: WallFaceCandidate[]): WallFaceCandidate {
  // The room side is preferable for selecting a wall from within the 3D model.
  return [...candidates].sort((a, b) => Number(a.wall.outerWall) - Number(b.wall.outerWall) || b.wall.lengthM - a.wall.lengthM)[0]
}

function wallsFromPhysicalFaceGroup(
  faces: WallFaceCandidate[],
  groupIndex: number,
  canonicalDoorMap: Map<string, BuildingOpening>,
): BuildingWall[] {
  const tangent = faces[0].tangent
  const normal = faces[0].normal
  const boundaries = faces.flatMap((candidate) => [
    dot(tangent, candidate.wall.start),
    dot(tangent, candidate.wall.end),
  ])
  const xs = [...new Set(boundaries.map(roundMm))].sort((a, b) => a - b)
  const slices: BuildingWall[] = []
  for (let i = 0; i < xs.length - 1; i += 1) {
    const t0 = xs[i]
    const t1 = xs[i + 1]
    if (t1 - t0 < 0.002) continue
    const mid = (t0 + t1) / 2
    const active = faces.filter((face) => {
      const a = dot(tangent, face.wall.start)
      const b = dot(tangent, face.wall.end)
      return mid >= Math.min(a, b) - 0.002 && mid <= Math.max(a, b) + 0.002
    })
    if (!active.length) continue

    const low = Math.min(...active.map((candidate) => dot(normal, candidate.wall.start) - candidate.wall.thicknessM / 2))
    const high = Math.max(...active.map((candidate) => dot(normal, candidate.wall.start) + candidate.wall.thicknessM / 2))
    const center = (low + high) / 2
    const chosen = pickWallFace(active)
    const openings = new Map<string, BuildingOpening>()
    for (const face of active) {
      for (const item of face.wall.openings) {
        const centerT = projectOpeningT(face, item, tangent)
        if (centerT + item.widthM / 2 < t0 + 0.0001 || centerT - item.widthM / 2 > t1 - 0.0001) continue
        const selected = canonicalDoorMap.get(item.groupId) ?? item
        // A shared door has two API records. Use one canonical opening on all
        // slices, including the slice where the opening center is located.
        const matching = active.find((entry) => entry.wall.openings.some((opening) => opening.id === selected.id))
        const reference = matching ?? face
        const source = matching ? selected : item
        const projectedCenter = projectOpeningT(reference, source, tangent)
        const local = { ...source, centerM: projectedCenter - t0 }
        const key = item.groupId || item.id
        const prior = openings.get(key)
        if (!prior || source.id === selected.id) openings.set(key, local)
      }
    }
    // Active rooms are retained so selection/highlighting works from either side.
    slices.push({
      id: `wall138:${groupIndex}:${i}`,
      roomId: chosen.wall.roomId,
      edgeIndex: chosen.wall.edgeIndex,
      roomIds: [...new Set(active.map((face) => face.wall.roomId))],
      start: { x: roundMm(tangent.x * t0 + normal.x * center), y: roundMm(tangent.y * t0 + normal.y * center) },
      end: { x: roundMm(tangent.x * t1 + normal.x * center), y: roundMm(tangent.y * t1 + normal.y * center) },
      lengthM: roundMm(t1 - t0),
      thicknessM: roundMm(high - low),
      heightM: chosen.wall.heightM,
      outerWall: active.some((candidate) => candidate.wall.outerWall),
      openings: [...openings.values()],
    })
  }
  return slices
}

export function buildBuildingModel(floor: Floor, rooms: Room[], objects: WallObject[]): BuildingModel {
  const safeHeight = Math.max(0.1, floor.heightM)
  const validRooms = rooms.filter((room) => Array.isArray(room.vertices) && room.vertices.length >= 3)
  const modelRooms: BuildingRoom[] = validRooms.map((room) => ({
    id: room.id,
    name: room.name.startsWith('__strom_outer_wall__') ? 'Außenwand' : room.name,
    vertices: room.vertices.map((point) => ({ x: point.x, y: point.y })),
    kind: room.name.startsWith('__strom_outer_wall__') ? 'outer' : room.roomType === 'stair' ? 'stair' : 'room',
  }))
  const candidates: BuildingWall[] = []
  for (const room of validRooms) {
    const count = room.vertices.length
    for (let edgeIndex = 0; edgeIndex < count; edgeIndex += 1) {
      const start = room.vertices[edgeIndex]
      const end = room.vertices[(edgeIndex + 1) % count]
      const lengthM = distance(start, end)
      if (lengthM < 0.05) continue
      candidates.push({
        id: `${room.id}:${edgeIndex}`,
        roomId: room.id,
        edgeIndex,
        start: { ...start }, end: { ...end },
        lengthM,
        thicknessM: clamp(room.wallThicknessM || 0.12, 0.04, 0.45),
        heightM: safeHeight,
        outerWall: room.name.startsWith('__strom_outer_wall__'),
        openings: objects
          .filter((item) => item.roomId === room.id && item.edgeIndex === edgeIndex && (item.objectType === 'door' || item.objectType === 'window'))
          .map((item) => wallOpeningFromApi(item, lengthM, safeHeight)),
      })
    }
  }

  const candidatesById = new Map(validRooms.map((room) => [room.id, room]))
  const faceCandidates = candidates.map((wall) => faceCandidate(wall, candidatesById.get(wall.roomId)!))

  // Canonical door IDs and editor coordinates remain on the original API edge.
  // New 3D wall slices use local rendering offsets without changing the DB.
  const doorMap = new Map<string, BuildingOpening>()
  for (const wall of [...candidates].sort((a, b) => Number(a.outerWall) - Number(b.outerWall))) {
    for (const opening of wall.openings) {
      if (opening.type === 'door' && !opening.groupId.startsWith('wall-open:') && !doorMap.has(opening.groupId)) {
        doorMap.set(opening.groupId, opening)
      }
    }
  }

  const walls = groupPhysicalWallFaces(faceCandidates)
    .flatMap((group, groupIndex) => wallsFromPhysicalFaceGroup(group, groupIndex, doorMap))

  const vertices = modelRooms.filter((room) => room.kind !== 'outer').flatMap((room) => room.vertices)
  const allPoints = vertices.length > 0 ? vertices : modelRooms.flatMap((room) => room.vertices)
  const minX = allPoints.length ? Math.min(...allPoints.map((p) => p.x)) : 0
  const maxX = allPoints.length ? Math.max(...allPoints.map((p) => p.x)) : 0
  const minY = allPoints.length ? Math.min(...allPoints.map((p) => p.y)) : 0
  const maxY = allPoints.length ? Math.max(...allPoints.map((p) => p.y)) : 0
  return {
    floorId: floor.id,
    floorName: floor.name,
    floorHeightM: safeHeight,
    floorElevationM: floor.elevationM || 0,
    rooms: modelRooms,
    walls,
    doors: [...doorMap.values()],
    center: { x: (minX + maxX) / 2, y: (minY + maxY) / 2 },
    spanM: Math.max(5, maxX - minX, maxY - minY),
  }
}

/** Generate an actual hole in the wall by subdividing it into solid boxes. */
export function wallSolidPieces(wall: BuildingWall): WallSolidPiece[] {
  const eps = 0.0001
  const breakpoints = [0, wall.lengthM]
  for (const opening of wall.openings) {
    breakpoints.push(clamp(opening.centerM - opening.widthM / 2, 0, wall.lengthM))
    breakpoints.push(clamp(opening.centerM + opening.widthM / 2, 0, wall.lengthM))
  }
  const xs = [...new Set(breakpoints.map(roundMm))].sort((a, b) => a - b)
  const pieces: WallSolidPiece[] = []
  for (let i = 0; i < xs.length - 1; i += 1) {
    const fromM = xs[i]
    const toM = xs[i + 1]
    if (toM - fromM < eps) continue
    const mid = (fromM + toM) / 2
    const cutouts = wall.openings
      .filter((opening) => mid >= opening.centerM - opening.widthM / 2 - eps && mid <= opening.centerM + opening.widthM / 2 + eps)
      .map((opening) => ({
        bottom: clamp(opening.sillM, 0, wall.heightM),
        top: clamp(opening.sillM + opening.heightM, 0, wall.heightM),
      }))
      .sort((a, b) => a.bottom - b.bottom)
    let cursor = 0
    for (const hole of cutouts) {
      if (hole.bottom > cursor + eps) pieces.push({ fromM, toM, bottomM: cursor, topM: hole.bottom })
      cursor = Math.max(cursor, hole.top)
    }
    if (cursor < wall.heightM - eps) pieces.push({ fromM, toM, bottomM: cursor, topM: wall.heightM })
  }
  return pieces
}
STROM138_MODEL

export STROM138_SCENE="$WORK_DIR/frontend/src/components/Building3DWorkspace.tsx"
python3 - <<'STROM138_PATCH'
from pathlib import Path
import os
scene=Path(os.environ['STROM138_SCENE'])
s=scene.read_text(encoding='utf-8')
original='selected={selectedRoomId === wall.roomId}'
replacement='selected={wall.roomIds?.includes(selectedRoomId) ?? (selectedRoomId === wall.roomId)}'
if replacement not in s:
    if s.count(original) != 1: raise SystemExit('138: Auswahllogik nicht eindeutig gefunden. Abbruch.')
    s=s.replace(original,replacement,1)
old_filter="opening.type === 'door' && model.doors.some((door) => door.id === opening.id)"
new_filter="opening.type === 'door' && opening.centerM >= -0.0001 && opening.centerM <= wall.lengthM + 0.0001 && model.doors.some((door) => door.id === opening.id)"
if new_filter not in s:
    if s.count(old_filter) != 1: raise SystemExit('138: Tuer-Renderer nicht eindeutig gefunden. Abbruch.')
    s=s.replace(old_filter,new_filter,1)
scene.write_text(s,encoding='utf-8')
print('138: Physische Wandquader, Auswahl aller gekoppelten Raumseiten und Tueranker geprueft.')
STROM138_PATCH

cat > "$WORK_DIR/docs/3D_WANDKOERPER_INCREMENT_138.md" <<'STROM138_DOC'
# STROM 138 – Physische Wandkoerper statt getrennter 3D-Wandschalen

## Ursache
In Update 137 wurde jede Raumkante als eigener Quader extrudiert. Nur Kanten
mit exakt denselben Endpunkten wurden dedupliziert. Zwei parallele, leicht
versetzte Wandseiten konnten deshalb als zwei getrennte Quader mit Hohlraum
erscheinen.

## Neue Ableitung
- Normalisierung der Wandkanten auf eine gemeinsame Richtung (unabhaengig
  von der Laufrichtung des Raumpolygons).
- Kopplung von deckungsgleichen bzw. nahen parallelen Wandseiten, deren
  Laengsprojektionen ueberlappen, unter Beruecksichtigung der Rauminnenseite.
- Laengsseitige Aufteilung an den Endpunkten beteiligter Kanten. So koennen
  lange Aussenwandkanten und mehrere kuerzere Raumkanten zusammenwirken.
- Pro Abschnitt ein geschlossener massiver Wandquader, der den Zwischenraum
  zwischen den beschriebenen Wandseiten ausfuellt.
- Tueren und Fenster werden in reale Meterkoordinaten des physischen
  Wandkoerpers projiziert. Ausschnitte gehen durch dessen volle Dicke.
- Zuordnungen zu Raumen und Tuergruppen bleiben erhalten. Blueprint, API und
  Datenbank werden nicht veraendert.

## Grenzen
Die aktuelle Projektion erkennt nahe, parallele Flaechen mit grob passenden
Wandstaerken. Stark schraeg oder nur punktfoermig aneinanderstossende Waende
bleiben getrennte Koerper. In einer spaeteren Phase kann eine globale
Polygonvereinigung/CSG fuer Wandverbindungen folgen.

## Sicherheit
Stage zuerst mit lokaler Arbeitskopie bauen; GitHub-Commit und Push vor
Stage-Deployment. Produktion nicht aendern. Keine Datenbankmigration.
STROM138_DOC

log "4) TypeScript/Vite-Build und Wandgeometrie pruefen..."
(
  cd "$WORK_DIR/frontend"
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Frontend-Build fehlgeschlagen. Kein Git-Push/Stage-Deploy."

# Geometry regression tests use TypeScript's installed transpiler and only
# pure model functions (no browser or network required).
export STROM138_MODEL_FILE="$WORK_DIR/frontend/src/building/model.ts"
export STROM138_TYPESCRIPT="$DEPENDENCIES/typescript"
node - <<'STROM138_TEST' >>"$DIAG_LOG" 2>&1 || fail "Wandgeometrie-Selbsttest fehlgeschlagen."
const fs = require('fs')
const ts = require(process.env.STROM138_TYPESCRIPT)
const source = fs.readFileSync(process.env.STROM138_MODEL_FILE, 'utf8')
const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } })
const exportsObject = { exports: {} }
new Function('module', 'exports', 'require', output.outputText)(exportsObject, exportsObject.exports, () => ({}))
const { buildBuildingModel, wallSolidPieces } = exportsObject.exports
const floor = { id: 'f', name: 'EG', heightM: 2.7, elevationM: 0 }
const rect = (x0,y0,x1,y1) => [{x:x0,y:y0},{x:x1,y:y0},{x:x1,y:y1},{x:x0,y:y1}]
const room = (id, vertices, thickness = .12, outer = false) => ({ id, floorId:'f', name:outer?'__strom_outer_wall__Aussenwand':id, roomType:'room', wallThicknessM:thickness, vertices })
const check = (ok, error) => { if (!ok) throw new Error(error) }
const a = room('a', rect(0,0,4,3))
const b = room('b', rect(4.28,0,8,3))
const wall = buildBuildingModel(floor,[a,b],[]).walls.filter(w=>Math.abs(w.start.x-4.14)<.02 && Math.abs(w.end.x-4.14)<.02)
check(wall.length===1 && wall[0].thicknessM>=.39, 'Parallel adjacent wall faces not merged to a solid prism')
const skinny = buildBuildingModel(floor,[room('skinny',rect(1,1,3,1.23))],[])
check(skinny.walls.length===4, 'Opposite faces of a thin room collapsed')
const outer=room('outer',rect(0,0,10,6),.24,true)
const x=room('x',rect(.2,.25,4.2,5.8))
const y=room('y',rect(4.2,.25,9.8,5.8))
const outside=buildBuildingModel(floor,[outer,x,y],[]).walls
const longSection=outside.filter(w=>w.start.x < 3 && w.end.x > 3 && Math.abs(w.start.y)<.6 && Math.abs(w.end.y)<.6)
check(longSection.length===1 && longSection[0].thicknessM>.3, 'Outer facade remains hollow')
const door=(id,roomId,edgeIndex,x,w)=>({ id,roomId,edgeIndex,floorId:'f',objectType:'door',groupId:'shared-door',x,y:.6,w,h:.8 })
const doorModel=buildBuildingModel(floor,[a,b],[door('d1','a',1,.5,.25),door('d2','b',3,.5,.25)])
const physical=doorModel.walls.find(w=>Math.abs(w.start.x-4.14)<.02 && Math.abs(w.end.x-4.14)<.02)
check(doorModel.doors.length===1 && physical?.openings.length===1,'Door not unified')
check(wallSolidPieces(physical).every(p=>!(p.fromM<1.6 && p.toM>1.4 && p.bottomM<2.16)), 'Doorway did not cut all the way through wall')
console.log('138 geometrische Regressionstests: OK')
STROM138_TEST

log "5) Gepruefte Quellkopie nach Stage uebernehmen..."
rsync -a --delete \
  --exclude='frontend/node_modules' \
  --exclude='frontend/dist' \
  --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage-Synchronisation fehlgeschlagen. Backup: $BACKUP_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Build und Geometrietests erfolgreich; kein Web-Deployment und keine Produktion geaendert."
  exit 0
fi

log "6) Stage bauen und /strom-test/ aktualisieren..."
(
  cd "$STAGE_DIR/frontend"
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Stage-Build fehlgeschlagen. Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Build-Ausgabe frontend/dist fehlt."
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Web-Deployment nach $WEB_TEST_DIR fehlgeschlagen. Backup: $BACKUP_DIR"
log ""
log "Update 138 erfolgreich. Bitte unter https://home.moja.de/strom-test/ pruefen:"
log "  - Innen-/Aussenwaende bilden massive, geschlossene Querschnitte."
log "  - Tueren und Fenster durchdringen die ganze Wandstaerke."
log "  - Auswahl der Raumwande und 2D/3D-Synchronisation bleiben erhalten."
log "  - Blueprint und Produktion wurden nicht direkt geaendert."
log "Backup: $BACKUP_DIR"
