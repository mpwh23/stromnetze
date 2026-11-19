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
