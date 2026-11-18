#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-1425_141a_wanddetail_hover_highlight_typfix"
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
COMMIT_MESSAGE="Update 141a: Hover-Highlight (TypeScript faceIndex null-Fix) einzelner Wandflaechen im echten 3D-Wanddetail"
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
  echo "2) Aktuellen Stage-Source + Update 141a nach GitHub pushen ..."
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

  echo "1.3) Update 141a auf Git-Source anwenden und Build pruefen ..."
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

log "=== Update 141a / Wanddetail Hover-Highlight TypeScript-Fix ==="
log "Stage: $STAGE_DIR"
log "Produktion, Blueprint und bestehendes massives 3D-Wandvolumen werden nicht veraendert."
log "Diagnose: $DIAG_LOG"
[ -f "$STAGE_DIR/frontend/src/building/solidGeometry.ts" ] || fail "Update 139 fehlt: solidGeometry.ts nicht gefunden."
[ -f "$STAGE_DIR/frontend/src/building/model.ts" ] || fail "Gebaeudemodell fehlt."
[ -f "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" ] || fail "3D-Renderer fehlt."
[ -f "$STAGE_DIR/frontend/src/App.tsx" ] || fail "App.tsx fehlt."
grep -q 'function SolidWallMeshes(' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "Update 139 fehlt: kein gemeinsames 3D-Wandvolumen."
grep -q 'legacyWallDetail' "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 139 fehlt: alte Wandbearbeitung nicht vorhanden."
grep -q 'function WallFrontOverlay(' "$STAGE_DIR/frontend/src/App.tsx" || fail "Bisherige Frontalansicht fehlt."
grep -q 'function WallObjectLibraryFloating(' "$STAGE_DIR/frontend/src/App.tsx" || fail "Bisherige Objektbibliothek fehlt."
[ -f "$STAGE_DIR/frontend/src/building/wallHitSelection.ts" ] || fail "140a-Wandauswahl fehlt."
grep -q 'STROM140_3D_WALL_EDITOR' "$STAGE_DIR/frontend/src/App.tsx" || fail "140a-Wandbearbeitung fehlt."
grep -q 'selectWallEdgeFrom3DHit' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "140a-Klickzuordnung fehlt."
if grep -q 'STROM141_WALL_HOVER' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx"; then fail "Hover-Update 141 ist bereits eingespielt."; fi
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

log "3) Hover-Highlight auf bestehende Wandklick-Auswahl aufsetzen..."
cat > "$WORK_DIR/.strom141_wallHoverGeometry.ts" <<'STROM141_MODULE'
import type { PointM } from '../types'

/**
 * STROM141_WALL_HOVER: highlight the exact *visible* triangles of a wall face.
 *
 * The 139 wall geometry is a single unioned surface, not one object per wall.
 * We therefore cannot simply recolor the clicked mesh. Instead, we copy only
 * triangles on the hovered physical face, clipped to the chosen Blueprint edge.
 * Existing door/window holes remain holes because the source surface contains
 * no triangles there. This module neither edits nor persists building geometry.
 */
export type WallHoverPlane = {
  normalX: number
  normalZ: number
  offsetM: number
}

type Vertex3 = { x: number; y: number; z: number }
type Face3 = { vertices: [Vertex3, Vertex3, Vertex3]; normalX: number; normalY: number; normalZ: number }
const EPS = 1e-8

function triangleAt(array: ArrayLike<number>, faceIndex: number): Face3 | null {
  const i = faceIndex * 9
  if (!Number.isInteger(faceIndex) || i < 0 || i + 8 >= array.length) return null
  const a = { x: Number(array[i]), y: Number(array[i + 1]), z: Number(array[i + 2]) }
  const b = { x: Number(array[i + 3]), y: Number(array[i + 4]), z: Number(array[i + 5]) }
  const c = { x: Number(array[i + 6]), y: Number(array[i + 7]), z: Number(array[i + 8]) }
  const ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z
  const vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z
  const nx = uy * vz - uz * vy
  const ny = uz * vx - ux * vz
  const nz = ux * vy - uy * vx
  const len = Math.hypot(nx, ny, nz)
  if (len < EPS) return null
  return { vertices: [a, b, c], normalX: nx / len, normalY: ny / len, normalZ: nz / len }
}

function edgeBasis(a: PointM, b: PointM) {
  const length = Math.hypot(b.x - a.x, b.y - a.y)
  if (length < 0.05) return null
  return { length, dx: (b.x - a.x) / length, dz: (b.y - a.y) / length }
}

function plausibleVerticalFace(face: Face3, tx: number, tz: number) {
  // A vertical face parallel to the selected Blueprint edge.
  return Math.abs(face.normalY) < 0.22 && Math.abs(face.normalX * tx + face.normalZ * tz) < 0.17
}

/** Find the actually hit vertical plane, or its closest physical face when the cursor is on its top. */
export function pickWallHoverPlane(
  positions: ArrayLike<number>, a: PointM, b: PointM,
  hit: PointM, faceIndex?: number,
): WallHoverPlane | null {
  const edge = edgeBasis(a, b)
  if (!edge) return null
  const hitFace = faceIndex !== undefined ? triangleAt(positions, faceIndex) : null
  if (hitFace && plausibleVerticalFace(hitFace, edge.dx, edge.dz)) {
    return {
      normalX: hitFace.normalX,
      normalZ: hitFace.normalZ,
      offsetM: hitFace.normalX * hit.x + hitFace.normalZ * hit.y,
    }
  }

  // A top/edge-of-wall click has an upward normal. Find the nearest vertical
  // surface on the selected segment instead of highlighting the entire union.
  let winner: WallHoverPlane | null = null
  let best = Number.POSITIVE_INFINITY
  const hitT = (hit.x - a.x) * edge.dx + (hit.y - a.y) * edge.dz
  if (hitT < -0.12 || hitT > edge.length + 0.12) return null
  for (let i = 0; i + 8 < positions.length; i += 9) {
    const face = triangleAt(positions, i / 9)
    if (!face || !plausibleVerticalFace(face, edge.dx, edge.dz)) continue
    const center = {
      x: (face.vertices[0].x + face.vertices[1].x + face.vertices[2].x) / 3,
      y: (face.vertices[0].z + face.vertices[1].z + face.vertices[2].z) / 3,
    }
    const t = (center.x - a.x) * edge.dx + (center.y - a.y) * edge.dz
    if (t < -0.15 || t > edge.length + 0.15) continue
    const offset = face.normalX * center.x + face.normalZ * center.y
    const gap = Math.abs(face.normalX * hit.x + face.normalZ * hit.y - offset)
    if (gap < best && gap < 0.91) {
      winner = { normalX: face.normalX, normalZ: face.normalZ, offsetM: offset }
      best = gap
    }
  }
  return winner
}

function clipAlongEdge(vertices: Vertex3[], a: PointM, dx: number, dz: number, boundary: number, keepAbove: boolean): Vertex3[] {
  if (!vertices.length) return vertices
  const at = (v: Vertex3) => (v.x - a.x) * dx + (v.z - a.y) * dz
  const inside = (v: Vertex3) => keepAbove ? at(v) >= boundary - 1e-7 : at(v) <= boundary + 1e-7
  const output: Vertex3[] = []
  for (let i = 0; i < vertices.length; i += 1) {
    const first = vertices[i]
    const second = vertices[(i + 1) % vertices.length]
    const fi = inside(first)
    const si = inside(second)
    if (fi) output.push(first)
    if (fi !== si) {
      const from = at(first), to = at(second)
      const alpha = Math.max(0, Math.min(1, (boundary - from) / (to - from)))
      output.push({
        x: first.x + (second.x - first.x) * alpha,
        y: first.y + (second.y - first.y) * alpha,
        z: first.z + (second.z - first.z) * alpha,
      })
    }
  }
  return output
}

/** Copies the exact surface fragments on the hovered plane, leaving true openings empty. */
export function buildWallHoverTriangles(
  positions: ArrayLike<number>, a: PointM, b: PointM, plane: WallHoverPlane,
): number[] {
  const edge = edgeBasis(a, b)
  if (!edge) return []
  const output: number[] = []
  for (let i = 0; i + 8 < positions.length; i += 9) {
    const face = triangleAt(positions, i / 9)
    if (!face || !plausibleVerticalFace(face, edge.dx, edge.dz)) continue
    if (Math.abs(face.normalX * plane.normalX + face.normalZ * plane.normalZ) < 0.98) continue
    if (face.vertices.some((p) => Math.abs(plane.normalX * p.x + plane.normalZ * p.z - plane.offsetM) > 0.005)) continue

    let polygon: Vertex3[] = face.vertices
    polygon = clipAlongEdge(polygon, a, edge.dx, edge.dz, 0, true)
    polygon = clipAlongEdge(polygon, a, edge.dx, edge.dz, edge.length, false)
    if (polygon.length < 3) continue
    for (let j = 1; j < polygon.length - 1; j += 1) {
      const p0 = polygon[0], p1 = polygon[j], p2 = polygon[j + 1]
      const ux = p1.x - p0.x, uy = p1.y - p0.y, uz = p1.z - p0.z
      const vx = p2.x - p0.x, vy = p2.y - p0.y, vz = p2.z - p0.z
      const area2 = Math.hypot(uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
      if (area2 < 1e-8) continue
      for (const p of [p0, p1, p2]) output.push(p.x, p.y, p.z)
    }
  }
  return output
}
STROM141_MODULE
cat > "$WORK_DIR/.strom141_patch.py" <<'STROM141_PATCH'
#!/usr/bin/env python3
"""STROM141: add hover highlighting to already working 140a wall selection."""
from pathlib import Path
import os

root = Path(os.environ['STROM141_ROOT'])
scene_file = root / 'frontend/src/components/Building3DWorkspace.tsx'
module_file = root / 'frontend/src/building/wallHoverGeometry.ts'
source_module = Path(os.environ['STROM141_MODULE_SOURCE'])

scene = scene_file.read_text(encoding='utf-8')
if 'STROM141_WALL_HOVER' in scene:
    raise RuntimeError('141 ist bereits vorhanden; Doppelpatch verhindert')
if 'selectWallEdgeFrom3DHit' not in scene or 'onSelectWall' not in scene:
    raise RuntimeError('Erfolgreiche 140a-3D-Wandauswahl ist nicht gefunden')
if 'function SolidWallMeshes(' not in scene or 'function DoorHandle(' not in scene:
    raise RuntimeError('Unerwarteter 3D-Renderer; Patch abgebrochen')

import_anchor = "import { selectWallEdgeFrom3DHit, type WallHitSelection3D } from '../building/wallHitSelection'"
assert scene.count(import_anchor) == 1, '140a wallHitSelection import unexpectedly changed'
scene = scene.replace(import_anchor,
    import_anchor + "\nimport { pickWallHoverPlane, buildWallHoverTriangles, type WallHoverPlane } from '../building/wallHoverGeometry'", 1)

start_marker = 'function SolidWallMeshes('
end_marker = 'function DoorHandle('
start = scene.index(start_marker)
end = scene.index(end_marker, start)
old = scene[start:end]
if not all(x in old for x in ['geometry={geometry}', 'onClick=', 'onSelectWall', 'selectWallEdgeFrom3DHit', 'meshStandardMaterial']):
    raise RuntimeError('SolidWallMeshes unterscheidet sich von 140a; unveraendert abbrechen')

hover_block = r'''// STROM141_WALL_HOVER: same Blueprint wall edge for hover and click.
// Hover rendering uses a selective COPY of the exact watertight 139 wall face.
// No second set of wall solids, no overlays across real door/window openings.
type HoveredSolidWall = WallHitSelection3D & { plane: WallHoverPlane }

function SolidWallMeshes({ model, onSelectRoom, onSelectWall, transparent }: {
  model: BuildingModel
  onSelectRoom: (id: string) => void
  onSelectWall?: (wall: WallHitSelection3D | null) => void
  transparent: boolean
}) {
  const [hovered, setHovered] = useState<HoveredSolidWall | null>(null)
  const gl = useThree((state) => state.gl)

  // Preserve the 139 model and geometry byte-for-byte: only its material
  // surface triangles are copied into the optional hover visualization.
  const geometry = useMemo(() => {
    const surface = buildSolidSurface(model)
    const mesh = new THREE.BufferGeometry()
    mesh.setAttribute('position', new THREE.Float32BufferAttribute(surface.positions, 3))
    mesh.computeVertexNormals()
    mesh.computeBoundingSphere()
    return mesh
  }, [model])
  useEffect(() => () => geometry.dispose(), [geometry])

  const hoverGeometry = useMemo(() => {
    if (!onSelectWall || !hovered) return null
    const room = model.rooms.find((item) => item.id === hovered.roomId)
    if (!room?.vertices || room.vertices.length < 2) return null
    const a = room.vertices[hovered.edgeIndex]
    const b = room.vertices[(hovered.edgeIndex + 1) % room.vertices.length]
    if (!a || !b) return null
    const positions = buildWallHoverTriangles(
      (geometry.getAttribute('position') as THREE.BufferAttribute).array, a, b, hovered.plane,
    )
    if (!positions.length) return null
    const patch = new THREE.BufferGeometry()
    patch.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3))
    patch.computeVertexNormals()
    patch.computeBoundingSphere()
    return patch
  }, [geometry, model, hovered, onSelectWall])
  useEffect(() => () => { hoverGeometry?.dispose() }, [hoverGeometry])

  // Only Wanddetail provides onSelectWall. 3D Haus is left untouched.
  useEffect(() => {
    if (!onSelectWall) return
    gl.domElement.style.cursor = hovered ? 'pointer' : ''
    return () => { gl.domElement.style.cursor = '' }
  }, [gl, hovered, onSelectWall])

  function hoverAt(event: ThreeEvent<PointerEvent>) {
    if (!onSelectWall) return
    const point = { x: event.point.x, y: event.point.z }
    const hitWall = selectWallEdgeFrom3DHit(model, point)
    if (!hitWall) {
      setHovered((previous) => previous === null ? previous : null)
      return
    }
    const room = model.rooms.find((item) => item.id === hitWall.roomId)
    if (!room?.vertices || room.vertices.length < 2) {
      setHovered(null)
      return
    }
    const a = room.vertices[hitWall.edgeIndex]
    const b = room.vertices[(hitWall.edgeIndex + 1) % room.vertices.length]
    if (!a || !b) { setHovered(null); return }
    const plane = pickWallHoverPlane(
      (geometry.getAttribute('position') as THREE.BufferAttribute).array, a, b, point, event.faceIndex ?? undefined,
    )
    if (!plane) { setHovered(null); return }
    // No React rerender while moving within the same physical wall surface.
    setHovered((previous) => {
      if (previous && previous.roomId === hitWall.roomId && previous.edgeIndex === hitWall.edgeIndex
        && Math.abs(previous.plane.offsetM - plane.offsetM) < 0.006
        && previous.plane.normalX * plane.normalX + previous.plane.normalZ * plane.normalZ > 0.99) {
        return previous
      }
      return { ...hitWall, plane }
    })
  }

  return (
    <group>
      <mesh
        geometry={geometry}
        onPointerMove={hoverAt}
        onPointerOut={() => setHovered(null)}
        onClick={(event: ThreeEvent<MouseEvent>) => {
          event.stopPropagation()
          if (onSelectWall && event.delta > 5) return // 3D camera orbit, not a wall click
          const point = { x: event.point.x, y: event.point.z }
          const hitWall = onSelectWall ? selectWallEdgeFrom3DHit(model, point) : null
          if (hitWall) {
            onSelectWall?.(hitWall)
            onSelectRoom(hitWall.roomId)
          } else {
            const roomId = nearestRoomForWallHit(model, point)
            if (roomId) onSelectRoom(roomId)
          }
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
      {hovered && hoverGeometry && onSelectWall && (
        <mesh
          geometry={hoverGeometry}
          position={[hovered.plane.normalX * 0.006, 0, hovered.plane.normalZ * 0.006]}
          raycast={() => {}}
          renderOrder={9}
        >
          <meshBasicMaterial
            color="#2563eb"
            transparent
            opacity={transparent ? 0.56 : 0.42}
            depthWrite={false}
            depthTest
            side={THREE.DoubleSide}
            polygonOffset
            polygonOffsetFactor={-2}
            polygonOffsetUnits={-2}
          />
        </mesh>
      )}
    </group>
  )
}

'''
scene = scene[:start] + hover_block + scene[end:]
scene_file.write_text(scene, encoding='utf-8')
module_file.parent.mkdir(parents=True, exist_ok=True)
module_file.write_text(source_module.read_text(encoding='utf-8'), encoding='utf-8')
print('141a: Wanddetail zeigt pro Wand eine blaue Hover-Flaeche; exakt dieselbe Raumkante wird beim Klicken ausgewaehlt. 3D Haus unveraendert.')
STROM141_PATCH
STROM141_ROOT="$WORK_DIR" STROM141_MODULE_SOURCE="$WORK_DIR/.strom141_wallHoverGeometry.ts" \
  python3 "$WORK_DIR/.strom141_patch.py" >>"$DIAG_LOG" 2>&1 || fail "Hover-Patch fehlgeschlagen."
rm -f "$WORK_DIR/.strom141_patch.py" "$WORK_DIR/.strom141_wallHoverGeometry.ts"

cat > "$WORK_DIR/docs/3D_WAND_HOVER_INCREMENT_141.md" <<'STROM141_DOC'
# Update 141a – Wandhover im echten 3D-Wanddetail

- TypeScript/R3F: `event.faceIndex` kann `null` liefern; `?? undefined` passt die Signatur von `pickWallHoverPlane` korrekt an.

- Dieselbe `selectWallEdgeFrom3DHit`-Funktion wie beim Klick ermittelt die betroffene Raumkante beim Mouseover.
- Nur im Wanddetail werden die EXAKTEN vertikalen Oberflaechendreiecke des massiven Wandmodells blau halbtransparent hervorgehoben.
- Die Hoverflaeche wird auf die ausgewaehlte Wandkante begrenzt; keine separate Wandgeometrie wird erzeugt.
- Tuer- und Fensteroeffnungen bleiben offen, weil ihre Dreiecke im massiven Originalmodell fehlen.
- Beim Verlassen der Wand verschwindet das Highlight. Das Overlay ist nicht anklickbar und blockiert deshalb keine Auswahl.
- 3D Haus, Blueprint, Geometrie, Datenbank und vorhandene Wandbearbeitungs-Popups werden nicht geaendert.
- Fallback beim Hover auf eine Wandoberkante: Naechste vertikale reale Wandflaeche ermitteln.
STROM141_DOC

# Guard: no changes to solid wall geometry or canonical building model.
cmp -s "$STAGE_DIR/frontend/src/building/model.ts" "$WORK_DIR/frontend/src/building/model.ts" || fail "Unbeabsichtigte Aenderung am Gebaeudemodell."
cmp -s "$STAGE_DIR/frontend/src/building/solidGeometry.ts" "$WORK_DIR/frontend/src/building/solidGeometry.ts" || fail "Unbeabsichtigte Aenderung an der Wandvolumen-Geometrie."

log "4) TypeScript/Vite-Build in Arbeitskopie pruefen..."
(
  cd "$WORK_DIR/frontend"
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Frontend-Build fehlgeschlagen. Kein Git-Push/Stage-Deploy."

log "4.1) Hover-Geometrie auf Wandbezug und freie Tuerbereiche pruefen..."
export STROM141_HOVER_MODULE="$WORK_DIR/frontend/src/building/wallHoverGeometry.ts"
export STROM141_TYPESCRIPT="$DEPENDENCIES/typescript"
node <<'STROM141_TEST' >>"$DIAG_LOG" 2>&1 || fail "Hover-Geometrietest fehlgeschlagen. Kein Git-Push/Stage-Deploy."
'use strict'
const fs = require('fs')
const ts = require(process.env.STROM141_TYPESCRIPT)
const source = process.env.STROM141_HOVER_MODULE
const result = ts.transpileModule(fs.readFileSync(source, 'utf8'), {
  fileName: source,
  reportDiagnostics: true,
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
})
if (result.diagnostics?.some((d) => d.category === ts.DiagnosticCategory.Error)) {
  throw new Error('Hover TypeScript syntax invalid')
}
const mod = { exports: {} }
new Function('module', 'exports', result.outputText)(mod, mod.exports)
const { pickWallHoverPlane, buildWallHoverTriangles } = mod.exports
const quad = (x, za, zb) => {
  const a = [x, 0, za], b = [x, 2.7, za], c = [x, 2.7, zb], d = [x, 0, zb]
  return [...a, ...b, ...c, ...a, ...c, ...d]
}
// A real opening: on the selected wall there are NO triangles from z=1.5 to z=2.5.
// Neighboring surfaces on another plane/edge must not be highlighted.
const solidPositions = [...quad(0.2, 0, 1.5), ...quad(0.2, 2.5, 5), ...quad(0.4, 0, 5), ...quad(0.2, 5, 7)]
const a = { x: 0, y: 0 }, b = { x: 0, y: 5 }
const plane = pickWallHoverPlane(solidPositions, a, b, { x: 0.2, y: 1 }, 0)
if (!plane) throw Error('Hovered wall plane was not found')
const points = buildWallHoverTriangles(solidPositions, a, b, plane)
if (!points.length || points.length % 9 !== 0) throw Error('Invalid highlighted surface triangles')
for (let i = 0; i < points.length; i += 3) {
  if (Math.abs(points[i] - 0.2) > 0.005) throw Error('Wrong physical wall plane highlighted')
  if (points[i + 2] < -0.001 || points[i + 2] > 5.001) throw Error('Highlight extends beyond selected wall edge')
}
for (let i = 0; i < points.length; i += 9) {
  const z = [points[i + 2], points[i + 5], points[i + 8]]
  if (Math.min(...z) < 2.499 && Math.max(...z) > 1.501) throw Error('Hover covered the real opening')
}
if (!pickWallHoverPlane(solidPositions, a, b, { x: 0.21, y: 1 }, undefined)) throw Error('Wall top-face fallback broken')
if (pickWallHoverPlane(solidPositions, a, b, { x: 99, y: 99 }, undefined)) throw Error('Faraway face was selected')
console.log('141a: wall hover visible-surface test PASS, triangles:', points.length / 9)
STROM141_TEST

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
log "Update 141a erfolgreich. Test: https://home.moja.de/strom-test/"
log "  - Wanddetail: Maus ueber sichtbare Wand bewegen -> Wandflaeche wird blau markiert."
log "  - Klick auf die markierte Wand oeffnet die bekannte Wandbearbeitung."
log "  - Tuer-/Fensteroeffnungen werden nicht uebermalt."
log "  - Maus von der Wand weg -> Highlight verschwindet."
log "  - Blueprint, 3D Haus, Wandgeometrie, vorhandene Objekte bleiben unveraendert."
log "Backup: $BACKUP_DIR"
