#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1540_150m_kamera_feste_startpose"
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
COMMIT_MESSAGE="Update 150m: deterministic camera preparation, fixed top view during fade, smooth 5s flight"
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
  echo "2) Update 150m im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150m isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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
fail() { log ""; log "ERROR: $*"; log "Diagnostics: $DIAG_LOG"; if [ -f "$DIAG_LOG" ]; then echo '--- Last diagnostic lines ---'; tail -n 100 "$DIAG_LOG"; fi; exit 1; }
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
  for candidate in /home/mpwh/.nvm/versions/node/*/bin/node /root/.nvm/versions/node/*/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -x "$candidate" ] || continue
    version="$($candidate -p 'process.versions.node' 2>/dev/null || true)"
    node_supported "$version" || continue
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best_v" "$version" | sort -V | tail -n 1)" = "$version" ]; then best="$candidate";best_v="$version"; fi
  done
  [ -n "$best" ] || fail "Node >=20.19 or >=22.12 missing"
  export PATH="$(dirname "$best"):$PATH";hash -r 2>/dev/null || true
  log "Node: $best ($best_v), npm: $(npm -v 2>/dev/null || echo missing)"
}


log "=== Update 150m: Blender starts only after an actual R3F camera has been locked ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
# This is a deliberate replacement of the 150l camera module, not a reinstallation of update 150.
grep -Fq 'STROM150L_READY_HANDSHAKE' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "150m requires installed 150l. Existing stage is different; no files changed."
grep -Fq 'STROM150C_PRESERVE_BLUEPRINT' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150m requires the live Blueprint overlay introduced by 150c"
grep -Fq 'STROM150K_FAIL_CLOSED' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150m requires the safe fallback guard introduced by 150k"
grep -Fq 'export const ENTER_FADE150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "Expected 5000ms fade constant not found"
grep -Fq 'export const DURATION150=5000' "$STAGE_DIR/frontend/src/components/cameraTransitions150.ts" || \
  fail "Expected 5000ms flight constant not found"
select_node
log "1) Backup current Stage source ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no live source backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
fi
log "2) Prepare fully isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Unable to copy Stage source"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "Missing existing TypeScript/Vite/Three dependencies"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/150m_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/CameraFlight150.tsx" <<'STROM150M_FLIGHT_TSX'
import { useLayoutEffect, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import {
  consumeEntry150, restoreEntry150, currentFrame150,
  registerExit150, notifyEnterReady150, DURATION150, ENTER_FADE150,
} from './cameraTransitions150'
import type { BlueprintFrame150, Enter150 } from './cameraTransitions150'

type PlanPoint = { x: number; y: number }
type OrbitControl = {
  target?: THREE.Vector3
  enabled?: boolean
  update?: () => void
}
type CameraPose = {
  position: THREE.Vector3
  rotation: THREE.Quaternion
  target: THREE.Vector3
  up: THREE.Vector3
  zoom: number
}
type CameraFlight = {
  kind: 'entry' | 'exit'
  start: CameraPose
  end: CameraPose
  phase: 'prepare' | 'fade' | 'flight'
  preparedFrames: number
  movementStartsAt: number
  finish?: () => void
}
type FrozenOrbit = { control: OrbitControl; update?: () => void; enabled?: boolean }

const clamp01 = (t: number) => Math.min(1, Math.max(0, t))
const easeOut = (t: number) => 1 - Math.pow(1 - t, 3)

function planBounds(points: readonly PlanPoint[], frame: BlueprintFrame150 | null) {
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  for (const point of points) {
    if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) continue
    minX = Math.min(minX, point.x); maxX = Math.max(maxX, point.x)
    minY = Math.min(minY, point.y); maxY = Math.max(maxY, point.y)
  }
  if (!Number.isFinite(minX)) { minX = -4; maxX = 4; minY = -3; maxY = 3 }
  const width = Math.max(2, maxX - minX)
  const height = Math.max(2, maxY - minY)
  if (frame && frame.widthM > 0.1 && frame.heightM > 0.1 && frame.widthM < 150 && frame.heightM < 150) {
    return { cx: frame.cx, cy: frame.cy, width: frame.widthM, height: frame.heightM }
  }
  return { cx: (minX + maxX) / 2, cy: (minY + maxY) / 2, width: width * 1.14, height: height * 1.14 }
}

// STROM150M_BLUEPRINT_BASIS: use exactly the same landscape choice as 150h.
// A blueprint right/up pair is an orthogonal 3D XZ basis viewed from +Y.
function topBasis(points: readonly PlanPoint[]) {
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  for (const p of points) {
    if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) continue
    minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x)
    minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y)
  }
  const spanX = Number.isFinite(minX) ? maxX - minX : 0
  const spanY = Number.isFinite(minY) ? maxY - minY : 0
  if (spanY > spanX * 1.12 && spanY > 0.1) {
    return { right: new THREE.Vector3(0, 0, -1), up: new THREE.Vector3(-1, 0, 0), swapped: true }
  }
  return { right: new THREE.Vector3(1, 0, 0), up: new THREE.Vector3(0, 0, -1), swapped: false }
}

function capturePose(camera: THREE.Camera, control: OrbitControl | null, fallback: THREE.Vector3): CameraPose {
  return {
    position: camera.position.clone(),
    rotation: camera.quaternion.clone(),
    target: control?.target?.clone() || fallback.clone(),
    up: camera.up.clone(),
    zoom: (camera as THREE.OrthographicCamera).zoom || 1,
  }
}
function overheadPose(camera: THREE.Camera, points: readonly PlanPoint[], frame: BlueprintFrame150 | null, aspect: number, levelY: number) {
  const bounds = planBounds(points, frame)
  const basis = topBasis(points)
  const width = basis.swapped ? bounds.height : bounds.width
  const height = basis.swapped ? bounds.width : bounds.height
  const target = new THREE.Vector3(bounds.cx, levelY, bounds.cy)
  let distance = 12, zoom = (camera as THREE.OrthographicCamera).zoom || 1
  if ((camera as THREE.PerspectiveCamera).isPerspectiveCamera) {
    const fov = THREE.MathUtils.degToRad((camera as THREE.PerspectiveCamera).fov || 45)
    const tangent = Math.max(0.05, Math.tan(fov / 2))
    distance = Math.max(2, Math.min(500, Math.max(height / 2 / tangent, width / 2 / Math.max(0.3, aspect) / tangent)))
    // A little clearance avoids clipping at the top of tall walls.
    distance *= 1.10
  } else if ((camera as THREE.OrthographicCamera).isOrthographicCamera) {
    const ortho = camera as THREE.OrthographicCamera
    zoom = Math.min(100, Math.max(0.05, Math.min(
      Math.abs(ortho.right - ortho.left) / width,
      Math.abs(ortho.top - ortho.bottom) / height,
    )))
    distance = Math.max(10, height * 2, width * 2)
  }
  const position = new THREE.Vector3(target.x, target.y + distance, target.z)
  const matrix = new THREE.Matrix4().makeBasis(basis.right, basis.up, new THREE.Vector3(0, 1, 0))
  return {
    position, rotation: new THREE.Quaternion().setFromRotationMatrix(matrix),
    target, up: basis.up.clone(), zoom,
  }
}

/** STROM150M_EXPLICIT_PHASES: Blueprint+spinner -> locked top pose -> fade -> flight. */
export default function CameraFlight150({ points }: { points: readonly PlanPoint[] }) {
  // Do not subscribe to a replaceable camera or to the late OrbitControls registration.
  // state.camera in useFrame is the camera used to render that *same* frame.
  const get = useThree(state => state.get)
  const invalidate = useThree(state => state.invalidate)
  const queuedEntry = useRef<Enter150 | null>(null)
  const exitRequest = useRef<(() => void) | null>(null)
  const flight = useRef<CameraFlight | null>(null)
  const frozen = useRef<FrozenOrbit | null>(null)
  const pointsRef = useRef(points)
  pointsRef.current = points

  const orbit = () => ((get().controls || null) as OrbitControl | null)
  const releaseOrbit = () => {
    const old = frozen.current
    if (!old) return
    if (old.update) old.control.update = old.update
    if (old.enabled !== undefined) old.control.enabled = old.enabled
    frozen.current = null
  }
  const lockOrbit = () => {
    const control = orbit()
    if (frozen.current?.control === control) return
    releaseOrbit()
    if (!control) return
    frozen.current = { control, update: control.update, enabled: control.enabled }
    control.enabled = false
    // Drei may call OrbitControls.update each frame even when enabled=false.
    if (control.update) control.update = () => {}
  }
  const applyPose = (camera: THREE.Camera, pose: CameraPose) => {
    camera.position.copy(pose.position)
    camera.quaternion.copy(pose.rotation)
    camera.up.copy(pose.up)
    const control = orbit()
    if (control?.target) control.target.copy(pose.target)
    const ortho = camera as THREE.OrthographicCamera
    if (ortho.isOrthographicCamera) { ortho.zoom = pose.zoom; ortho.updateProjectionMatrix() }
    camera.updateMatrixWorld()
    invalidate()
  }

  useLayoutEffect(() => {
    queuedEntry.current = consumeEntry150()
    if (queuedEntry.current) invalidate()
    // Merely queue the reverse here. The true camera is sampled in useFrame,
    // not in a click handler or a stale React effect.
    const unregister = registerExit150(done => {
      exitRequest.current = done
      invalidate()
    })
    return () => {
      unregister()
      if (queuedEntry.current) restoreEntry150(queuedEntry.current)
      queuedEntry.current = null
      exitRequest.current = null
      flight.current = null
      releaseOrbit()
    }
    // get/invalidate are stable R3F store callbacks for the lifetime of Canvas.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [get, invalidate])

  // Priority 0: runs after Drei OrbitControls (-1), before the Canvas render.
  useFrame(state => {
    const camera = state.camera
    const control = orbit()
    const pts = pointsRef.current
    const aspect = Math.max(0.3, state.size.width / Math.max(state.size.height, 1))

    if (exitRequest.current) {
      const done = exitRequest.current
      exitRequest.current = null
      queuedEntry.current = null
      const current = capturePose(camera, control, new THREE.Vector3(0, 0, 0))
      const top = overheadPose(camera, pts, currentFrame150(), aspect, current.target.y)
      lockOrbit()
      flight.current = {
        kind: 'exit', start: current, end: top,
        phase: 'flight', preparedFrames: 0, movementStartsAt: performance.now(), finish: done,
      }
    }

    if (queuedEntry.current) {
      const incoming = queuedEntry.current
      queuedEntry.current = null
      const original = capturePose(camera, control, new THREE.Vector3(0, 0, 0))
      const top = overheadPose(camera, pts, incoming.frame, aspect, original.target.y)
      lockOrbit()
      flight.current = {
        kind: 'entry', start: top, end: original,
        phase: 'prepare', preparedFrames: 0, movementStartsAt: Number.POSITIVE_INFINITY,
      }
      // IMPORTANT: the first camera frame is prepared before any fade is allowed.
      applyPose(camera, top)
      return
    }

    const running = flight.current
    if (!running) return
    // Even if OrbitControls registers late, prevent it from overwriting the
    // locked start pose while preparing or fading.
    lockOrbit()

    if (running.kind === 'entry' && running.phase === 'prepare') {
      // STROM150M_LOCKED_START: same camera, same pose every frame, no rotations.
      applyPose(camera, running.start)
      running.preparedFrames++
      if (running.preparedFrames >= 3) {
        running.movementStartsAt = performance.now() + ENTER_FADE150
        running.phase = 'fade'
        // This signal is emitted by the actual R3F render loop, not RAF timers,
        // invisible meshes or OrbitControls readiness predicates.
        notifyEnterReady150()
      }
      return
    }

    if (running.kind === 'entry' && running.phase === 'fade') {
      // STROM150M_CROSSFADE_LOCK: no camera movement throughout the whole fade.
      applyPose(camera, running.start)
      if (performance.now() >= running.movementStartsAt) running.phase = 'flight'
      return
    }

    const t = clamp01((performance.now() - running.movementStartsAt) / DURATION150)
    const k = easeOut(t)
    const a = running.start, b = running.end
    const pose: CameraPose = {
      position: a.position.clone().lerp(b.position, k),
      rotation: a.rotation.clone().slerp(b.rotation, k),
      target: a.target.clone().lerp(b.target, k),
      up: k >= 1 ? b.up.clone() : a.up.clone(),
      zoom: a.zoom + (b.zoom - a.zoom) * k,
    }
    applyPose(camera, pose)
    if (t < 1) return

    applyPose(camera, b)
    flight.current = null
    if (running.kind === 'exit') {
      // Remain locked until the 3D Canvas actually unmounts.
      running.finish?.()
      return
    }
    // Entry completed: restore OrbitControls only at the final default pose.
    releaseOrbit()
    const live = orbit()
    if (live?.target) live.target.copy(b.target)
    live?.update?.()
    applyPose(camera, b)
  })
  return null
}
STROM150M_FLIGHT_TSX
cat > "$RESOURCE_DIR/test_camera.js" <<'STROM150M_TEST_JS'
'use strict'
const fs=require('fs'),assert=require('assert'),ts=require(process.env.STROM150M_TS||'typescript')
const source=process.env.STROM150M_SOURCE||'/mnt/data/150m_work/CameraFlight150.tsx'
const code=fs.readFileSync(source,'utf8')
const parsed=ts.createSourceFile(source,code,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
assert.equal(parsed.parseDiagnostics.length,0,'TSX must parse')
for(const marker of ['STROM150M_EXPLICIT_PHASES','STROM150M_LOCKED_START','STROM150M_CROSSFADE_LOCK','STROM150M_BLUEPRINT_BASIS'])assert(code.includes(marker),'marker '+marker)
assert(!code.includes('STROM150L_READY_HANDSHAKE'),'obsolete gate removed')
class Vec {
 constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}
 clone(){return new Vec(this.x,this.y,this.z)}
 copy(p){this.x=p.x;this.y=p.y;this.z=p.z;return this}
 lerp(p,t){this.x+=(p.x-this.x)*t;this.y+=(p.y-this.y)*t;this.z+=(p.z-this.z)*t;return this}
 distanceTo(p){return Math.hypot(this.x-p.x,this.y-p.y,this.z-p.z)}
}
class Quat {
 constructor(n=0){this.n=n}
 clone(){return new Quat(this.n)}
 copy(p){this.n=p.n;return this}
 slerp(p,t){this.n+=(p.n-this.n)*t;return this}
 setFromRotationMatrix(m){this.n=100+(m.right.z||0)*10;return this}
 dot(q){return this.n===q.n?1:.5}
}
class Mat {
 makeBasis(right,up,back){this.right=right;this.up=up;this.back=back;return this}
}
const Three={Vector3:Vec,Quaternion:Quat,Matrix4:Mat,MathUtils:{degToRad:deg=>deg*Math.PI/180}}
let pending=null,onReady=null,onExit=null,fade=5000,duration=5000
const bridge={
  consumeEntry150(){const e=pending;pending=null;return e},
  restoreEntry150(e){if(!pending)pending=e},
  currentFrame150(){return {floorId:'test',levelId:'A',cx:5,cy:3,widthM:12,heightM:8}},
  registerExit150(fn){onExit=fn;return ()=>{if(onExit===fn)onExit=null}},
  notifyEnterReady150(){onReady?.()},
  DURATION150:duration,ENTER_FADE150:fade,
}
let callbacks=[],cleanups=[],now=1000,invalidated=0
let orbitOrientation=12
const control={enabled:true,target:new Vec(5,0,3),update(){camera.quaternion.n=orbitOrientation}}
const originalUpdate=control.update
const camera={
  position:new Vec(8,14,12),quaternion:new Quat(12),up:new Vec(0,1,0),
  fov:45,isPerspectiveCamera:true,isOrthographicCamera:false,
  updateMatrixWorld(){},
}
const state={
  camera,size:{width:1200,height:800},controls:control,
  get(){return state},invalidate(){invalidated++}
}
const React={
  useRef:v=>({current:v}),
  useLayoutEffect:fn=>{const cleanup=fn();if(typeof cleanup==='function')cleanups.push(cleanup)}
}
const Fiber={useThree:fn=>fn(state),useFrame:fn=>{callbacks.push(fn)}}
const transpiled=ts.transpileModule(code,{fileName:source,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}})
assert.equal(transpiled.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length||0,0)
const moduleFlight={exports:{}}
const req=name=>name==='react'?React:name==='@react-three/fiber'?Fiber:name==='three'?Three:name==='./cameraTransitions150'?bridge:(()=>{throw Error('Unexpected '+name)})()
new Function('module','exports','require','performance',transpiled.outputText)(moduleFlight,moduleFlight.exports,req,{now:()=>now})
function launch(entry,pts){
  callbacks=[];cleanups=[];pending=entry
  const output=moduleFlight.exports.default({points:pts})
  assert.equal(output,null)
  assert.equal(callbacks.length,1)
  assert(onExit)
}
function tick(){if(state.controls?.update)state.controls.update();callbacks[0](state)}
let ready=0
onReady=()=>ready++
const points=[{x:0,y:0},{x:11,y:0},{x:11,y:6},{x:0,y:6}]
launch({mode:'threeD',frame:{floorId:'test',levelId:'A',cx:5,cy:3,widthM:12,heightM:8}},points)
tick()
const top=camera.position.clone(),topQuat=camera.quaternion.clone()
assert.equal(ready,0,'spinner stays during first setup frame')
assert.equal(control.enabled,false,'OrbitControls disabled before rendering overhead')
assert.equal(camera.quaternion.n,100,'top orientation follows X+ and Z- basis')
assert.notEqual(control.update,originalUpdate,'OrbitControls frame updates suppressed')
for(let i=0;i<2;i++){tick();assert.equal(ready,0);assert.equal(camera.position.distanceTo(top),0)}
tick()
assert.equal(ready,1,'ready after exactly three stable preparation frames')
assert.equal(camera.quaternion.n,topQuat.n,'top rotation identical when ready')
now=3000;tick()
assert.equal(camera.position.distanceTo(top),0,'top position locked during crossfade')
assert.equal(camera.quaternion.n,topQuat.n,'top quaternion locked during crossfade')
now=5999;tick();assert.equal(camera.position.distanceTo(top),0,'no movement before fade end')
now=6000;tick();assert.equal(camera.position.distanceTo(top),0,'first frame at fade end remains fixed')
now=8500;tick();assert(camera.position.distanceTo(top)>0.0001,'flight starts after fade')
assert(camera.position.distanceTo(new Vec(8,14,12))>0.0001,'not at default until flight completes')
now=11000;tick();assert.equal(camera.position.distanceTo(new Vec(8,14,12)),0,'default pose restored at end')
assert.equal(camera.quaternion.n,12,'original default rotation exact')
assert.equal(control.enabled,true,'orbit re-enabled after flight')
assert.equal(control.update,originalUpdate,'original orbit.update restored')
assert(invalidated>0,'demand Canvas invalidation active')
// Reverse starts from current real displayed camera pose and ends at the same bird's-eye basis.
camera.position.copy(new Vec(14,10,13));camera.quaternion.n=21;orbitOrientation=21
let exitDone=0
onExit(()=>exitDone++)
now=12000;tick()
assert.equal(control.enabled,false,'reverse movement freezes controls')
assert.equal(camera.quaternion.n,21,'reverse first frame retains user camera quaternion')
now=14500;tick();assert.equal(exitDone,0)
now=17000;tick();assert.equal(exitDone,1,'reverse completes only after full 5000ms')
assert.equal(camera.quaternion.n,100,'reverse ends at matching blueprint top angle')
cleanups.forEach(fn=>fn())
assert.equal(control.update,originalUpdate)
console.log('PASS 150m runtime: hold -> 3 preparation frames -> full 5s fade with unchanged pose -> full 5s eased flight -> exact default; reverse from real pose to top; OrbitControls lock/unlock')
STROM150M_TEST_JS
log "3) Replace the 150l wait chain with an explicit R3F frame-driven camera state machine ..."
install -m 644 "$RESOURCE_DIR/CameraFlight150.tsx" "$WORK_DIR/frontend/src/components/CameraFlight150.tsx"
log "4) TypeScript AST audit and 5s phase invariants ..."
STROM150M_ROOT="$WORK_DIR/frontend/src" STROM150M_TS="$DEPENDENCIES/typescript" node <<'STROM150M_AST' >>"$DIAG_LOG" 2>&1 || fail "150m AST audit failed; GitHub and Stage unchanged"
'use strict'
const fs=require('fs'),assert=require('assert'),path=require('path'),ts=require(process.env.STROM150M_TS)
const root=process.env.STROM150M_ROOT
for(const rel of ['App.tsx','components/CameraFlight150.tsx','components/cameraTransitions150.ts','components/Building3DWorkspace.tsx']){
 const file=path.join(root,rel),str=fs.readFileSync(file,'utf8')
 const ast=ts.createSourceFile(file,str,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 assert.equal(ast.parseDiagnostics.length,0,rel+': TS/TSX parse errors '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const css=fs.readFileSync(path.join(root,'styles.css'),'utf8')
for(const marker of ['STROM150M_EXPLICIT_PHASES','STROM150M_LOCKED_START','STROM150M_CROSSFADE_LOCK','STROM150M_BLUEPRINT_BASIS','notifyEnterReady150()']){
 assert(flight.includes(marker),'Missing 150m camera invariant '+marker)
}
assert(!flight.includes('readyScheduled150l'),'Old 150l ready gate must be absent')
assert(!flight.includes('readyRaf150l'),'Old 150l RAF ready gate must be absent')
assert.equal((flight.match(/notifyEnterReady150\(\)/g)||[]).length,1,'Ready notification must be unique')
assert(app.includes('STROM150C_PRESERVE_BLUEPRINT')&&app.includes('STROM150E_LOADING_GUARD'),'Blueprint overlay must be retained')
assert(bridge.includes('export const ENTER_FADE150=5000')&&bridge.includes('export const DURATION150=5000'),'5 second timings must be retained')
assert(css.includes('transition:opacity 5000ms ease;'),'CSS fade must be 5000ms')
console.log('PASS 150m AST: prepared R3F camera first, fade second, flight third; 5s/5s retained')
STROM150M_AST
log "5) Full TypeScript and Vite build against real Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150m TypeScript/Vite build failed before GitHub push"
log "5.1) Simulated camera timeline, control-lock and reverse-flight regressions ..."
STROM150M_SOURCE="$WORK_DIR/frontend/src/components/CameraFlight150.tsx" STROM150M_TS="$DEPENDENCIES/typescript" \
 node "$RESOURCE_DIR/test_camera.js" >>"$DIAG_LOG" 2>&1 || fail "150m runtime regression failed; GitHub and Stage unchanged"
log "PASS: verified 3 preparation frames, locked camera during full 5000ms crossfade, 5000ms flight and smooth reverse"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150M.md" <<'STROM150M_DOC'
# Update 150m: Kamerastart, Blende und Flug strikt entkoppelt
- Ersetzt die 150l-Renderbestaetigung durch eine deterministische R3F Frame-Sequenz.
- Kamera ist beim ersten 3D-Frame korrekt auf die Blueprint-ausgerichtete Vogelperspektive eingestellt.
- Drei weitere Frame-Ticks halten dieselbe Kamerapose, bevor die Original-Blueprint-Ebene mit Ladeindikator ausgeblendet wird.
- Waerend der vollen Blende (5000ms) wird dieselbe Kamerapose in JEDEM 3D-Frame erneut angewendet.
- Erst nach Ende der Blende beginnt die Ease-out-Fahrt (5000ms).
- Bei Rueckkehr startet die Kamera von der tatsaechlich gerenderten aktuellen Ansicht.
- OrbitControls wird waehrend Vorbereitung, Blende und Fahrt deaktiviert und erst danach wiederhergestellt.
- Die vorhandene Ladeoberflaeche, 3D-Geometrie, Icons, Modelldaten und die Produktionsansicht bleiben unveraendert.
- Isolierter TS/Vite Build und Kamera-Regressionstests vor GitHub-Push; danach Stage und /strom-test/ only.
STROM150M_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150m Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150m Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150m frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150m test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150m deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
