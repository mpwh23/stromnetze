#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20260908-1435_133_strom_wanddetail_depth_winder_outerwall_doors"
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
COMMIT_MESSAGE="Update 133: robustere 3D-Tiefensortierung, Ecktreppen-Riser und Aussenwand-Tueren"
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
  echo "1) Aktuellen Stage-Source + Update 133 nach GitHub pushen ..."
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

  echo "1.3) Update 133 auf Git-Source anwenden und Build pruefen ..."
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
elif 'const stairRoomDepthById = useMemo(() =>' not in s:
    raise SystemExit('Konnte wallDepthScene aus 132g nicht finden.')

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
log "Update 133 wurde erfolgreich in Stage gebaut und deployed. Produktion wurde nicht geaendert."
log ""
log "Bitte in https://home.moja.de/strom-test/ testen:"
log "  1. Treppenhaus: Vorderwand bleibt voll sichtbar; Hinterwand liegt hinter den Stufen."
log "  2. Ecktreppen/Biegungen besitzen sichtbare vertikale Setzstufen."
log "  3. Tuer zwischen Raumwand und Aussenwand ist auch ohne Auswahl sichtbar."
log "  4. Neue Tueren werden auf beiden physisch gepaarten Wandseiten gespeichert."
log "  5. Auswahl und Popup funktionieren von Raum- und Aussenwandseite."
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
