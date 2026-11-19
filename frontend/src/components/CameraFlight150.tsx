import { useLayoutEffect, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import {
  consumeEntry150, restoreEntry150, currentFrame150,
  registerExit150, notifyEnterReady150, DURATION150, ENTER_FADE150, EXIT_FLIGHT159,
} from './cameraTransitions150'
import type { BlueprintFrame150, Enter150 } from './cameraTransitions150'
import { captureCameraHandoff155 } from './cameraHandoffDiagnostics155' // STROM155_CAMERA_VIEWPORT_DIAGNOSTICS
import { alignBlueprintCenter156,applyViewOffset156,clearViewOffset156,type ViewOffset156 } from './cameraBlueprintCenter156' // STROM156_BLUEPRINT_CAMERA_CENTER
import { captureThreeFloorExtrema150q } from './threeFloorExtrema150q' // STROM150Q_3D_FLOOR_EXTENTS
import { calibrateFloorStart150r, floorWorldPoints150r } from './cameraFloorMatch150r' // STROM150R_CAMERA_MATCH
import { alignBlueprintGrid154 } from './cameraGridAlignment154' // STROM154_GRID_PIXEL_ALIGNMENT

type PlanPoint = { x: number; y: number }
type OrbitControl = { target?: THREE.Vector3; enabled?: boolean; update?: () => void }
type CameraPose = {
  position: THREE.Vector3
  rotation: THREE.Quaternion
  target: THREE.Vector3
  up: THREE.Vector3
  zoom: number
}
// STROM158_REVERSE_EXACT: reuse the calibrated Blueprint pose from the entry.
function clonePose158(p:CameraPose):CameraPose{
  return {position:p.position.clone(),rotation:p.rotation.clone(),
    target:p.target.clone(),up:p.up.clone(),zoom:p.zoom}
}
/** Check all three canonical world-grid anchors at the reverse endpoint.
 * No guess-based model or Blueprint shifts. Measurements are in CSS pixels. */
function checkReverseAxes158(scene:THREE.Object3D,camera:THREE.Camera,
  canvas:HTMLCanvasElement,frame:BlueprintFrame150|null):void{
  const b=frame?.screen150o
  if(!b)return
  const rect=canvas.getBoundingClientRect()
  if(!(rect.width>20&&rect.height>20))return
  scene.updateMatrixWorld(true)
  let marker:THREE.Object3D|null=null
  scene.traverse(obj=>{
    if(!marker&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
  })
  const matrix=marker?(marker as THREE.Object3D).matrixWorld.clone():new THREE.Matrix4()
  matrix.elements[13]=0
  camera.updateMatrixWorld(true)
  const compare=(x:number,y:number)=>{
    const point=new THREE.Vector3(x,0,y).applyMatrix4(matrix)
    point.y=0
    const projected=point.project(camera)
    const sx=rect.left+(projected.x+1)*rect.width/2
    const sy=rect.top+(1-projected.y)*rect.height/2
    const bx=b.x+b.ax*x+b.bx*y,by=b.y+b.ay*x+b.by*y
    return Math.hypot(sx-bx,sy-by)
  }
  const zero=compare(0,0),x1=compare(1,0),y1=compare(0,1)
  const toEye=camera.getWorldDirection(new THREE.Vector3()).negate().normalize()
  const verticalError=Math.hypot(toEye.x,toEye.z)
  const result={version:158,phase:'3D -> Blueprint, end of 5s reverse flight',
    gridErrorPx:{zero,x1,y1,max:Math.max(zero,x1,y1)},
    normalToEyeXYZ:{x:toEye.x,y:toEye.z,z:toEye.y},
    perpendicularError:verticalError,
    canvas:{left:rect.left,top:rect.top,width:rect.width,height:rect.height}}
  try{window.localStorage.setItem('strom.camera158.returnAlignment',JSON.stringify(result))}catch{/* optional */}
  console.info('[STROM 158] Exit frame grid/axes (0,0), (+1,0), (0,+1)',result)
  if(result.gridErrorPx.max>0.5||verticalError>1e-4)
    console.warn('[STROM 158] Screen/grid or normal mismatch at Blueprint return',result)
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
  viewOffset156?: ViewOffset156
  finish?: () => void
}

// STROM162_EXACT_RENDERED_BLUEPRINT_RETURN: record and reproduce the real,
// fully rendered top-view camera, including the full WebGL lens shift.
type Lens162={fullWidth:number;fullHeight:number;offsetX:number;offsetY:number;width:number;height:number}
type SavedTop162={pose:CameraPose;lens:Lens162|null}
type LensTransition162={from:Lens162|null;to:Lens162|null}
function snapshotLens162(camera:THREE.Camera):Lens162|null {
  const c=camera as THREE.PerspectiveCamera | THREE.OrthographicCamera
  if(!('isPerspectiveCamera' in c) && !('isOrthographicCamera' in c))return null
  const v=c.view
  if(!v?.enabled)return null
  const result={fullWidth:v.fullWidth,fullHeight:v.fullHeight,offsetX:v.offsetX,offsetY:v.offsetY,
    width:v.width,height:v.height}
  if(!Object.values(result).every(Number.isFinite)||result.fullWidth<1||result.fullHeight<1||
      result.width<1||result.height<1)return null
  return result
}
function setLens162(camera:THREE.Camera,lens:Lens162|null):void {
  const c=camera as THREE.PerspectiveCamera | THREE.OrthographicCamera
  if(!('isPerspectiveCamera' in c) && !('isOrthographicCamera' in c))return
  if(lens)c.setViewOffset(lens.fullWidth,lens.fullHeight,lens.offsetX,lens.offsetY,lens.width,lens.height)
  else if(c.view?.enabled)c.clearViewOffset()
}
function interpolateLens162(camera:THREE.Camera,from:Lens162|null,to:Lens162|null,k:number):void {
  if(k<=0){setLens162(camera,from);return}
  if(k>=1){setLens162(camera,to);return}
  if(!from && !to)return
  const start=from||{...to!,offsetX:0,offsetY:0}
  const finish=to||{...from!,offsetX:0,offsetY:0}
  const mix=(a:number,b:number)=>a+(b-a)*k
  setLens162(camera,{
    fullWidth:mix(start.fullWidth,finish.fullWidth),
    fullHeight:mix(start.fullHeight,finish.fullHeight),
    offsetX:mix(start.offsetX,finish.offsetX),offsetY:mix(start.offsetY,finish.offsetY),
    width:mix(start.width,finish.width),height:mix(start.height,finish.height),
  })
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
function blueprintProjection(canvas: HTMLCanvasElement | undefined, bounds: ReturnType<typeof modelBounds>,
  frame: BlueprintFrame150 | null) {
  try {
    // STROM150O_PRE_NAV_SNAPSHOT: do not recalibrate from the reflowed Blueprint overlay.
    const saved = frame?.screen150o
    const stableRect = canvas?.getBoundingClientRect()
    if(saved&&stableRect&&stableRect.width>50&&stableRect.height>50){
      const scaleX=Math.hypot(saved.ax,saved.ay)
      const scaleY=Math.hypot(saved.bx,saved.by)
      const pixelsPerM=(scaleX+scaleY)/2
      if(pixelsPerM>2&&pixelsPerM<1000&&Math.abs(scaleX-scaleY)<=pixelsPerM*0.07){
        return {
          pixelsPerM,
          screenX:saved.x+saved.ax*bounds.cx+saved.bx*bounds.cy,
          screenY:saved.y+saved.ay*bounds.cx+saved.by*bounds.cy,
          canvasX:stableRect.left+stableRect.width/2,
          canvasY:stableRect.top+stableRect.height/2,
          canvasHeight:stableRect.height,
        }
      }
    }
    // Fallback only for sessions where the Blueprint snapshot could not be captured.
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
  const mapped = blueprintProjection(canvas, box, frame)
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
  const savedTop162 = useRef<SavedTop162 | null>(null)
  const returnLens162 = useRef<LensTransition162 | null>(null)
  const returnHold162 = useRef(0)
  const frozen = useRef<FrozenControl | null>(null)
  const pointsRef = useRef(points)
  const exactOverhead158=useRef<{pose:CameraPose;offset?:ViewOffset156}|null>(null)
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
      exactOverhead158.current = null
      unlock()
      // Never leave off-axis camera projection behind after unmount.
      clearViewOffset156(get().camera)
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [get, invalidate])

  // OrbitControls renders at -1; priority 0 writes the final camera of each R3F frame.
  useFrame(state => {
    const camera = state.camera
    const control = orbit()
    const aspect = Math.max(0.3, state.size.width / Math.max(1, state.size.height))

    // STROM158_REVERSE_EXACT: reverse the actual calibrated entry pose,
    // rather than constructing an uncalibrated overhead approximation.
    if (requestedExit.current) {
      const exitStartingLens162 = snapshotLens162(camera) // read BEFORE any camera mutation

      const finish = requestedExit.current
      requestedExit.current = null
      pending.current = null
      const original = capture(camera, control)
      const matched=exactOverhead158.current
      const top=matched?clonePose158(matched.pose):overheadPose(
        camera,pointsRef.current,currentFrame150(),aspect,
        original.target.y,state.gl.domElement)
      let offset=matched?.offset?{...matched.offset}:undefined
      lock()
      // Re-check the canonical BP 0/+1 m axes against the currently mounted scene
      // before moving; never change the Blueprint model, axes or grid data.
      const frame=currentFrame150()
      if(frame?.screen150o){
        clearViewOffset156(camera)
        apply(camera,top)
        try{
          const aligned=alignBlueprintGrid154(state.scene,camera,state.gl.domElement,
            top,frame,pose=>apply(camera,pose))
          if(aligned){
            offset=alignBlueprintCenter156(state.scene,camera,state.gl.domElement,
              top,frame,pose=>apply(camera,pose))||undefined
          }
        }catch(error){console.warn('[STROM 158] Reverse grid fit skipped',error)}
        clearViewOffset156(camera)
        apply(camera,original)
      }
      flight.current = {
        kind: 'exit', phase: 'flight', start: original, end: top,
        startedAt: performance.now(), steady: 0, settleFrames: 0, preparedFrames: 0,
        viewOffset156:offset,finish,
      }
      // Use exactly the displayed blueprint pose. Preserves the 159b forward.
      returnHold162.current = 0
      const exactTop162 = savedTop162.current
      if (exactTop162 && flight.current?.kind === 'exit') {
        const p162=exactTop162.pose
        flight.current.end={
          position:p162.position.clone(),rotation:p162.rotation.clone(),
          target:p162.target.clone(),up:p162.up.clone(),zoom:p162.zoom,
        }
        // The lens is handled by interpolateLens162. Don't also run the old
        // forward-facing compensator in the reverse direction.
        flight.current.viewOffset156=undefined
        returnLens162.current={from:exitStartingLens162,to:exactTop162.lens}
      } else {
        returnLens162.current=null
      }

    }

    if (pending.current) {
      savedTop162.current = null // new Blueprint viewport is the new truth
      returnLens162.current = null
      returnHold162.current = 0
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
      // STROM150R_CAMERA_MATCH: calibrate the locked 3D start pose from *actual*
      // transformed, selected-level floor anchors against the click-time BP transform.
      // It changes only the START of this flight, never the final default camera.
      calibrateFloorStart150r(state.scene,camera,state.gl.domElement,start,currentFrame150(),
        pose => apply(camera,pose))
      apply(camera, start)
      return
    }

    lock()
    if (running.kind === 'entry' && running.phase === 'prepare') {
      apply(camera, running.start)
      running.preparedFrames++
      if (running.preparedFrames >= 3) {
        // STROM153_CAMERA_VIEWPORT_FIT: at the LAST concealed frame, fit the
        // actual 3D projection to the stored Blueprint xMin/xMax/yMin/yMax.
        // No waiting, no changes to either 5-second transition duration.
        try {
          // STROM154_GRID_PIXEL_ALIGNMENT: direct 0/0 + 1m X/Y match from
          // the click-time SVG matrix. Do NOT align using floor bounding extents.
          const gridAligned154=alignBlueprintGrid154(state.scene,camera,state.gl.domElement,
            running.start,currentFrame150(),pose=>apply(camera,pose))
          if(gridAligned154){
            // The WebGL canvas and Blueprint viewport are different DOM rects.
            // Rebase the eye on the TRUE BP centre and retain screen-perfect
            // projection with a temporary camera lens/view offset.
            running.viewOffset156=alignBlueprintCenter156(
              state.scene,camera,state.gl.domElement,running.start,
              currentFrame150(),pose=>apply(camera,pose))||undefined
          }
        } catch(error){console.warn('[Strom 153] Viewport-Abgleich nicht möglich',error)}
        apply(camera,running.start)
        // Exact start is also the destination of the reverse journey.
        exactOverhead158.current={pose:clonePose158(running.start),
          offset:running.viewOffset156?{...running.viewOffset156}:undefined}
        running.phase = 'fade'
        running.startedAt = performance.now() + ENTER_FADE150
        // STROM150Q_3D_FLOOR_EXTENTS: actual 3D camera projection at the start of the fade.
        // This diagnostic never changes camera/controls or delays the animation.
        try {
          captureThreeFloorExtrema150q(pointsRef.current, state.camera, state.gl.domElement, 0, floorWorldPoints150r(state.scene))
        } catch (error) { console.warn('[STROM 150q] 3D-Boden-Messung fehlgeschlagen', error) }
        // STROM155_CAMERA_VIEWPORT_DIAGNOSTICS: last fitted, LIVE R3F camera.
        // Read-only: does not change the start pose, controls, FOV or animation.
        try {
          captureCameraHandoff155(state.camera,state.gl.domElement,currentFrame150())
        } catch (error) {console.warn('[STROM 155] Kameradiagnose fehlgeschlagen',error)}
        notifyEnterReady150()
      }
      return
    }
    if (running.kind === 'entry' && running.phase === 'fade') {
      apply(camera, running.start)
      if(running.viewOffset156)applyViewOffset156(camera,running.viewOffset156,1)
      if (performance.now() >= running.startedAt) running.phase = 'flight'

      // Passive observation: capture precisely what the fade is actually rendering.
      if (!savedTop162.current) {
        savedTop162.current = {pose:capture(camera,control),lens:snapshotLens162(camera)}
        const p162=savedTop162.current.pose.position
        console.info('[STROM 162] blueprint camera captured',
          {x:p162.x,y:p162.z,z:p162.y,lens:savedTop162.current.lens})
      }
      return
    }

    // STROM159_TIMINGS: separate 2500ms forward from 1000ms reverse duration.
    const duration159=running.kind==='exit'?EXIT_FLIGHT159:DURATION150
    const t = clamp01((performance.now() - running.startedAt) / (running.kind === 'exit' ? 1000 : duration159))
    // Inverse temporal path: forward easeOut(s)=1-(1-s)^3,
    // reverse progress=1-easeOut(1-t)=t^3. No camera jumps.
    const k = running.kind==='exit'?t*t*t:easeOut(t)
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
    if (running.kind === 'exit' && returnLens162.current)
      interpolateLens162(camera,returnLens162.current.from,returnLens162.current.to,k)
    // Entry: shifted -> unshifted; reverse: unshifted -> the same shifted BP view.
    if(running.viewOffset156)
      applyViewOffset156(camera,running.viewOffset156,
        running.kind==='entry'?1-k:k)
    if (t < 1) return

    // Keep final Blueprint viewport alive for three THREE/WebGL frames.
    if (running.kind === 'exit') {
      apply(camera,b)
      if (returnLens162.current) interpolateLens162(camera,returnLens162.current.from,returnLens162.current.to,1)
      returnHold162.current += 1
      if (returnHold162.current < 3) { invalidate(); return }
    }

    // STROM150N_NO_END_JUMP: no second camera pose or manual reset on unlock.
    apply(camera, b)
    if(running.kind==='entry'&&running.viewOffset156)clearViewOffset156(camera)
    // The exit must remain overhead with the calibrated BP lens shift until
    // the *subsequent* 5-second Blueprint cross-fade has finished.
    if(running.kind==='exit'){
      if(running.viewOffset156)applyViewOffset156(camera,running.viewOffset156,1)
      // Independent measured floor-outline extrema, so the screenshot's tiny
      // edge residual can be distinguished from axis and camera misalignment.
      try{
        const outline158=captureThreeFloorExtrema150q(pointsRef.current,camera,
          state.gl.domElement,0,floorWorldPoints150r(state.scene))
        if(outline158)window.localStorage.setItem('strom.camera158.returnFloor',JSON.stringify(outline158))
      }catch(error){console.warn('[STROM 158] Reverse floor-outline check skipped',error)}
      checkReverseAxes158(state.scene,camera,state.gl.domElement,currentFrame150())
    }
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
