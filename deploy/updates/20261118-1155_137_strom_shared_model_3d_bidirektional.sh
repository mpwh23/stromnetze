#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-1155_137_strom_shared_model_3d_bidirektional"
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
COMMIT_MESSAGE="Update 137: Reales 3D, gemeinsames Gebaeudemodell und bidirektionale Bearbeitung"
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
  echo "2) Aktuellen Stage-Source + Update 137 nach GitHub pushen ..."
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

  echo "1.3) Update 137 auf Git-Source anwenden und Build pruefen ..."
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
# Pi / Stage update body. Real WebGL increment 137.
# -----------------------------------------------------------------------------
if [ "$MODE" != "--stage-phase" ]; then
  echo "FEHLER: Unbekannter Modus '$MODE'." >&2
  echo "Auf dem Mac ohne Parameter starten." >&2
  exit 1
fi

DEPLOY_DIR="$REMOTE_DEPLOY_DIR"
if [ ! -d "$BACKUP_BASE" ]; then BACKUP_BASE="$(dirname "$STAGE_DIR")"; fi
BACKUP_DIR="$BACKUP_BASE/strom_stage_backup_${SCRIPT_NAME}_$(date +%Y%m%d-%H%M%S)"
WORK_DIR="/tmp/${SCRIPT_NAME}_work_$(id -u)_$$_${RANDOM}"
DIAG_LOG="/tmp/${SCRIPT_NAME}_diagnostics_$(date +%Y%m%d-%H%M%S).log"

run_sudo() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}
log() { echo "$@" | tee -a "$DIAG_LOG"; }
fail() {
  log ""
  log "FEHLER: $*"
  log "Diagnose: $DIAG_LOG"
  [ -f "$DIAG_LOG" ] && { echo '--- Letzte Diagnosezeilen ---'; tail -n 100 "$DIAG_LOG"; echo '--- Ende Diagnose ---'; }
  exit 1
}

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

log "=== Update 137 / geteiltes Gebaeudemodell und echtes 3D ==="
log "Stage: $STAGE_DIR"
log "Produktion wird nicht veraendert."
log "Diagnose: $DIAG_LOG"
[ -f "$STAGE_DIR/frontend/src/App.tsx" ] || fail "App.tsx fehlt."
[ -f "$STAGE_DIR/frontend/package.json" ] || fail "Frontend package.json fehlt."
select_node

log "1) Backup der Stage erstellen..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Vorabtest in temporaerem Git-Checkout."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage-Backup fehlgeschlagen."
fi

log "2) Isolierte Arbeitskopie vorbereiten (keine Produktion-node_modules-Symlinks)..."
mkdir -p "$WORK_DIR"
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' "$STAGE_DIR/" "$WORK_DIR/" || fail "Isolierte Quellkopie fehlgeschlagen."
# A symlink pointing at production must NEVER be used by npm install.
if [ -L "$WORK_DIR/frontend/node_modules" ]; then
  rm -f "$WORK_DIR/frontend/node_modules"
elif [ -d "$WORK_DIR/frontend/node_modules" ]; then
  rm -rf "$WORK_DIR/frontend/node_modules"
fi
mkdir -p "$WORK_DIR/frontend/src/building" "$WORK_DIR/frontend/src/components" "$WORK_DIR/docs"

log "3) Neue TypeScript-Module und den zentralen 3D-Adapter schreiben..."
cat > "$WORK_DIR/frontend/src/building/model.ts" <<'STROM137_MODEL'
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

function identicalPhysicalEdge(first: BuildingWall, second: BuildingWall) {
  return (distance(first.start, second.start) < 0.008 && distance(first.end, second.end) < 0.008)
    || (distance(first.start, second.end) < 0.008 && distance(first.end, second.start) < 0.008)
}

function remapOpening(opening: BuildingOpening, from: BuildingWall, to: BuildingWall): BuildingOpening {
  const ratio = opening.centerM / Math.max(minSizeM, from.lengthM)
  const point = {
    x: from.start.x + (from.end.x - from.start.x) * ratio,
    y: from.start.y + (from.end.y - from.start.y) * ratio,
  }
  const vx = (to.end.x - to.start.x) / to.lengthM
  const vy = (to.end.y - to.start.y) / to.lengthM
  return {
    ...opening,
    centerM: clamp((point.x - to.start.x) * vx + (point.y - to.start.y) * vy, 0, to.lengthM),
  }
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

  // Coincident reverse room edges describe the same physical wall. Render it once;
  // project openings from both source edges onto that one wall.
  const walls: BuildingWall[] = []
  for (const candidate of candidates) {
    const existing = walls.find((wall) => identicalPhysicalEdge(wall, candidate))
    if (!existing) {
      walls.push(candidate)
      continue
    }
    existing.thicknessM = Math.max(existing.thicknessM, candidate.thicknessM)
    for (const opening of candidate.openings) {
      if (existing.openings.some((item) => item.groupId === opening.groupId)) continue
      existing.openings.push(remapOpening(opening, candidate, existing))
    }
  }

  const doorMap = new Map<string, BuildingOpening>()
  // Prefer a room wall as the reference when a door is present on both faces.
  for (const wall of [...walls].sort((a, b) => Number(a.outerWall) - Number(b.outerWall))) {
    for (const opening of wall.openings) {
      if (opening.type === 'door' && !opening.groupId.startsWith('wall-open:') && !doorMap.has(opening.groupId)) doorMap.set(opening.groupId, opening)
    }
  }

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
STROM137_MODEL
cat > "$WORK_DIR/frontend/src/components/Building3DWorkspace.tsx" <<'STROM137_SCENE'
import { useEffect, useMemo, useState } from 'react'
import { Canvas, ThreeEvent, useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import { OrbitControls } from 'three/addons/controls/OrbitControls.js'
import { getWallObjects, updateWallObject as updateWallObjectApi } from '../api'
import type { Floor, Room, WallObject, PointM } from '../types'
import { buildBuildingModel, wallSolidPieces, type BuildingModel, type BuildingRoom, type BuildingWall, type BuildingOpening } from '../building/model'

const roundMm = (value: number) => Math.round(value * 1000) / 1000
const fmtMm = (value: number) => Math.round(value * 1000).toLocaleString('de-DE')
const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, value))

function FloorMesh({ room, selected, onSelect }: { room: BuildingRoom; selected: boolean; onSelect: () => void }) {
  const shape = useMemo(() => {
    const s = new THREE.Shape()
    room.vertices.forEach((point, index) => {
      if (index === 0) s.moveTo(point.x, -point.y)
      else s.lineTo(point.x, -point.y)
    })
    s.closePath()
    return s
  }, [room.vertices])
  if (room.kind === 'outer') return null
  return (
    <mesh rotation={[-Math.PI / 2, 0, 0]} position={[0, 0.015, 0]} onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); onSelect() }}>
      <shapeGeometry args={[shape]} />
      <meshStandardMaterial color={selected ? '#d3e6ff' : room.kind === 'stair' ? '#f5e7fb' : '#e9edf2'} side={THREE.DoubleSide} roughness={0.87} />
    </mesh>
  )
}

function WallMeshes({ wall, selected, onSelect, transparent }: { wall: BuildingWall; selected: boolean; onSelect: () => void; transparent: boolean }) {
  const pieces = useMemo(() => wallSolidPieces(wall), [wall])
  const dx = wall.end.x - wall.start.x
  const dz = wall.end.y - wall.start.y
  const angle = -Math.atan2(dz, dx)
  const color = selected ? '#93bafa' : wall.outerWall ? '#adbacb' : '#c5d0db'
  return (
    <group>
      {pieces.map((piece, index) => {
        const along = (piece.fromM + piece.toM) / 2 / wall.lengthM
        const x = wall.start.x + dx * along
        const z = wall.start.y + dz * along
        return (
          <mesh
            key={`${wall.id}-${index}`}
            position={[x, (piece.bottomM + piece.topM) / 2, z]}
            rotation={[0, angle, 0]}
            onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); onSelect() }}
            castShadow={!transparent}
            receiveShadow
          >
            <boxGeometry args={[piece.toM - piece.fromM, piece.topM - piece.bottomM, wall.thicknessM]} />
            <meshStandardMaterial color={color} roughness={0.84} transparent={transparent} opacity={transparent ? 0.34 : 1} depthWrite={!transparent} />
          </mesh>
        )
      })}
    </group>
  )
}

function DoorHandle({ door, wall, selected, onSelect }: { door: BuildingOpening; wall: BuildingWall; selected: boolean; onSelect: () => void }) {
  const t = door.centerM / wall.lengthM
  const x = wall.start.x + (wall.end.x - wall.start.x) * t
  const z = wall.start.y + (wall.end.y - wall.start.y) * t
  return (
    <mesh
      position={[x, door.sillM + door.heightM / 2, z]}
      rotation={[0, -Math.atan2(wall.end.y - wall.start.y, wall.end.x - wall.start.x), 0]}
      onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); onSelect() }}
    >
      <boxGeometry args={[door.widthM, door.heightM, Math.max(0.045, wall.thicknessM + 0.018)]} />
      <meshBasicMaterial color={selected ? '#2563eb' : '#79a4d5'} transparent opacity={selected ? 0.3 : 0.085} depthWrite={false} />
    </mesh>
  )
}

function SceneControls({ model }: { model: BuildingModel }) {
  const { camera, gl } = useThree()
  const controls = useMemo(() => new OrbitControls(camera, gl.domElement), [camera, gl.domElement])
  useEffect(() => {
    controls.target.set(model.center.x, model.floorElevationM + model.floorHeightM / 2, model.center.y)
    controls.enableDamping = true
    controls.dampingFactor = 0.11
    controls.minDistance = 1
    controls.maxDistance = Math.max(35, model.spanM * 7)
    controls.maxPolarAngle = Math.PI * 0.49
    controls.update()
    return () => controls.dispose()
  }, [controls, model.floorId, model.center.x, model.center.y, model.floorElevationM, model.floorHeightM, model.spanM])
  useFrame(() => controls.update())
  return null
}

function RealBuildingScene({ model, selectedRoomId, selectedDoorId, onSelectRoom, onSelectDoor, transparent }: {
  model: BuildingModel
  selectedRoomId: string
  selectedDoorId: string
  onSelectRoom: (id: string) => void
  onSelectDoor: (id: string) => void
  transparent: boolean
}) {
  const distance = Math.max(8, model.spanM * 1.2)
  return (
    <Canvas
      shadows={!transparent}
      dpr={[1, 1.75]}
      camera={{ position: [model.center.x + distance, model.floorElevationM + distance * 0.8 + model.floorHeightM, model.center.y + distance], fov: 48, near: 0.05, far: Math.max(100, model.spanM * 20) }}
      onPointerMissed={() => { onSelectDoor(''); onSelectRoom('') }}
      gl={{ antialias: true, alpha: false }}
      aria-label="Echte dreidimensionale Gebaeudeansicht"
    >
      <color attach="background" args={['#f5f8fc']} />
      <ambientLight intensity={1.15} />
      <directionalLight position={[14, 20, 16]} intensity={2.1} castShadow={!transparent} shadow-mapSize={[1024, 1024]} />
      <hemisphereLight args={['#e8f1ff', '#9698a6', 0.85]} />
      <group position={[0, model.floorElevationM, 0]}>
        {model.rooms.map((room) => (
          <FloorMesh key={room.id} room={room} selected={selectedRoomId === room.id} onSelect={() => { onSelectRoom(room.id); onSelectDoor('') }} />
        ))}
        {model.walls.map((wall) => (
          <WallMeshes key={wall.id} wall={wall} selected={selectedRoomId === wall.roomId} onSelect={() => { onSelectRoom(wall.roomId); onSelectDoor('') }} transparent={transparent} />
        ))}
        {model.walls.flatMap((wall) => wall.openings
          .filter((opening) => opening.type === 'door' && model.doors.some((door) => door.id === opening.id))
          .map((door) => (
            <DoorHandle
              key={`${wall.id}/${door.id}`}
              door={door}
              wall={wall}
              selected={selectedDoorId === door.groupId}
              onSelect={() => { onSelectDoor(door.groupId); onSelectRoom(door.roomId) }}
            />
          )))}
      </group>
      <gridHelper args={[Math.max(40, model.spanM * 4), 40, '#bbc7d5', '#dce5ef']} position={[model.center.x, model.floorElevationM - 0.035, model.center.y]} />
      <SceneControls model={model} />
    </Canvas>
  )
}

function DoorForm({ model, door, rooms, rawObjects, onSaved }: {
  model: BuildingModel
  door: BuildingOpening
  rooms: Room[]
  rawObjects: WallObject[]
  onSaved: () => Promise<void>
}) {
  const [positionMm, setPositionMm] = useState(Math.round(door.centerM * 1000))
  const [widthMm, setWidthMm] = useState(Math.round(door.widthM * 1000))
  const [heightMm, setHeightMm] = useState(Math.round(door.heightM * 1000))
  const [saving, setSaving] = useState(false)
  const [notice, setNotice] = useState('')
  useEffect(() => {
    setPositionMm(Math.round(door.centerM * 1000))
    setWidthMm(Math.round(door.widthM * 1000))
    setHeightMm(Math.round(door.heightM * 1000))
    setNotice('')
  }, [door.id, door.centerM, door.widthM, door.heightM])

  async function save() {
    const originalWall = model.walls.find((wall) => wall.roomId === door.roomId && wall.edgeIndex === door.edgeIndex)
    const sourceRoom = rooms.find((room) => room.id === door.roomId)
    if (!originalWall && !sourceRoom) { setNotice('Quellwand nicht gefunden.'); return }
    const edge = sourceRoom && sourceRoom.vertices.length > door.edgeIndex
      ? { start: sourceRoom.vertices[door.edgeIndex], end: sourceRoom.vertices[(door.edgeIndex + 1) % sourceRoom.vertices.length] }
      : { start: originalWall!.start, end: originalWall!.end }
    const sourceLength = Math.hypot(edge.end.x - edge.start.x, edge.end.y - edge.start.y)
    const widthM = widthMm / 1000
    const heightM = heightMm / 1000
    const centerM = positionMm / 1000
    if (widthM < 0.3 || widthM > sourceLength - 0.01 || heightM < 0.5 || heightM > model.floorHeightM || centerM < widthM / 2 || centerM > sourceLength - widthM / 2) {
      setNotice('Bitte gueltige Masse innerhalb der Wand waehlen.')
      return
    }
    const point: PointM = {
      x: edge.start.x + ((edge.end.x - edge.start.x) * centerM) / sourceLength,
      y: edge.start.y + ((edge.end.y - edge.start.y) * centerM) / sourceLength,
    }
    const group = rawObjects.filter((item) => item.objectType === 'door' && (door.groupId === item.id || item.groupId === door.groupId))
    if (!group.length) { setNotice('Tuerobjekt nicht gefunden.'); return }
    const patches: { id: string; x: number; y: number; w: number; h: number }[] = []
    for (const item of group) {
      const room = rooms.find((candidate) => candidate.id === item.roomId)
      if (!room) { setNotice('Zugehoeriger Raum nicht gefunden.'); return }
      const a = room.vertices[item.edgeIndex]
      const b = room.vertices[(item.edgeIndex + 1) % room.vertices.length]
      if (!a || !b) { setNotice('Zugehoerige Wand nicht gefunden.'); return }
      const vx = b.x - a.x
      const vy = b.y - a.y
      const lengthM = Math.hypot(vx, vy)
      if (widthM > lengthM - 0.01) { setNotice('Tuer ist breiter als ihre Gegenwand.'); return }
      const projected = ((point.x - a.x) * vx + (point.y - a.y) * vy) / (lengthM * lengthM)
      const fraction = clamp(projected, widthM / lengthM / 2, 1 - widthM / lengthM / 2)
      const h = roundMm(heightM / model.floorHeightM)
      patches.push({ id: item.id, x: roundMm(fraction), y: roundMm(1 - h / 2), w: roundMm(widthM / lengthM), h })
    }
    setSaving(true)
    setNotice('')
    try {
      // Update each physical face; on a failed update attempt to restore any
      // already-written faces. This does not require a database schema change.
      const updated: string[] = []
      try {
        for (const entry of patches) {
          await updateWallObjectApi(entry.id, { x: entry.x, y: entry.y, w: entry.w, h: entry.h })
          updated.push(entry.id)
        }
      } catch (error) {
        await Promise.allSettled(updated.map((id) => {
          const previous = group.find((item) => item.id === id)!
          return updateWallObjectApi(id, { x: previous.x, y: previous.y, w: previous.w, h: previous.h })
        }))
        throw error
      }
      await onSaved()
      setNotice('Gespeichert – Blueprint und 3D verwenden dieselbe Tuer.')
    } catch (error) {
      await onSaved()
      setNotice(`Speichern fehlgeschlagen: ${error instanceof Error ? error.message : String(error)}`)
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="building3d-inspector-section">
      <h3>Tuer bearbeiten (3D → Blueprint)</h3>
      <p>Unterkante: 0 mm (Boden). Position ab Wandanfang.</p>
      <label>Position (mm)<input type="number" min={0} step={10} value={positionMm} onChange={(event) => setPositionMm(Number(event.target.value))} /></label>
      <label>Breite (mm)<input type="number" min={300} step={10} value={widthMm} onChange={(event) => setWidthMm(Number(event.target.value))} /></label>
      <label>Hoehe (mm)<input type="number" min={500} step={10} value={heightMm} onChange={(event) => setHeightMm(Number(event.target.value))} /></label>
      <button type="button" disabled={saving} onClick={() => void save()} title="Tuer in den gemeinsamen Gebaeudedaten speichern">{saving ? 'Speichere ...' : 'Tuer speichern'}</button>
      {notice && <p className="building3d-notice" role="status">{notice}</p>}
    </div>
  )
}

export default function Building3DWorkspace({ floor, rooms, selectedRoomId, onSelectRoom, onPersistRoom, onCaptureUndo, onBackToBlueprint }: {
  floor: Floor
  rooms: Room[]
  selectedRoomId: string
  onSelectRoom: (id: string) => void
  onPersistRoom: (room: Room) => Promise<void>
  onCaptureUndo: () => void
  onBackToBlueprint: () => void
}) {
  const [objects, setObjects] = useState<WallObject[]>([])
  const [selectedDoorId, setSelectedDoorId] = useState('')
  const [transparent, setTransparent] = useState(false)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [xMm, setXmm] = useState(0)
  const [yMm, setYmm] = useState(0)
  const model = useMemo(() => buildBuildingModel(floor, rooms, objects), [floor, rooms, objects])
  const selectedRoom = rooms.find((room) => room.id === selectedRoomId) ?? null
  const selectedDoor = model.doors.find((door) => door.groupId === selectedDoorId) ?? null
  const movable = Boolean(selectedRoom && !selectedRoom.name.startsWith('__strom_outer_wall__') && selectedRoom.roomType !== 'stair')
  const centroid = useMemo(() => {
    if (!selectedRoom?.vertices.length) return { x: 0, y: 0 }
    return selectedRoom.vertices.reduce((acc, point) => ({ x: acc.x + point.x / selectedRoom.vertices.length, y: acc.y + point.y / selectedRoom.vertices.length }), { x: 0, y: 0 })
  }, [selectedRoom])

  async function reloadDoors() {
    try {
      setObjects(await getWallObjects(floor.id))
    } catch (error) {
      setMessage(`Tueren konnten nicht geladen werden: ${error instanceof Error ? error.message : String(error)}`)
    }
  }
  useEffect(() => { void reloadDoors() }, [floor.id])
  useEffect(() => { setXmm(Math.round(centroid.x * 1000)); setYmm(Math.round(centroid.y * 1000)) }, [selectedRoomId, centroid.x, centroid.y])

  async function shiftSelectedRoom(dxM: number, dyM: number) {
    if (!selectedRoom || !movable || busy) return
    const next: Room = {
      ...selectedRoom,
      vertices: selectedRoom.vertices.map((point) => ({ x: roundMm(point.x + dxM), y: roundMm(point.y + dyM) })),
    }
    setBusy(true)
    setMessage('')
    try {
      onCaptureUndo()
      await onPersistRoom(next)
      setMessage('Raum gespeichert. Blueprint verwendet dieselben Koordinaten.')
    } catch (error) {
      setMessage(`Speichern fehlgeschlagen: ${error instanceof Error ? error.message : String(error)}`)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="building3d-layout" aria-label="Echtes 3D Gebaeudemodell">
      <div className="building3d-toolbar">
        <strong>Echtes 3D · Aufbauphase 1</strong>
        <span>Etage: {model.floorName}</span>
        <button type="button" title="Transparente Waende umschalten" onClick={() => setTransparent((value) => !value)}>{transparent ? 'Waende deckend' : 'Waende transparent'}</button>
        <button type="button" title="Zum 2D-Blueprint wechseln" onClick={onBackToBlueprint}>Zurueck zum Blueprint (2D)</button>
      </div>
      <div className="building3d-content">
        <div className="building3d-view">
          <RealBuildingScene model={model} selectedRoomId={selectedRoomId} selectedDoorId={selectedDoorId} onSelectRoom={onSelectRoom} onSelectDoor={setSelectedDoorId} transparent={transparent} />
          <div className="building3d-help">Linke Maustaste: drehen · Mausrad: zoomen · rechte Maustaste: verschieben · Klick: Raum oder Tuer waehlen</div>
        </div>
        <aside className="building3d-inspector">
          <h2>3D-Eigenschaften</h2>
          <p>Die Daten stammen direkt aus demselben Gebaeudemodell wie im Blueprint.</p>
          <div className="building3d-inspector-section">
            <strong>{selectedRoom ? `Raum: ${selectedRoom.name}` : 'Raum anklicken'}</strong>
            <p>{selectedRoom ? `${selectedRoom.vertices.length} Eckpunkte · ${fmtMm(floor.heightM)} mm Hoehe` : 'Ein Raum kann in 3D ausgewaehlt und verschoben werden.'}</p>
            {movable && (
              <>
                <label>Mittelpunkt X (mm)<input type="number" value={xMm} step={100} onChange={(event) => setXmm(Number(event.target.value))} /></label>
                <label>Mittelpunkt Y (mm)<input type="number" value={yMm} step={100} onChange={(event) => setYmm(Number(event.target.value))} /></label>
                <button type="button" disabled={busy} onClick={() => void shiftSelectedRoom((xMm / 1000) - centroid.x, (yMm / 1000) - centroid.y)} title="Raumposition speichern">Raumposition speichern</button>
                <p>Feinverschiebung um 100 mm:</p>
                <div className="building3d-directional">
                  <button type="button" disabled={busy} title="Raum um 100 mm nach links verschieben" onClick={() => void shiftSelectedRoom(-0.1, 0)}>X −100</button>
                  <button type="button" disabled={busy} title="Raum um 100 mm nach oben verschieben" onClick={() => void shiftSelectedRoom(0, -0.1)}>Y −100</button>
                  <button type="button" disabled={busy} title="Raum um 100 mm nach unten verschieben" onClick={() => void shiftSelectedRoom(0, 0.1)}>Y +100</button>
                  <button type="button" disabled={busy} title="Raum um 100 mm nach rechts verschieben" onClick={() => void shiftSelectedRoom(0.1, 0)}>X +100</button>
                </div>
              </>
            )}
            {selectedRoom && !movable && <p>Dieses Spezialobjekt bleibt in Phase 1 im Blueprint bearbeitbar.</p>}
          </div>
          {selectedDoor && <DoorForm model={model} door={selectedDoor} rooms={rooms} rawObjects={objects} onSaved={reloadDoors} />}
          {!selectedDoor && <p>Eine blau angedeutete Tuer anklicken, um Position, Breite oder Hoehe auch in 3D zu bearbeiten.</p>}
          {message && <p className="building3d-notice" role="status">{message}</p>}
        </aside>
      </div>
      <div className="building3d-status">Modell: {model.rooms.length} Raumkonturen, {model.walls.length} Wandkanten, {model.doors.length} Tuergruppen · Phase 1: nur eine Etage; Treppen, Dach und Geschossverbindungen folgen schrittweise.</div>
    </div>
  )
}
STROM137_SCENE
cat > "$WORK_DIR/docs/3D_ARCHITEKTUR_INCREMENT_137.md" <<'STROM137_DOC'
# STROM 137 – Architekturinkrement 1: echtes 3D / gemeinsames Modell

## Ziel
Blueprint bleibt die erste und fuehrende 2D-Zeichenoberflaeche. Die bestehende
Room- und WallObject-API bildet die kanonische Datenbasis. 2D und Three.js lesen
dieselben Objekte; 3D speichert keine separate Kopie von Raum- oder Tuerdaten.

## Neu
- `frontend/src/building/model.ts`: pure Ableitung des Gebaeudemodells aus
  Floor, Room[] und WallObject[] mit Metern als Einheit. Wanddurchbrueche werden
  durch echte 3D-Wandsegmente realisiert (keine optische Uebermalung).
- `frontend/src/components/Building3DWorkspace.tsx`: Three.js + React Three
  Fiber, Orbit-Kamera, Auswahl, transparente/deckende Waende, Raumbearbeitung
  und Bearbeitung der gespeicherten Tueren.
- Im Menuepunkt `3D Haus` wird die bisherige Platzhaltergrafik durch echtes
  browserseitiges WebGL ersetzt. Das bisherige SVG-Wanddetail bleibt erhalten.
- 2D -> 3D: neuer/verschobener Raum oder neue Tuer wird beim Eintritt in die
  3D-Ansicht aus dem API-Zustand gerendert.
- 3D -> 2D: Raummittelpunkt kann um 100 mm verschoben oder numerisch gesetzt
  werden, Tuer-Breite/-Hoehe/-Position kann ueber den 3D-Inspector gespeichert
  werden. Danach zeigt Blueprint denselben API-Datensatz.

## Bewusste Grenzen von Inkrement 1
- Nur die gegenwaertig vom Backend gelieferte Etage; spaeter werden alle
  Etagen in einem absoluten Koordinatensystem zusammengefuehrt.
- Treppenlayout und deren Etagenkanten werden bisher teilweise im Browser-
  localStorage gespeichert. Das muss in einer spaeteren, verlustfreien
  Datenmigration in die kanonische DB-Schicht aufgenommen werden.
- Dach, Dachoeffnungen, Deckenplatten, Wandvereinigungen, 3D-Drag-Gizmos und
  bauliche Materialkataloge sind fuer spaetere Inkremente vorgesehen.
- Polygonale Raeume werden bereits als 3D-Bodenflaechen gezeigt; die Waende
  werden als einzelne echte Quadersegmente mit Tuerausschnitten abgebildet.
- Noch keine generelle Zusammenlegung angrenzender, aber nicht deckungsgleicher
  Raumwandelemente. Exakt deckungsgleiche Kanten werden dedupliziert.

## Sicherheitsprinzip
- Keine Migration oder Loeschung produktiver Daten, kein DB-Schema-Update.
- Eigenes 3D-Modell wird ausschliesslich aus bestehenden API-Objekten erzeugt.
- Deploy arbeitet zuerst auf einer temporaeren Quellkopie, prueft den Build,
  pusht den geaenderten Source nach GitHub und deployed danach Stage.
- Production /var/www/strom und /home/mpwh/strom bleiben unberuehrt.
STROM137_DOC
export STROM_PATCH_ROOT="$WORK_DIR"
python3 - <<'STROM137_PATCH'
from pathlib import Path
import os

root = Path(os.environ['STROM_PATCH_ROOT'])
app = root / 'frontend/src/App.tsx'
css = root / 'frontend/src/styles.css'
assert app.exists() and css.exists(), 'Frontend-Quellcode fehlt.'
s = app.read_text(encoding='utf-8')

imp = "import Building3DWorkspace from './components/Building3DWorkspace'"
if imp not in s:
    anchor = "import StromIcon from './components/StromIcon'"
    if anchor not in s:
        # Older stage source without 136: still enable the 3D integration.
        anchor = "import { type CSSProperties,"
        pos = s.find('\n', s.find(anchor))
        if pos < 0: raise SystemExit('137: React import fehlt. Abbruch ohne Sourceaenderung.')
        s = s[:pos + 1] + imp + '\n' + s[pos + 1:]
    else:
        s = s.replace(anchor, anchor + '\n' + imp, 1)

old = "          {selectedObject && viewMode === 'threeD' && <ThreeDMock />}"
new = '''          {selectedObject && viewMode === 'threeD' && floor && (
            <Building3DWorkspace
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
            />
          )}
          {selectedObject && viewMode === 'threeD' && !floor && <div className="hint-box">Bitte zuerst im Blueprint eine Etage anlegen.</div>}'''
if old in s:
    s = s.replace(old, new, 1)
elif "viewMode === 'threeD' && floor && (" not in s:
    raise SystemExit('137: 3D-Haus-Ansicht nicht am erwarteten Ort. Kein riskanter Patch.')

# Old 3D mock is no longer needed and is removed in a precise bounded edit.
start = s.find('function ThreeDMock() {')
if start >= 0:
    end = s.find('function roomToPayload(', start)
    if end < 0: raise SystemExit('137: 3D-Mock-Ende nicht gefunden.')
    s = s[:start] + s[end:]
app.write_text(s, encoding='utf-8')

vite_config = root / 'frontend/vite.config.ts'
if vite_config.exists():
    vite_text = vite_config.read_text(encoding='utf-8')
    if "base: '/strom/'" in vite_text:
        vite_text = vite_text.replace("base: '/strom/'", "base: process.env.VITE_BASE || '/strom/'", 1)
        vite_config.write_text(vite_text, encoding='utf-8')

style_marker = '/* 137: actual 3D workspace with shared building model */'
c = css.read_text(encoding='utf-8')
if style_marker not in c:
    c += '''

/* 137: actual 3D workspace with shared building model */
.building3d-layout { display: flex; flex-direction: column; height: min(85vh, 950px); min-height: 600px; border: 1px solid #d7e1ef; border-radius: 18px; overflow: hidden; background: #fff; }
.building3d-toolbar { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; min-height: 58px; padding: 9px 14px; background: #eef3fb; border-bottom: 1px solid #d5deeb; }
.building3d-toolbar strong { font-size: 15px; color: #1e3a8a; }
.building3d-toolbar span { margin-right: auto; color: #53627c; font-size: 13px; }
.building3d-toolbar button, .building3d-inspector button { cursor: pointer; border-radius: 9px; border: 1px solid #bdcce2; color: #1e3a8a; background: white; padding: 9px 12px; font-size: 13px; font-weight: 700; }
.building3d-toolbar button:hover, .building3d-inspector button:hover:not(:disabled) { background: #e6efff; }
.building3d-inspector button:disabled { opacity: .55; cursor: wait; }
.building3d-content { display: grid; grid-template-columns: minmax(0, 1fr) 280px; flex: 1; min-height: 0; }
.building3d-view { position: relative; min-width: 0; min-height: 350px; background: #f5f8fc; }
.building3d-view canvas { display: block; outline: none; touch-action: none; }
.building3d-help { position: absolute; bottom: 14px; left: 14px; max-width: calc(100% - 28px); color: #334155; background: rgba(255,255,255,.87); font-size: 12px; border-radius: 9px; padding: 9px 12px; pointer-events: none; }
.building3d-inspector { border-left: 1px solid #dce3ef; padding: 16px; background: #fbfcff; overflow: auto; color: #29364c; }
.building3d-inspector h2 { font-size: 16px; margin: 0 0 12px; }
.building3d-inspector h3 { font-size: 14px; margin: 0 0 8px; }
.building3d-inspector p { font-size: 12px; line-height: 1.5; color: #58677f; }
.building3d-inspector-section { border-top: 1px solid #e3e9f2; padding-top: 16px; margin-top: 16px; display: grid; gap: 9px; }
.building3d-inspector-section label { display: grid; gap: 4px; font-size: 12px; color: #485872; }
.building3d-inspector-section input { background: white; min-width: 0; width: 100%; padding: 8px; border: 1px solid #bdcce2; border-radius: 8px; color: #172337; font-size: 14px; }
.building3d-directional { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px; }
.building3d-directional button { padding: 9px 0; }
.building3d-status { border-top: 1px solid #d7e1ef; background: #f9fbff; font-size: 12px; padding: 10px 14px; color: #53627c; }
.building3d-notice { background: #ebf3ff; border-radius: 8px; padding: 9px; color: #1e40af !important; }
@media (max-width: 780px) { .building3d-layout { height: auto; min-height: 700px; } .building3d-content { grid-template-columns: 1fr; } .building3d-view { min-height: 440px; } .building3d-inspector { border-left: 0; border-top: 1px solid #dce3ef; max-height: 360px; } }
'''
css.write_text(c, encoding='utf-8')
print('137: Gemeinsames Gebaeudemodell und echte 3D-Haus-Ansicht angeschlossen.')
STROM137_PATCH

log "4) Three.js und React Three Fiber in der ISOLIERTEN Kopie installieren..."
(
  cd "$WORK_DIR/frontend"
  npm install --save-exact --no-audit --no-fund react@19.2.7 react-dom@19.2.7 three@0.187.0 @react-three/fiber@9.8.2
  npm install --save-exact --save-dev --no-audit --no-fund @types/three@0.187.0
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Dependency-Installation oder Frontend-Build fehlgeschlagen. Kein Git-Push/Stage-Deploy."

log "5) Build erfolgreich: Quellstand nach $STAGE_DIR uebernehmen..."
# No module binaries, secrets or build outputs enter Git.
rsync -a --delete --exclude 'frontend/node_modules' --exclude 'frontend/dist' --exclude '.git' "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Source-Synchronisation fehlgeschlagen. Backup: $BACKUP_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  rm -rf "$WORK_DIR"
  log "PATCH_ONLY: Code und Build geprueft, keine Stage-Webseite oder Produktionsdaten veraendert."
  exit 0
fi

# Replace only Stage's dependency directory, never production's. A backup exists.
if [ -L "$STAGE_DIR/frontend/node_modules" ]; then
  rm -f "$STAGE_DIR/frontend/node_modules"
elif [ -d "$STAGE_DIR/frontend/node_modules" ]; then
  rm -rf "$STAGE_DIR/frontend/node_modules"
fi
if [ -d "$WORK_DIR/frontend/node_modules" ]; then
  mv "$WORK_DIR/frontend/node_modules" "$STAGE_DIR/frontend/node_modules" || fail "Stage-Abhaengigkeiten konnten nicht uebernommen werden. Backup: $BACKUP_DIR"
fi

log "6) Stage-Build und /strom-test/-Deployment..."
(
  cd "$STAGE_DIR/frontend"
  VITE_BASE=/strom-test/ npm run build
) >>"$DIAG_LOG" 2>&1 || fail "Stage-Build fehlgeschlagen. Backup: $BACKUP_DIR"

run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Web-Deployment fehlgeschlagen. Backup: $BACKUP_DIR"
rm -rf "$WORK_DIR"
log ""
log "137 erfolgreich: Echtes WebGL-3D in /strom-test/ aktiv; Production unveraendert."
log "GitHub wurde bereits vor dem Stage-Deployment aktualisiert."
log "Tests: zuerst Blueprint-Raum auswaehlen, nach 3D Haus wechseln, Raum positionieren, zur Blueprint-Ansicht zurueckkehren."
log "Anschliessend Tuer im 3D-Inspector parametrisch anpassen, speichern und im Blueprint kontrollieren."
log "Treppen/alle Etagen/Wanddetail-Migration sind fuer die Folgeinkremente vorgesehen."
