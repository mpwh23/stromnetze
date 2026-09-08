#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20260908-1040_132g_strom_wanddetail_temp_permissions_git_cleanup"
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
COMMIT_MESSAGE="Update 132g: Wanddetail 3D/Popup/Blueprint plus Temp-Rechte- und Git-Cleanup-Fix"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"

# -----------------------------------------------------------------------------
# Mac launcher
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

  REMOTE_TMP_SCRIPT="${REMOTE_TMP_DIR}/$(basename "$SELF_PATH")"
  REMOTE_DEPLOY_SCRIPT="${REMOTE_DEPLOY_DIR}/$(basename "$SELF_PATH")"

  echo "0) Temporaere Hilfskopie auf den Pi uebertragen ..."
  echo "   Nur fuer den Git-Push mit dem dort vorhandenen Deploy-Key; noch kein Stage-Deployment."
  scp "$SELF_PATH" "$REMOTE_HOST:$REMOTE_TMP_SCRIPT"

  echo ""
  echo "1) Aktuellen Stage-Source + Update 132g nach GitHub pushen ..."
  ssh -t "$REMOTE_HOST" "chmod +x '$REMOTE_TMP_SCRIPT' && '$REMOTE_TMP_SCRIPT' --git-phase"

  echo ""
  echo "2) Git-Push erfolgreich. Update-Script jetzt nach ~/deploy kopieren ..."
  scp "$SELF_PATH" "$REMOTE_HOST:$REMOTE_DEPLOY_SCRIPT"

  echo ""
  echo "3) Stage-Update auf dem Pi ausfuehren ..."
  ssh -t "$REMOTE_HOST" "rm -f '$REMOTE_TMP_SCRIPT'; chmod +x '$REMOTE_DEPLOY_SCRIPT'; cd '$REMOTE_DEPLOY_DIR'; './$(basename "$SELF_PATH")' --stage-phase"
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

  echo "1.3) Update 132g auf Git-Source anwenden und Build pruefen ..."
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
log "Ziel: 3D-Tiefensortierung, Treppenursprung, Wandobjekte im Popup, Wandoeffnung-Schraffur und Blueprint-Tuergeometrie."
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

# -----------------------------------------------------------------------------
# A) Popup: auch Objekte einer physisch gepaarten Gegenwand anzeigen.
# -----------------------------------------------------------------------------
old_selected = """  const selectedWallKey = selectedWall ? wallObjectKey(floor.id, selectedWall.roomId, selectedWall.edgeIndex) : ''\n  const selectedWallObjects = selectedWallKey ? wallObjectsByKey[selectedWallKey] ?? [] : []"""
new_selected = """  const selectedWallObjects = useMemo(() => {
    if (!selectedWall || !selectedWallRoom) return []
    return wallObjectsForSelectedWall(floor.id, selectedWallRoom, selectedWall.edgeIndex, wallDetailRooms, wallObjectsByKey)
  }, [floor.id, selectedWall, selectedWallRoom, wallDetailRooms, wallObjectsByKey])"""
if old_selected in s:
    s = s.replace(old_selected, new_selected, 1)
elif 'wallObjectsForSelectedWall(floor.id' not in s:
    raise SystemExit('Konnte selectedWallObjects-Block nicht finden.')

selected_helper = r'''function wallObjectsForSelectedWall(
  floorId: string,
  targetRoom: Room,
  targetEdgeIndex: number,
  rooms: Room[],
  wallObjectsByKey: Record<string, WallPlacedObject[]>,
) {
  const ownKey = wallObjectKey(floorId, targetRoom.id, targetEdgeIndex)
  const ownObjects = (wallObjectsByKey[ownKey] ?? []).map(normalizeWallPlacedObject)
  const result: WallPlacedObject[] = [...ownObjects]
  const seenIds = new Set(result.map((item) => item.id))
  const seenGroups = new Set(result.map((item) => item.groupId).filter((value): value is string => Boolean(value)))
  const targetEdge = edgePoints(targetRoom.vertices, targetEdgeIndex)
  if (!targetEdge) return result

  rooms.forEach((room) => {
    room.vertices.forEach((_, edgeIndex) => {
      if (room.id === targetRoom.id && edgeIndex === targetEdgeIndex) return
      const sourceEdge = edgePoints(room.vertices, edgeIndex)
      if (!sourceEdge || !wallEdgePairInfo(targetEdge, sourceEdge)?.paired) return
      const key = wallObjectKey(floorId, room.id, edgeIndex)
      ;(wallObjectsByKey[key] ?? []).forEach((item) => {
        if (seenIds.has(item.id)) return
        if (item.groupId && seenGroups.has(item.groupId)) return
        const mapped = projectWallPlacedObjectBetweenRooms(item, room, edgeIndex, targetRoom, targetEdgeIndex)
        result.push({ ...mapped, id: item.id })
        seenIds.add(item.id)
        if (item.groupId) seenGroups.add(item.groupId)
      })
    })
  })
  return result
}
'''
if 'function wallObjectsForSelectedWall(' not in s:
    anchor = 'type WallObjectEntry = { key: string; roomId: string; edgeIndex: number; item: WallPlacedObject }'
    if anchor not in s:
        raise SystemExit('Konnte WallObjectEntry nicht finden.')
    s = s.replace(anchor, selected_helper + '\n' + anchor, 1)

# -----------------------------------------------------------------------------
# B) Vollstaendige Wandoeffnung im Popup immer ueber die ganze Wand schraffieren.
# -----------------------------------------------------------------------------
s = s.replace("  const fullWallOpenRect = fullWallOpenPlacement ? wallObjectRect(fullWallOpenPlacement) : null\n", "", 1)
old_hatch = '''        {fullWallOpenRect && (
          <rect
            x={x + fullWallOpenRect.left * drawW}
            y={y + fullWallOpenRect.top * drawH}
            width={(fullWallOpenRect.right - fullWallOpenRect.left) * drawW}
            height={(fullWallOpenRect.bottom - fullWallOpenRect.top) * drawH}
            rx="1"
            className="wall-front-full-open-overlay"
          />
        )}'''
new_hatch = '''        {fullWallOpenPlacement && (
          <rect
            x={x}
            y={y}
            width={drawW}
            height={drawH}
            rx="1"
            className="wall-front-full-open-overlay"
            fill="url(#wall-front-fullopen-hatch)"
          />
        )}'''
if old_hatch in s:
    s = s.replace(old_hatch, new_hatch, 1)
elif 'fill="url(#wall-front-fullopen-hatch)"' not in s:
    raise SystemExit('Konnte Schraffur-Rechteck im Wand-Popup nicht finden.')

# -----------------------------------------------------------------------------
# C) Treppen-Biegung: denselben Ursprung wie im "Treppe einzeichnen" Canvas
#    verwenden. Der naechste gerade Treppenlauf bestimmt links/rechts.
# -----------------------------------------------------------------------------
neighbor_fn = r'''function stairNeighborSideForWallDetail(room: Room, target: StairEditorElement, elements: StairEditorElement[]): 'left' | 'right' {
  void room
  const rect = {
    left: target.xM,
    top: target.yM,
    right: target.xM + target.widthM,
    bottom: target.yM + target.heightM,
  }
  const centerX = target.xM + target.widthM / 2
  const centerY = target.yM + target.heightM / 2
  const candidates = elements
    .filter((candidate) => candidate.id !== target.id && candidate.kind === 'stair')
    .map((candidate) => {
      const candidateCenterX = candidate.xM + candidate.widthM / 2
      const candidateCenterY = candidate.yM + candidate.heightM / 2
      const verticalOverlap = Math.max(0, Math.min(rect.bottom, candidate.yM + candidate.heightM) - Math.max(rect.top, candidate.yM))
      const gap = candidateCenterX > centerX
        ? Math.max(0, candidate.xM - rect.right)
        : Math.max(0, rect.left - (candidate.xM + candidate.widthM))
      const score = gap + Math.abs(candidateCenterY - centerY) * 0.25 - verticalOverlap * 0.6
      return { candidateCenterX, score }
    })
    .sort((a, b) => a.score - b.score)
  return candidates[0]
    ? (candidates[0].candidateCenterX > centerX ? 'right' : 'left')
    : (target.mirrored ? 'left' : 'right')
}'''
if 'function stairNeighborSideForWallDetail(' in s:
    s = replace_between(s, 'function stairNeighborSideForWallDetail(', 'function stairElementPolygons3D(', neighbor_fn)
else:
    raise SystemExit('Konnte stairNeighborSideForWallDetail nicht finden.')

# -----------------------------------------------------------------------------
# D) Automatische Treppen-Eingangswandoeffnung aus Update 130 entfernen.
#    Die Wand bleibt geschlossen, bis der neue Popup-Button benutzt wird.
# -----------------------------------------------------------------------------
if '  const stairCurrentFloorOpeningFaceIds = useMemo(() => {' in s:
    s = replace_between(s, '  const stairCurrentFloorOpeningFaceIds = useMemo(() => {', '  const visibleWallFacePieces = useMemo(() => projectedWallFaces.flatMap((face) => {', '')

wall_hit = r'''  const wallHitFaces = useMemo(() => [...projectedWallFaces].sort((a, b) => {
    return b.avgDepth - a.avgDepth
  }), [projectedWallFaces])'''
if '  const wallHitFaces = useMemo(() =>' in s:
    s = replace_between(s, '  const wallHitFaces = useMemo(() =>', '  function selectLayer(id: string) {', wall_hit)
else:
    raise SystemExit('Konnte wallHitFaces nicht finden.')

# -----------------------------------------------------------------------------
# E) Robuste SVG-3D-Darstellung: Waende und Treppen nicht mehr in zwei festen
#    Ebenen rendern, sondern gemeinsam per Kameratiefe (Painter-Algorithmus).
# -----------------------------------------------------------------------------
scene_memo = r'''  const wallDepthScene = useMemo(() => [
    ...visibleWallFacePieces.map((entry) => ({ kind: 'wall' as const, depth: entry.face.avgDepth, entry })),
    ...projectedStairObjects.map((entry) => ({ kind: 'stair' as const, depth: entry.avgDepth, entry })),
  ].sort((a, b) => b.depth - a.depth), [visibleWallFacePieces, projectedStairObjects])
'''
if 'const wallDepthScene = useMemo(' not in s:
    anchor = '  const wallPassageRevealsIn3D = useMemo(() => projectedWallFaces.flatMap((face) => {'
    if anchor not in s:
        raise SystemExit('Konnte wallPassageRevealsIn3D nicht finden.')
    s = s.replace(anchor, scene_memo + '\n' + anchor, 1)

scene_render = r'''              {showWallSubmodels && ceilingGapPath && <path d={ceilingGapPath} className="wall-ceiling-gap" fillRule="evenodd" style={wallSubmodelStyle} />}
              {wallDepthScene.map((scene) => {
                if (scene.kind === 'stair') {
                  if (!showWallSubmodels) return null
                  const item = scene.entry
                  return (
                    <polygon
                      key={item.key}
                      points={svgPointsToString(item.points)}
                      className={`wall-detail-stair wall-detail-stair-${item.role}`}
                      data-room-id={item.roomId}
                      data-depth={round2(item.avgDepth)}
                      style={wallSubmodelStyle}
                    />
                  )
                }
                const { face, polygon, pieceIndex, opened, fullOpen } = scene.entry
                const pairedHover = wallFaceIsInPair(face, hoveredWall, wallDetailRooms)
                return (
                  <polygon
                    key={`${face.room.id}-wall-face-${face.edgeIndex}-${pieceIndex}`}
                    points={svgPointsToString(polygon)}
                    className={`wall-detail-face wall-detail-face-3d ${face.outerWall ? 'outer-wall-face-3d' : ''} ${face.selected ? 'selected' : ''} ${pairedHover ? 'pair-hover' : ''} ${opened ? 'opened' : ''} ${fullOpen ? 'full-open' : ''}`}
                    data-depth={round2(face.avgDepth)}
                    style={{
                      '--wall-axis-x': String(face.axis.x),
                      '--wall-axis-y': String(face.axis.y),
                      '--wall-origin-x': `${face.axis.originX}px`,
                      '--wall-origin-y': `${face.axis.originY}px`,
                    } as CSSProperties}
                    onMouseEnter={() => setHoveredWall({ roomId: face.room.id, edgeIndex: face.edgeIndex })}
                    onMouseLeave={() => setHoveredWall(null)}
                    onClick={(event) => pickWall(event, face.room, face.edgeIndex)}
                  />
                )
              })}
'''
render_start = '              {showWallSubmodels && ceilingGapPath && <path d={ceilingGapPath} className="wall-ceiling-gap" fillRule="evenodd" style={wallSubmodelStyle} />}'
render_end = '              {showWallSubmodels && wallPassageRevealsIn3D.map(({ face, item, polygon, index, kind }) => ('
if render_start in s and render_end in s:
    s = replace_between(s, render_start, render_end, scene_render)
elif 'wallDepthScene.map((scene)' not in s:
    raise SystemExit('Konnte 3D-Renderblock fuer Waende/Treppen nicht finden.')

# -----------------------------------------------------------------------------
# F) Blueprint-Tueren: beide Wandseiten auf ein gemeinsames physisches Intervall
#    normieren. Dadurch keine gekreuzten Ecken und korrekte Lage auch bei
#    unterschiedlich langen Gegenwaenden. Alte, bereits gespeicherte Paare
#    werden bei der Darstellung ebenfalls korrigiert.
# -----------------------------------------------------------------------------
blueprint_block = r'''function BlueprintWallObjectConnections({ wallObjects, rooms }: { wallObjects: ApiWallObject[]; rooms: Room[] }) {
  const byGroup = wallObjects
    .filter((item) => item.objectType === 'door' && item.groupId && !isFullWallOpenGroupId(item.groupId))
    .reduce<Record<string, ApiWallObject[]>>((acc, item) => {
      const key = item.groupId || item.id
      acc[key] = [...(acc[key] ?? []), item]
      return acc
    }, {})

  const connectors = Object.entries(byGroup).flatMap(([groupId, groupItems]) => {
    const segments = groupItems
      .map((item) => blueprintWallObjectSegment(item, rooms))
      .filter((segment): segment is BlueprintWallSegment => Boolean(segment))
    if (segments.length < 2) return []
    const pair = bestBlueprintConnectionPair(segments)
    const normalized = normalizeBlueprintConnectionPair(pair.a, pair.b)
    return [{ groupId, points: [normalized.a.left, normalized.a.right, normalized.b.right, normalized.b.left] }]
  })

  if (connectors.length === 0) return null
  return (
    <g className="blueprint-wall-object-connections" aria-label="Wanddetail-Durchgaenge">
      {connectors.map((connector) => (
        <polygon
          key={connector.groupId}
          points={connector.points.map((point) => `${mToX(point.x)},${mToY(point.y)}`).join(' ')}
          className="blueprint-wall-connection-door"
        />
      ))}
    </g>
  )
}

type BlueprintWallSegment = {
  left: PointM
  right: PointM
  edge: { a: PointM; b: PointM }
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
  return { left: pointAt(leftT), right: pointAt(rightT), edge }
}

function bestBlueprintConnectionPair(segments: BlueprintWallSegment[]) {
  let best = { a: segments[0], b: segments[1], score: Number.POSITIVE_INFINITY }
  for (let i = 0; i < segments.length; i += 1) {
    for (let j = i + 1; j < segments.length; j += 1) {
      const a = segments[i]
      const b = segments[j]
      const centerA = { x: (a.left.x + a.right.x) / 2, y: (a.left.y + a.right.y) / 2 }
      const centerB = { x: (b.left.x + b.right.x) / 2, y: (b.left.y + b.right.y) / 2 }
      const score = distance(centerA, centerB)
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

  let commonMin = clamp((intervalA.min + intervalB.min) / 2, overlapMin, overlapMax)
  let commonMax = clamp((intervalA.max + intervalB.max) / 2, overlapMin, overlapMax)
  if (commonMax < commonMin) [commonMin, commonMax] = [commonMax, commonMin]
  if (commonMax - commonMin < 0.01) {
    const center = clamp((commonMin + commonMax) / 2, overlapMin, overlapMax)
    commonMin = clamp(center - 0.005, overlapMin, overlapMax)
    commonMax = clamp(center + 0.005, overlapMin, overlapMax)
  }

  const pointOnEdge = (edge: { a: PointM; b: PointM }, targetScalar: number): PointM => {
    const aScalar = scalar(edge.a)
    const bScalar = scalar(edge.b)
    const denom = bScalar - aScalar
    const t = Math.abs(denom) < 0.000001 ? 0 : clamp((targetScalar - aScalar) / denom, 0, 1)
    return {
      x: round3(edge.a.x + (edge.b.x - edge.a.x) * t),
      y: round3(edge.a.y + (edge.b.y - edge.a.y) * t),
    }
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
    s = replace_between(s, 'function BlueprintWallObjectConnections(', 'type WallSelection = { roomId: string; edgeIndex: number }', blueprint_block)
else:
    raise SystemExit('Konnte BlueprintWallObjectConnections nicht finden.')

app.write_text(s)

c = css.read_text()
marker = '/* 132: robust 3d depth + wall popup + blueprint doors */'
if marker in c:
    c = c[:c.index(marker)].rstrip() + '\n'
c += r'''

/* 132: robust 3d depth + wall popup + blueprint doors */
.wall-front-full-open-overlay {
  fill: url(#wall-front-fullopen-hatch) !important;
  stroke: rgba(180, 83, 9, 0.68) !important;
  stroke-width: 1.4px !important;
  pointer-events: none;
}
.wall-detail-canvas .wall-detail-stair {
  pointer-events: none;
}
.wall-detail-canvas .wall-detail-face-3d.full-open {
  fill-opacity: 0.10 !important;
  stroke-opacity: 0.46 !important;
}
.wall-detail-canvas .wall-detail-hit-face {
  pointer-events: all;
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
log "Update 132g wurde erfolgreich in Stage gebaut und deployed. Produktion wurde nicht geaendert."
log ""
log "Bitte in https://home.moja.de/strom-test/ testen:"
log "  1. Treppe: hintere Waende liegen hinter den Stufen; vordere Waende liegen davor."
log "  2. Treppen-Biegung: Ursprung entspricht dem Canvas 'Treppe einzeichnen'."
log "  3. Wand-Popup: vorhandene Objekte werden auch bei Auswahl der Gegenwand angezeigt."
log "  4. Vollstaendige Wandoeffnung: Wandrechteck im Popup ist diagonal schraffiert."
log "  5. Vollstaendig geoeffnete Wand: im 3D-Modell ca. 10% sichtbar und weiterhin anklickbar."
log "  6. Blueprint-Tueren: kein X/keine gekreuzten Ecken; physische Position und Breite stimmen auch bei unterschiedlich langen Waenden."
log "  7. Infrastruktur: keine Permission-denied-Fehler in /tmp; frontend/node_modules wird nicht in Git versioniert."
log ""
read -r -p "Test in /strom-test/ bestanden? [j/N] " answer
case "$answer" in
  j|J|ja|JA|Ja)
    log "OK: Stage bleibt mit Update 132f aktiv."
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
