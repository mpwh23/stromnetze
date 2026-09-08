#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20260908-1715_135a_strom_outerdoor_blueprint_stairs_buildfix"
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
COMMIT_MESSAGE="Update 135a: Buildfix fuer Blueprint-Treppen, Aussenwand-Tuerskalierung, SSH-Multiplexing"
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
  echo "2) Aktuellen Stage-Source + Update 135a nach GitHub pushen ..."
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

  echo "1.3) Update 135a auf Git-Source anwenden und Build pruefen ..."
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
log "Ziel: 135a Buildfix fuer Aussenwand-Tuerskalierung, hoehenabhaengige Blueprint-Treppen und gebuendelte SSH-Anmeldung."
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

work = Path(os.environ['WORK_DIR'])
app = work / 'frontend/src/App.tsx'
css = work / 'frontend/src/styles.css'

s = app.read_text()


def replace_between(text: str, start_marker: str, end_marker: str, replacement: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f'Start-Marker nicht gefunden: {start_marker}')
    end = text.find(end_marker, start + len(start_marker))
    if end < 0:
        raise SystemExit(f'End-Marker nicht gefunden: {end_marker}')
    return text[:start] + replacement.rstrip() + '\n\n' + text[end:]

# A) Treppenhaus-3D: ganze Treppenraumwaende eindeutig vor/hinter der Treppe.
old_scene = r'''  const wallDepthScene = useMemo(() => [
    ...visibleWallFacePieces.map((entry) => ({ kind: 'wall' as const, depth: entry.face.avgDepth, entry })),
    ...projectedStairObjects.map((entry) => ({ kind: 'stair' as const, depth: entry.avgDepth, entry })),
  ].sort((a, b) => b.depth - a.depth), [visibleWallFacePieces, projectedStairObjects])'''
new_scene = r'''  const stairRoomDepthById = useMemo(() => {
    const result = new Map<string, number>()
    projectedRooms.forEach((entry) => {
      if (isStairRoom(entry.room)) result.set(entry.room.id, entry.avgDepth)
    })
    return result
  }, [projectedRooms])

  const wallDepthScene = useMemo(() => {
    const stairEntries = projectedStairObjects.map((entry) => ({
      kind: 'stair' as const,
      depth: entry.avgDepth,
      layer: 1,
      entry,
    }))
    const wallEntries = visibleWallFacePieces.map((entry) => {
      const stairRoomDepth = stairRoomDepthById.get(entry.face.room.id)
      if (stairRoomDepth === undefined) {
        return { kind: 'wall' as const, depth: entry.face.avgDepth, layer: 1, entry }
      }
      const behindStair = entry.face.avgDepth >= stairRoomDepth
      return {
        kind: 'wall' as const,
        depth: entry.face.avgDepth,
        layer: behindStair ? 2 : 0,
        entry,
      }
    })
    return [...wallEntries, ...stairEntries].sort((a, b) => {
      if (a.layer !== b.layer) return b.layer - a.layer
      return b.depth - a.depth
    })
  }, [visibleWallFacePieces, projectedStairObjects, stairRoomDepthById])'''
if old_scene in s:
    s = s.replace(old_scene, new_scene, 1)
elif 'const stairRoomDepthById = useMemo(() =>' not in s and 'const stairGeometryDepthByRoomId = useMemo(() =>' not in s:
    raise SystemExit('Konnte vorhandene wallDepthScene-Tiefensortierung nicht finden.')

# B) Ecktreppen/Biegungen: radiale vertikale Setzstufen.
old_turn_riser = r'''      polygons.push({
        role: 'riser',
        points: [
          { x: startPoint.x, y: startPoint.y, z: zPrev },
          { x: endPoint.x, y: endPoint.y, z: zPrev },
          { x: endPoint.x, y: endPoint.y, z: zNext },
          { x: startPoint.x, y: startPoint.y, z: zNext },
        ],
      })'''
new_turn_riser = r'''      polygons.push({
        role: 'riser',
        points: [
          { x: origin.x, y: origin.y, z: zPrev },
          { x: startPoint.x, y: startPoint.y, z: zPrev },
          { x: startPoint.x, y: startPoint.y, z: zNext },
          { x: origin.x, y: origin.y, z: zNext },
        ],
      })'''
if old_turn_riser in s:
    s = s.replace(old_turn_riser, new_turn_riser, 1)
elif "{ x: origin.x, y: origin.y, z: zPrev }" not in s:
    raise SystemExit('Konnte Setzstufen-Geometrie der Biegung nicht finden.')

# C) Raumwand <-> Aussenwand als physisches Paar trotz Versatz/anderer Laenge.
outer_pair_helper = r'''function wallObjectPairInfo(
  sourceRoom: Room,
  sourceEdge: { a: PointM; b: PointM },
  targetRoom: Room,
  targetEdge: { a: PointM; b: PointM },
): WallEdgePairInfo | null {
  const normalPair = wallEdgePairInfo(sourceEdge, targetEdge)
  if (normalPair?.paired) return normalPair
  if (!isOuterWallRoom(sourceRoom) && !isOuterWallRoom(targetRoom)) return null

  const ax = sourceEdge.b.x - sourceEdge.a.x
  const ay = sourceEdge.b.y - sourceEdge.a.y
  const bx = targetEdge.b.x - targetEdge.a.x
  const by = targetEdge.b.y - targetEdge.a.y
  const lenA = Math.hypot(ax, ay)
  const lenB = Math.hypot(bx, by)
  if (lenA < 0.2 || lenB < 0.2) return null
  const dot = (ax * bx + ay * by) / (lenA * lenB)
  if (Math.abs(dot) < 0.985) return null

  const ux = ax / lenA
  const uy = ay / lenA
  const normalA = Math.abs((targetEdge.a.x - sourceEdge.a.x) * uy - (targetEdge.a.y - sourceEdge.a.y) * ux)
  const normalB = Math.abs((targetEdge.b.x - sourceEdge.a.x) * uy - (targetEdge.b.y - sourceEdge.a.y) * ux)
  const normalDistance = (normalA + normalB) / 2
  const allowedNormalDistance = Math.max(
    0.42,
    Math.max(sourceRoom.wallThicknessM || 0, targetRoom.wallThicknessM || 0) * 2 + 0.12,
  )
  if (normalDistance > allowedNormalDistance) return null

  const t0 = (targetEdge.a.x - sourceEdge.a.x) * ux + (targetEdge.a.y - sourceEdge.a.y) * uy
  const t1 = (targetEdge.b.x - sourceEdge.a.x) * ux + (targetEdge.b.y - sourceEdge.a.y) * uy
  const overlap = Math.max(0, Math.min(lenA, Math.max(t0, t1)) - Math.max(0, Math.min(t0, t1)))
  const requiredOverlap = Math.min(0.30, Math.min(lenA, lenB) * 0.28)
  if (overlap < requiredOverlap) return null

  return { paired: true, reversed: dot < 0 }
}
'''
if 'function wallObjectPairInfo(' not in s:
    anchor = 'function pairedWallLocations(floorId: string, sourceRoom: Room, sourceEdgeIndex: number, rooms: Room[]): WallFaceLocation[] {'
    if anchor not in s:
        raise SystemExit('Konnte pairedWallLocations nicht finden.')
    s = s.replace(anchor, outer_pair_helper + '\n' + anchor, 1)

s = s.replace(
    '      const pair = wallEdgePairInfo(sourceEdge, otherEdge)\n      if (!pair?.paired) return',
    '      const pair = wallObjectPairInfo(sourceRoom, sourceEdge, room, otherEdge)\n      if (!pair?.paired) return',
    1,
)
s = s.replace(
    '      if (!sourceEdge || !wallEdgePairInfo(targetEdge, sourceEdge)?.paired) return',
    '      if (!sourceEdge || !wallObjectPairInfo(targetRoom, targetEdge, room, sourceEdge)?.paired) return',
    1,
)
old_face_pair = '      if (!otherEdge || !samePhysicalWallEdge(faceEdge, otherEdge)) return'
if old_face_pair in s:
    s = s.replace(old_face_pair, '      if (!otherEdge || !wallObjectPairInfo(face.room, faceEdge, room, otherEdge)?.paired) return', 1)

# findOpeningPartnerFace bekommt sourceRoom/candidateRoom bereits aus 131/132.
old_partner_pair = '    const pair = wallEdgePairInfo(faceEdge, candidateEdge)\n    if (!pair?.paired) return []'
if old_partner_pair in s:
    s = s.replace(old_partner_pair, '    const pair = wallObjectPairInfo(sourceRoom, faceEdge, candidateRoom, candidateEdge)\n    if (!pair?.paired) return []', 1)

old_hover = "  return Boolean(hoveredEdge && faceEdge && wallEdgePairInfo(hoveredEdge, faceEdge)?.paired)"
if old_hover in s:
    s = s.replace(old_hover, "  return Boolean(hoveredRoom && hoveredEdge && faceEdge && wallObjectPairInfo(hoveredRoom, hoveredEdge, face.room, faceEdge)?.paired)", 1)

# D) 134: Treppenhaus-Tiefenlogik robust machen.
scene_133 = r'''  const stairRoomDepthById = useMemo(() => {
    const result = new Map<string, number>()
    projectedRooms.forEach((entry) => {
      if (isStairRoom(entry.room)) result.set(entry.room.id, entry.avgDepth)
    })
    return result
  }, [projectedRooms])

  const wallDepthScene = useMemo(() => {
    const stairEntries = projectedStairObjects.map((entry) => ({
      kind: 'stair' as const,
      depth: entry.avgDepth,
      layer: 1,
      entry,
    }))
    const wallEntries = visibleWallFacePieces.map((entry) => {
      const stairRoomDepth = stairRoomDepthById.get(entry.face.room.id)
      if (stairRoomDepth === undefined) {
        return { kind: 'wall' as const, depth: entry.face.avgDepth, layer: 1, entry }
      }
      const behindStair = entry.face.avgDepth >= stairRoomDepth
      return {
        kind: 'wall' as const,
        depth: entry.face.avgDepth,
        layer: behindStair ? 2 : 0,
        entry,
      }
    })
    return [...wallEntries, ...stairEntries].sort((a, b) => {
      if (a.layer !== b.layer) return b.layer - a.layer
      return b.depth - a.depth
    })
  }, [visibleWallFacePieces, projectedStairObjects, stairRoomDepthById])'''
scene_134 = r'''  const stairGeometryDepthByRoomId = useMemo(() => {
    const grouped = new Map<string, number[]>()
    projectedStairObjects.forEach((entry) => {
      const values = grouped.get(entry.roomId) ?? []
      values.push(entry.avgDepth)
      grouped.set(entry.roomId, values)
    })
    const result = new Map<string, number>()
    grouped.forEach((values, roomId) => {
      const sorted = [...values].sort((a, b) => a - b)
      const middle = Math.floor(sorted.length / 2)
      const median = sorted.length % 2 === 0
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle]
      result.set(roomId, median)
    })
    return result
  }, [projectedStairObjects])

  const stairFaceRoomByFaceId = useMemo(() => {
    const result = new Map<string, string>()
    projectedWallFaces.forEach((face) => {
      if (face.modelFaceId && isStairRoom(face.room)) result.set(face.modelFaceId, face.room.id)
    })
    projectedWallFaces.forEach((face) => {
      if (!face.modelFaceId || isStairRoom(face.room)) return
      const partner = projectedWallFaces.find((candidate) =>
        Boolean(candidate.modelFaceId)
        && isStairRoom(candidate.room)
        && (face.pairedFaceIds ?? []).includes(candidate.modelFaceId!),
      )
      if (partner?.modelFaceId) result.set(face.modelFaceId, partner.room.id)
    })
    return result
  }, [projectedWallFaces])

  const stairReferenceFaceDepth = useMemo(() => {
    const result = new Map<string, number>()
    projectedWallFaces.forEach((face) => {
      if (!face.modelFaceId || !isStairRoom(face.room)) return
      result.set(face.modelFaceId, face.avgDepth)
      ;(face.pairedFaceIds ?? []).forEach((pairedId) => result.set(pairedId, face.avgDepth))
    })
    return result
  }, [projectedWallFaces])

  const wallDepthScene = useMemo(() => {
    const stairEntries = projectedStairObjects.map((entry) => ({
      kind: 'stair' as const,
      depth: entry.avgDepth,
      layer: 2,
      entry,
    }))
    const wallEntries = visibleWallFacePieces.map((entry) => {
      const faceId = entry.face.modelFaceId
      const stairRoomId = faceId ? stairFaceRoomByFaceId.get(faceId) : undefined
      if (!stairRoomId) {
        return { kind: 'wall' as const, depth: entry.face.avgDepth, layer: 2, entry }
      }
      const stairDepth = stairGeometryDepthByRoomId.get(stairRoomId)
      const referenceFaceDepth = faceId ? stairReferenceFaceDepth.get(faceId) : undefined
      if (stairDepth === undefined || referenceFaceDepth === undefined) {
        return { kind: 'wall' as const, depth: entry.face.avgDepth, layer: 2, entry }
      }
      const behindStair = referenceFaceDepth >= stairDepth
      return {
        kind: 'wall' as const,
        depth: entry.face.avgDepth,
        layer: behindStair ? 3 : 1,
        entry,
      }
    })
    return [...wallEntries, ...stairEntries].sort((a, b) => {
      if (a.layer !== b.layer) return b.layer - a.layer
      return b.depth - a.depth
    })
  }, [visibleWallFacePieces, projectedStairObjects, projectedWallFaces, stairGeometryDepthByRoomId, stairFaceRoomByFaceId, stairReferenceFaceDepth])'''
if scene_133 in s:
    s = s.replace(scene_133, scene_134, 1)
elif 'const stairGeometryDepthByRoomId = useMemo(() =>' not in s:
    raise SystemExit('Konnte 133-Tiefensortierung nicht finden.')

# E) 134: Partnerflaeche fuer Tueren/Durchbrueche stabil ueber groupId waehlen.
partner_134 = r'''function findOpeningPartnerFace(
  face: RenderedWallFace,
  item: WallPlacedObject,
  faces: RenderedWallFace[],
  floorId: string,
  rooms: Room[],
  wallObjectsByKey: Record<string, WallPlacedObject[]>,
): { face: RenderedWallFace; item: WallPlacedObject } | null {
  const sourceRoom = rooms.find((room) => room.id === face.room.id) ?? face.room
  const faceEdge = edgePoints(sourceRoom.vertices, face.edgeIndex)
  if (!faceEdge) return null

  const candidates = faces.flatMap((candidate) => {
    if (candidate.modelFaceId === face.modelFaceId) return []
    const candidateRoom = rooms.find((room) => room.id === candidate.room.id) ?? candidate.room
    const candidateEdge = edgePoints(candidateRoom.vertices, candidate.edgeIndex)
    if (!candidateEdge) return []
    const pair = wallObjectPairInfo(sourceRoom, faceEdge, candidateRoom, candidateEdge)
    if (!pair?.paired) return []

    const candidateKey = wallObjectKey(floorId, candidateRoom.id, candidate.edgeIndex)
    const ownPartner = item.groupId
      ? (wallObjectsByKey[candidateKey] ?? []).find((candidateItem) => candidateItem.groupId === item.groupId)
      : undefined
    const projectedItem = projectWallPlacedObjectBetweenRooms(item, sourceRoom, face.edgeIndex, candidateRoom, candidate.edgeIndex)
    const pairScore = wallPairPlacementScore(faceEdge, candidateEdge)
    const groupBonus = ownPartner ? 100000 : 0
    const outerBonus = isOuterWallRoom(sourceRoom) !== isOuterWallRoom(candidateRoom) ? 2500 : 0
    const centerDistance = openingCenterDistance(face.points, item, candidate.points, projectedItem)
    return [{ face: candidate, item: projectedItem, score: groupBonus + outerBonus + pairScore * 10 - centerDistance }]
  })
  if (candidates.length === 0) return null
  candidates.sort((a, b) => b.score - a.score)
  return { face: candidates[0].face, item: candidates[0].item }
}'''
if 'function findOpeningPartnerFace(' in s:
    s = replace_between(s, 'function findOpeningPartnerFace(', 'function openingCenterDistance(', partner_134)
else:
    raise SystemExit('Konnte findOpeningPartnerFace nicht finden.')

# F) 134: Blueprint-Tueren auch an Aussenwaenden anzeigen.
blueprint_134 = r'''function BlueprintWallObjectConnections({ wallObjects, rooms }: { wallObjects: ApiWallObject[]; rooms: Room[] }) {
  const byGroup = wallObjects
    .filter((item) => item.objectType === 'door' && item.groupId && !isFullWallOpenGroupId(item.groupId))
    .reduce<Record<string, ApiWallObject[]>>((acc, item) => {
      const key = item.groupId || item.id
      acc[key] = [...(acc[key] ?? []), item]
      return acc
    }, {})

  const connectors = Object.entries(byGroup).flatMap(([groupId, groupItems]) => {
    const actualSegments = groupItems
      .map((item) => blueprintWallObjectSegment(item, rooms))
      .filter((segment): segment is BlueprintWallSegment => Boolean(segment))
    if (actualSegments.length === 0) return []

    let pair: { a: BlueprintWallSegment; b: BlueprintWallSegment } | null = null
    if (actualSegments.length >= 2) {
      pair = bestBlueprintConnectionPair(actualSegments)
    } else {
      const synthetic = synthesizeBlueprintDoorPartner(actualSegments[0], rooms)
      if (synthetic) pair = { a: actualSegments[0], b: synthetic }
    }
    if (!pair) return []

    const normalized = normalizeBlueprintConnectionPair(pair.a, pair.b)
    return [{ groupId, points: [normalized.a.left, normalized.a.right, normalized.b.right, normalized.b.left], edgeA: normalized.a, edgeB: normalized.b }]
  })

  if (connectors.length === 0) return null
  return (
    <g className="blueprint-wall-object-connections" aria-label="Wanddetail-Durchgaenge">
      {connectors.map((connector) => (
        <g key={connector.groupId}>
          <polygon
            points={connector.points.map((point) => `${mToX(point.x)},${mToY(point.y)}`).join(' ')}
            className="blueprint-wall-connection-door"
          />
          <line x1={mToX(connector.edgeA.left.x)} y1={mToY(connector.edgeA.left.y)} x2={mToX(connector.edgeA.right.x)} y2={mToY(connector.edgeA.right.y)} className="blueprint-wall-door-edge" />
          <line x1={mToX(connector.edgeB.left.x)} y1={mToY(connector.edgeB.left.y)} x2={mToX(connector.edgeB.right.x)} y2={mToY(connector.edgeB.right.y)} className="blueprint-wall-door-edge" />
        </g>
      ))}
    </g>
  )
}

type BlueprintWallSegment = {
  left: PointM
  right: PointM
  edge: { a: PointM; b: PointM }
  room: Room
  edgeIndex: number
  sourceItem: ApiWallObject
}

function blueprintWallObjectSegment(item: ApiWallObject, rooms: Room[]): BlueprintWallSegment | null {
  const room = rooms.find((candidate) => candidate.id === item.roomId)
  if (!room || room.vertices.length < 2) return null
  const edge = edgePoints(room.vertices, item.edgeIndex)
  if (!edge) return null
  const len = distance(edge.a, edge.b)
  if (len < 0.0001) return null
  const t = clamp(item.x, 0, 1)
  const half = clamp(item.w / 2, 0.005, 0.495)
  const leftT = clamp(t - half, 0, 1)
  const rightT = clamp(t + half, 0, 1)
  const pointAt = (value: number): PointM => ({
    x: round3(edge.a.x + (edge.b.x - edge.a.x) * value),
    y: round3(edge.a.y + (edge.b.y - edge.a.y) * value),
  })
  return { left: pointAt(leftT), right: pointAt(rightT), edge, room, edgeIndex: item.edgeIndex, sourceItem: item }
}

function synthesizeBlueprintDoorPartner(source: BlueprintWallSegment, rooms: Room[]): BlueprintWallSegment | null {
  const sourcePlaced: WallPlacedObject = {
    id: source.sourceItem.id,
    type: 'door',
    x: source.sourceItem.x,
    y: source.sourceItem.y,
    w: source.sourceItem.w,
    h: source.sourceItem.h,
    groupId: source.sourceItem.groupId || undefined,
  }
  const candidates = rooms.flatMap((room) => room.vertices.map((_, edgeIndex) => {
    if (room.id === source.room.id && edgeIndex === source.edgeIndex) return null
    const targetEdge = edgePoints(room.vertices, edgeIndex)
    if (!targetEdge) return null
    const pair = wallObjectPairInfo(source.room, source.edge, room, targetEdge)
    if (!pair?.paired) return null
    const mapped = projectWallPlacedObjectBetweenRooms(sourcePlaced, source.room, source.edgeIndex, room, edgeIndex)
    const leftT = clamp(mapped.x - mapped.w / 2, 0, 1)
    const rightT = clamp(mapped.x + mapped.w / 2, 0, 1)
    const pointAt = (value: number): PointM => ({
      x: round3(targetEdge.a.x + (targetEdge.b.x - targetEdge.a.x) * value),
      y: round3(targetEdge.a.y + (targetEdge.b.y - targetEdge.a.y) * value),
    })
    const outerBonus = isOuterWallRoom(source.room) !== isOuterWallRoom(room) ? 10000 : 0
    return {
      segment: { left: pointAt(leftT), right: pointAt(rightT), edge: targetEdge, room, edgeIndex, sourceItem: source.sourceItem } as BlueprintWallSegment,
      score: outerBonus + wallPairPlacementScore(source.edge, targetEdge),
    }
  }).filter((candidate): candidate is { segment: BlueprintWallSegment; score: number } => Boolean(candidate)))
  if (candidates.length === 0) return null
  candidates.sort((a, b) => b.score - a.score)
  return candidates[0].segment
}

function bestBlueprintConnectionPair(segments: BlueprintWallSegment[]) {
  let best = { a: segments[0], b: segments[1], score: Number.POSITIVE_INFINITY }
  for (let i = 0; i < segments.length; i += 1) {
    for (let j = i + 1; j < segments.length; j += 1) {
      const a = segments[i]
      const b = segments[j]
      const centerA = { x: (a.left.x + a.right.x) / 2, y: (a.left.y + a.right.y) / 2 }
      const centerB = { x: (b.left.x + b.right.x) / 2, y: (b.left.y + b.right.y) / 2 }
      const outerBonus = isOuterWallRoom(a.room) !== isOuterWallRoom(b.room) ? -1000 : 0
      const score = distance(centerA, centerB) + outerBonus
      if (score < best.score) best = { a, b, score }
    }
  }
  return { a: best.a, b: best.b }
}

function normalizeBlueprintConnectionPair(a: BlueprintWallSegment, b: BlueprintWallSegment) {
  const axisDx = a.edge.b.x - a.edge.a.x
  const axisDy = a.edge.b.y - a.edge.a.y
  const axisLen = Math.hypot(axisDx, axisDy) || 1
  const ux = axisDx / axisLen
  const uy = axisDy / axisLen
  const origin = a.edge.a
  const scalar = (point: PointM) => (point.x - origin.x) * ux + (point.y - origin.y) * uy
  const sorted = (left: PointM, right: PointM) => {
    const values = [scalar(left), scalar(right)].sort((x, y) => x - y)
    return { min: values[0], max: values[1] }
  }
  const intervalA = sorted(a.left, a.right)
  const intervalB = sorted(b.left, b.right)
  const edgeA = sorted(a.edge.a, a.edge.b)
  const edgeB = sorted(b.edge.a, b.edge.b)
  const overlapMin = Math.max(edgeA.min, edgeB.min)
  const overlapMax = Math.min(edgeA.max, edgeB.max)
  if (overlapMax - overlapMin < 0.001) return alignBlueprintSegmentPair(a, b)

  const commonCenter = clamp(((intervalA.min + intervalA.max) + (intervalB.min + intervalB.max)) / 4, overlapMin, overlapMax)
  const widthA = Math.max(0.01, intervalA.max - intervalA.min)
  const widthB = Math.max(0.01, intervalB.max - intervalB.min)
  const commonWidth = Math.min(widthA, widthB, Math.max(0.01, overlapMax - overlapMin))
  let commonMin = clamp(commonCenter - commonWidth / 2, overlapMin, overlapMax)
  let commonMax = clamp(commonCenter + commonWidth / 2, overlapMin, overlapMax)
  if (commonMax - commonMin < commonWidth * 0.95) {
    if (commonMin <= overlapMin + 0.0001) commonMax = clamp(commonMin + commonWidth, overlapMin, overlapMax)
    else commonMin = clamp(commonMax - commonWidth, overlapMin, overlapMax)
  }

  const pointOnEdge = (edge: { a: PointM; b: PointM }, targetScalar: number): PointM => {
    const aScalar = scalar(edge.a)
    const bScalar = scalar(edge.b)
    const denom = bScalar - aScalar
    const t = Math.abs(denom) < 0.000001 ? 0 : clamp((targetScalar - aScalar) / denom, 0, 1)
    return { x: round3(edge.a.x + (edge.b.x - edge.a.x) * t), y: round3(edge.a.y + (edge.b.y - edge.a.y) * t) }
  }

  return {
    a: { ...a, left: pointOnEdge(a.edge, commonMin), right: pointOnEdge(a.edge, commonMax) },
    b: { ...b, left: pointOnEdge(b.edge, commonMin), right: pointOnEdge(b.edge, commonMax) },
  }
}

function alignBlueprintSegmentPair(a: BlueprintWallSegment, b: BlueprintWallSegment) {
  const same = distance(a.left, b.left) + distance(a.right, b.right)
  const swapped = distance(a.left, b.right) + distance(a.right, b.left)
  if (swapped < same) return { a, b: { ...b, left: b.right, right: b.left } }
  return { a, b }
}
'''
if 'function BlueprintWallObjectConnections(' in s:
    s = replace_between(s, 'function BlueprintWallObjectConnections(', 'type WallSelection = { roomId: string; edgeIndex: number }', blueprint_134)
else:
    raise SystemExit('Konnte BlueprintWallObjectConnections nicht finden.')


# G) 135: Aussenwand-Tueren in realen Wandmetern auf die Gegenwand uebertragen.
project_start = s.find('function projectWallPlacedObjectBetweenRooms(')
project_end = s.find('\nfunction ', project_start + 1)
if project_start < 0:
    raise SystemExit('Konnte projectWallPlacedObjectBetweenRooms nicht finden.')
if project_end < 0:
    project_end = len(s)
project_block = s[project_start:project_end]
old_pair_line = '  const pair = wallEdgePairInfo(sourceEdge, targetEdge)'
new_pair_line = '  const pair = wallObjectPairInfo(sourceRoom, sourceEdge, targetRoom, targetEdge)'
if old_pair_line in project_block:
    project_block = project_block.replace(old_pair_line, new_pair_line, 1)
elif new_pair_line not in project_block:
    raise SystemExit('Konnte Paarpruefung in projectWallPlacedObjectBetweenRooms nicht aktualisieren.')
s = s[:project_start] + project_block + s[project_end:]

# Bestehende Aussenwand-Tueren fuer die 3D-Darstellung von der inneren Raumwand
# als physischer Referenz auf die Aussenwand projizieren. So bleibt die reale
# Tuerbreite auf unterschiedlich langen Wandflaechen identisch.
wall_objects_135 = r'''function wallObjectsForFace(face: RenderedWallFace, floorId: string, rooms: Room[], wallObjectsByKey: Record<string, WallPlacedObject[]>) {
  const targetKey = wallObjectKey(floorId, face.room.id, face.edgeIndex)
  const targetEdge = edgePoints(face.room.vertices, face.edgeIndex)
  const ownObjects = wallObjectsByKey[targetKey] ?? []
  if (!targetEdge) return ownObjects

  type SourceCandidate = { room: Room; edgeIndex: number; item: WallPlacedObject; own: boolean }
  const candidates: SourceCandidate[] = []
  rooms.forEach((room) => {
    room.vertices.forEach((_, edgeIndex) => {
      const sourceEdge = edgePoints(room.vertices, edgeIndex)
      if (!sourceEdge || !wallObjectPairInfo(face.room, targetEdge, room, sourceEdge)?.paired) return
      const key = wallObjectKey(floorId, room.id, edgeIndex)
      ;(wallObjectsByKey[key] ?? []).forEach((item) => candidates.push({
        room,
        edgeIndex,
        item,
        own: room.id === face.room.id && edgeIndex === face.edgeIndex,
      }))
    })
  })

  const groups = new Map<string, SourceCandidate[]>()
  const ungrouped: SourceCandidate[] = []
  candidates.forEach((candidate) => {
    const groupId = candidate.item.groupId
    if (!groupId) {
      if (candidate.own) ungrouped.push(candidate)
      return
    }
    groups.set(groupId, [...(groups.get(groupId) ?? []), candidate])
  })

  const result: WallPlacedObject[] = ungrouped.map((candidate) => candidate.item)
  groups.forEach((groupCandidates, groupId) => {
    const own = groupCandidates.find((candidate) => candidate.own)
    const inner = groupCandidates.find((candidate) => !isOuterWallRoom(candidate.room))
    const source = isOuterWallRoom(face.room) ? (inner ?? own ?? groupCandidates[0]) : (own ?? inner ?? groupCandidates[0])
    if (!source) return
    const mapped = projectWallPlacedObjectBetweenRooms(source.item, source.room, source.edgeIndex, face.room, face.edgeIndex)
    result.push({
      ...mapped,
      id: own?.item.id ?? `${source.item.id}-mirror-${face.room.id}-${face.edgeIndex}`,
      groupId,
    })
  })
  return result
}'''
if 'function wallObjectsForFace(' not in s:
    raise SystemExit('Konnte wallObjectsForFace nicht finden.')
s = replace_between(s, 'function wallObjectsForFace(', 'function samePhysicalWallEdge(', wall_objects_135)

# H) 135: Blueprint-Treppe als senkrechte Draufsicht der echten 3D-Stufen.
room_call_old = '''                    ghost={renderState.ghost}
                  />'''
room_call_new = '''                    ghost={renderState.ghost}
                    floorHeightM={floor.heightM}
                  />'''
if room_call_old in s:
    s = s.replace(room_call_old, room_call_new, 1)
elif 'floorHeightM={floor.heightM}' not in s:
    raise SystemExit('Konnte RoomShape-Aufruf fuer floorHeightM nicht erweitern.')

param_old = '''  ghost = false,
}: {'''
param_new = '''  ghost = false,
  floorHeightM = 2.7,
}: {'''
if param_old in s:
    s = s.replace(param_old, param_new, 1)
elif 'floorHeightM = 2.7' not in s:
    raise SystemExit('Konnte RoomShape-Parameter nicht erweitern.')

room_shape_pos = s.find('function RoomShape({')
if room_shape_pos < 0:
    raise SystemExit('Konnte RoomShape nicht finden.')
room_shape_end = s.find('}) {', room_shape_pos)
room_shape_sig = s[room_shape_pos:room_shape_end + 4]
if 'floorHeightM?: number' not in room_shape_sig:
    old_tail = '  ghost?: boolean\n}) {'
    new_tail = '  ghost?: boolean\n  floorHeightM?: number\n}) {'
    if old_tail not in room_shape_sig:
        raise SystemExit('Konnte RoomShape-Prop-Typ nicht erweitern.')
    room_shape_sig = room_shape_sig.replace(old_tail, new_tail, 1)
    s = s[:room_shape_pos] + room_shape_sig + s[room_shape_end + 4:]

old_layout_call = '{stairRoom && bounds && stairLayoutElements.length > 0 && <StairBlueprintLayoutOverlay room={room} elements={stairLayoutElements} />}'
new_layout_call = '{stairRoom && bounds && stairLayoutElements.length > 0 && <StairBlueprintHeightOverlay135 room={room} elements={stairLayoutElements} roomHeightM={floorHeightM} />}'
if old_layout_call in s:
    s = s.replace(old_layout_call, new_layout_call, 1)
elif new_layout_call not in s:
    raise SystemExit('Konnte StairBlueprintLayoutOverlay-Aufruf nicht ersetzen.')

old_visibility_call = '{stairRoom && bounds && stairLayoutElements.length > 0 && <StairBlueprintVisibilityOverlay room={room} elements={stairLayoutElements} />}'
if old_visibility_call in s:
    s = s.replace(old_visibility_call, '', 1)

blueprint_stair_135 = r'''function stairBlueprintOpacityForRelativeHeight135(relativeHeightM: number, roomHeightM: number) {
  const safeHeight = Math.max(0.05, roomHeightM)
  const relative = Math.abs(relativeHeightM) / safeHeight
  if (relative <= 0.25) return 1
  if (relative >= 0.5) return 0
  return clamp(round3(1 - (relative - 0.25) / 0.25), 0, 1)
}

type StairBlueprintPolygon135 = {
  key: string
  role: 'landing' | 'tread'
  zM: number
  opacity: number
  points: Vec3[]
}

function StairBlueprintHeightOverlay135({ room, elements, roomHeightM }: { room: Room; elements: StairEditorElement[]; roomHeightM: number }) {
  const safeHeight = Math.max(0.05, roomHeightM)
  const polygons: StairBlueprintPolygon135[] = []
  const ordered = stairOrderedElementsForWallDetail(room, elements)

  ordered.forEach((element) => {
    stairElementPolygons3D(room, element, safeHeight, elements)
      .filter((entry) => entry.role === 'tread' || entry.role === 'landing')
      .forEach((entry, index) => {
        const zM = entry.points.reduce((sum, point) => sum + point.z, 0) / Math.max(1, entry.points.length)
        const opacity = stairBlueprintOpacityForRelativeHeight135(zM, safeHeight)
        if (opacity <= 0.001) return
        polygons.push({
          key: `${element.id}-${entry.role}-${index}`,
          role: entry.role === 'landing' ? 'landing' : 'tread',
          zM,
          opacity,
          points: entry.points,
        })
      })
  })

  polygons.sort((a, b) => a.zM - b.zM)
  return (
    <g className="stair-blueprint-height-overlay-135" aria-label="Treppenstufen nach Hoehe">
      {polygons.map((entry) => (
        <polygon
          key={entry.key}
          points={entry.points.map((point) => `${mToX(point.x)},${mToY(point.y)}`).join(' ')}
          className={`stair-blueprint-height-step-135 ${entry.role}`}
          style={{ opacity: entry.opacity }}
          data-height-m={round3(entry.zM)}
        />
      ))}
    </g>
  )
}
'''
if 'function StairBlueprintHeightOverlay135(' not in s:
    anchor135 = 'function DimensionLabels({ vertices, muted = false }: { vertices: PointM[]; muted?: boolean }) {'
    if anchor135 not in s:
        raise SystemExit('Konnte Einfuegepunkt fuer Blueprint-Treppenfunktion nicht finden.')
    s = s.replace(anchor135, blueprint_stair_135 + '\n' + anchor135, 1)


app.write_text(s)

c = css.read_text()
marker = '/* 133: stair depth, winder risers, outer wall doors */'
if marker in c:
    c = c[:c.index(marker)].rstrip() + '\n'
c += r'''

/* 133: stair depth, winder risers, outer wall doors */
.wall-detail-canvas .wall-detail-stair-riser {
  fill-opacity: 0.82;
  stroke-opacity: 0.82;
}
'''
marker134 = '/* 134: stair depth layers + exterior door blueprint */'
if marker134 in c:
    c = c[:c.index(marker134)].rstrip() + '\n'
c += r'''

/* 134: stair depth layers + exterior door blueprint */
.blueprint-wall-object-connections .blueprint-wall-door-edge {
  stroke: rgba(37, 99, 235, 0.95);
  stroke-width: 4;
  stroke-linecap: butt;
  stroke-dasharray: none !important;
}
'''

marker135 = '/* 135: outer door scaling + height based stair blueprint */'
if marker135 in c:
    c = c[:c.index(marker135)].rstrip() + '\n'
c += r'''

/* 135: outer door scaling + height based stair blueprint */
.stair-blueprint-height-overlay-135 {
  pointer-events: none;
}
.stair-blueprint-height-step-135 {
  fill: rgba(219, 234, 254, 0.34);
  stroke: rgba(37, 99, 235, 0.96);
  stroke-width: 1.4;
  stroke-linejoin: round;
  vector-effect: non-scaling-stroke;
}
.stair-blueprint-height-step-135.landing {
  fill: rgba(254, 249, 195, 0.46);
  stroke: rgba(180, 83, 9, 0.82);
}
'''
css.write_text(c)

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
log "Update 135a wurde erfolgreich in Stage gebaut und deployed. Produktion wurde nicht geaendert."
log ""
log "Bitte in https://home.moja.de/strom-test/ testen:"
log "  1. Aussenwand-Tuer: Innen- und Aussenkante haben dieselbe reale Tuerbreite; kein konischer Durchbruch."
log "  2. Blueprint-Treppe: Stufen entsprechen exakt der Draufsicht der 3D-Geometrie."
log "  3. Blueprint-Treppe: 0-25% Raumhoehe = 100% sichtbar; 25-50% linear ausblendend; >50% unsichtbar."
log "  4. Treppenhauswaende und Biegungs-Setzstufen aus 134 bleiben unveraendert korrekt."
log "  5. Blueprint-Aussenwandtuer, Speicherung, Auswahl und Popup bleiben korrekt."
log ""
read -r -p "Test in /strom-test/ bestanden? [j/N] " answer
case "$answer" in
  j|J|ja|JA|Ja)
    log "OK: Stage bleibt mit Update 135a aktiv."
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
