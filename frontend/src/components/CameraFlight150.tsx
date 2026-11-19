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
