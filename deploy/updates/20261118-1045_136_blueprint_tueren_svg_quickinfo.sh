#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-1045_136_blueprint_tueren_svg_quickinfo"
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
COMMIT_MESSAGE="Update 136: Blueprint-Tueren, SVG-Icons, Quickinfos und Wanddetail-Integration"
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
  echo "2) Aktuellen Stage-Source + Update 136 nach GitHub pushen ..."
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

  echo "1.3) Update 136 auf Git-Source anwenden und Build pruefen ..."
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
  echo "FEHLER: Unbekannter Modus '$MODE'." >&2
  echo "Auf dem Mac ohne Parameter starten." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Pi / Stage update body.
# -----------------------------------------------------------------------------
DEPLOY_DIR="$REMOTE_DEPLOY_DIR"
if [ ! -d "$BACKUP_BASE" ]; then
  BACKUP_BASE="$(dirname "$STAGE_DIR")"
fi
BACKUP_DIR="$BACKUP_BASE/strom_stage_backup_${SCRIPT_NAME}_$(date +%Y%m%d-%H%M%S)"
WORK_DIR="/tmp/${SCRIPT_NAME}_work_$(id -u)_$$_${RANDOM}"
DIAG_LOG="/tmp/${SCRIPT_NAME}_diagnostics_$(date +%Y%m%d-%H%M%S).log"

run_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

log() {
  echo "$@" | tee -a "$DIAG_LOG"
}

fail() {
  log ""
  log "FEHLER: $*"
  log "Diagnose: $DIAG_LOG"
  if [ -f "$DIAG_LOG" ]; then
    echo ""
    echo "--- Letzte Diagnosezeilen ---"
    tail -n 80 "$DIAG_LOG" 2>/dev/null || true
    echo "--- Ende Diagnose ---"
  fi
  exit 1
}


node_version_supported() {
  local version="$1"
  local major minor patch
  IFS=. read -r major minor patch <<<"${version#v}"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  if [ "$major" -eq 20 ] && [ "$minor" -ge 19 ]; then return 0; fi
  if [ "$major" -eq 22 ] && [ "$minor" -ge 12 ]; then return 0; fi
  if [ "$major" -gt 22 ]; then return 0; fi
  return 1
}

select_compatible_node() {
  local candidates=()
  local candidate version best_bin="" best_version=""

  if command -v node >/dev/null 2>&1; then
    candidates+=("$(command -v node)")
  fi

  for candidate in \
    /home/mpwh/.nvm/versions/node/*/bin/node \
    /root/.nvm/versions/node/*/bin/node \
    /usr/local/lib/nodejs/node-v*/bin/node \
    /usr/local/lib/nodejs/node*/bin/node \
    /opt/node*/bin/node \
    /opt/node/*/bin/node \
    /usr/local/bin/node \
    /usr/bin/node; do
    [ -x "$candidate" ] && candidates+=("$candidate")
  done

  if [ -d /home/mpwh/.local/share/fnm/node-versions ]; then
    for candidate in /home/mpwh/.local/share/fnm/node-versions/*/installation/bin/node; do
      [ -x "$candidate" ] && candidates+=("$candidate")
    done
  fi

  for candidate in "${candidates[@]}"; do
    version="$($candidate -p 'process.versions.node' 2>/dev/null || true)"
    [ -n "$version" ] || continue
    if node_version_supported "$version"; then
      if [ -z "$best_bin" ] || [ "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -n 1)" = "$version" ]; then
        best_bin="$candidate"
        best_version="$version"
      fi
    fi
  done

  if [ -z "$best_bin" ]; then
    log "Gefundene Node-Versionen:"
    for candidate in "${candidates[@]}"; do
      [ -x "$candidate" ] || continue
      version="$($candidate -p 'process.versions.node' 2>/dev/null || true)"
      [ -n "$version" ] && log "  $candidate -> $version"
    done
    fail "Kein kompatibles Node.js gefunden. Benoetigt wird Node 20.19+ oder Node 22.12+."
  fi

  NODE_BIN="$best_bin"
  NODE_VERSION="$best_version"
  NODE_BIN_DIR="$(dirname "$NODE_BIN")"
  export PATH="$NODE_BIN_DIR:$PATH"
  hash -r 2>/dev/null || true

  log "Node fuer Frontend-Build: $NODE_BIN (v$NODE_VERSION)"
  command -v npm >/dev/null 2>&1 || fail "Zum ausgewaehlten Node wurde kein npm gefunden: $NODE_BIN_DIR"
  log "npm fuer Frontend-Build: $(command -v npm) ($(npm --version 2>/dev/null || echo unbekannt))"
}

run_frontend_build() {
  local frontend_dir="$1"
  (
    cd "$frontend_dir"
    PATH="$NODE_BIN_DIR:$PATH" VITE_BASE=/strom-test/ npm run build
  )
}

trap 'log "ABBRUCH bei Zeile $LINENO. Diagnose: $DIAG_LOG"' ERR

log "=== $SCRIPT_NAME / Pi ==="
log "Ziel: Blueprint Tueren zeichnen, echte Breite/Hoehe, Unterkante 0, Wanddetail-Datenbindung und SVG-Designicons."
log "Stage: $STAGE_DIR"
log "Produktion wird nicht direkt geaendert."
log "Diagnose: $DIAG_LOG"
log ""

[ -d "$STAGE_DIR/frontend/src" ] || fail "Stage-Frontend nicht gefunden: $STAGE_DIR/frontend/src"
[ -f "$STAGE_DIR/frontend/src/App.tsx" ] || fail "App.tsx nicht gefunden"
[ -f "$STAGE_DIR/frontend/src/styles.css" ] || fail "styles.css nicht gefunden"

log "0) Kompatible Node.js-Version fuer Vite bestimmen..."
select_compatible_node

log "1) Backup der Stage erstellen..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Backup der temporaeren Git-Arbeitskopie wird uebersprungen."
else
  rm -rf "$BACKUP_DIR"
  cp -a "$STAGE_DIR" "$BACKUP_DIR"
fi

log "2) Arbeitskopie vorbereiten..."
# Eindeutiger Prozesspfad: kollidiert weder mit der root-Git-Phase noch mit frueheren Laeufen.
rm -rf "$WORK_DIR"
cp -a "$STAGE_DIR" "$WORK_DIR"

if [ ! -e "$WORK_DIR/frontend/node_modules" ]; then
  if [ -e "$STAGE_DIR/frontend/node_modules" ]; then
    ln -s "$STAGE_DIR/frontend/node_modules" "$WORK_DIR/frontend/node_modules"
  elif [ -e "$PROD_DIR/frontend/node_modules" ]; then
    ln -s "$PROD_DIR/frontend/node_modules" "$WORK_DIR/frontend/node_modules"
  fi
fi

log "3) Patch in Arbeitskopie anwenden..."
export WORK_DIR
python3 - <<'INNERPY'
from pathlib import Path
import os
import base64
import zlib
import re

work = Path(os.environ['WORK_DIR'])
app = work / 'frontend/src/App.tsx'
css_file = work / 'frontend/src/styles.css'
sprite_path = work / 'frontend/public/strom-icons-v7.svg'
component_path = work / 'frontend/src/components/StromIcon.tsx'
s = app.read_text(encoding='utf-8')
if 'function blueprintDoorCandidate136(' in s:
    raise SystemExit('Update 136 ist bereits angewendet. Keine doppelte Installation.')

def one(old, new, label):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'Update 136: {label}: erwarteter Codeblock fehlt oder nicht eindeutig (Anzahl {n}).')
    s = s.replace(old, new, 1)

def before(marker, block, label):
    global s
    n = s.count(marker)
    if n != 1:
        raise SystemExit(f'Update 136: {label}: Marker fehlt oder mehrfach vorhanden (Anzahl {n}).')
    s = s.replace(marker, block + marker, 1)

# Common SVG component. Identifiers are the names of the approved SVG design-v7 sprite.
component_path.parent.mkdir(parents=True, exist_ok=True)
component_path.write_text('''type StromIconProps = {
  name: string
  title?: string
  size?: number
  className?: string
}

/** SVG-only design library; no icon fonts. */
export default function StromIcon({ name, title, size = 20, className = '' }: StromIconProps) {
  // Distinguish Stage from production even when an older Vite config still has base=/strom/.
  const basePath = typeof window === 'undefined'
    ? import.meta.env.BASE_URL
    : window.location.pathname.startsWith('/strom-test/') ? '/strom-test/'
      : window.location.pathname.startsWith('/strom/') ? '/strom/'
        : import.meta.env.BASE_URL
  return (
    <svg
      className={`strom-ui-icon ${className}`}
      width={size}
      height={size}
      viewBox="0 0 80 80"
      role={title ? 'img' : undefined}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      focusable="false"
    >
      {title && <title>{title}</title>}
      <use href={`${basePath}strom-icons-v7.svg#${name}`} />
    </svg>
  )
}
''', encoding='utf-8')

sprite_path.parent.mkdir(parents=True, exist_ok=True)
sprite_path.write_bytes(zlib.decompress(base64.b64decode('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')))

import_line = "import { type CSSProperties, ChangeEvent as ReactChangeEvent, DragEvent as ReactDragEvent, MouseEvent as ReactMouseEvent, WheelEvent as ReactWheelEvent, useEffect, useMemo, useRef, useState } from 'react'\n"
if "import StromIcon from './components/StromIcon'" not in s:
    one(import_line, import_line + "import StromIcon from './components/StromIcon'\n", 'SVG-Komponente importieren')

# Door is another Blueprint tool, not a distinct data model.
old_type = "type Tool = 'select' | 'rectangle' | 'outerwall' | 'polygon' | 'recess' | 'distance' | 'stair'"
new_type = old_type + " | 'door'"
one(old_type, new_type, 'Werkzeug-Typ')

# Single source of truth for all main navigation icons.
nav_start = s.find('function viewModeIcon(mode: ViewMode) {')
nav_end = s.find('function toolLabel(tool: Tool)', nav_start)
if nav_start < 0 or nav_end < 0:
    raise SystemExit('Update 136: Navigationsicon-Marker fehlen.')
s = s[:nav_start] + '''function viewModeIcon(mode: ViewMode) {
  const name = mode === 'floorplan' ? 'blueprint'
    : mode === 'wall' ? 'wall-detail'
      : mode === 'board' ? 'lightning' : 'cube'
  return <StromIcon name={name} title={viewModes.find((entry) => entry.id === mode)?.label ?? mode} size={22} />
}

''' + s[nav_end:]

# Existing toolIcon and visibilityModeIcon are only presentation helpers.
start = s.find('function toolIcon(tool: Tool) {')
end = s.find('function mToX(', start)
if start < 0 or end < 0:
    raise SystemExit('Update 136: toolIcon-Marker fehlen.')
s = s[:start] + '''function toolIcon(tool: Tool) {
  const name = tool === 'select' ? 'select'
    : tool === 'rectangle' ? 'room-rect'
      : tool === 'outerwall' ? 'outer-wall'
        : tool === 'polygon' ? 'polygon'
          : tool === 'recess' ? 'cutout'
            : tool === 'stair' ? 'stair-run'
              : tool === 'door' ? 'door' : 'measure'
  return <StromIcon name={name} title={toolLabel(tool)} />
}

''' + s[end:]

start = s.find('function visibilityModeIcon(mode: LayerVisibilityMode) {')
end = s.find('type Bounds = ', start)
if start < 0 or end < 0:
    raise SystemExit('Update 136: Sichtbarkeitsicon-Marker fehlen.')
s = s[:start] + '''function visibilityModeIcon(mode: LayerVisibilityMode) {
  const name = mode === 'active' ? 'layers-current'
    : mode === 'adjacentGhostNoDims' ? 'layers-neighbor'
      : mode === 'adjacentGhostDims' ? 'layers-neighbor-dim' : 'layers-all'
  return <StromIcon name={name} title={visibilityModeLabel(mode)} />
}

''' + s[end:]

# Add new Tool label; avoids misleading 'distance' fallback.
one("  if (tool === 'recess') return 'Aussparung / Wandvorsprung'\n", "  if (tool === 'recess') return 'Aussparung / Wandvorsprung'\n  if (tool === 'door') return 'Tuer zwischen Raeumen einsetzen'\n", 'Tuer-Werkzeuglabel')

# Blueprint state, coordinates, and persist trigger.
state_anchor = "  const [blueprintWallObjects, setBlueprintWallObjects] = useState<ApiWallObject[]>([])"
state_new = state_anchor + '''
  const [blueprintDoorWidth136, setBlueprintDoorWidth136] = useState(0.9)
  const [blueprintDoorHeight136, setBlueprintDoorHeight136] = useState(2.1)
  const [blueprintDoorNotice136, setBlueprintDoorNotice136] = useState('')
  const [blueprintDoorSaving136, setBlueprintDoorSaving136] = useState(false)'''
one(state_anchor, state_new, 'Tuer-Parameterzustand')

# Nearby wall intersections are computed using real metres, not normalized wall widths.
helper = '''// Update 136: Door placement in physical coordinates, for differently sized wall faces.
type BlueprintDoorFace136 = { roomId: string; edgeIndex: number; x: number; w: number }
type BlueprintDoorCandidate136 = {
  faces: [BlueprintDoorFace136, BlueprintDoorFace136]
  left: PointM
  right: PointM
  score: number
}

function blueprintDoorCandidate136(point: PointM, rooms: Room[], widthM: number): BlueprintDoorCandidate136 | null {
  if (rooms.length < 2 || !Number.isFinite(widthM) || widthM <= 0) return null
  const edges = rooms.flatMap((room) => room.vertices.flatMap((_, edgeIndex) => {
    const edge = edgePoints(room.vertices, edgeIndex)
    return edge ? [{ room, edgeIndex, edge }] : []
  }))
  let winner: BlueprintDoorCandidate136 | null = null
  for (let i = 0; i < edges.length; i += 1) {
    const first = edges[i]
    const dx = first.edge.b.x - first.edge.a.x
    const dy = first.edge.b.y - first.edge.a.y
    const len = Math.hypot(dx, dy)
    if (len < widthM + 0.001) continue
    const ux = dx / len
    const uy = dy / len
    const candidateAt = (t: number) => ({ x: first.edge.a.x + t * ux, y: first.edge.a.y + t * uy })
    for (let j = i + 1; j < edges.length; j += 1) {
      const second = edges[j]
      if (first.room.id === second.room.id) continue
      if (!wallObjectPairInfo(first.room, first.edge, second.room, second.edge)?.paired) continue
      const bx = second.edge.b.x - second.edge.a.x
      const by = second.edge.b.y - second.edge.a.y
      const secondLength = Math.hypot(bx, by)
      if (secondLength < widthM + 0.001) continue
      const vx = bx / secondLength
      const vy = by / secondLength
      const projection = (p: PointM) => (p.x - first.edge.a.x) * ux + (p.y - first.edge.a.y) * uy
      const otherStart = projection(second.edge.a)
      const otherEnd = projection(second.edge.b)
      const sharedStart = Math.max(0, Math.min(otherStart, otherEnd))
      const sharedEnd = Math.min(len, Math.max(otherStart, otherEnd))
      if (sharedEnd - sharedStart < widthM + 0.001) continue
      const alongClick = projection(point)
      const chosen = clamp(alongClick, sharedStart + widthM / 2, sharedEnd - widthM / 2)
      const center = candidateAt(chosen)
      const crossA = Math.abs((point.x - center.x) * uy - (point.y - center.y) * ux)
      const centerOnSecond = (center.x - second.edge.a.x) * vx + (center.y - second.edge.a.y) * vy
      if (centerOnSecond - widthM / 2 < -0.003 || centerOnSecond + widthM / 2 > secondLength + 0.003) continue
      const distToSecond = Math.abs((point.x - second.edge.a.x) * vy - (point.y - second.edge.a.y) * vx)
      const distToFirst = Math.abs((point.x - first.edge.a.x) * uy - (point.y - first.edge.a.y) * ux)
      const nearest = Math.min(distToFirst, distToSecond)
      if (nearest > 0.28) continue
      const alongError = Math.abs(alongClick - chosen)
      if (alongError > widthM / 2 + 0.45) continue
      const wallOffset = Math.abs((second.edge.a.x - first.edge.a.x) * uy - (second.edge.a.y - first.edge.a.y) * ux)
      const score = nearest * 3 + alongError + distToFirst + distToSecond + wallOffset * 0.3 + crossA * 0.1
      const faceA = { roomId: first.room.id, edgeIndex: first.edgeIndex, x: Math.round(chosen / len * 1e6) / 1e6, w: Math.round(widthM / len * 1e6) / 1e6 }
      const faceB = { roomId: second.room.id, edgeIndex: second.edgeIndex, x: Math.round(centerOnSecond / secondLength * 1e6) / 1e6, w: Math.round(widthM / secondLength * 1e6) / 1e6 }
      const result = {
        faces: [faceA, faceB] as [BlueprintDoorFace136, BlueprintDoorFace136],
        left: candidateAt(chosen - widthM / 2),
        right: candidateAt(chosen + widthM / 2),
        score,
      }
      if (!winner || score < winner.score) winner = result
    }
  }
  return winner
}

'''
before('function BlueprintWallObjectConnections(', helper, 'Tueren-Geometriehelper')

# The chosen edge must be shared by two real rooms in the active layer.
geometry_anchor = '''  const activeLayerRooms = useMemo(
    () => rooms.filter((room) => (roomLayerAssignments[room.id] ?? defaultLayerId) === activeLayerId),
    [rooms, roomLayerAssignments, activeLayerId],
  )'''
geometry_new = geometry_anchor + '''
  const blueprintDoorWallHeight136 = loadWallHeightM(floor.id, floor.heightM)
  const blueprintDoorPreview136 = tool === 'door' && cursorPoint
    ? blueprintDoorCandidate136(cursorPoint, activeLayerRooms, blueprintDoorWidth136) : null
'''
one(geometry_anchor, geometry_new, 'Aktive Ebene fuer Tuer-Geometrie')

# Place in the same wall-objects DB that Wanddetail reads. Bottom is always 0m.
placement_method = '''  async function placeBlueprintDoor136(point: PointM) {
    if (blueprintDoorSaving136) return
    setBlueprintDoorNotice136('')
    const widthM = blueprintDoorWidth136
    const heightM = blueprintDoorHeight136
    if (!Number.isFinite(widthM) || widthM < 0.3) {
      setBlueprintDoorNotice136('Bitte eine Tuerbreite ab 300 mm eingeben.')
      return
    }
    if (!Number.isFinite(heightM) || heightM < 0.5 || heightM > blueprintDoorWallHeight136 + 0.0001) {
      setBlueprintDoorNotice136(`Tuerhoehe muss zwischen 500 mm und ${Math.round(blueprintDoorWallHeight136 * 1000)} mm liegen.`)
      return
    }
    const match = blueprintDoorCandidate136(point, activeLayerRooms, widthM)
    if (!match) {
      setBlueprintDoorNotice136('Keine ausreichend lange gemeinsame Wand an dieser Stelle gefunden. Bitte direkt auf die gemeinsame Wand klicken.')
      return
    }
    const h = Math.round(heightM / blueprintDoorWallHeight136 * 1e6) / 1e6
    const y = Math.round((1 - h / 2) * 1e6) / 1e6
    const groupId = `blueprint-door-${Date.now()}-${Math.round(Math.random() * 1000000)}`
    const created: ApiWallObject[] = []
    setBlueprintDoorSaving136(true)
    try {
      for (const face of match.faces) {
        const record = await createWallObject({
          floorId: floor.id,
          roomId: face.roomId,
          edgeIndex: face.edgeIndex,
          objectType: 'door',
          x: face.x,
          y,
          w: face.w,
          h,
          groupId,
        })
        created.push(record)
      }
      setBlueprintWallObjects(await getWallObjects(floor.id))
      setBlueprintDoorNotice136(`Tuer gespeichert: ${Math.round(widthM * 1000)} x ${Math.round(heightM * 1000)} mm, Unterkante 0 mm. Im Wanddetail sichtbar.`)
    } catch (err) {
      await Promise.allSettled(created.map((record) => deleteWallObjectFromApi(record.id)))
      try { setBlueprintWallObjects(await getWallObjects(floor.id)) } catch { /* original error takes precedence */ }
      const message = err instanceof Error ? err.message : String(err)
      setBlueprintDoorNotice136(`Tuer konnte nicht gespeichert werden: ${message}`)
      onError(message)
    } finally {
      setBlueprintDoorSaving136(false)
    }
  }

'''
before('  function handleCanvasClick(event: ReactMouseEvent<SVGSVGElement>) {', placement_method, 'Tuer-Placement')

click_anchor = '''    const point = eventToMeters(event)
    if (!point) return

    if (tool === 'rectangle' || tool === 'outerwall') {'''
click_replacement = '''    const point = eventToMeters(event)
    if (!point) return

    if (tool === 'door') {
      void placeBlueprintDoor136(point)
      return
    }

    if (tool === 'rectangle' || tool === 'outerwall') {'''
one(click_anchor, click_replacement, 'Klickverhalten im Blueprint')

# Keep other tools' behavior unchanged, but reset door messages when tool changes.
choose_start = s.find('  async function chooseTool(nextTool: Tool) {')
choose_end = s.find('  function changeZoom(next: number) {', choose_start)
if choose_start < 0 or choose_end < 0:
    raise SystemExit('Update 136: Werkzeugumschaltung fehlt.')
fragment = s[choose_start:choose_end]
if "    if (nextTool === 'recess' && !selectedRoom) return" not in fragment:
    raise SystemExit('Update 136: chooseTool-Struktur veraendert.')
fragment = fragment.replace("    if (nextTool === 'recess' && !selectedRoom) return", "    if (nextTool === 'recess' && !selectedRoom) return\n    setBlueprintDoorNotice136('')", 1)
fragment = fragment.replace("    if (nextTool === 'distance') onSelectRoom('')", "    if (nextTool === 'distance' || nextTool === 'door') onSelectRoom('')", 1)
s = s[:choose_start] + fragment + s[choose_end:]

# New door is an explicit state, not the fallback distance help.
hint_anchor = "          : tool === 'stair'\n            ? 'Treppe einzeichnen: OK bestaetigt die Umwandlung des ausgewaehlten Objekts in einen Treppenraum.'"
if hint_anchor not in s:
    raise SystemExit('Update 136: Blueprint-Hilfetextstruktur fehlt.')
s = s.replace(hint_anchor, hint_anchor + "\n            : tool === 'door'\n              ? 'Tuer: Breite und Hoehe in mm eingeben, dann eine gemeinsame Wand zweier Raeume anklicken. Tueren beginnen immer bei 0 mm Fussbodenhoehe.'", 1)

# Blueprint toolbar: keep the existing commands and replace only their glyphs.
toolbar_start_marker = '<div className="canvas-toolbox" aria-label="Blueprint Werkzeuge">'
toolbar_start = s.find(toolbar_start_marker)
toolbar_end = s.find('        </div>', toolbar_start)
if toolbar_start < 0 or toolbar_end < 0:
    raise SystemExit('Update 136: Blueprint-Werkzeugleiste fehlt.')
bar = s[toolbar_start:toolbar_end]
icon = lambda name, title: f'<StromIcon name="{name}" title="{title}" />'
# Exact glyph lookup avoids changing any Wanddetail or stair editor controls.
mappings = [
    ('\u21b6', 'undo', 'Rueckgaengig'),
    ('\u25a3', 'select', 'Alle auswaehlen'),
    ('\u21d4', 'measure', 'Abstand messen'),
    ('\u25b1', 'cutout', 'Aussparung'),
    ('\u21f5', 'stair-run', 'Treppe einzeichnen'),
    ('\U0001f5d1', 'trash', 'Loeschen'),
    ('\U0001f9f9', 'broom', 'Alle Elemente loeschen'),
    ('\u2194', 'snap', 'Snapping umschalten'),
    ('\u2212', 'zoom-out', 'Herauszoomen'),
    ('\u26f6', 'fit', 'Alles einpassen'),
    ('\u2316', 'target', 'Auf Auswahl zoomen'),
    ('\u2301', 'measure', 'Bemassung umschalten'),
]
for glyph, name, title in mappings:
    bar = bar.replace('>' + glyph + '</button>', '>' + icon(name, title) + '</button>')
    bar = bar.replace('>\n            ' + glyph + '\n          </button>', '>\n            ' + icon(name, title) + '\n          </button>')
    bar = bar.replace('>\n            ' + glyph + '\n', '>\n            ' + icon(name, title) + '\n')
    if glyph == '\U0001f9f9':
        bar = re.sub(r'(>\s*)' + re.escape(glyph) + r'(\s*</button>)', lambda m: m.group(1) + icon(name, title) + m.group(2), bar)
    if glyph == '\u2194':
        bar = bar.replace('            ' + glyph + '\n          </label>', '            ' + icon(name, title) + '\n          </label>')
bar = bar.replace('>1:1</button>', '>' + icon('one-to-one', '100 Prozent Ansicht') + '</button>')
bar = bar.replace('W\n            <input type="number"', icon('outer-wall', 'Wandstaerke') + '\n            <input type="number"')
bar = bar.replace('onClick={() => changeZoom(zoom + 0.15)}>+</button>', 'onClick={() => changeZoom(zoom + 0.15)}>' + icon('zoom-in', 'Hineinzoomen') + '</button>')
# Insert door tool immediately beside stair tool.
end_stair_button = bar.find('>\u21f5</button>')
if end_stair_button >= 0:
    raise SystemExit('Update 136: Treppensymbol wurde nicht auf SVG umgestellt.')
needle = 'title="Treppe einzeichnen"'
needle_pos = bar.find(needle)
if needle_pos < 0:
    raise SystemExit('Update 136: Treppen-Button als Anker fehlt.')
closing = bar.find('</button>', needle_pos)
if closing < 0:
    raise SystemExit('Update 136: Treppen-Button-Ende fehlt.')
closing += len('</button>')
door_button = '''
          <button type="button" title="Tuer zwischen Raeumen einsetzen (Breite / Hoehe in mm)" data-tooltip="Tuer einsetzen" aria-label="Tuer zwischen Raeumen einsetzen" className={tool === 'door' ? 'active' : ''} disabled={activeLayerRooms.length < 2 || blueprintDoorSaving136} onMouseDown={(event) => event.preventDefault()} onClick={() => void chooseTool('door')}><StromIcon name="door" title="Tuer einsetzen" /></button>'''
bar = bar[:closing] + door_button + bar[closing:]
s = s[:toolbar_start] + bar + s[toolbar_end:]

# Pointer style communicates placing a door rather than selecting a room.
s = s.replace(
    "className={`canvas floorplan-canvas ${tool === 'select' ? 'select-mode' : ''}`}",
    "className={`canvas floorplan-canvas ${tool === 'select' ? 'select-mode' : ''} ${tool === 'door' ? 'blueprint-door-active136' : ''}`}",
    1,
)

# Door-specific size controls live under the toolbar; no changes to existing room properties.
settings_anchor = '''        <CanvasRulers zoom={zoom} scrollLeft={scrollPosition.left} scrollTop={scrollPosition.top} />'''
settings = '''        {tool === 'door' && (
          <div className="canvas-settings blueprint-door-settings136" aria-label="Tuerparameter">
            <strong>Tuer einsetzen</strong>
            <label title="Tuerbreite in Millimetern">Breite (mm)
              <MmNumberInput valueM={blueprintDoorWidth136} minM={0.3} disabled={blueprintDoorSaving136} onChangeM={(value) => setBlueprintDoorWidth136(Math.max(0.3, round3(value)))} />
            </label>
            <label title="Tuerhoehe in Millimetern">Hoehe (mm)
              <MmNumberInput valueM={blueprintDoorHeight136} minM={0.5} disabled={blueprintDoorSaving136} onChangeM={(value) => setBlueprintDoorHeight136(Math.max(0.5, round3(value)))} />
            </label>
            <span title="Die Unterkante liegt fest bei 0 mm Fussbodenhoehe">Unterkante: 0 mm</span>
            <button type="button" title="Tuerwerkzeug beenden" onClick={() => void chooseTool('select')}>Fertig</button>
            {blueprintDoorNotice136 && <span className="blueprint-door-notice136" role="status">{blueprintDoorNotice136}</span>}
          </div>
        )}

'''
one(settings_anchor, settings + settings_anchor, 'Eingabefelder fuer Tuer')

# Preview goes above the room drawings and is always non-interactive.
preview_anchor = '''            <BlueprintWallObjectConnections wallObjects={blueprintWallObjects} rooms={rooms} />'''
preview = '''            {blueprintDoorPreview136 && tool === 'door' && (
              <g className="blueprint-door-preview136" pointerEvents="none" aria-label="Tuer-Vorschau">
                <line x1={mToX(blueprintDoorPreview136.left.x)} y1={mToY(blueprintDoorPreview136.left.y)} x2={mToX(blueprintDoorPreview136.right.x)} y2={mToY(blueprintDoorPreview136.right.y)} />
                <circle cx={mToX((blueprintDoorPreview136.left.x + blueprintDoorPreview136.right.x) / 2)} cy={mToY((blueprintDoorPreview136.left.y + blueprintDoorPreview136.right.y) / 2)} r="4" />
              </g>
            )}'''
one(preview_anchor, preview_anchor + '\n' + preview, 'Tuervorschau')

# Escape and mouseleave do not interfere with other tools.
old_leave = '            onMouseLeave={() => void handleMouseUp()}'
new_leave = "            onMouseLeave={() => { if (tool === 'door') setCursorPoint(null); void handleMouseUp() }}"
one(old_leave, new_leave, 'Tuervorschau bei Mouseleave')

# Existing sidebar labels already have title. Replace glyphs only.
subs = [
    ('>\u203a</button>', '><StromIcon name="chevron-right" title="Seitenleiste erweitern" /></button>'),
    ('>\u2039</button>', '><StromIcon name="chevron-left" title="Seitenleiste einklappen" /></button>'),
]
for old, new in subs:
    s = s.replace(old, new)
s = s.replace('<span className="nav-icon" aria-hidden="true">\u21e5</span>', '<span className="nav-icon"><StromIcon name="logout" title="Logout" /></span>')

# Change the layer icons on Blueprint side only.
layer_menu_start = s.find('<div className={`canvas-layer-menu ${layersOpen ? \'open\' : \'\'}`} aria-label="Ebenen">')
layer_menu_end = s.find('        {layerDeleteRequest && (', layer_menu_start)
if layer_menu_start < 0 or layer_menu_end < 0:
    raise SystemExit('Update 136: Blueprint-Ebenenmenu fehlt.')
layer = s[layer_menu_start:layer_menu_end]
layer = layer.replace('>\u2630 {activeLayer.name}</button>', '><StromIcon name="chevron-down" title="Ebenenmenue" /> {activeLayer.name}</button>')
layer = layer.replace("{effectivelyVisible ? '\U0001f441' : '\u25cc'}", "<StromIcon name={effectivelyVisible ? 'eye' : 'eye-off'} title={effectivelyVisible ? 'Ebene sichtbar' : 'Ebene ausgeblendet'} />")
layer = layer.replace('>\u22ee\u22ee</button>', '><StromIcon name="drag-dots" title="Ebene verschieben" /></button>')
layer = layer.replace('>\uff0b</button>', '><StromIcon name="new-object" title="Neue Ebene" /></button>')
layer = layer.replace('>\U0001f5d1</button>', '><StromIcon name="trash" title="Ebene loeschen" /></button>')
s = s[:layer_menu_start] + layer + s[layer_menu_end:]

# Existing Wanddetail and stair editor controls keep their functions. SVG style is now reusable there too.
# Limit automatic swaps to the stair tool bar, which is opened from the Blueprint.
stair_toolbar_start = s.find('<div className="canvas-toolbox stair-editor-toolbar"')
stair_toolbar_end = s.find('</div>', stair_toolbar_start)
if stair_toolbar_start >= 0 and stair_toolbar_end > stair_toolbar_start:
    bar2 = s[stair_toolbar_start:stair_toolbar_end]
    replacements = [
        ('\u2196','move','Verschieben'),
        ('\u27f3','rotate-90','90 Grad drehen'),
        ('\u21c4','mirror','Biegung spiegeln'),
        ('\u2212','zoom-out','Herauszoomen'),
        ('+','zoom-in','Hineinzoomen'),
        ('\u21d4','align','Ausrichten'),
        ('\u21b6','undo','Rueckgaengig'),
        ('\u232b','trash','Loeschen'),
    ]
    for glyph, name, title in replacements:
        bar2 = bar2.replace('>' + glyph + '</button>', '><StromIcon name="' + name + '" title="' + title + '" /></button>')
    s = s[:stair_toolbar_start] + bar2 + s[stair_toolbar_end:]

app.write_text(s, encoding='utf-8')

c = css_file.read_text(encoding='utf-8')
c += '''

/* Update 136: SVG design icons, Blueprint door-tool and interactive preview. */
.strom-ui-icon { display: inline-block; flex: none; vertical-align: middle; overflow: visible; color: inherit; }
.canvas-toolbox button .strom-ui-icon { width: 21px; height: 21px; }
.nav-icon .strom-ui-icon { width: 22px; height: 22px; }
.layer-menu-panel .strom-ui-icon { width: 18px; height: 18px; }
.snap-control .strom-ui-icon, .wall-control .strom-ui-icon { width: 19px; height: 19px; }
.blueprint-door-settings136 { gap: 0.7rem; align-items: center; flex-wrap: wrap; }
.blueprint-door-settings136 label { min-width: 112px; display: grid; gap: 0.2rem; }
.blueprint-door-settings136 label input { width: 104px; }
.blueprint-door-settings136 strong { color: #1e3a8a; white-space: nowrap; }
.blueprint-door-notice136 { max-width: 400px; font-size: 0.8rem; font-weight: 600; color: #1e40af; }
.floorplan-canvas.blueprint-door-active136 { cursor: crosshair; }
.floorplan-canvas .blueprint-door-preview136 line { stroke: #2563eb; stroke-width: 5px; stroke-dasharray: 7 4; pointer-events: none; }
.floorplan-canvas .blueprint-door-preview136 circle { fill: #fff; stroke: #2563eb; stroke-width: 2px; pointer-events: none; }
'''
css_file.write_text(c, encoding='utf-8')

print('Update 136: Blueprint-Tuerwerkzeug, Parameter, Vorschau, SVG-Design und Quickinfos erfolgreich gepatcht.')

INNERPY

log "4) Frontend-Build der Arbeitskopie testen..."
run_frontend_build "$WORK_DIR/frontend" >>"$DIAG_LOG" 2>&1 || fail "Frontend-Build in Arbeitskopie fehlgeschlagen"

log "5) Gepruefte Arbeitskopie nach Stage uebernehmen..."
rsync -a --delete \
  --exclude "frontend/node_modules" \
  "$WORK_DIR/" "$STAGE_DIR/"

if [ -e "$BACKUP_DIR/frontend/node_modules" ] && [ ! -e "$STAGE_DIR/frontend/node_modules" ]; then
  if [ -L "$BACKUP_DIR/frontend/node_modules" ]; then
    target="$(readlink "$BACKUP_DIR/frontend/node_modules")"
    ln -s "$target" "$STAGE_DIR/frontend/node_modules"
  elif [ -d "$BACKUP_DIR/frontend/node_modules" ]; then
    ln -s "$BACKUP_DIR/frontend/node_modules" "$STAGE_DIR/frontend/node_modules"
  fi
fi

# Die Arbeitskopie gehoert immer dem aktuellen Prozessbenutzer und wird nach
# erfolgreicher Uebernahme sofort entfernt.
rm -rf "$WORK_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log ""
  log "PATCH_ONLY: Source wurde gepatcht und erfolgreich gebaut; kein /strom-test/-Deploy und keine Rueckfrage."
  exit 0
fi

log "6) Stage nach /strom-test/ bauen und deployen..."
log "Build-Umgebung verwendet Node v$NODE_VERSION aus $NODE_BIN"
if [ -x "$DEPLOY_DIR/strom_stage_build_test.sh" ]; then
  "$DEPLOY_DIR/strom_stage_build_test.sh" >>"$DIAG_LOG" 2>&1
elif [ -x "$STAGE_DIR/tools/strom_stage_build_test.sh" ]; then
  "$STAGE_DIR/tools/strom_stage_build_test.sh" >>"$DIAG_LOG" 2>&1
else
  log "Kein strom_stage_build_test.sh gefunden. Fuehre direkten Vite-Build aus."
  run_frontend_build "$STAGE_DIR/frontend" >>"$DIAG_LOG" 2>&1 || fail "Direkter Stage-Build fehlgeschlagen"
  [ -d "$STAGE_DIR/frontend/dist" ] || fail "frontend/dist nach Build nicht gefunden"
  run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Deploy nach $WEB_TEST_DIR fehlgeschlagen"
fi

log ""
log "Update 136 wurde erfolgreich in Stage gebaut und deployed. Produktion wurde nicht geaendert."
log ""
log "Bitte in https://home.moja.de/strom-test/ testen:"
log "  1. Blueprint Werkzeugleiste: SVG-Tuericon (Quickinfo per Mouseover)."
log "  2. Tuerwerkzeug: Breite und Hoehe in mm eintragen, Wand zwischen zwei Raeumen anklicken."
log "  3. Gemeinsame Kanten trotz unterschiedlicher Laengen und Richtungen erkennen."
log "  4. Blueprint: Tuer sofort sehen, Wanddetail: Tueren auf beiden Wandseiten sichtbar."
log "  5. Tuer-Unterkante exakt 0 mm, Oberkante durch Eingabehoehe bestimmt."
log "  6. Blueprint/Navigationsicons als SVG aus der abgestimmten Designvorlage, mit Quickinfos."
log "  7. Vorhandene Raeume, Treppen, Wanddetail und Produktion bleiben unveraendert."
log ""
read -r -p "Test in /strom-test/ bestanden? [j/N] " answer
case "$answer" in
  j|J|ja|JA|Ja)
    log "OK: Stage bleibt mit Update 136 aktiv."
    log "Zur spaeteren Uebernahme in Produktion separat:"
    log "  cd ~/deploy"
    log "  ./strom_stage_promote_to_prod.sh"
    ;;
  *)
    log "Test nicht bestaetigt. Produktion bleibt unveraendert."
    log "Stage-Backup: $BACKUP_DIR"
    log "Diagnose: $DIAG_LOG"
    exit 1
    ;;
esac
