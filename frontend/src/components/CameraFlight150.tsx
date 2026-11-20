import { useLayoutEffect, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import {
  consumeEntry150, restoreEntry150, currentFrame150, measureBlueprint165,
  registerExit150, notifyEnterReady150, notifyEnterFailed165,
  DURATION150, ENTER_FADE150, EXIT_FLIGHT159,
} from './cameraTransitions150'
import type { BlueprintMeasure165, Enter150 } from './cameraTransitions150'
import {
  solveTopView165, fallbackTopView165, poseAt165, gridErrorPx165, planToWorld165,
} from './cameraTop165'
import type { OrbitView165, Rect165, TopView165 } from './cameraTop165'

/** STROM165_ONE_CAMERA_OWNER
 * Einziger Kameratreiber fuer Blueprint -> 3D -> Blueprint.
 *
 * Hinweg:  settle  (3D baut sich verdeckt auf, Standardansicht wird gemerkt)
 *          prepare (Draufsicht aus dem LIVE-Blueprint berechnen, zeichnen, nachmessen)
 *          fade    (Draufsicht steht still, Blueprint blendet aus)
 *          flight  (Flug zur Standardansicht, Ease-out)
 * Rueckweg: flight (Flug zur Draufsicht, Ease-out) -> hold (nachmessen, dann Blende)
 *
 * Die OrbitControls sind im R3F-Store angemeldet (Building3DWorkspace) und werden hier
 * fuer die Dauer des Uebergangs wirklich gesperrt. Vor 165 fehlte die Anmeldung; die
 * Controls haben die Kamera deshalb in jedem Frame wieder auf die Hausmitte gedreht.
 */
type PlanPoint = { x: number; y: number }
type OrbitControl = { target?: THREE.Vector3; enabled?: boolean; update?: () => void }
type FrozenControl = { control: OrbitControl; update?: () => void; enabled?: boolean }
type Lens165 = { fov: number; near: number; far: number }
type OrbitState165 = OrbitView165 & { position: THREE.Vector3 }
type Check165 = { armed: boolean; measure: BlueprintMeasure165 | null; canvas: Rect165 | null; errorPx: number | null; key: string }
type Run165 = {
  kind: 'entry' | 'exit'
  phase: 'settle' | 'prepare' | 'fade' | 'flight' | 'hold' | 'done'
  top: TopView165 | null
  orbit: OrbitState165 | null
  from: number
  startedAt: number
  frames: number
  steady: number
  verified: number
  previous: THREE.Matrix4 | null
  reason: string
  finish?: () => void
}

/** Blickwinkel waehrend der Blende. Fast parallel, damit auch Waende ueber dem Blueprint liegen. */
const START_FOV165 = 2
/** Zulaessige Abweichung zwischen Blueprint und gezeichnetem 3D-Raster in CSS-Pixeln. */
const TOLERANCE_PX165 = 1
const VERIFY_FRAMES165 = 2
const PREPARE_LIMIT165 = 240
const HOLD_LIMIT165 = 45
const GRID_NAME165 = 'strom152-blueprint-grid'
const STALE_KEYS165 = [
  'strom.camera150p.blueprintExtents', 'strom.camera150q.floorExtents', 'strom.camera150r.calibration',
  'strom.camera153.alignment', 'strom.camera154.gridAlignment', 'strom.camera155.handoff',
  'strom.camera156.center', 'strom.camera158.returnAlignment', 'strom.camera158.returnFloor',
  'strom.camera163.alignment', 'strom.camera164.alignment',
]
const clamp01 = (t: number) => Math.min(1, Math.max(0, t))
const easeOut = (t: number) => 1 - (1 - t) ** 3

function planBounds(points: readonly PlanPoint[]) {
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
function perspective(camera: THREE.Camera): THREE.PerspectiveCamera | null {
  const candidate = camera as THREE.PerspectiveCamera
  return candidate.isPerspectiveCamera === true ? candidate : null
}
function canvasRect(canvas: HTMLCanvasElement): Rect165 {
  const rect = canvas.getBoundingClientRect()
  return { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
}
function measureKey(measure: BlueprintMeasure165, canvas: Rect165): string {
  const s = measure.screen, v = measure.viewport
  return [s.x, s.y, s.ax, s.ay, s.bx, s.by, v.left, v.top, v.width, v.height,
    canvas.left, canvas.top, canvas.width, canvas.height].map(value => value.toFixed(3)).join('/')
}
function report165(phase: string, data: Record<string, unknown>) {
  const record = { version: 165, phase, time: new Date().toISOString(), ...data }
  try { window.localStorage.setItem('strom.camera165.check', JSON.stringify(record)) } catch { /* optional */ }
  return record
}

export default function CameraFlight150({ points }: { points: readonly PlanPoint[] }) {
  const get = useThree(state => state.get)
  const invalidate = useThree(state => state.invalidate)
  const pending = useRef<Enter150 | null>(null)
  const requestedExit = useRef<(() => void) | null>(null)
  const run = useRef<Run165 | null>(null)
  const savedTop = useRef<TopView165 | null>(null)
  const baseLens = useRef<Lens165 | null>(null)
  const frozen = useRef<FrozenControl | null>(null)
  const check = useRef<Check165>({ armed: false, measure: null, canvas: null, errorPx: null, key: '' })
  const pointsRef = useRef(points)
  pointsRef.current = points

  const orbit = () => (get().controls || null) as OrbitControl | null
  const unlock = () => {
    const snapshot = frozen.current
    if (!snapshot) return
    if (snapshot.update) snapshot.control.update = snapshot.update
    if (snapshot.enabled !== undefined) snapshot.control.enabled = snapshot.enabled
    frozen.current = null
  }
  const lock = () => {
    const control = orbit()
    if (frozen.current?.control === control) return
    if (frozen.current) unlock()
    if (!control) return
    frozen.current = { control, update: control.update, enabled: control.enabled }
    control.enabled = false
    if (control.update) control.update = () => {}
  }
  const gridMatrix = (scene: THREE.Object3D): THREE.Matrix4 | null => {
    const grid = scene.getObjectByName(GRID_NAME165)
    if (!grid) return null
    grid.updateWorldMatrix(true, false)
    return grid.matrixWorld.clone()
  }
  const restoreLens = (camera: THREE.Camera) => {
    const cam = perspective(camera), lens = baseLens.current
    if (!cam) return
    if (lens) { cam.fov = lens.fov; cam.near = lens.near; cam.far = lens.far }
    cam.clearViewOffset() // also refreshes the projection matrix
  }
  /** Schreibt genau eine Kamerapose. Nichts anderes fasst die Kamera waehrend des Uebergangs an. */
  const apply = (camera: THREE.Camera, top: TopView165, target: OrbitView165, s: number, grid: THREE.Matrix4 | null) => {
    const cam = perspective(camera), lens = baseLens.current
    if (!cam || !lens) return
    const pose = poseAt165(top, target, s, lens.fov, START_FOV165)
    cam.position.copy(pose.position)
    cam.quaternion.copy(pose.quaternion)
    cam.fov = pose.fov
    // Schnittebenen folgen dem Abstand: genug Tiefenaufloesung auch aus grosser Hoehe.
    const bounds = planBounds(pointsRef.current)
    const center = grid ? planToWorld165(grid, bounds.cx, bounds.cy) : new THREE.Vector3(bounds.cx, 0, bounds.cy)
    const radius = 0.75 * Math.hypot(bounds.width, bounds.height) + 30
    const reach = pose.position.distanceTo(center)
    const nearFree = Math.max(lens.near, 0.5 * (reach - radius))
    cam.near = lens.near + (nearFree - lens.near) * pose.offsetFactor
    cam.far = Math.max(lens.far, reach + radius + 50, pose.distance * 1.25 + 50)
    const offset = top.offset, factor = pose.offsetFactor
    if (factor > 1e-6 && (Math.abs(offset.x) > 1e-6 || Math.abs(offset.y) > 1e-6)) {
      cam.setViewOffset(offset.width, offset.height, offset.x * factor, offset.y * factor, offset.width, offset.height)
    } else {
      cam.clearViewOffset()
    }
    cam.updateMatrixWorld(true)
    invalidate()
  }
  const captureOrbit = (camera: THREE.Camera, grid: THREE.Matrix4 | null): OrbitState165 => {
    const control = orbit()
    const forward = camera.getWorldDirection(new THREE.Vector3())
    let pivot = control?.target?.clone() || null
    if (pivot) {
      // Blickpunkt muss auf der Sichtachse liegen; die Controls garantieren das nach update().
      const along = pivot.clone().sub(camera.position).dot(forward)
      pivot = along > 0.05 ? camera.position.clone().addScaledVector(forward, along) : null
    }
    if (!pivot) {
      const planeY = grid ? planToWorld165(grid, 0, 0).y : 0
      const reach = forward.y < -0.05 ? (camera.position.y - planeY) / -forward.y : 12
      pivot = camera.position.clone().addScaledVector(forward, Math.max(1, Math.min(500, reach)))
    }
    return {
      pivot, quaternion: camera.quaternion.clone(), position: camera.position.clone(),
      distance: Math.max(0.05, camera.position.distanceTo(pivot)),
    }
  }
  const finishOrbit = (camera: THREE.Camera, target: OrbitState165) => {
    camera.position.copy(target.position)
    camera.quaternion.copy(target.quaternion)
    restoreLens(camera)
    camera.updateMatrixWorld(true)
    unlock()
    invalidate()
  }
  /** Draufsicht aus dem aktuell sichtbaren Blueprint; sonst aus dem Klick-Schnappschuss. */
  const solveFromBlueprint = (camera: THREE.Camera, canvas: Rect165, grid: THREE.Matrix4) => {
    const lens = baseLens.current
    const live = measureBlueprint165()
    const frame = currentFrame150()
    const measure = live || (frame?.screen150o && frame.viewport163
      ? { screen: frame.screen150o, viewport: frame.viewport163 } : null)
    if (!lens || !perspective(camera)) return { measure, live: false, top: 'Keine Perspektivkamera' as TopView165 | string }
    if (!measure) return { measure, live: false, top: 'Blueprint nicht messbar' as TopView165 | string }
    return { measure, live: Boolean(live), top: solveTopView165(measure.screen, measure.viewport, canvas, grid, lens.fov) }
  }

  useLayoutEffect(() => {
    pending.current = consumeEntry150()
    if (pending.current) invalidate()
    for (const key of STALE_KEYS165) { try { window.localStorage.removeItem(key) } catch { /* optional */ } }
    const unbind = registerExit150(done => {
      requestedExit.current = done
      invalidate()
    })
    // STROM165_RENDER_CHECK: gemessen wird NACH dem Zeichnen, mit genau der Kamera, die
    // gezeichnet hat, gegen den Blueprint, wie er in diesem Moment im Browser steht.
    const scene = get().scene
    const previousAfterRender = scene.onAfterRender
    scene.onAfterRender = (renderer, renderedScene, camera, ...rest) => {
      previousAfterRender.call(scene, renderer, renderedScene, camera, ...rest)
      const state = check.current
      if (!state.armed) return
      state.armed = false
      state.errorPx = null
      const live = measureBlueprint165()
      const grid = gridMatrix(renderedScene)
      if (!live || !grid) return
      const canvas = canvasRect(renderer.domElement)
      const error = gridErrorPx165(live.screen, live.viewport, canvas, grid, camera)
      if (!error) return
      state.measure = live
      state.canvas = canvas
      state.key = measureKey(live, canvas)
      state.errorPx = error.max
    }
    return () => {
      unbind()
      scene.onAfterRender = previousAfterRender
      if (pending.current) restoreEntry150(pending.current)
      pending.current = null
      requestedExit.current = null
      run.current = null
      unlock()
      // Never leave the transition lens behind after unmount.
      restoreLens(get().camera)
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [get, invalidate])

  useFrame(state => {
    const camera = state.camera
    const cam = perspective(camera)
    const now = performance.now()

    if (requestedExit.current) {
      const finish = requestedExit.current
      requestedExit.current = null
      pending.current = null
      const active = run.current
      const grid = gridMatrix(state.scene)
      if (!cam) { run.current = null; finish(); return }
      if (!baseLens.current) baseLens.current = { fov: cam.fov, near: cam.near, far: cam.far }
      // Laeuft der Hinflug noch, kehrt der Rueckflug an genau dieser Stelle um.
      let from = 1
      let target: OrbitState165 | null = null
      let top = savedTop.current
      if (active && active.kind === 'entry' && active.top && active.orbit && (active.phase === 'fade' || active.phase === 'flight')) {
        from = active.phase === 'fade' ? 0 : easeOut(clamp01((now - active.startedAt) / DURATION150))
        target = active.orbit
        top = active.top
      } else {
        if (active) restoreLens(camera)
        target = captureOrbit(camera, grid)
      }
      if (!top) {
        top = fallbackTopView165(planBounds(pointsRef.current), canvasRect(state.gl.domElement),
          grid || new THREE.Matrix4(), baseLens.current.fov)
      }
      lock()
      check.current = { armed: false, measure: null, canvas: null, errorPx: null, key: '' }
      run.current = {
        kind: 'exit', phase: 'flight', top, orbit: target, from, startedAt: now,
        frames: 0, steady: 0, verified: 0, previous: null, reason: '', finish,
      }
    }

    if (pending.current) {
      pending.current = null
      savedTop.current = null // the new Blueprint viewport is the new truth
      if (run.current) { restoreLens(camera); unlock() }
      check.current = { armed: false, measure: null, canvas: null, errorPx: null, key: '' }
      run.current = {
        kind: 'entry', phase: 'settle', top: null, orbit: null, from: 0,
        startedAt: Number.POSITIVE_INFINITY, frames: 0, steady: 0, verified: 0,
        previous: null, reason: '',
      }
      invalidate()
      return
    }
    const active = run.current
    if (!active) return

    if (active.kind === 'entry' && active.phase === 'settle') {
      // Die Szene und die Controls stellen verdeckt ihre Standardansicht ein.
      camera.updateMatrixWorld(true)
      const current = camera.matrixWorld.clone()
      const stable = active.previous !== null && active.previous.equals(current)
      active.steady = stable ? active.steady + 1 : 0
      active.previous = current
      active.frames++
      const grid = gridMatrix(state.scene)
      const waiting = active.steady < 3 || !grid || (!orbit() && active.frames < 24)
      if (waiting && active.frames < 90) { invalidate(); return }
      if (!cam) { run.current = null; notifyEnterFailed165('3D-Kamera ist keine Perspektivkamera.'); return }
      orbit()?.update?.()
      baseLens.current = { fov: cam.fov, near: cam.near, far: cam.far }
      active.orbit = captureOrbit(camera, grid)
      active.phase = 'prepare'
      active.frames = 0
      lock()
      invalidate()
      // no return: the first top view is drawn in this very frame
    }

    lock()
    const grid = gridMatrix(state.scene)
    const canvas = canvasRect(state.gl.domElement)

    if (active.kind === 'entry' && active.phase === 'prepare' && active.orbit) {
      active.frames++
      // Ergebnis der Messung nach dem zuletzt gezeichneten Bild.
      const last = check.current
      const solved = grid ? solveFromBlueprint(camera, canvas, grid) : null
      if (!solved || typeof solved.top === 'string' || !solved.measure || !grid) {
        active.reason = !grid ? '3D-Raster noch nicht aufgebaut' : String(solved?.top)
        active.verified = 0
      } else {
        const key = measureKey(solved.measure, canvas)
        const drawnExactly = last.errorPx !== null && last.key === key && active.top !== null
        if (drawnExactly && last.errorPx! <= TOLERANCE_PX165) active.verified++
        else {
          active.verified = 0
          if (last.errorPx !== null && last.key === key) active.reason = `Rasterabweichung ${last.errorPx.toFixed(2)} px`
          else active.reason = 'Blueprint oder 3D-Fenster noch in Bewegung'
        }
        active.top = solved.top
        apply(camera, active.top, active.orbit, 0, grid)
        check.current.armed = true
        if (active.verified >= VERIFY_FRAMES165) {
          savedTop.current = active.top
          active.phase = 'fade'
          active.startedAt = now + ENTER_FADE150
          const position = camera.position
          console.info('[STROM165] Blueprint -> 3D: Raster deckungsgleich', report165('Blueprint -> 3D', {
            maxErrorCssPx: last.errorPx, toleranceCssPx: TOLERANCE_PX165,
            blueprint: solved.live ? 'live gemessen' : 'Klick-Schnappschuss',
            blueprintCenterM: active.top.planCenter, pixelsPerMetre: active.top.pixelsPerMetre,
            cameraXYZ: { x: position.x, y: position.z, z: position.y },
            fovDeg: cam?.fov, lensOffsetCssPx: { x: active.top.offset.x, y: active.top.offset.y },
            canvas, blueprintViewport: solved.measure.viewport, frames: active.frames,
          }))
          notifyEnterReady150()
          return
        }
      }
      if (active.frames > PREPARE_LIMIT165) {
        // Kein unbestaetigtes Ueberblenden und kein Dauer-Ladekreis.
        const record = report165('Blueprint -> 3D abgebrochen', {
          reason: active.reason, lastErrorCssPx: last.errorPx, toleranceCssPx: TOLERANCE_PX165, canvas,
          blueprint: solved?.measure || null,
        })
        console.error('[STROM165] Uebergang abgebrochen:', active.reason, record)
        finishOrbit(camera, active.orbit)
        run.current = null
        notifyEnterFailed165(`3D-Ansicht konnte nicht deckungsgleich ausgerichtet werden (${active.reason}). Bitte Ansicht erneut öffnen.`)
        return
      }
      invalidate()
      return
    }

    if (!active.top || !active.orbit) { run.current = null; unlock(); return }

    if (active.kind === 'entry' && active.phase === 'fade') {
      apply(camera, active.top, active.orbit, 0, grid)
      if (now >= active.startedAt) active.phase = 'flight'
      return
    }

    if (active.kind === 'entry') {
      const t = clamp01((now - active.startedAt) / DURATION150)
      if (t < 1) { apply(camera, active.top, active.orbit, easeOut(t), grid); return }
      // STROM150N_NO_END_JUMP: genau die vorher gemerkte Standardansicht, danach uebernehmen die Controls.
      finishOrbit(camera, active.orbit)
      run.current = null
      return
    }

    // ---- Rueckweg ----
    // Sobald der Blueprint wieder im Browser steht, ist ER das Ziel (nicht ein altes Kamerabild).
    if (grid && measureBlueprint165()) {
      const solved = solveFromBlueprint(camera, canvas, grid)
      if (solved.live && typeof solved.top !== 'string') active.top = solved.top
    }
    if (active.phase === 'flight') {
      const t = clamp01((now - active.startedAt) / EXIT_FLIGHT159)
      // Ease-out auch auf dem Rueckweg: schnell los, weich in die Draufsicht.
      apply(camera, active.top, active.orbit, active.from * (1 - easeOut(t)), grid)
      if (t >= 1) { active.phase = 'hold'; active.frames = 0; active.verified = 0 }
      else return
    }
    // hold / done: Draufsicht steht still, bis 3D ausgeblendet und entfernt ist.
    apply(camera, active.top, active.orbit, 0, grid)
    if (active.phase === 'done') return
    const last = check.current
    active.frames++
    if (last.errorPx !== null && last.errorPx <= TOLERANCE_PX165) active.verified++
    else active.verified = 0
    check.current.armed = true
    if (active.verified >= VERIFY_FRAMES165 || active.frames > HOLD_LIMIT165) {
      const position = camera.position
      const record = report165('3D -> Blueprint', {
        maxErrorCssPx: last.errorPx, toleranceCssPx: TOLERANCE_PX165, verified: active.verified >= VERIFY_FRAMES165,
        cameraXYZ: { x: position.x, y: position.z, z: position.y }, canvas, frames: active.frames,
      })
      if (active.verified >= VERIFY_FRAMES165) console.info('[STROM165] 3D -> Blueprint: Raster deckungsgleich', record)
      else console.warn('[STROM165] 3D -> Blueprint: Raster nicht bestaetigt', record)
      active.phase = 'done'
      check.current.armed = false
      active.finish?.()
    }
  })
  return null
}
