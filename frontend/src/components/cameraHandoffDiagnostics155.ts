import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'

/** STROM155_CAMERA_VIEWPORT_DIAGNOSTICS
 * Read-only measurement from the real, active R3F camera at the start of
 * the Blueprint -> 3D fade. Never changes a camera pose, controls, zoom or FOV.
 * Three.js axes are X horizontal, Y height, Z second plan axis;
 * architectural/Blueprint axes are X,Y in the horizontal plan.
 */
type Screen150o155 = {x:number;y:number;ax:number;ay:number;bx:number;by:number}
type Point155 = {x:number;y:number}
type BlueprintStored155 = {
  viewport?:{screenLeft:number;screenTop:number;width:number;height:number}
  drawing?:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}|null
}
type Rect155 = {left:number;top:number;width:number;height:number}

function valid155(v:number):boolean {return Number.isFinite(v)}
function round155(n:number,places=3):number {return Number(n.toFixed(places))}
function rect155(v:Rect155):Rect155 {return {left:v.left,top:v.top,width:v.width,height:v.height}}
function plan155(s:Screen150o155,screenX:number,screenY:number):Point155|null {
  const det=s.ax*s.by-s.ay*s.bx
  if(!valid155(det)||Math.abs(det)<1e-9)return null
  const dx=screenX-s.x,dy=screenY-s.y
  return {x:(s.by*dx-s.bx*dy)/det,y:(-s.ay*dx+s.ax*dy)/det}
}
function finiteRect155(v:Rect155|null|undefined):v is Rect155 {
  return !!v&&[v.left,v.top,v.width,v.height].every(valid155)&&v.width>1&&v.height>1
}
function coords155(v:THREE.Vector3):{x:number;y:number;z:number}{
  return {x:round155(v.x),y:round155(v.y),z:round155(v.z)}
}
function txt155(v:number|undefined,unit=''):string {return v===undefined?'nicht verfügbar':`${v.toFixed(2)}${unit}`}

export function captureCameraHandoff155(
  camera:THREE.Camera,canvas:HTMLCanvasElement,frame:BlueprintFrame150|null,
):void {
  let stored:BlueprintStored155|null=null
  try {
    const raw=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(raw)stored=JSON.parse(raw) as BlueprintStored155
  }catch{/* The diagnostic must never block navigation. */}
  const view0=stored?.viewport
  const view= view0 ? {left:view0.screenLeft,top:view0.screenTop,width:view0.width,height:view0.height} : null
  const canvasRect=rect155(canvas.getBoundingClientRect())
  const saved=frame?.screen150o
  const vp=finiteRect155(view)?view:null

  let blueprint:null|{
    screen:{xMin:number;xMax:number;yMin:number;yMax:number;centerX:number;centerY:number}
    visiblePlan:{xMin:number;xMax:number;yMin:number;yMax:number;centerX:number;centerY:number}
    drawingPx:BlueprintStored155['drawing']
  }=null
  if(vp&&saved){
    // Capture the FOUR original visible viewport corners, using the pre-navigation
    // SVG screen transform; do not use rendered-house polygon bounds as viewport limits.
    const corners=[
      plan155(saved,vp.left,vp.top),plan155(saved,vp.left+vp.width,vp.top),
      plan155(saved,vp.left,vp.top+vp.height),
      plan155(saved,vp.left+vp.width,vp.top+vp.height),
    ]
    const center=plan155(saved,vp.left+vp.width/2,vp.top+vp.height/2)
    if(center&&corners.every((v):v is Point155=>v!==null)){
      const points=corners as Point155[]
      blueprint={
        screen:{xMin:round155(vp.left,1),xMax:round155(vp.left+vp.width,1),
          yMin:round155(vp.top,1),yMax:round155(vp.top+vp.height,1),
          centerX:round155(vp.left+vp.width/2,1),centerY:round155(vp.top+vp.height/2,1)},
        visiblePlan:{xMin:round155(Math.min(...points.map(v=>v.x))),
          xMax:round155(Math.max(...points.map(v=>v.x))),
          yMin:round155(Math.min(...points.map(v=>v.y))),
          yMax:round155(Math.max(...points.map(v=>v.y))),
          centerX:round155(center.x),centerY:round155(center.y)},
        drawingPx:stored?.drawing,
      }
    }
  }

  // Read the live world-space camera, not its React props or captured flight target.
  camera.updateMatrixWorld(true)
  const worldPosition=camera.getWorldPosition(new THREE.Vector3())
  const worldRotation=camera.getWorldQuaternion(new THREE.Quaternion())
  const angles=new THREE.Euler().setFromQuaternion(worldRotation,'XYZ')
  // STROM157_OPTICAL_AXIS_TO_EYE: real camera orientation, unaffected by lens/viewOffset.
  // Positive architectural Z is the direction from floor to the observer.
  // The actual forward viewing direction is the opposite vector (toward -Z).
  const toEye157=camera.getWorldDirection(new THREE.Vector3()).negate().normalize()
  const zero157=(value:number):number=>Math.abs(value)<0.0005?0:round155(value)
  const opticalAxisToEye157={
    x:zero157(toEye157.x),y:zero157(toEye157.z),z:zero157(toEye157.y),
  }
  // The ray through NDC (0,0) is the ACTUAL pixel-centre ray, even if
  // projectionMatrix has a film/lens shift; no camera controls are consulted.
  const near=new THREE.Vector3(0,0,-1).unproject(camera)
  const far=new THREE.Vector3(0,0,1).unproject(camera)
  const direction=far.clone().sub(near).normalize()
  const perspective=(camera as THREE.PerspectiveCamera).isPerspectiveCamera===true
  const origin=perspective?worldPosition:near
  const t=Math.abs(direction.y)>1e-9?(0-origin.y)/direction.y:NaN
  const hit=valid155(t)&&t>=0 ? origin.clone().addScaledVector(direction,t) : null
  const projection=(camera as THREE.PerspectiveCamera).projectionMatrix.elements
  const fovVertical=perspective&&projection&&Math.abs(projection[5])>1e-9
    ?THREE.MathUtils.radToDeg(2*Math.atan(1/Math.abs(projection[5]))):undefined
  const fovHorizontal=perspective&&projection&&Math.abs(projection[0])>1e-9
    ?THREE.MathUtils.radToDeg(2*Math.atan(1/Math.abs(projection[0]))):undefined
  const ortho=camera as THREE.OrthographicCamera
  const bpViewportCentre=blueprint?.screen
  let bpCentreRayHit:THREE.Vector3|null=null
  if(bpViewportCentre&&canvasRect.width>0&&canvasRect.height>0){
    const nx=2*(bpViewportCentre.centerX-canvasRect.left)/canvasRect.width-1
    const ny=1-2*(bpViewportCentre.centerY-canvasRect.top)/canvasRect.height
    const a=new THREE.Vector3(nx,ny,-1).unproject(camera)
    const b=new THREE.Vector3(nx,ny,1).unproject(camera)
    const dir=b.clone().sub(a).normalize()
    const start=perspective?worldPosition:a
    const t0=Math.abs(dir.y)>1e-9?-start.y/dir.y:NaN
    if(valid155(t0)&&t0>=0)bpCentreRayHit=start.clone().addScaledVector(dir,t0)
  }
  const activeView=(camera as THREE.PerspectiveCamera).view
  const offAxisView=activeView?.enabled?{
    offsetX:round155(activeView.offsetX,2),offsetY:round155(activeView.offsetY,2)
  }:null
  const orthographicView=!perspective&&ortho.isOrthographicCamera?{
    widthM:round155((ortho.right-ortho.left)/ortho.zoom),
    heightM:round155((ortho.top-ortho.bottom)/ortho.zoom),
  }:null
  const rad=THREE.MathUtils.radToDeg
  const result={
    version:'155',phase:'3D-Kamera nach Ausrichtung, direkt vor der Blende',
    measuredAt:new Date().toISOString(),
    blueprintViewport:vp?rect155(vp):null,
    threeCanvasViewport:canvasRect,
    viewportOffsetPx:vp?{
      left:round155(canvasRect.left-vp.left,1),top:round155(canvasRect.top-vp.top,1),
      width:round155(canvasRect.width-vp.width,1),height:round155(canvasRect.height-vp.height,1),
    }:null,
    blueprint,
    camera:{
      axes:'Three.js world: X horizontal, Y elevation, Z horizontal (Blueprint Y)',
      type:perspective?'PerspectiveCamera':ortho.isOrthographicCamera?'OrthographicCamera':'Camera',
      position:coords155(worldPosition),
      architecturalPosition:{x:round155(worldPosition.x),y:round155(worldPosition.z),z:round155(worldPosition.y)},
      direction:coords155(direction),
      architecturalDirection:{x:round155(direction.x),y:round155(direction.z),z:round155(direction.y)},
      // Optical camera axis in plan coordinates, oriented toward the observer.
      opticalAxisToEye157,
      blueprintCenterRayOnHeightZero:bpCentreRayHit?{x:round155(bpCentreRayHit.x),y:round155(bpCentreRayHit.z)}:null,
      lensOffsetCssPx:offAxisView,
      viewportCenterOnZ0:hit?coords155(hit):null,
      rotationXYZDegrees:{x:round155(rad(angles.x),2),y:round155(rad(angles.y),2),z:round155(rad(angles.z),2)},
      fovVerticalDegrees:fovVertical===undefined?null:round155(fovVertical,2),
      fovHorizontalDegrees:fovHorizontal===undefined?null:round155(fovHorizontal,2),
      orthoView:orthographicView,
    },
  }
  try{window.localStorage.setItem('strom.camera155.handoff',JSON.stringify(result))}catch{/* optional */}
  console.info('[STROM 155] Blueprint-Viewport und reale 3D-Kamera beim Blendenstart',result)

  const panel=document.getElementById('strom-150p-viewport-geometry')
  if(!panel)return
  // Also set position at measurement time for already-mounted Blueprint panels.
  Object.assign(panel.style,{
    position:'fixed',left:'16px',bottom:'16px',top:'auto',right:'auto',
    maxHeight:'calc(100vh - 32px)',maxWidth:'min(480px, calc(100vw - 32px))',
    overflowY:'auto',zIndex:'2147483647',
  })
  let section=document.getElementById('strom-155-camera-values')
  if(!section){
    section=document.createElement('span')
    section.id='strom-155-camera-values'
    section.style.cssText='display:block;margin-top:9px;padding-top:8px;'
      +'border-top:1px solid rgba(255,255,255,.3);color:#ffd18b;font-weight:500;'
    panel.appendChild(section)
  }
  const bp=blueprint?.visiblePlan
  const p=result.camera.position,r=result.camera.rotationXYZDegrees
  const facing=result.camera.opticalAxisToEye157
  const gaze=result.camera.viewportCenterOnZ0
  const bpRay=result.camera.blueprintCenterRayOnHeightZero
  const lens=result.camera.lensOffsetCssPx
  section.textContent=
    `SICHTBARER BLUEPRINT-VIEWPORT (Plan, m)\n`
    +(bp?`Xmin: ${bp.xMin}  | Xmax: ${bp.xMax}\n`
        +`Ymin: ${bp.yMin}  | Ymax: ${bp.yMax}\n`
        +`Mitte: X ${bp.centerX} / Y ${bp.centerY} m\n`
      :'Nicht messbar: Blueprint-Transform/Viewport fehlt\n')
    +(blueprint?`Pixel-Bereich: X ${blueprint.screen.xMin}..${blueprint.screen.xMax}`
       +` / Y ${blueprint.screen.yMin}..${blueprint.screen.yMax}\n`
       +`Pixel-Mitte: ${blueprint.screen.centerX} / ${blueprint.screen.centerY}\n`:'')
    +`3D-KAMERA (PLAN: X Breite / Y Tiefe / Z Hoehe)\n`
    +`Position: X ${p.x} / Y ${p.z} / Z ${p.y} m\n`
    +`Blickachse zur Kamera XYZ (Plan): (${facing.x}, ${facing.y}, ${facing.z})\n`
    +(bpRay?`Punkt unter Blueprint-Mitte (Z=0): X ${bpRay.x} / Y ${bpRay.y}\n`
      :'Blueprint-Mitte: kein Strahlschnitt\n')
    +(gaze?`Punkt unter 3D-Canvas-Mitte (Z=0): X ${gaze.x} / Y ${gaze.z}\n`
      :'3D-Canvas-Mitte: kein Strahlschnitt\n')
    +(lens?`Lens-/Canvas-Versatz: ${lens.offsetX}px / ${lens.offsetY}px\n`:'')
    +`Rotation (intern Three XYZ): ${r.x}° / ${r.y}° / ${r.z}°\n`
    +(perspective?`Blickwinkel: vert. ${txt155(fovVertical,'°')} / horiz. ${txt155(fovHorizontal,'°')}\n`
      :orthographicView?`Orthografisch (kein FOV): ${orthographicView.widthM} × ${orthographicView.heightM} m\n`
        :'Blickwinkel: Kameratyp unbekannt\n')
    +(result.viewportOffsetPx?
       `Canvas minus BP: Links ${result.viewportOffsetPx.left}px, Oben ${result.viewportOffsetPx.top}px\n`
         +`Breite Δ${result.viewportOffsetPx.width}px / Hoehe Δ${result.viewportOffsetPx.height}px\n`:'')
    +'Details: Browser-Konsole [STROM 155]'
}
