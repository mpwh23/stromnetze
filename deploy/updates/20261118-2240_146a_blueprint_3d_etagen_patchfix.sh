#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-2240_146a_blueprint_3d_etagen_patchfix"
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
COMMIT_MESSAGE="Update 146a: fix scene controls patch boundary; blueprint zoom, icon library, 3D levels and edge snapping"
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
  echo "2) Update 146a im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 146a isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 146a / Blueprint, 3D Haus, Wanddetail, Kanten-Snapping (Patchfix) ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
log "Bestehende Gebaeude-/Datenbankgeometrie, Tueren, Treppen und Produktion bleiben unveraendert."
for required in \
  frontend/src/App.tsx \
  frontend/src/styles.css \
  frontend/src/components/StromIcon.tsx \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/building/wallSurface145.ts \
  frontend/src/building/neighborSnap143.ts \
  frontend/src/building/solidGeometry.ts \
  frontend/src/building/blueprintLevels.ts \
  frontend/src/building/stair3d.ts \
  frontend/public/strom-icons-v7.svg; do
  [ -f "$STAGE_DIR/$required" ] || fail "Update 146 benoetigt Stage 145: $required fehlt."
done
for marker in STROM145_FLOATING_LEVELS STROM143B_STAIR_AUDIT STROM141_WALL_HOVER; do
  grep -q "$marker" "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "Update 146: Stage hat Marker $marker nicht (145 zuerst deployen)."
done
grep -q 'STROM144_BLUEPRINT_DOOR_LEVEL' "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 146: Tueren-Ebenenfilter aus 144a fehlt."
select_node

log "1) Stage-Sicherung erstellen ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolierte Git-Arbeitskopie, kein Backup noetig."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage-Sicherung fehlgeschlagen."
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


log "3) Blueprint 1000%, v7-Bibliothek, Frontalansicht und echte 3D-Mehr-Etagen-Darstellung integrieren ..."
cat > "$WORK_DIR/.strom146_edgeSnap.ts" <<'STROM146_EDGE_TS'
import type { PointM } from '../types'

/** STROM146_EDGE_SNAP: direct topology alignment, never wall thickness offset. */
export type SnapTarget146 = { vertices: PointM[] }
export type EdgeSnapResult146 = { vertices: PointM[]; point: PointM | null; label: string }
type RectEdge146 = 'left' | 'right' | 'top' | 'bottom'
const round = (n: number) => Math.round(n * 1000) / 1000
const distance = (a: PointM, b: PointM) => Math.hypot(a.x - b.x, a.y - b.y)
const dot = (a: PointM, b: PointM) => a.x * b.x + a.y * b.y
const subtract = (a: PointM, b: PointM): PointM => ({ x: a.x - b.x, y: a.y - b.y })

function segmentProjection146(point: PointM, start: PointM, end: PointM): PointM {
  const ab = subtract(end, start)
  const size = dot(ab, ab)
  if (size < 1e-12) return start
  const t = Math.max(0, Math.min(1, dot(subtract(point, start), ab) / size))
  return { x: start.x + t * ab.x, y: start.y + t * ab.y }
}

/** Preserve the Shift-key direction even when a snap candidate is considered. */
function lockedShift146(dx: number, dy: number, referenceDx: number, referenceDy: number): PointM {
  const angle = Math.atan2(referenceDy, referenceDx)
  const step = Math.PI / 4
  const locked = Math.round(angle / step) * step
  const axis = { x: Math.cos(locked), y: Math.sin(locked) }
  const length = dx * axis.x + dy * axis.y
  return { x: axis.x * length, y: axis.y * length }
}

/** Translate BOTH ends by the same delta so moving an edge cannot shear it.
 * The shift flag restricts the complete translation, not only the final snap correction.
 * A snap is reported only when the resulting point really lies on the target.
 */
export function snapTranslatedEdge146(
  original: PointM[], indexA: number, indexB: number,
  rawDx: number, rawDy: number, targets: SnapTarget146[], thresholdM: number, shift: boolean,
): EdgeSnapResult146 {
  if (!original[indexA] || !original[indexB]) return { vertices: original, point: null, label: '' }
  const tolerance = Math.max(0.002, Math.min(0.3, thresholdM))
  const move = shift ? lockedShift146(rawDx, rawDy, rawDx, rawDy) : { x: rawDx, y: rawDy }
  const proposed = (p: PointM): PointM => ({ x: p.x + move.x, y: p.y + move.y })
  const moving = [indexA, indexB]
  let best: { dx: number; dy: number; point: PointM; label: string; dist: number } | null = null
  for (const target of targets) {
    if (!Array.isArray(target.vertices) || target.vertices.length < 2) continue
    for (const movingIndex of moving) {
      const sourcePoint = proposed(original[movingIndex])
      for (let i = 0; i < target.vertices.length; i++) {
        const a = target.vertices[i]
        const b = target.vertices[(i + 1) % target.vertices.length]
        const candidates: Array<{ point: PointM; label: string }> = [
          { point: a, label: 'Eckpunkt' },
          { point: segmentProjection146(sourcePoint, a, b), label: 'Kante' },
        ]
        for (const candidate of candidates) {
          const correction = subtract(candidate.point, sourcePoint)
          const translated = shift
            ? lockedShift146(move.x + correction.x, move.y + correction.y, rawDx, rawDy)
            : { x: move.x + correction.x, y: move.y + correction.y }
          const resulting = { x: original[movingIndex].x + translated.x, y: original[movingIndex].y + translated.y }
          const afterDistance = distance(resulting, candidate.point)
          const movedDistance = Math.hypot(translated.x - move.x, translated.y - move.y)
          if (afterDistance > Math.max(0.001, tolerance * 0.05) || movedDistance > tolerance) continue
          if (!best || movedDistance < best.dist - 1e-7 || (Math.abs(movedDistance - best.dist) < 1e-7 && candidate.label === 'Eckpunkt')) {
            best = { dx: translated.x, dy: translated.y, point: candidate.point, label: candidate.label, dist: movedDistance }
          }
        }
      }
    }
  }
  const currentMove: PointM = best ? { x: best.dx, y: best.dy } : move
  const vertices = original.map((p, i) => moving.includes(i)
    ? { x: round(p.x + currentMove.x), y: round(p.y + currentMove.y) }
    : p)
  return { vertices, point: best?.point ?? null, label: best ? `${best.label} · 0 mm` : '' }
}

/** Only the dragged side of an axis-aligned rectangular room is adjusted.
 * Opposite side and remaining dimensions are preserved. No clearance added.
 */
export function snapRectEdge146(
  vertices: PointM[], handle: RectEdge146, targets: SnapTarget146[], thresholdM: number,
): EdgeSnapResult146 {
  if (vertices.length < 4) return { vertices, point: null, label: '' }
  const vertical = handle === 'left' || handle === 'right'
  const xs = vertices.map((p) => p.x), ys = vertices.map((p) => p.y)
  const current = handle === 'left' ? Math.min(...xs) : handle === 'right' ? Math.max(...xs)
    : handle === 'top' ? Math.min(...ys) : Math.max(...ys)
  const moving = vertices.filter((p) => Math.abs((vertical ? p.x : p.y) - current) < 0.0005)
  if (moving.length < 2) return { vertices, point: null, label: '' }
  const low = Math.min(...moving.map((p) => vertical ? p.y : p.x))
  const high = Math.max(...moving.map((p) => vertical ? p.y : p.x))
  let best: { value: number; point: PointM; dist: number } | null = null
  const tolerance = Math.max(0.002, Math.min(0.3, thresholdM))
  for (const target of targets) {
    const points = target.vertices
    if (!Array.isArray(points) || points.length < 2) continue
    for (let i = 0; i < points.length; i++) {
      const a = points[i], b = points[(i + 1) % points.length]
      const tA = vertical ? a.y : a.x, tB = vertical ? b.y : b.x
      if (Math.min(tA, tB) > high + tolerance || Math.max(tA, tB) < low - tolerance) continue
      const uA = vertical ? a.x : a.y, uB = vertical ? b.x : b.y
      // Only align to parallel segments; do not pull a rectangular edge onto a diagonal.
      if (Math.abs(uB - uA) > 0.001) continue
      const candidate = (uA + uB) / 2
      const delta = Math.abs(candidate - current)
      if (delta > tolerance || (best && delta >= best.dist)) continue
      best = { value: candidate, dist: delta, point: vertical
        ? { x: candidate, y: Math.max(low, Math.min(high, (tA + tB) / 2)) }
        : { x: Math.max(low, Math.min(high, (tA + tB) / 2)), y: candidate } }
    }
  }
  if (!best) return { vertices, point: null, label: '' }
  const next = vertices.map((point) => Math.abs((vertical ? point.x : point.y) - current) < 0.0005
    ? (vertical ? { ...point, x: round(best!.value) } : { ...point, y: round(best!.value) }) : point)
  const span = vertical ? Math.max(...next.map((p) => p.x)) - Math.min(...next.map((p) => p.x))
    : Math.max(...next.map((p) => p.y)) - Math.min(...next.map((p) => p.y))
  if (span < 0.05) return { vertices, point: null, label: '' }
  return { vertices: next, point: best.point, label: 'Kante · 0 mm' }
}

STROM146_EDGE_TS
cat > "$WORK_DIR/.strom146_patch.py" <<'STROM146_PATCH_PY'
from pathlib import Path
import os, re

root=Path(os.environ['STROM146_ROOT'])
app=root/'frontend/src/App.tsx'
scene=root/'frontend/src/components/Building3DWorkspace.tsx'
css=root/'frontend/src/styles.css'
snap_src=Path(os.environ['STROM146_SNAP_MODULE'])
snap_dst=root/'frontend/src/building/edgeSnap146.ts'
for p in (app, scene, css, root/'frontend/src/building/blueprintLevels.ts', root/'frontend/src/building/solidGeometry.ts',root/'frontend/src/components/StromIcon.tsx',snap_src):
    if not p.is_file(): raise RuntimeError(f'146 required source file missing: {p}')
a=app.read_text('utf8')
s=scene.read_text('utf8')
style=css.read_text('utf8')
if 'STROM146_ZOOM' in a or 'STROM146_ALL_LEVELS' in s or snap_dst.exists():
    raise RuntimeError('146 already applied; abort to avoid duplicate code')
for marker in ('function FloorplanEditor(', 'function WallFrontPlacedObject(', 'function WallObjectLibraryFloating(', 'STROM144_BLUEPRINT_DOOR_LEVEL', 'snapVisibleNeighbors143'):
    if marker not in a: raise RuntimeError(f'146 requires deployed 143b+144a Blueprint; missing {marker}')
for marker in ('STROM145_FLOATING_LEVELS','STROM141_WALL_HOVER','STROM143B_STAIR_AUDIT','function RealBuildingScene(', 'PlacedStairSurface143', 'function SolidWallMeshes('):
    if marker not in s: raise RuntimeError(f'146 requires deployed 145 scene; missing {marker}')

def one(t, old, new, label):
    n=t.count(old)
    if n!=1: raise RuntimeError(f'146 {label}: expected one anchor, found {n}')
    return t.replace(old,new,1)

def block(t, begin, end):
    st=t.index(begin)
    en=t.index(end,st)
    return st,en,t[st:en]

# 1) Only BLUEPRINT zoom, not independent stair-editor zoom or physical height.
start,end,zoom=a[a.index('function loadCanvasViewport('):a.index('function normalizeDegrees(')].count('0.22, 2.5'),None,None
if start<2: raise RuntimeError('146 zoom viewport clamp changed unexpectedly')
p0,p1,viewport=block(a,'function loadCanvasViewport(', 'function normalizeDegrees(')
viewport=viewport.replace('0.22, 2.5','0.22, 10')
viewport=viewport.replace('function loadCanvasViewport(', '/* STROM146_ZOOM: Blueprint 22%-1000%; viewport persisted without truncation. */\nfunction loadCanvasViewport(',1)
a=a[:p0]+viewport+a[p1:]
# Avoid silently truncating 1000% to 250% when returning from Wanddetail.
a=one(a,
  'zoom: Math.min(2.5, Math.max(0.22, round2(storedViewport.zoom * 1.1)))',
  'zoom: Math.min(10, Math.max(0.22, round2(storedViewport.zoom * 1.1)))',
  'preserve blueprint zoom across switching views')
p0,p1,editor=block(a, 'function FloorplanEditor(', 'type StairEditorElementKind')
# Zoom conversions are intentionally limited to the editor area.
zoom_before=len(re.findall(r'Math\.min\(2\.5',editor))
if zoom_before<3: raise RuntimeError(f'146 expected 3+ Blueprint zoom clamps, found {zoom_before}')
editor=editor.replace('Math.min(2.5','Math.min(10')
editor=re.sub(r'(const fitZoom\s*=\s*Math\.min\(\s*)2\.5(\s*,\s*Math\.max\(0\.22)',r'\g<1>10\g<2>',editor)
# Change 1000% should work in both wheel zoom and zoom buttons. Preserve 1:1.

# 2) A moved rectangle side gets exact, zero-distance snap (no normal W clearance).
# Polygon edge uses original geometry plus equal translation at both endpoints.
editor=one(editor,
  "  const [polygonEdgeDrag, setPolygonEdgeDrag] = useState<PolygonEdgeDrag | null>(null)",
  "  const [polygonEdgeDrag, setPolygonEdgeDrag] = useState<PolygonEdgeDrag | null>(null)\n  const [edgeSnapHint146, setEdgeSnapHint146] = useState<{ point: PointM; label: string } | null>(null)",
  'edge-snap hint state')
# Note the `if (rectHandleDrag)` branch is unique INSIDE mousemove but also appears in mouseup.
p0=editor.index('  function handleMouseMove(')
p1=editor.index('  function startRoomDrag(',p0)
mouse=editor[p0:p1]
rect_anchor='    if (rectHandleDrag) {'
poly_anchor='    if (polygonEdgeDrag) {'
if mouse.count(rect_anchor)!=1 or mouse.count(poly_anchor)!=1: raise RuntimeError('146 drag branch anchors missing/duplicated')
rs=mouse.index(rect_anchor); ps=mouse.index(poly_anchor,rs); vs=mouse.index('    if (vertexDrag) {',ps)
rect_branch='''    if (rectHandleDrag) {
      // STROM146_EDGE_SNAP: only the moving rectangle edge is moved; 0 mm gap.
      let nextVertices = resizeRectangleByHandle(rectHandleDrag.originalVertices, rectHandleDrag.handle, point)
      if (snapEnabled) {
        const sameFloor146 = rooms.filter((item) => item.id !== rectHandleDrag.roomId &&
          (roomLayerAssignments[item.id] ?? defaultLayerId) === activeLayerId).map((item) => ({ vertices: item.vertices }))
        const ghost146 = snapVisibleNeighbors143 ? visibleNeighborSnapTargets143([rectHandleDrag.roomId]) : []
        const aligned146 = snapRectEdge146(nextVertices, rectHandleDrag.handle,
          [...sameFloor146, ...ghost146], 12 / Math.max(0.1, canvas.scale * zoom))
        nextVertices = aligned146.vertices
        setEdgeSnapHint146(aligned146.point ? { point: aligned146.point, label: aligned146.label } : null)
      } else { setEdgeSnapHint146(null) }
      setRoomPreview({ roomId: rectHandleDrag.roomId, vertices: nextVertices })
      return
    }

'''
poly_branch='''    if (polygonEdgeDrag) {
      // Shift => x/y/45 degree. Both endpoints share an identical translation.
      const rawDx = round2(point.x - polygonEdgeDrag.start.x)
      const rawDy = round2(point.y - polygonEdgeDrag.start.y)
      const moved146 = event.shiftKey ? constrainDeltaTo45(rawDx, rawDy) : { dx: rawDx, dy: rawDy }
      const sameFloor146 = snapEnabled ? rooms.filter((item) => item.id !== polygonEdgeDrag.roomId &&
        (roomLayerAssignments[item.id] ?? defaultLayerId) === activeLayerId).map((item) => ({ vertices: item.vertices })) : []
      const ghost146 = snapEnabled && snapVisibleNeighbors143 ? visibleNeighborSnapTargets143([polygonEdgeDrag.roomId]) : []
      const result146 = snapTranslatedEdge146(
        polygonEdgeDrag.originalVertices, polygonEdgeDrag.indexA, polygonEdgeDrag.indexB,
        moved146.dx, moved146.dy, [...sameFloor146, ...ghost146],
        12 / Math.max(0.1, canvas.scale * zoom), Boolean(event.shiftKey),
      )
      setEdgeSnapHint146(result146.point ? { point: result146.point, label: result146.label } : null)
      setRoomPreview({ roomId: polygonEdgeDrag.roomId, vertices: result146.vertices })
      return
    }

'''
mouse=mouse[:rs]+rect_branch+poly_branch+mouse[vs:]
editor=editor[:p0]+mouse+editor[p1:]
editor=one(editor,'  async function handleMouseUp() {','  async function handleMouseUp() {\n    setEdgeSnapHint146(null)','clear guide when drag finishes')
# Prevent stale snap marker as user begins a new edge drag.
editor=one(editor, "    setPolygonEdgeDrag({ roomId: room.id, indexA: index, indexB: nextIndex, start: point, originalVertices: room.vertices })",
    "    setEdgeSnapHint146(null)\n    setPolygonEdgeDrag({ roomId: room.id, indexA: index, indexB: nextIndex, start: point, originalVertices: room.vertices })",
    'reset snap guide at polygon edge drag start')
# Overlay lives in the main Blueprint SVG, not in the floating properties panel.
svg_end='''          </svg>
        </div>
        {stairPanelOpen'''
svg_add='''            {edgeSnapHint146 && (
              <g className="strom-edge-snap-indicator146" pointerEvents="none" aria-label="Einrastpunkt">
                <circle cx={mToX(edgeSnapHint146.point.x)} cy={mToY(edgeSnapHint146.point.y)} r={8 / zoom} strokeWidth={2 / zoom} />
                <text x={mToX(edgeSnapHint146.point.x) + 13 / zoom} y={mToY(edgeSnapHint146.point.y) - 13 / zoom} fontSize={12 / zoom}>{edgeSnapHint146.label}</text>
              </g>
            )}
          </svg>
        </div>
        {stairPanelOpen'''
editor=one(editor, svg_end, svg_add,'visible edge snap location')
editor=one(editor, '<div className="canvas-statusbar">{hintText}',
   '<div className="canvas-statusbar">{hintText} {edgeSnapHint146 && <span className="strom-edge-snap-status146">· Eingerastet: {edgeSnapHint146.label}</span>}',
   'edge snap explanation')
a=a[:a.index('function FloorplanEditor(')]+editor+a[a.index('type StairEditorElementKind'):]
# Append import beside current v143b snap module.
import_target="import { snapPointToVisibleRooms143, snapRectangleHandle143, snapMovedVerticesToVisibleRooms143 } from './building/neighborSnap143'"
a=one(a,import_target,import_target+"\nimport { snapRectEdge146, snapTranslatedEdge146 } from './building/edgeSnap146'",'edge module import')

# 3) More legible, consistent v7 icon library with hover quick info.
p0,p1,library=block(a,'function WallObjectLibraryFloating(', 'function isWallLibraryItemType(')
for kind, icon, german in [('door','door','Tür'),('window','window','Fenster'),('socket','electrical-socket','Steckdose')]:
    regex=rf'(<button type="button" draggable onDragStart=\{{\(event\) => startLibraryDrag\(event, \'{kind}\'\)\}})(><span>.*?</span>\s*{german}</button>)'
    repl=rf'\g<1> title="{german} auf die ausgewählte Wand ziehen" aria-label="{german} platzieren"><StromIcon name="{icon}" title="{german}" size={{22}} /> <span>{german}</span></button>'
    library,n=re.subn(regex,repl,library)
    if n!=1: raise RuntimeError(f'146 library icon {kind}: expected one original button, found {n}')
a=a[:p0]+library+a[p1:]

# 4) Front view = true ELEVATION. No architectural plan swing arc at bottom.
p0,p1,front=block(a,'function WallFrontPlacedObject(', 'function WallObjectLibraryFloating(')
needle=r"  if \(item\.type === 'door'\) \{.*?\n  \}\n  if \(item\.type === 'window'\) \{.*?\n  \}\n  return <g"
replacement='''  if (item.type === 'door') {
    const left = cx - w / 2, top = cy - h / 2
    const jamb = Math.max(2, Math.min(6, w * 0.055))
    return (
      <g className={`${className} wall-front-door146`} onMouseDown={(event) => onBeginDrag(event, item, 'move')}>
        <title>Tür – Frontansicht, ohne Grundriss-Schwenkbogen</title>
        <rect className="wall-front-door-frame146" x={left} y={top} width={w} height={h} rx={1.5} />
        <rect className="wall-front-door-leaf146" x={left + jamb} y={top + jamb} width={Math.max(2, w - 2 * jamb)} height={Math.max(2, h - jamb)} rx={1} />
        <line className="wall-front-door-jamb146" x1={left + jamb} y1={top + jamb} x2={left + jamb} y2={top + h} />
        <circle className="wall-front-door-handle146" cx={left + w * 0.78} cy={cy + h * 0.07} r={Math.max(1.5, Math.min(3.2, w * 0.035))} />
        {resizeHandle}{dimensions}
      </g>
    )
  }
  if (item.type === 'window') {
    const left = cx - w / 2, top = cy - h / 2
    const frame = Math.max(2, Math.min(7, Math.min(w, h) * 0.12))
    return (
      <g className={`${className} wall-front-window146`} onMouseDown={(event) => onBeginDrag(event, item, 'move')}>
        <title>Fenster – Rahmen mit Glas und Mittelsprosse</title>
        <rect className="wall-front-window-frame146" x={left} y={top} width={w} height={h} rx={1.5} />
        <rect className="wall-front-window-glass146" x={left + frame} y={top + frame} width={Math.max(2, w - 2 * frame)} height={Math.max(2, h - 2 * frame)} rx={0.6} />
        <line className="wall-front-window-mullion146" x1={cx} y1={top + frame} x2={cx} y2={top + h - frame} />
        {w > h * 1.3 && <line className="wall-front-window-transom146" x1={left + frame} y1={cy} x2={left + w - frame} y2={cy} />}
        <line className="wall-front-window-sill146" x1={left - 3} y1={top + h} x2={left + w + 3} y2={top + h} />
        {resizeHandle}{dimensions}
      </g>
    )
  }
  return <g'''
front,n=re.subn(needle,replacement,front,flags=re.S)
if n!=1: raise RuntimeError(f'146 door/window frontal rendering: expected one pair of branches, found {n}')
a=a[:p0]+front+a[p1:]

# Avoid disposing OrbitControls on any floor selection or display-mode change.
# Disposal belongs to the controls instance lifetime, not the model target effect.
# R3F camera controls have to survive changing a floor; only reset target/fit.
react_import=re.search(r"import \{([^}]+)\} from 'react'",s)
if not react_import: raise RuntimeError('146 React hooks import missing in 3D component')
if 'useRef' not in react_import.group(1):
    s=s[:react_import.start()]+react_import.group(0).replace('useState', 'useRef, useState')+s[react_import.end():]
# STROM146A_SCENE_CONTROL_BOUNDARY: StairSolid was inserted BEFORE
# SceneControls in Update 142. The NEXT top-level component is RealBuildingScene.
# Using StairSolid as an end marker raises ValueError before the actual build.
controls_start,controls_end,controls=block(s,'function SceneControls(', 'function RealBuildingScene(')
if controls.count('function SceneControls(') != 1 or 'function StairSolid(' in controls:
    raise RuntimeError('146a: unexpected SceneControls boundaries; no unsafe source rewrite')
if '  useFrame(() => controls.update())' not in controls:
    raise RuntimeError('146a: SceneControls code changed; refusing to patch unrelated component')
controls=one(controls,'  const controls = useMemo(() => new OrbitControls(camera, gl.domElement), [camera, gl.domElement])',
    '  const controls = useMemo(() => new OrbitControls(camera, gl.domElement), [camera, gl.domElement])\n  const fittedSpan146 = useRef<number | null>(null)',
    'remember camera fit without resetting controls')
controls=one(controls,
    '    controls.target.set(model.center.x, model.floorElevationM + model.floorHeightM / 2, model.center.y)',
    '''    const nextTarget146 = new THREE.Vector3(model.center.x, model.floorElevationM + model.floorHeightM / 2, model.center.y)
    const nextSpan146 = Math.max(model.spanM, model.floorHeightM * 1.6)
    if (fittedSpan146.current !== null) {
      // Preserve orbit orientation. If the total building gets taller, zoom out to frame it.
      const eye146 = camera.position.clone().sub(controls.target)
      if (eye146.lengthSq() < 0.001) eye146.set(1, .7, 1)
      if (nextSpan146 > fittedSpan146.current + 0.15) eye146.setLength(Math.max(eye146.length(), nextSpan146 * 2.0))
      camera.position.copy(nextTarget146).add(eye146)
    }
    controls.target.copy(nextTarget146)
    fittedSpan146.current = nextSpan146''',
    'camera reframe when switching between single and multi-level')
controls=one(controls,
    '    return () => controls.dispose()\n  }, [controls, model.floorId,',
    '  }, [controls, model.floorId,',
    'preserve OrbitControls through floor toggle')
controls=one(controls,'  useFrame(() => controls.update())',
    '  useEffect(() => () => controls.dispose(), [controls])\n  useFrame(() => controls.update())',
    'dispose controls only on unmount')
s=s[:controls_start]+controls+s[controls_end:]

# 5) Display-only whole-building view. Keep active layer and existing editor unchanged.
# The live scene uses PlacedStairSurface143 for staircase elevation. Import the
# shared builder for additional floors; don't regress to the old Stair3DSurface type.
scene_import143 = "import { build3DStairsAcrossLevels143, type PlacedStairSurface143 } from '../building/stairVisibility143'"
s=one(s,scene_import143,scene_import143+"\nimport { buildStair3DSurfaces } from '../building/stair3d'",'3d stair generator compatible with 143b')
# Actual models are still derived from the SAME Blueprint layer room assignments.
scene_type='''// STROM146_ALL_LEVELS: one Blueprint storage schema, multiple read-only 3D floor meshes.
type SceneLevel146 = { id: string; model: BuildingModel; stairs: PlacedStairSurface143[]; offsetM: number }

'''
s=one(s,'function RealBuildingScene(',scene_type+'function RealBuildingScene(','3d layer type')
p0,p1,real=block(s,'function RealBuildingScene(', 'function DoorForm(')
real=one(real,'function RealBuildingScene({ model, stairs, ',
    'function RealBuildingScene({ model, stairs, extraLevels146, activeOffsetM146, showAllLevels146, ',
    'new 3d scene render arguments')
real=one(real,'  stairs: PlacedStairSurface143[]\n','''  stairs: PlacedStairSurface143[]
  extraLevels146: SceneLevel146[]
  activeOffsetM146: number
  showAllLevels146: boolean
''', '3d scene render props')
real=one(real,'  const distance = Math.max(8, model.spanM * 1.2)', '''  const cameraModel146 = useMemo(() => {
    if (!showAllLevels146 || extraLevels146.length === 0) return model
    const levels = [{ model, offsetM: activeOffsetM146 }, ...extraLevels146]
    const base = Math.min(...levels.map((entry) => entry.model.floorElevationM + entry.offsetM))
    const top = Math.max(...levels.map((entry) => entry.model.floorElevationM + entry.offsetM + entry.model.floorHeightM))
    const maxSpan = Math.max(...levels.map((entry) => entry.model.spanM))
    return { ...model, floorElevationM: base, floorHeightM: top - base, spanM: maxSpan }
  }, [model, extraLevels146, showAllLevels146, activeOffsetM146])
  const distance = Math.max(8, cameraModel146.spanM * 1.2, cameraModel146.floorHeightM * 1.35)''',
  'all-floors fit camera')
real=one(real,'model.center.x + distance, model.floorElevationM + distance * 0.8 + model.floorHeightM, model.center.y + distance',
  'cameraModel146.center.x + distance, cameraModel146.floorElevationM + distance * 0.8 + cameraModel146.floorHeightM, cameraModel146.center.y + distance',
  'camera position')
real=one(real,'far: Math.max(100, model.spanM * 20)', 'far: Math.max(100, cameraModel146.spanM * 20, cameraModel146.floorHeightM * 12)',
  'camera far clipping')
real=one(real,'<group position={[0, model.floorElevationM, 0]}>','<group position={[0, model.floorElevationM + activeOffsetM146, 0]}>', 'active floor position')
extra='''      </group>
      {showAllLevels146 && extraLevels146.map((entry146) => (
        <group key={`floor-146-${entry146.id}`} position={[0, entry146.model.floorElevationM + entry146.offsetM, 0]}>
          {entry146.model.rooms.map((room146) => (
            <FloorMesh key={room146.id} room={room146} selected={false} onSelect={() => undefined} />
          ))}
          <SolidWallMeshes model={entry146.model} onSelectRoom={() => undefined} transparent={transparent} />
          {entry146.stairs.map((surface146) => (
            <StairSolid key={surface146.key} surface={surface146} selected={false} onSelect={() => undefined} />
          ))}
          {entry146.model.walls.flatMap((wall146) => wall146.openings
            .filter((opening146) => opening146.type === 'door' && entry146.model.doors.some((door146) => door146.id === opening146.id))
            .map((door146) => (
              <DoorHandle key={`${wall146.id}/${door146.id}`} door={door146} wall={wall146} selected={false} onSelect={() => undefined} />
            )))}
        </group>
      ))}
      <gridHelper'''
real=one(real,'      </group>\n      <gridHelper',extra,'other levels true Three.js meshes')
real=one(real,'<SceneControls model={model} />','<SceneControls model={cameraModel146} />','all-floor orbit target')
s=s[:s.index('function RealBuildingScene(')]+real+s[s.index('function DoorForm('):]
# Component logic has an existing reactive Blueprint levelRevision.
p0,p1,component=block(s,'export default function Building3DWorkspace(', '\n}',)
# block() ends at FIRST newline-close; impossible for full React component. Re-evaluate from exported function to EOF.
component=s[s.index('export default function Building3DWorkspace('):]
state_target="  const [transparent, setTransparent] = useState(false)"
component=one(component,state_target,'''  const [showAllLevels146, setShowAllLevels146] = useState(false)
  const [separateLevels146, setSeparateLevels146] = useState(false)
'''+state_target,'3d house toggle state')
model_anchor='  const selectedRoom = activeLevel.rooms.find((room) => room.id === selectedRoomId) ?? null'
level_models='''  // STROM146: always derive floor/room assignments from the live Blueprint keys.
  const sceneLevels146 = useMemo((): SceneLevel146[] => {
    let assignments146: Record<string, string> = {}
    try {
      const saved146: unknown = JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floor.id}.roomAssignments`) || '{}')
      if (saved146 && typeof saved146 === 'object' && !Array.isArray(saved146)) assignments146 = saved146 as Record<string, string>
    } catch { /* unreadable legacy storage is treated as main layer */ }
    let elevation146 = Number(floor.elevationM) || 0
    return levelOptions144.map((item146, idx146) => {
      const floorRooms146 = rooms.filter((room146) => (assignments146[room146.id] || 'layer-main') === item146.id)
      const allowedIds146 = new Set(floorRooms146.map((room146) => room146.id))
      const floorObjects146 = objects.filter((object146) => allowedIds146.has(object146.roomId))
      const layerFloor146: Floor = { ...floor, name: `${floor.name} / ${item146.name}`,
        elevationM: elevation146, heightM: item146.heightM }
      elevation146 += item146.heightM
      return { id: item146.id,
        model: buildBuildingModel(layerFloor146, floorRooms146, floorObjects146),
        stairs: buildStair3DSurfaces(floorRooms146, item146.heightM, window.localStorage).map((surface146) => ({
          ...surface146, levelId: item146.id, levelOffsetM: 0,
        })),
        offsetM: showAllLevels146 && separateLevels146 ? idx146 * 1.15 : 0 }
    })
  }, [floor, rooms, objects, levelOptions144, levelRevision, showAllLevels146, separateLevels146])
  const activeOffsetM146 = showAllLevels146 && separateLevels146
    ? sceneLevels146.find((entry146) => entry146.id === activeLevel.id)?.offsetM ?? 0 : 0
  const extraLevels146 = showAllLevels146 && variant === 'house'
    ? sceneLevels146.filter((entry146) => entry146.id !== activeLevel.id) : []
  // 143b already supplies ghost stairs from every level. Suppress those
  // copies when dedicated floor groups render the same staircases in 146.
  const activeStairs146 = showAllLevels146 && variant === 'house'
    ? stairs.filter((surface146) => surface146.levelId === activeLevel.id) : stairs
'''
component=one(component,model_anchor,level_models+model_anchor,'build additional Blueprint levels')
# Inject props in only main scene call, preserving onSelectWall and onSelectDoor.
render_re=r'(<RealBuildingScene\s+model=\{model\}\s+stairs=\{stairs\})(\s+)'
component,n=re.subn(render_re,lambda match: match.group(1).replace("stairs={stairs}", "stairs={activeStairs146}") + " extraLevels146={extraLevels146} activeOffsetM146={variant === 'house' ? activeOffsetM146 : 0} showAllLevels146={variant === 'house' && showAllLevels146}" + match.group(2),component,count=1)
if n!=1: raise RuntimeError('146 main 3D scene prop passing not found')
# Add toggles alongside transparent walls; exclusive to 3D Haus. Use v7 sprite icons and tooltips.
toolbar_marker='<button type="button" title="Transparente Waende umschalten"'
buttons='''{variant === 'house' && (
          <div className="building3d-stacked-options146" role="group" aria-label="3D Haus Geschossdarstellung">
            <button type="button" className={showAllLevels146 ? 'active' : ''} aria-pressed={showAllLevels146}
              title="Alle Blueprint-Etagen gemeinsam als echtes 3D anzeigen" data-tooltip="Alle Etagen anzeigen"
              onClick={() => setShowAllLevels146((value) => !value)}>
              <StromIcon name="layers-all" size={19} title="Alle Etagen anzeigen" /> Alle Etagen {showAllLevels146 ? 'AN' : 'AUS'}
            </button>
            <button type="button" className={separateLevels146 && showAllLevels146 ? 'active' : ''}
              aria-pressed={separateLevels146 && showAllLevels146} disabled={!showAllLevels146}
              title="Etagen nur in der 3D-Ansicht mit zusätzlichem vertikalen Abstand darstellen; Blueprint-Höhen unverändert"
              data-tooltip="Etagen mit Abstand auseinanderziehen"
              onClick={() => setSeparateLevels146((value) => !value)}>
              <StromIcon name="layers-neighbor" size={19} title="Etagen auseinanderziehen" /> Offset {separateLevels146 ? 'AN' : 'AUS'}
            </button>
          </div>
        )}
        '''
component=one(component,toolbar_marker,buttons+toolbar_marker,'3d house display controls')
# Update outdated "only one floor" status if present. Avoid misleading wording.
component=component.replace('Weitere Etagen werden spaeter gleichzeitig gestapelt.', 'Weitere Etagen koennen ueber den Schalter Alle Etagen eingeblendet werden.')
component=component.replace('Phase 1: nur eine Etage; Treppen, Dach und Geschossverbindungen folgen schrittweise.',
  "{variant === 'house' && showAllLevels146 ? `3D Haus: ${sceneLevels146.length} Ebenen${separateLevels146 ? ' (explodierte Ansicht, +1150 mm pro Etage)' : ''}` : `Aktive Ebene: ${activeLevel.name}`}.")
s=s[:s.index('export default function Building3DWorkspace(')]+component

style+='''
/* STROM146: readable v7 object library; correct elevation symbols. */
.wall-object-library { background: #fff !important; color: #152a46 !important; opacity: 1 !important; }
.wall-object-library .wall-object-library-items button {
  display: flex !important; align-items: center !important; justify-content: flex-start !important;
  gap: 11px !important; min-height: 43px; background: #edf3fa !important;
  color: #173354 !important; border: 1px solid #d6e2ef !important;
  font-size: 13px !important; font-weight: 750 !important; opacity: 1 !important;
  text-shadow: none !important;
}
.wall-object-library .wall-object-library-items button:hover { background: #dcecff !important; border-color: #6ea4ea !important; }
.wall-object-library .wall-object-library-items button .strom-ui-icon { width: 22px; height: 22px; flex: 0 0 22px; color: #1d4ed8; }
.wall-object-library .wall-object-library-items button span { color: #173354; display: inline; width: auto; text-align: left; }
.wall-front-svg .wall-front-door-frame146 { fill: #e9eef7; stroke: #2757b1; stroke-width: 2.2; }
.wall-front-svg .wall-front-door-leaf146 { fill: #f8fbff; stroke: #85a2cc; stroke-width: 1.3; }
.wall-front-svg .wall-front-door-jamb146 { stroke: #285ca5; stroke-width: 2; }
.wall-front-svg .wall-front-door-handle146 { fill: #315c9b; stroke: #fff; stroke-width: .7; }
.wall-front-svg .wall-front-window-frame146 { fill: #f7faff; stroke: #2153a5; stroke-width: 2.6; }
.wall-front-svg .wall-front-window-glass146 { fill: #cfeaf7; stroke: #accde5; stroke-width: 1; }
.wall-front-svg .wall-front-window-mullion146, .wall-front-svg .wall-front-window-transom146 { stroke: #467caf; stroke-width: 2.4; }
.wall-front-svg .wall-front-window-sill146 { stroke: #869bb8; stroke-width: 3; }
.floorplan-canvas .strom-edge-snap-indicator146 circle { fill: #eff6ff; stroke: #0b70e8; stroke-dasharray: none; }
.floorplan-canvas .strom-edge-snap-indicator146 text { fill: #0f4d96; paint-order: stroke; stroke: white; stroke-width: 2px; font-weight: 800; }
.floorplan-layout .strom-edge-snap-status146 { color: #1d4ed8; font-weight: 800; }
.building3d-stacked-options146 { display: inline-flex; align-items: center; flex-wrap: wrap; gap: 5px; }
.building3d-stacked-options146 button { display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; }
.building3d-stacked-options146 button.active { background: #2457b7; color: white; border-color: #2457b7; }
.building3d-stacked-options146 button:disabled { opacity: .45; cursor: not-allowed; }
'''
snap_dst.parent.mkdir(parents=True,exist_ok=True)
snap_dst.write_text(snap_src.read_text('utf8'),'utf8')
app.write_text(a,'utf8')
scene.write_text(s,'utf8')
css.write_text(style,'utf8')
print('STROM146: zoom 1000%, v7 library, front doors/windows, 3D all floors+offset, single-edge Shift+direct snaps installed')

STROM146_PATCH_PY

[ -s "$WORK_DIR/.strom146_edgeSnap.ts" ] || fail "146 Snap-Modul wurde nicht angelegt."
[ -s "$WORK_DIR/.strom146_patch.py" ] || fail "146 Python-Patch wurde nicht angelegt."
STROM146_ROOT="$WORK_DIR" STROM146_SNAP_MODULE="$WORK_DIR/.strom146_edgeSnap.ts" \
  python3 "$WORK_DIR/.strom146_patch.py" >> "$DIAG_LOG" 2>&1 \
  || fail "146 Quellpatch fehlgeschlagen; GitHub und Stage unveraendert."
rm -f "$WORK_DIR/.strom146_edgeSnap.ts" "$WORK_DIR/.strom146_patch.py"

cat > "$WORK_DIR/docs/STROM_UPDATE_146.md" <<'STROM146_DOC'
# Update 146: Blueprint zoom / Wanddetail Frontalansicht / 3D Haus / Kanten-Snapping

- Blueprint Zoom max 1000% (state, wheel, zoom buttons, fit/selected, viewport persistent); stair-editor zoom unchanged.
- Wanddetail Objektbibliothek: real SVG icons `door`, `window`, `electrical-socket` from design v7, with readable high contrast and mouseover tooltips.
- Frontalansicht: door is drawn as elevation with frame, leaf and handle, NOT a plan swing-arc; windows with frame, glass and optional mullions; existing drag, resize, wall object persistence and dimensions unchanged.
- 3D Haus options: "Alle Etagen" reads the real Blueprint level list and room assignments, builds separate THREE scene groups, all layers at cumulative true elevations; "Offset" adds 1.15m visual gap per higher level. Neither toggle writes building data; other floor meshes are read-only. 3D Wanddetail remains on active floor.
- Single edge drag in Blueprint: polygon shift is 0/45/90; moving edges snap to other room endpoints and edges at 0 mm, no wall distance, at a zoom-relative tolerance. Rect sides align directly to parallel target edges, other sides fixed. The v143b ghost-layer toggle governs additional neighbor-floor targets. A blue marker explains what snapped.
- Existing building wall solid, 3D hover, stair geometry, Blueprint assignments, database and production untouched. Stage only.
STROM146_DOC

log "4) Vollstaendigen TypeScript-/Vite-Build vor Git-Push pruefen ..."
( cd "$WORK_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 \
  || fail "Frontend-Build 146 fehlgeschlagen. Kein GitHub-Push und kein Stage-Deploy."

log "4.1) Regressionstests: 1000%-Zoom, v7 Icons, 3D Etagen, Snap und Winkelbindung ..."
export STROM146_WORK="$WORK_DIR"
export STROM146_TS="$DEPENDENCIES/typescript"
node <<'STROM146_TEST_JS' >>"$DIAG_LOG" 2>&1 || fail "146 Regressionstests fehlgeschlagen. Kein Git-Push/Stage-Deployment."
'use strict'
const fs = require('fs')
const ts = require(process.env.STROM146_TS)
const assert = require('assert')
const root = process.env.STROM146_WORK + '/frontend/src/'
const app = fs.readFileSync(root + 'App.tsx','utf8')
const scene = fs.readFileSync(root + 'components/Building3DWorkspace.tsx','utf8')
const styles = fs.readFileSync(root + 'styles.css','utf8')
const moduleFile = root + 'building/edgeSnap146.ts'
const code = fs.readFileSync(moduleFile,'utf8')
for (const file of ['App.tsx','components/Building3DWorkspace.tsx','building/edgeSnap146.ts']) {
  const filename = root + file
  const result = ts.transpileModule(fs.readFileSync(filename,'utf8'), {fileName:filename, reportDiagnostics:true,compilerOptions:{module:ts.ModuleKind.ESNext,jsx:ts.JsxEmit.ReactJSX,target:ts.ScriptTarget.ES2022}})
  const errors = result.diagnostics?.filter((item)=>item.category === ts.DiagnosticCategory.Error) || []
  assert(errors.length === 0, `${file}: parse errors: ${errors.map((e)=>ts.flattenDiagnosticMessageText(e.messageText,' ')).join(', ')}`)
}
const transpiled = ts.transpileModule(code,{fileName:moduleFile,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
const m={exports:{}}
new Function('module','exports',transpiled)(m,m.exports)
const {snapTranslatedEdge146,snapRectEdge146}=m.exports
const square=[{x:0,y:0},{x:2,y:0},{x:2,y:2},{x:0,y:2}]
const target=[{x:3,y:0},{x:4,y:0},{x:4,y:2},{x:3,y:2}]
let result=snapTranslatedEdge146(square,1,2,.97,0,[{vertices:target}],.1,false)
assert.equal(result.vertices[1].x,3)
assert.equal(result.vertices[2].x,3)
assert.equal(result.vertices[0].x,0)
result=snapTranslatedEdge146(square,1,2,.9,.1,[{vertices:target}],.025,false)
assert.equal(result.point,null)
result=snapTranslatedEdge146(square,1,2,.86,.43,[{vertices:target}],.2,true)
const dx=result.vertices[1].x-2,dy=result.vertices[1].y
assert(Math.abs(dx-dy)<.002 || Math.abs(dx+dy)<.002 || Math.abs(dx)<.002 || Math.abs(dy)<.002)
const rect=[{x:0,y:0},{x:2.96,y:0},{x:2.96,y:2},{x:0,y:2}]
const aligned=snapRectEdge146(rect,'right',[{vertices:target}],.08)
assert.equal(aligned.vertices[1].x,3)
assert.equal(aligned.vertices[0].x,0)
assert(app.includes('STROM146_ZOOM') && app.includes('0.22, 10'))
assert(app.includes('wall-front-door146') && app.includes('wall-front-window146'))
assert(!app.includes('Q ${round2(cx + w * 0.22)}'))
assert(app.includes('StromIcon name="electrical-socket"'))
assert(scene.includes('STROM146_ALL_LEVELS') && scene.includes('extraLevels146.map('))
assert(scene.includes("variant === 'house'") && scene.includes('1.15'))
assert(scene.includes('STROM145_FLOATING_LEVELS') && scene.includes('STROM141_WALL_HOVER'))
assert(scene.includes('onPointerMove={hoverAt}') && scene.includes('<StairSolid'))
assert(styles.includes('strom-edge-snap-indicator146'))
console.log('PASS 146 TSX syntax, snapping/direct-zero-gap/Shift, 1000%, library, fronts, multi-level true 3D, original wall editor/stairs/hover retained')
STROM146_TEST_JS

log "5) Gepruefte Dateien nach Stage uebertragen ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage-Synchronisation fehlgeschlagen. Backup: $BACKUP_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Build und Tests bestanden. GitHub-Push darf erfolgen, Stage/Web unveraendert."
  exit 0
fi

log "6) Stage-Frontend bauen und auf /strom-test/ veroeffentlichen ..."
( cd "$STAGE_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 \
  || fail "Stage-Build fehlgeschlagen. Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Stage-Buildausgabe fehlt. Backup: $BACKUP_DIR"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 \
  || fail "Stage-Web-Deployment fehlgeschlagen. Backup: $BACKUP_DIR"
log ""
log "Update 146 Stage erfolgreich: https://home.moja.de/strom-test/"
log "  - Blueprint Zoom bis 1000%, exakte Kanten- und Eckpunkt-Snaps mit Shift (0/45/90 Grad)."
log "  - Wanddetail: v7-Icons und optisch korrekte Frontalansicht fuer Tueren/Fenster."
log "  - 3D Haus: echte mehrstoeckige Szene und optionaler visueller Geschossabstand."
log "  - Wandsolids, 3D Wandklick, Hover, Treppen, Datenbank und Produktion unveraendert."
log "Backup: $BACKUP_DIR"
