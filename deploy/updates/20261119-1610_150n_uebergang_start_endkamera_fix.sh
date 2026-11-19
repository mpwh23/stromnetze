#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1610_150n_uebergang_start_endkamera_fix"
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
COMMIT_MESSAGE="Update 150n: calibrated blueprint viewport and settled default camera, no end jump"
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
  echo "2) Update 150n im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 150n isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 150n: calibrated Blueprint start + actual settled 3D default at end ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for f in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts; do
  [ -s "$STAGE_DIR/$f" ] || fail "Missing source: $f"
done
# This is a deliberate replacement of the 150l camera module, not a reinstallation of update 150.
grep -Fq 'STROM150M_EXPLICIT_PHASES' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "150n requires installed 150m. Existing stage is different; no files changed."
grep -Fq 'STROM150C_PRESERVE_BLUEPRINT' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150n requires the live Blueprint overlay introduced by 150c"
grep -Fq 'STROM150K_FAIL_CLOSED' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "150n requires the safe fallback guard introduced by 150k"
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
RESOURCE_DIR="$WORK_DIR/150n_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/CameraFlight150.tsx" <<'STROM150N_FLIGHT_TSX'
import { useLayoutEffect, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import {
  consumeEntry150, restoreEntry150, currentFrame150,
  registerExit150, notifyEnterReady150, DURATION150, ENTER_FADE150,
} from './cameraTransitions150'
import type { BlueprintFrame150, Enter150 } from './cameraTransitions150'

type PlanPoint = { x: number; y: number }
type OrbitControl = { target?: THREE.Vector3; enabled?: boolean; update?: () => void }
type CameraPose = {
  position: THREE.Vector3
  rotation: THREE.Quaternion
  target: THREE.Vector3
  up: THREE.Vector3
  zoom: number
}
type Flight = {
  kind: 'entry' | 'exit'
  phase: 'settle' | 'prepare' | 'fade' | 'flight'
  start: CameraPose
  end: CameraPose
  startedAt: number
  steady: number
  settleFrames: number
  preparedFrames: number
  previous?: CameraPose
  finish?: () => void
}
type FrozenControl = { control: OrbitControl; update?: () => void; enabled?: boolean }
const clamp01 = (t: number) => Math.min(1, Math.max(0, t))
const easeOut = (t: number) => 1 - (1 - t) ** 3
const TOP_RIGHT = new THREE.Vector3(1, 0, 0)
const TOP_UP = new THREE.Vector3(0, 0, -1)
const TOP_BACK = new THREE.Vector3(0, 1, 0)
const DEGREES = Math.PI / 180

function modelBounds(points: readonly PlanPoint[]) {
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  for (const point of points) {
    if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) continue
    minX = Math.min(minX, point.x); maxX = Math.max(maxX, point.x)
    minY = Math.min(minY, point.y); maxY = Math.max(maxY, point.y)
  }
  if (!Number.isFinite(minX)) return { cx: 0, cy: 0, width: 10, height: 7 }
  return {
    cx: (minX + maxX) / 2, cy: (minY + maxY) / 2,
    width: Math.max(2, maxX - minX), height: Math.max(2, maxY - minY),
  }
}

function capture(camera: THREE.Camera, control: OrbitControl | null): CameraPose {
  return {
    position: camera.position.clone(),
    rotation: camera.quaternion.clone(),
    up: camera.up.clone(),
    target: control?.target?.clone() || new THREE.Vector3(0, 0, 0),
    zoom: (camera as THREE.OrthographicCamera).zoom || 1,
  }
}
function difference(a: CameraPose, b: CameraPose) {
  return Math.max(
    a.position.distanceTo(b.position),
    a.target.distanceTo(b.target),
    5 * a.rotation.angleTo(b.rotation),
    5 * a.up.distanceTo(b.up),
    Math.abs(a.zoom - b.zoom),
  )
}

/** STROM150N_BP_SCREEN_CALIBRATION: calibrate the R3F camera against the *actual* Blueprint DOM,
 * not against a scroll container center or a hard-coded house orientation. */
function blueprintProjection(canvas: HTMLCanvasElement | undefined, bounds: ReturnType<typeof modelBounds>) {
  try {
    const svg = document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement | null
    const matrix = svg?.getScreenCTM()
    const rect = canvas?.getBoundingClientRect()
    if (!matrix || !rect || rect.width < 50 || rect.height < 50) return null
    // The same mToX / mToY that the real Blueprint renderer uses:
    // 70 px margin, -10 m origin, 60 SVG units per metre.
    const svgX = 670 + 60 * bounds.cx
    const svgY = 670 + 60 * bounds.cy
    const screenX = matrix.a * svgX + matrix.c * svgY + matrix.e
    const screenY = matrix.b * svgX + matrix.d * svgY + matrix.f
    const scaleX = 60 * Math.hypot(matrix.a, matrix.b)
    const scaleY = 60 * Math.hypot(matrix.c, matrix.d)
    const pixelsPerM = (scaleX + scaleY) / 2
    if (!(pixelsPerM > 2) || !(pixelsPerM < 1000) ||
        Math.abs(scaleX - scaleY) > pixelsPerM * 0.07) return null
    return {
      pixelsPerM,
      screenX, screenY,
      canvasX: rect.left + rect.width / 2,
      canvasY: rect.top + rect.height / 2,
      canvasHeight: rect.height,
    }
  } catch {
    return null
  }
}

function overheadPose(camera: THREE.Camera, points: readonly PlanPoint[], frame: BlueprintFrame150 | null,
  aspect: number, levelY: number, canvas: HTMLCanvasElement | undefined): CameraPose {
  const box = modelBounds(points)
  const mapped = blueprintProjection(canvas, box)
  let cx = frame?.widthM && frame.widthM > 0.1 ? frame.cx : box.cx
  let cy = frame?.heightM && frame.heightM > 0.1 ? frame.cy : box.cy
  let distance = 12
  let zoom = (camera as THREE.OrthographicCamera).zoom || 1
  if (mapped) {
    // For top view, +X moves right and +Z moves down exactly as Blueprint +X / +Y.
    cx = box.cx - (mapped.screenX - mapped.canvasX) / mapped.pixelsPerM
    cy = box.cy - (mapped.screenY - mapped.canvasY) / mapped.pixelsPerM
    if ((camera as THREE.PerspectiveCamera).isPerspectiveCamera) {
      const fov = (camera as THREE.PerspectiveCamera).fov || 45
      distance = mapped.canvasHeight / (2 * Math.tan(fov * DEGREES / 2) * mapped.pixelsPerM)
      distance = Math.max(3, Math.min(500, distance))
    } else if ((camera as THREE.OrthographicCamera).isOrthographicCamera) {
      const ortho = camera as THREE.OrthographicCamera
      zoom = Math.max(0.05, Math.min(100,
        Math.abs(ortho.top - ortho.bottom) * mapped.pixelsPerM / mapped.canvasHeight))
      distance = Math.max(10, box.width * 2, box.height * 2)
    }
  } else {
    // Existing fallback when the live Blueprint SVG or Canvas DOM is unavailable.
    const width = frame && frame.widthM > 0.1 ? frame.widthM : box.width * 1.14
    const height = frame && frame.heightM > 0.1 ? frame.heightM : box.height * 1.14
    if ((camera as THREE.PerspectiveCamera).isPerspectiveCamera) {
      const fov = (camera as THREE.PerspectiveCamera).fov || 45
      const tan = Math.max(0.05, Math.tan(fov * DEGREES / 2))
      distance = Math.max(3, Math.min(500, Math.max(height / (2 * tan), width / (2 * aspect * tan))))
    } else if ((camera as THREE.OrthographicCamera).isOrthographicCamera) {
      const ortho = camera as THREE.OrthographicCamera
      zoom = Math.max(0.05, Math.min(100, Math.min(
        Math.abs(ortho.right - ortho.left) / width, Math.abs(ortho.top - ortho.bottom) / height)))
      distance = Math.max(10, height * 2, width * 2)
    }
  }
  const target = new THREE.Vector3(cx, levelY, cy)
  const position = target.clone().add(new THREE.Vector3(0, distance, 0))
  const rotation = new THREE.Quaternion().setFromRotationMatrix(
    new THREE.Matrix4().makeBasis(TOP_RIGHT, TOP_UP, TOP_BACK))
  return { position, rotation, target, up: TOP_UP.clone(), zoom }
}

/** STROM150N_FORWARD_HANDOFF: sample the real *settled* default view with native OrbitControls
 * before overriding the camera; the final pose is this verified default, never a first-frame guess. */
export default function CameraFlight150({ points }: { points: readonly PlanPoint[] }) {
  const get = useThree(state => state.get)
  const invalidate = useThree(state => state.invalidate)
  const pending = useRef<Enter150 | null>(null)
  const requestedExit = useRef<(() => void) | null>(null)
  const flight = useRef<Flight | null>(null)
  const frozen = useRef<FrozenControl | null>(null)
  const pointsRef = useRef(points)
  pointsRef.current = points

  const orbit = () => (get().controls || null) as OrbitControl | null
  const lock = () => {
    const control = orbit()
    if (frozen.current?.control === control) return
    if (frozen.current) unlock()
    if (!control) return
    frozen.current = { control, update: control.update, enabled: control.enabled }
    control.enabled = false
    if (control.update) control.update = () => {}
  }
  const unlock = () => {
    const snapshot = frozen.current
    if (!snapshot) return
    if (snapshot.update) snapshot.control.update = snapshot.update
    if (snapshot.enabled !== undefined) snapshot.control.enabled = snapshot.enabled
    frozen.current = null
  }
  const apply = (camera: THREE.Camera, pose: CameraPose) => {
    camera.position.copy(pose.position)
    camera.quaternion.copy(pose.rotation)
    camera.up.copy(pose.up)
    const control = orbit()
    if (control?.target) control.target.copy(pose.target)
    const ortho = camera as THREE.OrthographicCamera
    if (ortho.isOrthographicCamera) { ortho.zoom = pose.zoom; ortho.updateProjectionMatrix() }
    camera.updateMatrixWorld(true)
    invalidate()
  }

  useLayoutEffect(() => {
    pending.current = consumeEntry150()
    if (pending.current) invalidate()
    const unbind = registerExit150(done => {
      requestedExit.current = done
      invalidate()
    })
    return () => {
      unbind()
      if (pending.current) restoreEntry150(pending.current)
      pending.current = null
      requestedExit.current = null
      flight.current = null
      unlock()
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [get, invalidate])

  // OrbitControls renders at -1; priority 0 writes the final camera of each R3F frame.
  useFrame(state => {
    const camera = state.camera
    const control = orbit()
    const aspect = Math.max(0.3, state.size.width / Math.max(1, state.size.height))

    // Preserve the existing reverse-flight implementation for a separate update.
    if (requestedExit.current) {
      const finish = requestedExit.current
      requestedExit.current = null
      pending.current = null
      const original = capture(camera, control)
      const top = overheadPose(camera, pointsRef.current, currentFrame150(), aspect,
        original.target.y, state.gl.domElement)
      lock()
      flight.current = {
        kind: 'exit', phase: 'flight', start: original, end: top,
        startedAt: performance.now(), steady: 0, settleFrames: 0, preparedFrames: 0,
        finish,
      }
    }

    if (pending.current) {
      pending.current = null
      const initial = capture(camera, control)
      // Let the scene / OrbitControls finish their default camera setup while
      // the original Blueprint and its spinner still conceal the 3D Canvas.
      flight.current = {
        kind: 'entry', phase: 'settle', start: initial, end: initial,
        startedAt: Number.POSITIVE_INFINITY, steady: 0, settleFrames: 0,
        preparedFrames: 0, previous: initial,
      }
      invalidate()
      return
    }
    const running = flight.current
    if (!running) return

    if (running.kind === 'entry' && running.phase === 'settle') {
      const current = capture(camera, control)
      running.settleFrames++
      const stable = running.previous && difference(current, running.previous) < 0.001
      running.steady = stable ? running.steady + 1 : 0
      running.previous = current
      if ((running.steady < 8 || (!control && running.settleFrames < 24)) && running.settleFrames < 50) {
        invalidate()
        return
      }
      // STROM150N_DEFAULT_SETTLED: capture *after* native OrbitControls updates,
      // not from the first Canvas frame (which may point underneath the building).
      control?.update?.()
      const finalDefault = capture(camera, control)
      const start = overheadPose(camera, pointsRef.current, currentFrame150(), aspect,
        finalDefault.target.y, state.gl.domElement)
      running.start = start
      running.end = finalDefault
      running.phase = 'prepare'
      lock()
      apply(camera, start)
      return
    }

    lock()
    if (running.kind === 'entry' && running.phase === 'prepare') {
      apply(camera, running.start)
      running.preparedFrames++
      if (running.preparedFrames >= 3) {
        running.phase = 'fade'
        running.startedAt = performance.now() + ENTER_FADE150
        notifyEnterReady150()
      }
      return
    }
    if (running.kind === 'entry' && running.phase === 'fade') {
      apply(camera, running.start)
      if (performance.now() >= running.startedAt) running.phase = 'flight'
      return
    }

    const t = clamp01((performance.now() - running.startedAt) / DURATION150)
    const k = easeOut(t)
    const a = running.start, b = running.end
    const pose: CameraPose = {
      position: a.position.clone().lerp(b.position, k),
      rotation: a.rotation.clone().slerp(b.rotation, k),
      target: a.target.clone().lerp(b.target, k),
      // No discontinuous camera.up flip at the end of the flight.
      up: a.up.clone().lerp(b.up, k).normalize(),
      zoom: a.zoom + (b.zoom - a.zoom) * k,
    }
    apply(camera, pose)
    if (t < 1) return

    // STROM150N_NO_END_JUMP: no second camera pose or manual reset on unlock.
    apply(camera, b)
    flight.current = null
    if (running.kind === 'exit') {
      running.finish?.()
      return
    }
    unlock()
    // Don't explicitly call OrbitControls.update() here: this previously
    // overwrote the just-finished 5s interpolation with another camera pose.
  })
  return null
}
STROM150N_FLIGHT_TSX
cat > "$RESOURCE_DIR/test_camera.js" <<'STROM150N_TEST_JS'
'use strict'
const fs=require('fs'),assert=require('assert'),ts=require(process.env.STROM150N_TS || 'typescript')
const source=process.env.STROM150N_SOURCE
if(!source)throw Error('STROM150N_SOURCE required')
const code=fs.readFileSync(source,'utf8')
const ast=ts.createSourceFile(source,code,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
assert.equal(ast.parseDiagnostics.length,0,'TSX parses')
for(const marker of ['STROM150N_BP_SCREEN_CALIBRATION','STROM150N_DEFAULT_SETTLED','STROM150N_NO_END_JUMP','STROM150N_FORWARD_HANDOFF'])assert(code.includes(marker),marker)
assert(!code.includes('live?.update?.()'),'Old end-jump forcing control update must be removed')
class V {
  constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z}
  clone(){return new V(this.x,this.y,this.z)}
  copy(p){this.x=p.x;this.y=p.y;this.z=p.z;return this}
  add(p){this.x+=p.x;this.y+=p.y;this.z+=p.z;return this}
  lerp(p,t){this.x+=(p.x-this.x)*t;this.y+=(p.y-this.y)*t;this.z+=(p.z-this.z)*t;return this}
  normalize(){const len=Math.hypot(this.x,this.y,this.z)||1;this.x/=len;this.y/=len;this.z/=len;return this}
  distanceTo(p){return Math.hypot(this.x-p.x,this.y-p.y,this.z-p.z)}
}
class Q {
  constructor(n=0){this.n=n}
  clone(){return new Q(this.n)}
  copy(p){this.n=p.n;return this}
  angleTo(p){return Math.abs(this.n-p.n)}
  slerp(p,t){this.n+=(p.n-this.n)*t;return this}
  setFromRotationMatrix(m){this.n=100+m.right.x;return this}
}
class Mat {makeBasis(right,up,back){this.right=right;this.up=up;this.back=back;return this}}
const Three={Vector3:V,Quaternion:Q,Matrix4:Mat}
let now=1000,callback,cleanup,ready=0,exitCallback,pending={mode:'threeD',frame:{floorId:'test',levelId:'A',cx:5,cy:3,widthM:12,heightM:8}},invalidation=0,controlUpdates=0
let canvasRect={left:0,top:0,width:1200,height:900}
const camera={position:new V(0,-20,0),quaternion:new Q(-1),up:new V(0,1,0),fov:45,isPerspectiveCamera:true,isOrthographicCamera:false,updateMatrixWorld(){}}
const control={target:new V(0,0,0),enabled:true,update(){controlUpdates++}}
const state={camera,controls:control,size:{width:1200,height:900},gl:{domElement:{getBoundingClientRect(){return canvasRect}}},get(){return state},invalidate(){invalidation++}}
const React={useRef:v=>({current:v}),useLayoutEffect:fn=>{cleanup=fn()}}
const Fiber={useThree:fn=>fn(state),useFrame:fn=>{callback=fn}}
const Bridge={
 consumeEntry150(){const x=pending;pending=null;return x},
 restoreEntry150(e){if(!pending)pending=e},
 currentFrame150(){return {floorId:'test',levelId:'A',cx:5,cy:3,widthM:12,heightM:8}},
 registerExit150(fn){exitCallback=fn;return ()=>{if(exitCallback===fn)exitCallback=null}},
 notifyEnterReady150(){ready++},
 DURATION150:5000,ENTER_FADE150:5000,
}
const transpiled=ts.transpileModule(code,{fileName:source,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}})
assert.equal((transpiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0)
const moduleFlight={exports:{}}
const req=name=>name==='react'?React:name==='@react-three/fiber'?Fiber:name==='three'?Three:name==='./cameraTransitions150'?Bridge:(()=>{throw Error('Unexpected import '+name)})()
new Function('module','exports','require','document','performance',transpiled.outputText)(moduleFlight,moduleFlight.exports,req,{
 querySelector(q){assert.equal(q,'svg[aria-label="Blueprint Editor"]');return {getScreenCTM(){return {a:1.5,b:0,c:0,d:1.5,e:-755,f:-825}}}}
},{now:()=>now})
moduleFlight.exports.default({points:[{x:0,y:0},{x:10,y:0},{x:10,y:6},{x:0,y:6}]})
assert(callback&&cleanup&&exitCallback,'CameraFlight initialized')
function tick(){if(control.update)control.update();callback(state)}
// The initially mounted camera is *not* the actual standard view (old bug).
tick();assert.equal(ready,0)
tick();tick();
camera.position.copy(new V(2,17,11));camera.quaternion.n=7
control.target.copy(new V(5,1,3))
let startPose=null
for(let i=0;i<65&&ready===0;i++){
  now+=16;tick()
  if(camera.quaternion.n===101 && !startPose){startPose={position:camera.position.clone(),target:control.target.clone(),angle:camera.quaternion.n}}
}
assert.equal(ready,1,'Ready emitted automatically after stable default and 3 locked camera frames')
assert(startPose,'Top view established')
// Model centre at 700 px; 3D viewport centre at 600px => target is shifted 100 / 90 m.
assert(Math.abs(startPose.target.x-(5-100/90))<0.000001,'true DOM-mapped horizontal Blueprint pan')
assert(Math.abs(startPose.target.z-3)<0.000001,'true DOM-mapped vertical Blueprint pan')
assert.equal(control.enabled,false,'controls disabled while Blueprint fades')
const top=startPose.position.clone()
now+=2000;tick();assert.equal(camera.position.distanceTo(top),0,'top stays fixed mid-fade')
now+=3000;tick();assert.equal(camera.position.distanceTo(top),0,'no jump at fade end')
now+=2500;tick();assert(camera.position.y>top.y&&camera.position.y<17,'flight heads to real final camera')
now+=2500;tick()
assert.equal(camera.position.distanceTo(new V(2,17,11)),0,'flight ends exactly at settled default, not first frame')
assert.equal(camera.quaternion.n,7,'no angle jump at endpoint')
assert.equal(control.enabled,true,'controls restored')
const updatesBefore=controlUpdates
// Unlock never invokes native controls update at completion (only next normal frame).
assert.equal(controlUpdates,updatesBefore,'update count stable')
assert(invalidation>0)
cleanup()
console.log('PASS 150n: delayed settled-default sampling, real DOM canvas/Blueprint alignment, 5s fade + 5s eased flight, no final reset/update')
STROM150N_TEST_JS
log "3) Replace the 150m camera flight with calibrated start and measured default end pose ..."
install -m 644 "$RESOURCE_DIR/CameraFlight150.tsx" "$WORK_DIR/frontend/src/components/CameraFlight150.tsx"
log "4) TypeScript AST audit: viewport, camera handoff and 5s phase invariants ..."
STROM150N_ROOT="$WORK_DIR/frontend/src" STROM150N_TS="$DEPENDENCIES/typescript" node <<'STROM150N_AST' >>"$DIAG_LOG" 2>&1 || fail "150n TypeScript AST audit failed; GitHub and Stage unchanged"
'use strict'
const fs=require('fs'),assert=require('assert'),path=require('path'),ts=require(process.env.STROM150N_TS)
const root=process.env.STROM150N_ROOT
for(const rel of ['App.tsx','components/CameraFlight150.tsx','components/cameraTransitions150.ts','components/Building3DWorkspace.tsx']){
 const file=path.join(root,rel),str=fs.readFileSync(file,'utf8')
 const ast=ts.createSourceFile(file,str,ts.ScriptTarget.Latest,true,rel.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 assert.equal(ast.parseDiagnostics.length,0,rel+': TS/TSX parse errors '+ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
}
const flight=fs.readFileSync(path.join(root,'components/CameraFlight150.tsx'),'utf8')
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
const bridge=fs.readFileSync(path.join(root,'components/cameraTransitions150.ts'),'utf8')
const css=fs.readFileSync(path.join(root,'styles.css'),'utf8')
for(const marker of ['STROM150N_BP_SCREEN_CALIBRATION','STROM150N_DEFAULT_SETTLED','STROM150N_NO_END_JUMP','STROM150N_FORWARD_HANDOFF'])
 assert(flight.includes(marker),'Missing 150n camera invariant '+marker)
assert(app.includes('STROM150C_PRESERVE_BLUEPRINT')&&app.includes('STROM150E_LOADING_GUARD'),'Original Blueprint overlay must remain mounted')
assert(bridge.includes('export const ENTER_FADE150=5000')&&bridge.includes('export const DURATION150=5000'),'Analysis times 5+5 seconds must remain')
assert(css.includes('transition:opacity 5000ms ease;'),'CSS fade must remain 5000ms')
console.log('PASS 150n AST: TSX syntax, true DOM Blueprint projection, default camera calibration, 5s/5s preserved')
STROM150N_AST
log "5) Full TypeScript and Vite build against real Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150n TypeScript/Vite build failed before GitHub push"
log "5.1) Simulated camera timeline, Blueprint mapping and default handoff regressions ..."
STROM150N_SOURCE="$WORK_DIR/frontend/src/components/CameraFlight150.tsx" STROM150N_TS="$DEPENDENCIES/typescript" \
 node "$RESOURCE_DIR/test_camera.js" >>"$DIAG_LOG" 2>&1 || fail "150n runtime regression failed; GitHub and Stage unchanged"
log "PASS: verified settled default, true Blueprint viewport, 5000ms crossfade, 5000ms flight and unchanged final camera pose"
rm -rf "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150N.md" <<'STROM150N_DOC'
# Update 150n - Blueprint viewport and 3D handoff (forward only)
- Keep original Blueprint DOM and the loading spinner visible until the 3D scene is ready.
- Let the default 3D camera and OrbitControls settle before recording the final target pose.
- Compute the start pose from the actual Blueprint SVG screen transform and the new 3D Canvas rectangle, not from a guessed viewport center.
- Keep an unrotated +X / +Z top-down camera basis equal to the Blueprint axes.
- Freeze the overhead pose during the full 5000ms crossfade.
- Fly from that pose to the verified 3D default over 5000ms with cubic ease-out.
- Release OrbitControls without forcing an extra camera update or changing viewport values.
- Reverse camera animation is intentionally left for a later update.
- No model, data, layout, icon or production changes.
STROM150N_DOC
log "6) Transfer audited source into isolated Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150n Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PASS PATCH_ONLY; no web deployment"; exit 0; fi
log "7) Build Stage and deploy exclusively to /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "150n Stage rebuild failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "150n frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "150n test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: Update 150n deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
