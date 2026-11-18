#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-1250_139_3d_wandvolumen_wanddetail_vollhoehe"
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
COMMIT_MESSAGE="Update 139: Geschlossenes 3D-Wandvolumen, Wanddetail mit WebGL, volle Hoehe"
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
  echo "2) Aktuellen Stage-Source + Update 139 nach GitHub pushen ..."
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

  echo "1.3) Update 139 auf Git-Source anwenden und Build pruefen ..."
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

log "=== Update 139 / vereinte Volumengeometrie und Wanddetail in WebGL ==="
log "Stage: $STAGE_DIR"
log "Produktion wird nicht veraendert."
log "Diagnose: $DIAG_LOG"
[ -f "$STAGE_DIR/frontend/src/building/model.ts" ] || fail "Update 137 ist im Stage-Source noch nicht vorhanden (model.ts fehlt)."
[ -f "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" ] || fail "Building3DWorkspace.tsx fehlt."
[ -f "$STAGE_DIR/frontend/package.json" ] || fail "Frontend package.json fehlt."
grep -q 'export function wallSolidPieces' "$STAGE_DIR/frontend/src/building/model.ts" || fail "Update 138 Wandmodell fehlt; Abbruch ohne Patch."
grep -q 'function WallMeshes' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "Unerwarteter 3D-Renderer, Abbruch ohne Patch."
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

log "3) Drei Erweiterungen einbauen: Volumen-Union, WebGL-Wanddetail, Full-Height-Layout..."
mkdir -p "$WORK_DIR/frontend/src/building" "$WORK_DIR/docs"
cat > "$WORK_DIR/frontend/src/building/solidGeometry.ts" <<'STROM139_SOLID'
import type { PointM } from '../types'
import { wallSolidPieces, type BuildingModel, type BuildingWall } from './model'

/**
 * 139: A watertight, unioned set of wall solids, with a thick exterior infill.
 *
 * 138 generated one mesh for every longitudinal/vertical wall slice. That can
 * create overlapping coplanar faces and leave uncovered islands where an outer
 * wall encloses no individual room. Here we treat walls as ONE occupancy volume
 * and produce only its boundary triangles. No independent 3D data is stored.
 *
 * Blueprint coordinates (x, y) map to Three.js (x, z). Altitude maps to y.
 * This module is pure TypeScript and does not require Three.js or a CSG addon.
 */
export type SolidSurface = {
  positions: number[]
  triangleCount: number
  interiorFill: boolean
}

type Polygon2 = PointM[]
type Slab = { polygon: Polygon2; bottom: number; top: number }
type Segment = { a: PointM; b: PointM; xMin: number; xMax: number; zMin: number; zMax: number }
type AtX = { z: number; segment: Segment }
type Cell = { polygon: [PointM, PointM, PointM, PointM]; x: number; z: number }

type Occupancy = {
  solids: Slab[]
  openings: Slab[]
  outside: Polygon2[]
  inside: Polygon2[]
  height: number
}

const EPS = 0.00005 // 0.05 mm: well below the project's 1 mm coordinate precision
const MIN_AREA = 1e-8
const round10um = (value: number) => Math.round(value * 100000) / 100000
const clamp = (value: number, a: number, b: number) => Math.max(a, Math.min(b, value))

function pointInPoly(p: PointM, points: Polygon2): boolean {
  let inside = false
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    const a = points[i]
    const b = points[j]
    if ((a.y > p.y) !== (b.y > p.y)) {
      const x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
      if (p.x < x) inside = !inside
    }
  }
  return inside
}

function pointInSlab(p: PointM, y: number, slab: Slab) {
  return y >= slab.bottom - EPS / 2 && y <= slab.top + EPS / 2 && pointInPoly(p, slab.polygon)
}

/** Testable canonical predicate: positive solids union exterior infill, cut by openings. */
export function solidAt(model: BuildingModel, point: PointM, altitude: number): boolean {
  return occupied(makeOccupancy(model), point, altitude)
}

function occupied(ctx: Occupancy, point: PointM, y: number): boolean {
  if (y < 0 || y > ctx.height) return false
  const wall = ctx.solids.some((solid) => pointInSlab(point, y, solid))
  const infill = ctx.outside.length > 0
    && ctx.outside.some((polygon) => pointInPoly(point, polygon))
    && !ctx.inside.some((polygon) => pointInPoly(point, polygon))
  if (!wall && !infill) return false
  return !ctx.openings.some((opening) => pointInSlab(point, y, opening))
}

function wallRect(wall: BuildingWall, from: number, to: number, extraThickness = 0): Polygon2 {
  const vx = (wall.end.x - wall.start.x) / wall.lengthM
  const vz = (wall.end.y - wall.start.y) / wall.lengthM
  const nx = -vz * (wall.thicknessM / 2 + extraThickness)
  const nz = vx * (wall.thicknessM / 2 + extraThickness)
  return [
    { x: wall.start.x + vx * from + nx, y: wall.start.y + vz * from + nz },
    { x: wall.start.x + vx * to + nx, y: wall.start.y + vz * to + nz },
    { x: wall.start.x + vx * to - nx, y: wall.start.y + vz * to - nz },
    { x: wall.start.x + vx * from - nx, y: wall.start.y + vz * from - nz },
  ]
}

function makeOccupancy(model: BuildingModel): Occupancy {
  const solids: Slab[] = []
  const openings: Slab[] = []
  for (const wall of model.walls) {
    if (wall.lengthM < .001 || wall.thicknessM < .001) continue
    for (const piece of wallSolidPieces(wall)) {
      if (piece.topM - piece.bottomM < .001 || piece.toM - piece.fromM < .001) continue
      solids.push({ polygon: wallRect(wall, piece.fromM, piece.toM), bottom: piece.bottomM, top: piece.topM })
    }
    for (const item of wall.openings) {
      const from = clamp(item.centerM - item.widthM / 2, 0, wall.lengthM)
      const to = clamp(item.centerM + item.widthM / 2, 0, wall.lengthM)
      if (to - from < .001 || item.heightM < .001) continue
      const bottom = clamp(item.sillM, 0, model.floorHeightM)
      const top = clamp(item.sillM + item.heightM, 0, model.floorHeightM)
      openings.push({ polygon: wallRect(wall, from, to, .005), bottom, top })
    }
  }
  return {
    solids,
    openings,
    outside: model.rooms.filter((room) => room.kind === 'outer').map((room) => room.vertices),
    inside: model.rooms.filter((room) => room.kind !== 'outer').map((room) => room.vertices),
    height: model.floorHeightM,
  }
}

function allSegments(polygons: Polygon2[]): Segment[] {
  const result: Segment[] = []
  for (const polygon of polygons) {
    for (let i = 0; i < polygon.length; i++) {
      const a = polygon[i]
      const b = polygon[(i + 1) % polygon.length]
      if (Math.hypot(b.x - a.x, b.y - a.y) < .00001) continue
      result.push({ a, b, xMin: Math.min(a.x, b.x), xMax: Math.max(a.x, b.x), zMin: Math.min(a.y, b.y), zMax: Math.max(a.y, b.y) })
    }
  }
  return result
}

/** All x event positions including crossing points, so scanline bands cannot swap z ordering. */
function xEvents(segments: Segment[]): number[] {
  const events = new Set<number>()
  const bound = segments.map((s) => {
    events.add(round10um(s.a.x))
    events.add(round10um(s.b.x))
    return s
  })
  for (let i = 0; i < bound.length; i++) {
    const a = bound[i]
    for (let j = i + 1; j < bound.length; j++) {
      const b = bound[j]
      if (Math.min(a.xMax, b.xMax) - Math.max(a.xMin, b.xMin) < .00001) continue
      if (Math.min(a.zMax, b.zMax) < Math.max(a.zMin, b.zMin) - .00001) continue
      const ax = a.b.x - a.a.x, ay = a.b.y - a.a.y
      const bx = b.b.x - b.a.x, by = b.b.y - b.a.y
      const den = ax * by - ay * bx
      if (Math.abs(den) < 1e-10) continue
      const cx = b.a.x - a.a.x, cy = b.a.y - a.a.y
      const t = (cx * by - cy * bx) / den
      const u = (cx * ay - cy * ax) / den
      if (t > .00001 && t < .99999 && u > .00001 && u < .99999) {
        events.add(round10um(a.a.x + ax * t))
      }
    }
  }
  return [...events].sort((a, b) => a - b)
}

function zAtX(segment: Segment, x: number) {
  const dx = segment.b.x - segment.a.x
  return segment.a.y + (x - segment.a.x) / dx * (segment.b.y - segment.a.y)
}

function cutsAtX(segments: Segment[], x: number): AtX[] {
  const cuts = segments.filter((s) => x > s.xMin + 1e-9 && x < s.xMax - 1e-9)
    .map((segment) => ({ z: zAtX(segment, x), segment }))
    .sort((a, b) => a.z - b.z)
  const unique: AtX[] = []
  for (const cut of cuts) {
    if (unique.length && Math.abs(unique[unique.length - 1].z - cut.z) < 1e-7) continue
    unique.push(cut)
  }
  return unique
}

const signedArea = (poly: Polygon2) => {
  let area = 0
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i], b = poly[(i + 1) % poly.length]
    area += a.x * b.y - b.x * a.y
  }
  return area / 2
}

function emitTriangle(positions: number[], a: PointM, ay: number, b: PointM, by: number, c: PointM, cy: number) {
  positions.push(a.x, ay, a.y, b.x, by, b.y, c.x, cy, c.y)
}

function cap(positions: number[], cell: Cell, y: number, up: boolean) {
  const [a, b, c, d] = cell.polygon
  if (Math.abs(signedArea(cell.polygon)) <= MIN_AREA) return
  if (up) {
    emitTriangle(positions, a, y, c, y, b, y)
    emitTriangle(positions, a, y, d, y, c, y)
  } else {
    emitTriangle(positions, a, y, b, y, c, y)
    emitTriangle(positions, a, y, c, y, d, y)
  }
}

function side(positions: number[], a: PointM, b: PointM, bottom: number, top: number) {
  if (Math.hypot(b.x - a.x, b.y - a.y) < .00001) return
  // Right side of a CCW XZ polygon is the exterior. Normals are generated by
  // Three.js from winding; keep outward-facing triangles for front-only shading.
  emitTriangle(positions, a, bottom, a, top, b, top)
  emitTriangle(positions, a, bottom, b, top, b, bottom)
}

/**
 * Exact in the XZ plane for segments from the Blueprint. No overlapping slabs:
 * only the outside faces of the union are emitted. Door/window voids and the
 * exterior envelope's otherwise empty space share one occupancy definition.
 * Output coordinates are local to the floor; the scene group adds elevation.
 */
export function buildSolidSurface(model: BuildingModel): SolidSurface {
  const ctx = makeOccupancy(model)
  const planarEdges = allSegments([
    ...ctx.solids.map((item) => item.polygon),
    ...ctx.openings.map((item) => item.polygon),
    ...ctx.outside,
    ...ctx.inside,
  ])
  if (!planarEdges.length) return { positions: [], triangleCount: 0, interiorFill: false }
  const xs = xEvents(planarEdges)
  const ys = [...new Set([
    0, model.floorHeightM,
    ...ctx.solids.flatMap((slab) => [slab.bottom, slab.top]),
    ...ctx.openings.flatMap((slab) => [slab.bottom, slab.top]),
  ].map(round10um))].sort((a, b) => a - b)

  // Cache each horizontal scanline once: height affects occupancy, not the
  // planar partition. Avoid redrawing the same slice quadrilateral twice.
  const cells: Cell[] = []
  for (let i = 0; i < xs.length - 1; i++) {
    const x0 = xs[i], x1 = xs[i + 1]
    if (x1 - x0 < .00001) continue
    const x = (x0 + x1) / 2
    const crossings = cutsAtX(planarEdges, x)
    for (let j = 0; j < crossings.length - 1; j++) {
      const a = crossings[j], b = crossings[j + 1]
      if (b.z - a.z < .00001) continue
      const polygon: [PointM, PointM, PointM, PointM] = [
        { x: x0, y: zAtX(a.segment, x0) },
        { x: x1, y: zAtX(a.segment, x1) },
        { x: x1, y: zAtX(b.segment, x1) },
        { x: x0, y: zAtX(b.segment, x0) },
      ]
      if (Math.abs(signedArea(polygon)) > MIN_AREA) {
        cells.push({ polygon, x, z: (a.z + b.z) / 2 })
      }
    }
  }
  const positions: number[] = []
  for (let h = 0; h < ys.length - 1; h++) {
    const bottom = ys[h], top = ys[h + 1]
    if (top - bottom < .00001) continue
    const mid = (bottom + top) / 2
    for (const cell of cells) {
      const center = { x: cell.x, y: cell.z }
      if (!occupied(ctx, center, mid)) continue
      if (h === 0 || !occupied(ctx, center, bottom - EPS)) cap(positions, cell, bottom, false)
      if (h === ys.length - 2 || !occupied(ctx, center, top + EPS)) cap(positions, cell, top, true)
      const pts = cell.polygon
      for (let edge = 0; edge < 4; edge++) {
        const a = pts[edge], b = pts[(edge + 1) % 4]
        const dx = b.x - a.x, dz = b.y - a.y
        const length = Math.hypot(dx, dz)
        if (length < .00001) continue
        // A CCW cell has its interior on the left side of its directed edge.
        const outward = { x: (a.x + b.x) / 2 + dz / length * EPS, y: (a.y + b.y) / 2 - dx / length * EPS }
        if (!occupied(ctx, outward, mid)) side(positions, a, b, bottom, top)
      }
    }
  }
  return { positions, triangleCount: positions.length / 9, interiorFill: ctx.outside.length > 0 }
}

/** Selection stays linked to canonical rooms without adding a second 3D schema. */
export function nearestRoomForWallHit(model: BuildingModel, point: PointM): string {
  let bestRoom = ''
  let bestGap = Number.POSITIVE_INFINITY
  for (const wall of model.walls) {
    const ax = wall.start.x, az = wall.start.y
    const vx = wall.end.x - ax, vz = wall.end.y - az
    const t = clamp(((point.x - ax) * vx + (point.y - az) * vz) / Math.max(.000001, vx * vx + vz * vz), 0, 1)
    const d = Math.max(0, Math.hypot(point.x - ax - t * vx, point.y - az - t * vz) - wall.thicknessM / 2)
    if (d < bestGap) {
      bestGap = d
      bestRoom = model.rooms.find((room) => wall.roomIds?.includes(room.id) && room.kind !== 'outer')?.id ?? wall.roomId
    }
  }
  return bestRoom
}
STROM139_SOLID

cat > "$WORK_DIR/.strom139_patch.py" <<'STROM139_PATCH'
from pathlib import Path
import os
import re

root = Path(os.environ['STROM139_ROOT'])
scene = root / 'frontend/src/components/Building3DWorkspace.tsx'
app = root / 'frontend/src/App.tsx'
css = root / 'frontend/src/styles.css'
mod = root / 'frontend/src/building/solidGeometry.ts'
assert scene.is_file() and app.is_file() and css.is_file(), '139: expected stage sources are missing'
assert (root/'frontend/src/building/model.ts').is_file(), '139: model.ts from 138 missing'
source = scene.read_text(encoding='utf-8')
assert 'function WallMeshes(' in source and 'function RealBuildingScene(' in source, '139: Scene differs from expected 138 structure'
assert 'wallSolidPieces' in source, '139: expected wall mesh helper missing'

# 139 unified, watertight visible wall geometry; retained room and door selection.
source = source.replace("import { buildBuildingModel, wallSolidPieces,", "import { buildBuildingModel,", 1)
anchor = "import { buildBuildingModel,"
assert anchor in source
import_line = "import { buildSolidSurface, nearestRoomForWallHit } from '../building/solidGeometry'\n"
if import_line not in source: source = source.replace(anchor, import_line + anchor, 1)

m = re.search(r"function WallMeshes\([\s\S]*?(?=function DoorHandle\()", source)
assert m, '139: WallMeshes block not found'
new_wall_mesh = '''function SolidWallMeshes({ model, onSelectRoom, transparent }: {
  model: BuildingModel
  onSelectRoom: (id: string) => void
  transparent: boolean
}) {
  // Exactly one boundary mesh is rendered for the union of all walls on the
  // floor. This eliminates coplanar double-faces at projections and corners.
  const geometry = useMemo(() => {
    const surface = buildSolidSurface(model)
    const mesh = new THREE.BufferGeometry()
    mesh.setAttribute('position', new THREE.Float32BufferAttribute(surface.positions, 3))
    mesh.computeVertexNormals()
    mesh.computeBoundingSphere()
    return mesh
  }, [model])
  useEffect(() => () => geometry.dispose(), [geometry])
  return (
    <mesh
      geometry={geometry}
      onClick={(event: ThreeEvent<MouseEvent>) => {
        event.stopPropagation()
        const roomId = nearestRoomForWallHit(model, { x: event.point.x, y: event.point.z })
        if (roomId) onSelectRoom(roomId)
      }}
      castShadow={!transparent}
      receiveShadow
    >
      <meshStandardMaterial
        color="#c1ccda"
        roughness={0.84}
        transparent={transparent}
        opacity={transparent ? 0.34 : 1}
        depthWrite={!transparent}
        side={THREE.DoubleSide}
      />
    </mesh>
  )
}

'''
source = source[:m.start()] + new_wall_mesh + source[m.end():]
wall_render = '''        {model.walls.map((wall) => (
          <WallMeshes key={wall.id} wall={wall} selected={wall.roomIds?.includes(selectedRoomId) ?? (selectedRoomId === wall.roomId)} onSelect={() => { onSelectRoom(wall.roomId); onSelectDoor('') }} transparent={transparent} />
        ))}'''
if wall_render not in source:
    alternate = '''        {model.walls.map((wall) => (
          <WallMeshes key={wall.id} wall={wall} selected={selectedRoomId === wall.roomId} onSelect={() => { onSelectRoom(wall.roomId); onSelectDoor('') }} transparent={transparent} />
        ))}'''
    assert alternate in source, '139: old 3D wall rendering not found'
    wall_render = alternate
source = source.replace(wall_render, '''        <SolidWallMeshes
          model={model}
          onSelectRoom={(id) => { onSelectRoom(id); onSelectDoor('') }}
          transparent={transparent}
        />''', 1)

# Preserve 3D Haus controls and data editing; reuse exactly the same live scene
# in Wanddetail. Legacy SVG editing remains available by explicit button.
old_signature = "export default function Building3DWorkspace({ floor, rooms, selectedRoomId, onSelectRoom, onPersistRoom, onCaptureUndo, onBackToBlueprint }: {"
new_signature = "export default function Building3DWorkspace({ floor, rooms, selectedRoomId, onSelectRoom, onPersistRoom, onCaptureUndo, onBackToBlueprint, variant = 'house', onOpenLegacyWallDetail }: {"
assert old_signature in source, '139: Building3DWorkspace signature unexpected'
source = source.replace(old_signature, new_signature, 1)
old_prop = "  onBackToBlueprint: () => void\n}) {"
assert old_prop in source
source = source.replace(old_prop, "  onBackToBlueprint: () => void\n  variant?: 'house' | 'wall'\n  onOpenLegacyWallDetail?: () => void\n}) {", 1)
source = source.replace('<strong>Echtes 3D · Aufbauphase 1</strong>', "<strong>{variant === 'wall' ? 'Wanddetail · Echtes 3D' : 'Echtes 3D · Aufbauphase 1'}</strong>",1)
anchor = '<button type="button" title="Zum 2D-Blueprint wechseln" onClick={onBackToBlueprint}>Zurueck zum Blueprint (2D)</button>'
assert anchor in source
source = source.replace(anchor, anchor + '''
        {variant === 'wall' && onOpenLegacyWallDetail && (
          <button type="button" title="Bisherige Wandobjekte, Durchbrueche und Wand-Popup bearbeiten" onClick={onOpenLegacyWallDetail}>
            Klassische Wandbearbeitung
          </button>
        )}''',1)
source = source.replace('<h2>3D-Eigenschaften</h2>', "<h2>{variant === 'wall' ? 'Wanddetail · Eigenschaften' : '3D-Eigenschaften'}</h2>",1)
scene.write_text(source,encoding='utf-8')

src = app.read_text(encoding='utf-8')
assert "import Building3DWorkspace from './components/Building3DWorkspace'" in src, '139: Update 137 not integrated in App.tsx'
anchor = "  const [viewMode, setViewMode] = useState<ViewMode>('floorplan')"
assert src.count(anchor) == 1
src = src.replace(anchor, anchor+"\n  const [legacyWallDetail, setLegacyWallDetail] = useState(false)",1)
old_block = '''          {selectedObject && viewMode === 'wall' && floor && hasWallDetailAccess && (
            <WallDetailEditor
              floor={floor}
              rooms={rooms}
              selectedRoomId={selectedRoomId}
              onSelectRoom={setSelectedRoomId}
              canUndo={undoStack.length > 0}
              onUndo={undoLastAction}
            />
          )}'''
assert old_block in src, '139: current Wanddetail routing differs; abort before deploying'
wall_block='''          {selectedObject && viewMode === 'wall' && floor && hasWallDetailAccess && (
            legacyWallDetail ? (
              <div className="wall-detail-legacy-wrapper">
                <button type="button" title="Zur echten 3D-Darstellung wechseln" onClick={() => setLegacyWallDetail(false)}>
                  Zurueck zu Echtes 3D (Wanddetail)
                </button>
                <WallDetailEditor
                  floor={floor}
                  rooms={rooms}
                  selectedRoomId={selectedRoomId}
                  onSelectRoom={setSelectedRoomId}
                  canUndo={undoStack.length > 0}
                  onUndo={undoLastAction}
                />
              </div>
            ) : (
              <Building3DWorkspace
                variant="wall"
                floor={floor}
                rooms={rooms}
                selectedRoomId={selectedRoomId}
                onSelectRoom={setSelectedRoomId}
                onPersistRoom={async (nextRoom) => {
                  try {
                    setError(null)
                    const saved = await updateRoom(nextRoom.id, roomToPayload(nextRoom))
                    updateRoomInState({ ...saved, roomType: nextRoom.roomType ?? saved.roomType ?? 'room' })
                  } catch (err) {
                    setError(err instanceof Error ? err.message : String(err))
                    throw err
                  }
                }}
                onCaptureUndo={() => captureUndoSnapshot()}
                onBackToBlueprint={() => handleViewModeClick('floorplan')}
                onOpenLegacyWallDetail={() => setLegacyWallDetail(true)}
              />
            )
          )}'''
src = src.replace(old_block,wall_block,1)
# Default to modern wall view whenever the user enters Wanddetail from another tab.
mode_block = "  function handleViewModeClick(mode: ViewMode) {\n    if (!canUseViewMode(mode)) return"
assert mode_block in src
src=src.replace(mode_block,mode_block+"\n    if (mode === 'wall' && viewMode !== 'wall') setLegacyWallDetail(false)",1)
app.write_text(src,encoding='utf-8')

styles = css.read_text(encoding='utf-8')
css_tag = '/* 139: unified WebGL wall detail + full height 3D */'
assert css_tag not in styles, '139 already present in styles; stop to avoid repetition'
styles += '''

/* 139: unified WebGL wall detail + full height 3D */
.main-area:has(.building3d-layout) {
  display: flex !important;
  flex-direction: column;
  min-height: 0;
}
.main-area:has(.building3d-layout) > .workspace {
  display: flex !important;
  flex: 1 1 auto;
  height: auto !important;
  min-height: 0;
  overflow: hidden;
}
.workspace > .building3d-layout {
  flex: 1 1 auto;
  height: 100%;
  min-height: 0;
  max-height: none;
  overflow: hidden;
}
.building3d-layout > .building3d-content {
  min-height: 0;
  overflow: hidden;
}
.building3d-content > .building3d-view {
  min-height: 0;
  height: 100%;
}
.building3d-view > canvas { width: 100%; height: 100%; }
.wall-detail-legacy-wrapper { display: flex; flex-direction: column; gap: .65rem; height: 100%; min-height: 0; }
.wall-detail-legacy-wrapper > button { width: fit-content; flex: 0 0 auto; }
.wall-detail-legacy-wrapper > .wall-detail-layout { flex: 1 1 auto; min-height: 0; }
@media(max-width: 780px) {
  .workspace > .building3d-layout { height: 100%; min-height: 0; }
  .building3d-content { display: flex; flex-direction: column; }
  .building3d-view { flex: 1 1 auto; min-height: 180px; }
  .building3d-inspector { flex: 0 0 auto; max-height: 32vh; }
}
'''
css.write_text(styles,encoding='utf-8')

# The new solid geometry implementation is copied as the only new module.
module_path = Path(os.environ['STROM139_MODULE_FILE'])
mod.parent.mkdir(parents=True,exist_ok=True)
mod.write_text(module_path.read_text(encoding='utf-8'),encoding='utf-8')
print('139: unified wall surface in Three.js, live Wanddetail and full-height layout patched')
STROM139_PATCH
export STROM139_ROOT="$WORK_DIR"
export STROM139_MODULE_FILE="$WORK_DIR/frontend/src/building/solidGeometry.ts"
python3 "$WORK_DIR/.strom139_patch.py" >>"$DIAG_LOG" 2>&1 || fail "Code-Patch fehlgeschlagen. Kein Git-Push/Deploy."
rm -f "$WORK_DIR/.strom139_patch.py"

cat > "$WORK_DIR/docs/3D_WANDKOERPER_INCREMENT_139.md" <<'STROM139_DOC'
# STROM 139 - Gemeinsames Wandvolumen und Wanddetail als echtes 3D

## Anlass
Im Stand 138 wurden parallele Raumkanten bereits zu physischen Wandabschnitten
verbunden. An dicken Aussenwaenden ohne definierte Raumkontur blieben kleine
Hohlraeume und an Wandvorsprüngen sichtbare doppelte Oberflaechen.

## Neue dreidimensionale Wanddarstellung
- Die `BuildingWall`-Wandabschnitte werden zu einem gemeinsamen Volumen vereint.
- Wenn eine explizite Aussenwandkontur vorhanden ist, gilt ihr gesamtes Inneres
  ohne Raumzuweisung als vollstaendiges Bauteilvolumen. Definierte Raumflaechen
  bleiben hohl; modellierte Tueren und Fenster bleiben ausgeschnitten.
- Die Ebenen werden durch alle Bauteil- und Oeffnungshoehen aufgeteilt.
- Eine planare Scanline-Zerlegung bildet den exakten Grundriss der Volumen-Union
  inkl. schraegem Wandverlauf. Es werden ausschliesslich sichtbare Grenzflaechen
  trianguliert; doppelte interne Quaderflaechen werden nicht gerendert.
- Keine neuen Datenbanktabellen, kein lokaler zweiter Datenstand.

## Wanddetail und Fensterhoehe
- Wanddetail startet nun in demselben echten WebGL-Renderer wie 3D Haus.
- Die alte SVG-basierte Wandbearbeitung wird als optionale Altansicht erhalten,
  damit ihre spezifischen Objekt- und Wanddialoge vorerst nutzbar bleiben.
- 3D Haus und Wanddetail fuellen die Hoehe des verfuegbaren Workspace aus.
- Aenderungen von Raumposition und Tuerparametern bleiben im gemeinsamen API-
  Modell gespeichert und erscheinen bei der naechsten Blueprint-Darstellung.

## Grenzen
- Die neue Union wird zurzeit pro Etage gebildet, noch nicht etagenuebergreifend.
- Wanddetail-Objektauswahl/Popup wird fuer neu gerenderte 3D-Wandflaechen in
  weiteren Inkrementen ebenfalls direkt in den WebGL-Editor migriert; die
  bisherige Wandbearbeitung ist bis dahin weiterhin erreichbar.

## Deployment
- Stage zuerst; Temp-Copy-Build, Tests, GitHub-Push, dann Stage-Deployment.
- Produktionsanwendung und vorhandene Daten werden nicht direkt angepasst.
STROM139_DOC

log "4) TypeScript/Vite-Build und Volumengeometrie pruefen..."
(
  cd "$WORK_DIR/frontend"
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Frontend-Build fehlgeschlagen. Kein Git-Push/Stage-Deploy."

export STROM139_MODEL_PATH="$WORK_DIR/frontend/src/building/model.ts"
export STROM139_SURFACE_PATH="$WORK_DIR/frontend/src/building/solidGeometry.ts"
export STROM139_TYPESCRIPT="$DEPENDENCIES/typescript"
node <<'STROM139_TEST' >>"$DIAG_LOG" 2>&1 || fail "Geometrietest fehlgeschlagen. Kein Git-Push/Stage-Deploy."
'use strict'
const fs = require('fs');
const ts = require(process.env.STROM139_TYPESCRIPT);
const src = p => ts.transpileModule(fs.readFileSync(p, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, reportDiagnostics:true});
const compiled = {}
function load(name, file) {
  const result = src(file)
  const errors=result.diagnostics.filter(d=>d.category===ts.DiagnosticCategory.Error)
  if(errors.length) throw new Error(errors.map(e=>ts.flattenDiagnosticMessageText(e.messageText,' ')).join('\n'))
  const m={exports:{}}
  new Function('module','exports','require',result.outputText)(m,m.exports,(ref)=>{
    if(ref==='./model') return compiled.model
    throw Error(`Unhandled require ${ref}`)
  })
  compiled[name]=m.exports
}
load('model',process.env.STROM139_MODEL_PATH)
load('surface',process.env.STROM139_SURFACE_PATH)
const {buildBuildingModel}=compiled.model
const {buildSolidSurface,solidAt,nearestRoomForWallHit}=compiled.surface
const floor={id:'f',name:'EG',heightM:2.7,elevationM:0}
const rect=(x0,z0,x1,z1)=>[{x:x0,y:z0},{x:x1,y:z0},{x:x1,y:z1},{x:x0,y:z1}]
const room=(id,vertices,thickness=.12,outer=false)=>({id,floorId:'f',name:outer?'__strom_outer_wall__':id,roomType:'room',wallThicknessM:thickness,vertices})
function assert(ok,message){if(!ok)throw new Error(message)}
const outside=room('outer',rect(0,0,10,6),.3,true)
const inner=room('living',rect(.35,.35,9.65,5.65),.12)
const m=buildBuildingModel(floor,[outside,inner],[])
const outsideFill={x:.17,y:2.0}
const center={x:5,y:3}
assert(solidAt(m,outsideFill,1.4),'Area inside outer boundary but outside rooms must be solid')
assert(!solidAt(m,center,1.4),'Defined room interior must stay empty')
let t=Date.now();const geo=buildSolidSurface(m)
assert(geo.triangleCount>0,'Nonempty solid surface')
assert(geo.interiorFill,'Infill detection')
console.log('shell triangles',geo.triangleCount,'duration',Date.now()-t,'ms')
assert(nearestRoomForWallHit(m,{x:.35,y:3})==='living','Room mapping')
const door=(id,rid,edgeIndex,x,w,h=0.78)=>({id,roomId:rid,edgeIndex,floorId:'f',objectType:'door',groupId:'d1',x,y:1-h/2,w,h})
const withDoor=buildBuildingModel(floor,[outside,inner],[door('od','outer',3,.5,.12),door('id','living',3,.5,.12)])
assert(withDoor.doors.length===1,'Canonical door should remain unified')
const candidate=withDoor.walls.find(w=>w.openings.length)
assert(candidate,'Door should be mapped to wall')
const start=candidate.start,end=candidate.end, op=candidate.openings[0]
const d=(op.centerM/candidate.lengthM)
const cp={x:start.x+(end.x-start.x)*d,y:start.y+(end.y-start.y)*d}
assert(!solidAt(withDoor,cp,op.heightM/2),'Opening must not be refilled by exterior infill')
assert(solidAt(withDoor,cp,2.6),'Header must stay solid over opening')
t=Date.now(); const gd=buildSolidSurface(withDoor); console.log('door triangles',gd.triangleCount,'duration',Date.now()-t,'ms')
assert(gd.triangleCount>geo.triangleCount * .8,'Door mesh unexpectedly empty')
// Top-surface triangles must not geometrically overlap at sample points.
const polyArea=(a,b,c)=>Math.abs((b.x-a.x)*(c.y-a.y)-(c.x-a.x)*(b.y-a.y))*.5
const inTri=(p,a,b,c)=>{
 const all=polyArea(a,b,c)
 if(all<1e-8)return false
 const sum=polyArea(p,b,c)+polyArea(a,p,c)+polyArea(a,b,p)
 return Math.abs(sum-all)<Math.max(1e-9,all*1e-7)
}
for(const model of [m,withDoor]) {
 const data=buildSolidSurface(model).positions
 for(const p of [{x:.17,y:2.0},{x:5,y:3},{x:.3,y:.3},{x:9.8,y:5.9}]){
  let count=0
  for(let i=0;i<data.length;i+=9){
    const a={x:data[i],y:data[i+2]};const b={x:data[i+3],y:data[i+5]};const c={x:data[i+6],y:data[i+8]};
    if(Math.abs(data[i+1]-2.7)>.0001||Math.abs(data[i+4]-2.7)>.0001||Math.abs(data[i+7]-2.7)>.0001)continue
    if(inTri(p,a,b,c))count++
  }
  assert(count<=2,`Top surface is overdrawing (${count}) at ${JSON.stringify(p)}`)
 }
}
console.log('139: Geometric volume tests: PASS')
STROM139_TEST

log "4.1) Alle Volumen- und Oeffnungstests bestanden."

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
log "Update 139 erfolgreich. Bitte unter https://home.moja.de/strom-test/ pruefen:"
log "  - Innen-/Aussenwaende sind EIN Volumen ohne interne Ueberlappungsflaechen."
log "  - Freiraeume in der Aussenkontur ohne definierten Raum sind gefuellt.
  - Tueren und Fenster bleiben als echte Oeffnungen erhalten."
log "  - Wanddetail oeffnet standardmaessig den echten 3D-Renderer.
  - Alte SVG-Wandbearbeitung ist ueber einen Button weiterhin erreichbar.
  - 3D Haus und Wanddetail nutzen die gesamte verfuegbare Hoehe.
  - Auswahl der Raumwaende sowie 2D/3D-Datensynchronisation bleiben erhalten."
log "  - Blueprint und Produktion wurden nicht direkt geaendert."
log "Backup: $BACKUP_DIR"
