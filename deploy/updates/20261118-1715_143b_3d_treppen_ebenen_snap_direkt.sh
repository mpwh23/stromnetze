#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-1715_143b_3d_treppen_ebenen_snap_direkt"
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
COMMIT_MESSAGE="Update 143b: Render 3D stairs and direct 0-mm snapping to ghost levels"
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
  echo "2) Aktuellen Stage-Source + Update 143b nach GitHub pushen ..."
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

  echo "1.3) Update 143b auf Git-Source anwenden und Build pruefen ..."
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

log "=== Update 143b / Treppen-Rendering und geometrisches Ebenen-Snapping ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
log "Produktions-Frontend, bestehende 3D-Wandkoerper und Datenbank werden nicht veraendert."
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
  [ -f "$STAGE_DIR/$required" ] || fail "143b benoetigt 143a und Design-v7: $required fehlt."
done
# Distinguish a deployment that never happened from a stale browser cache.
grep -q 'STROM143_CROSS_LEVEL_SNAP' "$STAGE_DIR/frontend/src/App.tsx" || fail "143a nicht in Stage-Source vorhanden. Bitte nicht auf Verdacht updaten."
grep -q 'STROM143_STAIRS_FIX' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "143a 3D-Treppenadapter fehlt in Stage-Source."
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

log "3) 3D-Treppen und Ebenen-Snap an 143a gezielt korrigieren ..."
cat > "$WORK_DIR/neighborSnap143b.ts" <<'STROM143B_SNAP_TS'
import type { PointM } from '../types'

/** 143b: Ghost-level snapping is geometric alignment, never wall clearance. */
export type NeighborSnapTarget = { vertices: PointM[] }
export type SnapHandle143 = 'left' | 'right' | 'top' | 'bottom'
type DragAxis143 = 'x' | 'y' | null
const LIMIT = 0.18 // metres; snap capture radius, NOT an offset
const EPS = 1e-7
const r3 = (v: number) => Math.round(v * 1000) / 1000
function bounds(vertices: PointM[]) {
  if (!vertices.length) return null
  return { minX: Math.min(...vertices.map(p => p.x)), maxX: Math.max(...vertices.map(p => p.x)),
    minY: Math.min(...vertices.map(p => p.y)), maxY: Math.max(...vertices.map(p => p.y)) }
}
function closestOnSegment(p: PointM, a: PointM, b: PointM): PointM {
  const dx = b.x - a.x, dy = b.y - a.y
  const t = dx * dx + dy * dy > EPS
    ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy))) : 0
  return { x: a.x + t * dx, y: a.y + t * dy }
}
function distance(a: PointM, b: PointM) { return Math.hypot(a.x - b.x, a.y - b.y) }

/** Corner to corner, or corner to a true edge; exact coordinates, no wall spacing. */
export function snapPointToVisibleRooms143(point: PointM, targets: NeighborSnapTarget[], _wallM = 0): PointM {
  let best = point, score = LIMIT
  for (const target of targets) {
    const vs = target.vertices
    for (let i = 0; i < vs.length; i++) {
      const candidates = [vs[i], closestOnSegment(point, vs[i], vs[(i + 1) % vs.length])]
      for (const candidate of candidates) {
        const d = distance(point, candidate)
        if (d < score - EPS) { best = candidate; score = d }
      }
    }
  }
  return best === point ? point : { x: r3(best.x), y: r3(best.y) }
}

/** Move a selected rectangle edge to a visible ghost edge (0 mm gap). */
export function snapRectangleHandle143(vertices: PointM[], handle: SnapHandle143, targets: NeighborSnapTarget[], _wallM = 0): PointM[] {
  const b = bounds(vertices)
  if (!b) return vertices
  const vertical = handle === 'left' || handle === 'right'
  const current = handle === 'left' ? b.minX : handle === 'right' ? b.maxX : handle === 'top' ? b.minY : b.maxY
  let snapped = current, score = LIMIT
  for (const target of targets) {
    const other = bounds(target.vertices)
    if (!other) continue
    const overlaps = vertical
      ? b.minY <= other.maxY + LIMIT && b.maxY >= other.minY - LIMIT
      : b.minX <= other.maxX + LIMIT && b.maxX >= other.minX - LIMIT
    if (!overlaps) continue
    const coords = vertical ? [other.minX, other.maxX] : [other.minY, other.maxY]
    for (const p of target.vertices) coords.push(vertical ? p.x : p.y)
    for (const value of coords) {
      const error = Math.abs(value - current)
      if (error < score - EPS) { score = error; snapped = value }
    }
  }
  if (Math.abs(snapped - current) < 0.0005) return vertices
  const next = { ...b }
  if (handle === 'left') next.minX = Math.min(next.maxX - 0.1, snapped)
  if (handle === 'right') next.maxX = Math.max(next.minX + 0.1, snapped)
  if (handle === 'top') next.minY = Math.min(next.maxY - 0.1, snapped)
  if (handle === 'bottom') next.maxY = Math.max(next.minY + 0.1, snapped)
  return [
    { x: r3(next.minX), y: r3(next.minY) }, { x: r3(next.maxX), y: r3(next.minY) },
    { x: r3(next.maxX), y: r3(next.maxY) }, { x: r3(next.minX), y: r3(next.maxY) },
  ]
}

/** Move an entire room/group rigidly: corner-to-corner or parallel edge-to-edge. */
export function snapMovedVerticesToVisibleRooms143(vertices: PointM[], targets: NeighborSnapTarget[], axis: DragAxis143 = null): PointM[] {
  if (!vertices.length || !targets.length) return vertices
  let bestDx = 0, bestDy = 0, score = LIMIT
  const trySnap = (dx: number, dy: number) => {
    if ((axis === 'x' && Math.abs(dy) > EPS) || (axis === 'y' && Math.abs(dx) > EPS)) return
    const d = Math.hypot(dx, dy)
    if (d > EPS && d < score - EPS) { bestDx = dx; bestDy = dy; score = d }
  }
  for (const target of targets) {
    for (const sourcePoint of vertices) {
      for (let j = 0; j < target.vertices.length; j++) {
        const a = target.vertices[j], b = target.vertices[(j + 1) % target.vertices.length]
        const near = closestOnSegment(sourcePoint, a, b)
        trySnap(near.x - sourcePoint.x, near.y - sourcePoint.y)
        trySnap(a.x - sourcePoint.x, a.y - sourcePoint.y)
      }
    }
    // Align edges when they overlap but no vertex is near the opposing edge.
    for (let i = 0; i < vertices.length; i++) {
      const a = vertices[i], b = vertices[(i + 1) % vertices.length]
      for (let j = 0; j < target.vertices.length; j++) {
        const c = target.vertices[j], d = target.vertices[(j + 1) % target.vertices.length]
        const sourceVertical = Math.abs(a.x - b.x) < EPS
        const targetVertical = Math.abs(c.x - d.x) < EPS
        if (sourceVertical && targetVertical && Math.max(Math.min(a.y, b.y), Math.min(c.y, d.y)) <= Math.min(Math.max(a.y, b.y), Math.max(c.y, d.y)) + EPS) {
          trySnap(c.x - a.x, 0)
        }
        const sourceHorizontal = Math.abs(a.y - b.y) < EPS
        const targetHorizontal = Math.abs(c.y - d.y) < EPS
        if (sourceHorizontal && targetHorizontal && Math.max(Math.min(a.x, b.x), Math.min(c.x, d.x)) <= Math.min(Math.max(a.x, b.x), Math.max(c.x, d.x)) + EPS) {
          trySnap(0, c.y - a.y)
        }
      }
    }
  }
  if (score === LIMIT) return vertices
  return vertices.map(p => ({ x: r3(p.x + bestDx), y: r3(p.y + bestDy) }))
}
STROM143B_SNAP_TS
cat > "$WORK_DIR/patch143b.py" <<'STROM143B_PATCH_PY'
from pathlib import Path
import os,re
root=Path(os.environ['STROM143B_ROOT'])
module=Path(os.environ['STROM143B_MODULE'])
a=root/'frontend/src/App.tsx'
c=root/'frontend/src/components/Building3DWorkspace.tsx'
m=root/'frontend/src/building/neighborSnap143.ts'
css=root/'frontend/src/styles.css'
for p in (a,c,m,css,root/'frontend/src/building/stairVisibility143.ts'):
    if not p.is_file(): raise RuntimeError('143b missing 143a source: '+str(p))
s=a.read_text('utf8'); scene=c.read_text('utf8'); styles=css.read_text('utf8')
if 'STROM143_CROSS_LEVEL_SNAP' not in s or 'STROM143_STAIRS_FIX' not in scene:
    raise RuntimeError('143b requires Update 143a in current Stage. Check deployment first; no changes made.')
if 'STROM143B_DIRECT_GHOST' in s or 'STROM143B_STAIR_AUDIT' in scene:
    raise RuntimeError('143b already installed; abort to avoid duplicate modifications.')

def one(text,old,new,label):
    n=text.count(old)
    if n != 1: raise RuntimeError(f'143b {label}: expected one match, found {n}')
    return text.replace(old,new,1)

# Only the Blueprint editor may be changed, never the classic wall editor.
start=s.index('function FloorplanEditor(')
end=s.index('type StairEditorElementKind',start)
e=s[start:end]

# State persists independently by floor. The existing normal/same-level snap switch is not touched.
e=one(e,"  const [snapVisibleNeighbors143, setSnapVisibleNeighbors143] = useState<boolean>(() => safeReadJson<boolean>(layerStorageKey(floor.id, 'snapVisibleNeighbors143'), false))",
      "  // STROM143B_DIRECT_GHOST: independent toggle; direct geometry only, zero clearance.\n  const [snapVisibleNeighbors143, setSnapVisibleNeighbors143] = useState<boolean>(() => safeReadJson<boolean>(layerStorageKey(floor.id, 'snapVisibleNeighbors143'), false))",'toggle state')
e=one(e,"    setLayersOpen(false)\n  }, [floor.id])", "    setLayersOpen(false)\n    setSnapVisibleNeighbors143(safeReadJson<boolean>(layerStorageKey(floor.id, 'snapVisibleNeighbors143'), false))\n  }, [floor.id])",'reset toggle when floor changes')

# Do not ever mix ghost targets with ordinary same-floor snapping (which uses wall clearance).
e=one(e,'    return [...ownLayer, ...visibleNeighborSnapTargets143(excludeIds)]','    return ownLayer', 'separate normal room targets from visible ghost targets')
e=one(e,'    return snapPointToVisibleRooms143(point, targets, snapWallThicknessM)', '    return snapPointToVisibleRooms143(point, visibleNeighborSnapTargets143(), 0)', 'point snap uses ghost only') if '    return snapPointToVisibleRooms143(point, targets, snapWallThicknessM)' in e else e
# 143a emits the following exact function; guard both supported spellings.
if 'return snapPointToVisibleRooms143(point, allSnapTargets143(), snapWallThicknessM)' in e:
    e=one(e,'return snapPointToVisibleRooms143(point, allSnapTargets143(), snapWallThicknessM)', 'return snapPointToVisibleRooms143(point, visibleNeighborSnapTargets143(), 0)', 'point snap direct')
if 'return snapPointToVisibleRooms143(point, visibleNeighborSnapTargets143(), 0)' not in e:
    raise RuntimeError('143b pointSnap143 location not recognized')

# Replace checkbox/label by clearly visible button with the same approved icon ID.
old_ui='''          <label className="snap-control strom-neighbor-snap143" title="An sichtbaren Nachbarebenen einrasten (Ein/Aus)" data-tooltip="Snapping an sichtbaren Nachbarebenen" aria-label="Snapping an sichtbaren Nachbarebenen aktivieren oder deaktivieren">
            <input type="checkbox" checked={snapVisibleNeighbors143} onChange={(event) => setSnapVisibleNeighbors143(event.target.checked)} />
            <StromIcon name="layers-neighbor" title="Einrasten an sichtbaren Nachbarebenen" />
            <span>Nachbarebenen</span>
          </label>'''
new_ui='''          <button type="button" className={`strom-neighbor-snap143 ${snapVisibleNeighbors143 ? 'active' : ''}`}
            aria-pressed={snapVisibleNeighbors143}
            aria-label="Ebenen-Snap: direkt an sichtbaren Nachbarebenen einrasten"
            title="Ebenen-Snap: Eckpunkt an Eckpunkt, Kante an Kante. Abstand 0 mm. Benoetigt sichtbare Nachbarebene und normales Snapping."
            data-tooltip="Ebenen-Snap: Kante/Kante, Punkt/Punkt, 0 mm"
            onClick={() => setSnapVisibleNeighbors143((enabled) => !enabled)}>
            <StromIcon name="layers-neighbor" size={20} />
            <span>Ebenen-Snap {snapVisibleNeighbors143 ? 'AN' : 'AUS'}</span>
          </button>'''
e=one(e,old_ui,new_ui,'visible SVG toggle in toolbar')

# Room drag: same-floor snap already runs; afterwards apply 0-clearance ghost alignment.
old='''      setRoomPreview({ roomId: roomDrag.roomId, vertices: nextVertices })'''
new='''      if (snapEnabled && snapVisibleNeighbors143) {
        nextVertices = snapMovedVerticesToVisibleRooms143(nextVertices, visibleNeighborSnapTargets143([roomDrag.roomId]), drag.axis)
      }
      setRoomPreview({ roomId: roomDrag.roomId, vertices: nextVertices })'''
e=one(e,old,new,'room translation direct to ghost')

# Rectangle resize may snap to own layer as before, then to ghost with no wall offset.
old='''      if (snapEnabled) {
        if (snapVisibleNeighbors143) {
          nextVertices = snapRectangleHandle143(nextVertices, rectHandleDrag.handle, allSnapTargets143([rectHandleDrag.roomId]), snapWallThicknessM)
        } else {
          nextVertices = snapVerticesToRooms(nextVertices, allSnapTargets143([rectHandleDrag.roomId]), snapWallThicknessM, null)
        }
      }'''
new='''      if (snapEnabled) {
        // Preserve normal same-level snapping with its user-configured W.
        nextVertices = snapVerticesToRooms(nextVertices, allSnapTargets143([rectHandleDrag.roomId]), snapWallThicknessM, null)
        if (snapVisibleNeighbors143) {
          // Only align the moving edge to the ghost edge; 0 mm, opposite side fixed.
          nextVertices = snapRectangleHandle143(nextVertices, rectHandleDrag.handle, visibleNeighborSnapTargets143([rectHandleDrag.roomId]), 0)
        }
      }'''
e=one(e,old,new,'rectangle drag direct to ghost')

# Group drag: existing 143a code wrongly used ordinary wall-distance snapping with ghost targets.
old='''        const aligned = snapVerticesToRooms(vertices, allSnapTargets143(groupIds), snapWallThicknessM, drag.axis)'''
new='''        const aligned = snapMovedVerticesToVisibleRooms143(vertices, visibleNeighborSnapTargets143(groupIds), drag.axis)'''
e=one(e,old,new,'group drag no clearance')

# Polygon edge and vertex: visible ghosts only; do not expose ordinary same-level 0-clearance logic.
e=one(e,'snapPointToVisibleRooms143(before, allSnapTargets143([polygonEdgeDrag.roomId]), snapWallThicknessM)',
      'snapPointToVisibleRooms143(before, visibleNeighborSnapTargets143([polygonEdgeDrag.roomId]), 0)','polygon edge direct')
e=one(e,'snapPointToVisibleRooms143(point, allSnapTargets143([vertexDrag.roomId]), snapWallThicknessM)',
      'snapPointToVisibleRooms143(point, visibleNeighborSnapTargets143([vertexDrag.roomId]), 0)','polygon vertex direct')

# SVG approved icon, not emoji/font, permanently visible. Local help explains interaction.
e=one(e, '      <div className="canvas-statusbar">{hintText}</div>', '''      <div className="canvas-statusbar">{hintText}{snapVisibleNeighbors143 && (
        <span className="strom-ghost-snap-hint143b" title="Nur sichtbare Nachbarebenen; kein Wandabstand"> · Ebenen-Snap aktiv: Punkt/Punkt, Kante/Kante, 0 mm Abstand</span>
      )}</div>''', 'visible guidance')
s=s[:start]+e+s[end:]
s=one(s,"import { snapPointToVisibleRooms143, snapRectangleHandle143 } from './building/neighborSnap143'", "import { snapPointToVisibleRooms143, snapRectangleHandle143, snapMovedVerticesToVisibleRooms143 } from './building/neighborSnap143'",'new snapping algorithm import')

# If a previous migration missed inserting the actual meshes, put them in the scene.
# Where they are already rendered, do not change their location/shape.
if '<StairSolid' not in scene:
    render='''        {/* STROM143B_STAIR_RENDER: actual geometry, not just a status count. */}
        {stairs.map((surface) => (
          <StairSolid key={surface.key} surface={surface}
            selected={surface.roomId === selectedRoomId}
            onSelect={() => { onSelectRoom(surface.roomId); onSelectDoor('') }} />
        ))}
'''
    if '        <SolidWallMeshes' in scene:
        scene=one(scene,'        <SolidWallMeshes',render+'        <SolidWallMeshes','add stair meshes before solid walls')
    elif '        {model.walls.flatMap((wall) => wall.openings' in scene:
        scene=one(scene,'        {model.walls.flatMap((wall) => wall.openings',render+'        {model.walls.flatMap((wall) => wall.openings','add meshes to simplified scene')
    else:
        raise RuntimeError('143b could not locate scene mesh insertion point')
if '<StairSolid' not in scene:
    raise RuntimeError('143b: 3D scene still does not render stairs')

# Make the existing count useful when older layouts are missing in the current browser.
status='''{stairData143.savedLayouts} gespeicherten Treppenlayouts ({stairData143.activeLayouts} auf aktiver Ebene)'''
if status not in scene: raise RuntimeError('143b: stairs diagnostic status missing')
scene=one(scene,status,status+'''{stairData143.savedLayouts === 0 ? ' · Hinweis: keine Treppenlayouts im Browser-Speicher gefunden' : ''}''','indicate missing staircase storage')
scene=scene.replace('// STROM143_STAIRS_FIX:', '// STROM143B_STAIR_AUDIT: StairSolid is rendered and storage availability is displayed.\n// STROM143_STAIRS_FIX:',1)

# Restore exact CSS contract for button, no text/glyph fallback.
styles+='''
/* STROM143B: discoverable SVG switch for direct ghost-layer snapping. */
.floorplan-layout .canvas-toolbox button.strom-neighbor-snap143 {
  display: inline-flex !important; align-items: center; justify-content: center; gap: 5px;
  width: auto !important; min-width: 146px; padding: 0 10px !important;
  border: 1px solid #93b3df; border-radius: 16px; white-space: nowrap;
  font-size: 12px; font-weight: 700; color: #1e3a8a;
}
.floorplan-layout .canvas-toolbox button.strom-neighbor-snap143.active { background: #2563eb; border-color: #2563eb; color: white; }
.floorplan-layout .canvas-toolbox button.strom-neighbor-snap143 .strom-ui-icon { flex: 0 0 20px; }
.floorplan-layout .strom-ghost-snap-hint143b { color: #1d4ed8; font-weight: 700; }
'''
# Atomicity inside working copy is handled by stage script; no database writes.
a.write_text(s,'utf8'); c.write_text(scene,'utf8'); css.write_text(styles,'utf8')
m.write_text(module.read_text('utf8'),'utf8')
print('143b: mapped 3D StairSolid meshes, zero-clearance ghost snapping, explicit v7 toggle and status hint. Existing walls, 3D geometry and API unchanged.')
STROM143B_PATCH_PY
[ -s "$WORK_DIR/neighborSnap143b.ts" ] || fail "143b Hilfsmodul fehlt."
[ -s "$WORK_DIR/patch143b.py" ] || fail "143b Patch fehlt."
STROM143B_ROOT="$WORK_DIR" STROM143B_MODULE="$WORK_DIR/neighborSnap143b.ts" \
  python3 "$WORK_DIR/patch143b.py" >>"$DIAG_LOG" 2>&1 || fail "143b-Quellpatch fehlgeschlagen; kein Git-Push/Stage-Deployment."
rm -f "$WORK_DIR/neighborSnap143b.ts" "$WORK_DIR/patch143b.py"

cat > "$WORK_DIR/docs/BLUEPRINT_3D_UPDATE_143B.md" <<'STROM143B_DOC'
# STROM Update 143b - direct ghost layer snapping and stair visualization

- The 3D workspace must actually mount `StairSolid` meshes inside the 3D scene.
- The existing status display reports stored staircase layouts. Zero layouts means this browser's localStorage has no recognized room-keyed staircase layout; reloading the page cannot create layouts.
- The Blueprint toolbar has a visible SVG-v7 button `Ebenen-Snap AUS/AN` with a tooltip.
- Cross-level snapping uses *only* visible ghost-level polygon vertices/edges; a snapped edge touches the target with a 0 mm clearance.
- A normal/same-level snap remains separate and may still use the W wall offset.
- The ghost snapping operates only while both main snapping and cross-level snapping are enabled.
- No backend/database schema changes; no geometry migration; no production promotion.
STROM143B_DOC

for file in \
  frontend/src/building/model.ts \
  frontend/src/building/solidGeometry.ts \
  frontend/src/building/wallHitSelection.ts \
  frontend/src/building/wallHoverGeometry.ts \
  frontend/src/building/stair3d.ts \
  frontend/src/building/stairVisibility143.ts \
  frontend/src/building/blueprintLevels.ts \
  frontend/src/api.ts \
  frontend/src/types.ts; do
  cmp -s "$STAGE_DIR/$file" "$WORK_DIR/$file" || fail "143b hat unzulaessig $file geaendert."
done

log "4) Vollstaendigen TypeScript-/Vite-Build pruefen ..."
( cd "$WORK_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 \
  || fail "Build fehlgeschlagen. Kein Git-Push oder Deployment."

log "4.1) Ausfuehrbare Snapping-Regressionspruefung und Rendering-Checks ..."
export STROM143B_ROOT="$WORK_DIR"
export STROM143B_TYPESCRIPT="$DEPENDENCIES/typescript"
node <<'STROM143B_TEST_JS' >>"$DIAG_LOG" 2>&1 || fail "143b Funktionstests fehlgeschlagen. Kein Git-Push oder Deployment."
'use strict'
const fs=require('fs'), ts=require(process.env.STROM143B_TYPESCRIPT)
const root=process.env.STROM143B_ROOT
const path=root+'/frontend/src/building/neighborSnap143.ts'
const compiled=ts.transpileModule(fs.readFileSync(path,'utf8'), {fileName:path,reportDiagnostics:true,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}})
if (compiled.diagnostics?.some(d=>d.category===ts.DiagnosticCategory.Error)) throw Error('TypeScript snapping syntax invalid')
const mod={exports:{}}
new Function('module','exports','require',compiled.outputText)(mod,mod.exports,()=>({}))
const snap=mod.exports
function same(a,b,message){if(JSON.stringify(a)!==JSON.stringify(b)) throw Error(message+': '+JSON.stringify(a)+' expected '+JSON.stringify(b))}
const ghost=[{vertices:[{x:2,y:1},{x:4,y:1},{x:4,y:3},{x:2,y:3}]}]
for(const wallM of [0,0.12,0.3,0.5]) {
  same(snap.snapPointToVisibleRooms143({x:1.89,y:2.05},ghost,wallM),{x:2,y:2.05},'ghost wall offset leaked into point snap')
  const rect=[{x:1,y:1},{x:1.89,y:1},{x:1.89,y:2},{x:1,y:2}]
  const result=snap.snapRectangleHandle143(rect,'right',ghost,wallM)
  if(result[0].x!==1||result[1].x!==2||result[2].x!==2) throw Error('ghost resize moved fixed side or applied wall offset')
}
const rect=[{x:1,y:1},{x:1.89,y:1},{x:1.89,y:2},{x:1,y:2}]
const moved=snap.snapMovedVerticesToVisibleRooms143(rect,ghost,null)
if(moved[1].x!==2 || moved[0].x!==1.11) throw Error('ghost room move failed direct alignment')
same(snap.snapPointToVisibleRooms143({x:1.89,y:2.05},[],0.12),{x:1.89,y:2.05},'hidden ghost altered point')
const angled=snap.snapPointToVisibleRooms143({x:1.04,y:1.11},[{vertices:[{x:0,y:0},{x:2,y:2},{x:0,y:2}]}],0.2)
if(Math.abs(angled.x-angled.y)>0.002) throw Error('diagonal ghost wall did not align')
const app=fs.readFileSync(root+'/frontend/src/App.tsx','utf8')
const scene=fs.readFileSync(root+'/frontend/src/components/Building3DWorkspace.tsx','utf8')
const icon=fs.readFileSync(root+'/frontend/public/strom-icons-v7.svg','utf8')
if(!app.includes('Ebenen-Snap {snapVisibleNeighbors143') || !app.includes('aria-pressed={snapVisibleNeighbors143}')) throw Error('explicit toggle not mounted')
if(!scene.includes('<StairSolid') || !scene.includes('stairs.map((surface)')) throw Error('StairSolid not actually rendered')
if(!icon.includes('id="layers-neighbor"')) throw Error('SVG symbol unavailable')
console.log('PASS: direct 0 mm ghost alignment independent of wall offset, invisible ghosts, angled edges, true 3D stair meshes and SVG toggle.')
STROM143B_TEST_JS

log "4.2) Kontrolle: SVG-Schalter sichtbar, Ghost-Snap ohne Wandabstand, Treppen-Meshes gemountet."
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
log "Update 143b in Stage erfolgreich. Test: https://home.moja.de/strom-test/"
log "  - Wanddetail/3D Haus: Echte Treppen-Meshes und Browser-Speicher-Diagnose."
log "  - Blueprint: Ebenen-Snap EIN/AUS (Design-v7-SVG), direkt 0 mm Kante/Kante oder Punkt/Punkt."
log "  - Blueprint: Ebene je eigener Hoehe (mm), Ebenenmodi und Ghost-Sichtbarkeit."
log "  - 3D zeigt nur die aktive Blueprint-Ebene mit ihrer Geschosshoehe."
log "  - Historische Layer-IDs, Raumzuordnungen und Treppenlayouts bleiben erhalten."
log "  - Produktion bleibt unveraendert."
log "Backup: $BACKUP_DIR"
