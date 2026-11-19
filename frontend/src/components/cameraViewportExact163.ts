import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'
import type { ViewOffset156 } from './cameraBlueprintCenter156'

/** STROM163_BLUEPRINT_VIEWPORT_TRUTH
 * Source of truth: Blueprint SVG screen matrix + the visible Blueprint viewport
 * sampled in the SAME click handler, before React changes the layout.
 * Architecture: X=width, Y=depth, Z=height; Three: X, Z, Y.
 */
type Screen163 = {x:number;y:number;ax:number;ay:number;bx:number;by:number}
type Rect163 = {left:number;top:number;width:number;height:number}
type Pose163 = {
  position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;
  up:THREE.Vector3;zoom:number
}
type ViewCamera163 = THREE.PerspectiveCamera | THREE.OrthographicCamera
const good163=(v:number)=>Number.isFinite(v)
const distance163=(a:{x:number;y:number},b:{x:number;y:number})=>Math.hypot(a.x-b.x,a.y-b.y)

export function viewportMath163(screen:Screen163,viewport:Rect163,canvas:Rect163){
  const vals=[screen.x,screen.y,screen.ax,screen.ay,screen.bx,screen.by,
    viewport.left,viewport.top,viewport.width,viewport.height,
    canvas.left,canvas.top,canvas.width,canvas.height]
  if(!vals.every(good163)||viewport.width<30||viewport.height<30||canvas.width<30||canvas.height<30)
    return null
  const det=screen.ax*screen.by-screen.ay*screen.bx
  if(!(det>1e-7))return null
  const bpCx=viewport.left+viewport.width/2
  const bpCy=viewport.top+viewport.height/2
  const dx=bpCx-screen.x,dy=bpCy-screen.y
  const center={x:(screen.by*dx-screen.bx*dy)/det,y:(-screen.ay*dx+screen.ax*dy)/det}
  const sx=Math.hypot(screen.ax,screen.ay),sy=Math.hypot(screen.bx,screen.by)
  if(!(sx>0.1&&sy>0.1))return null
  return {center,viewportCenterPx:{x:bpCx,y:bpCy},
    canvasCenterPx:{x:canvas.left+canvas.width/2,y:canvas.top+canvas.height/2},
    svgPixelsPerM:{x:sx,y:sy},
    desiredZero:{x:screen.x,y:screen.y},
    desiredX:{x:screen.x+screen.ax,y:screen.y+screen.ay},
    desiredY:{x:screen.x+screen.bx,y:screen.y+screen.by}}
}
function viewCamera163(camera:THREE.Camera):ViewCamera163|null {
  const p=camera as THREE.PerspectiveCamera
  if(p.isPerspectiveCamera)return p
  const o=camera as THREE.OrthographicCamera
  return o.isOrthographicCamera?o:null
}
function project163(world:THREE.Vector3,camera:THREE.Camera,rect:Rect163){
  camera.updateMatrixWorld(true)
  const v=world.clone().project(camera)
  return {x:rect.left+rect.width*(v.x+1)/2,
    y:rect.top+rect.height*(1-v.y)/2}
}

/** Run only once, hidden behind the spinner, on the actual R3F camera. */
export function alignViewportExactly163<T extends Pose163>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:T,frame:BlueprintFrame150|null,apply:(p:T)=>void,
):ViewOffset156|null {
  const cam=viewCamera163(camera)
  const isPerspective163=(cam as THREE.PerspectiveCamera | null)?.isPerspectiveCamera===true
  const bp=frame?.screen150o
  const viewport=frame?.viewport163
  if(!cam||!bp||!viewport){
    console.warn('[Strom 163] Click-time Blueprint viewport/matrix missing; preserving previous calibration')
    return null
  }
  const rect=canvas.getBoundingClientRect()
  const math=viewportMath163(bp,viewport,rect)
  if(!math){console.warn('[Strom 163] Invalid Blueprint/Canvas transformation');return null}
  const original={position:pose.position.clone(),target:pose.target.clone(),
    rotation:pose.rotation.clone(),up:pose.up.clone(),zoom:pose.zoom}
  const oldView=cam.view?.enabled?{fullWidth:cam.view.fullWidth,fullHeight:cam.view.fullHeight,
    offsetX:cam.view.offsetX,offsetY:cam.view.offsetY,width:cam.view.width,height:cam.view.height}:null
  const oldAspect=isPerspective163?(cam as THREE.PerspectiveCamera).aspect:null
  try {
    // Same REAL model transform as the floor slabs (150r). Do NOT set Y=0:
    // upper/lower floors must be calibrated at their real elevation.
    scene.updateMatrixWorld(true)
    let marker:THREE.Object3D|null=null
    scene.traverse(obj=>{
      if(!marker&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
    })
    const m=marker?(marker as THREE.Object3D).matrixWorld.clone():new THREE.Matrix4()
    const world=(x:number,y:number)=>new THREE.Vector3(x,0,y).applyMatrix4(m)
    const origin=world(0,0),wx=world(1,0),wy=world(0,1)
    const center=world(math.center.x,math.center.y)
    if(![origin.x,origin.y,origin.z,center.x,center.y,center.z].every(good163))
      throw Error('Invalid 3D floor/coordinate matrix')
    cam.clearViewOffset()
    if(isPerspective163){
      const p=cam as THREE.PerspectiveCamera
      const aspect=rect.width/rect.height
      if(Math.abs(p.aspect-aspect)>1e-7){p.aspect=aspect;p.updateProjectionMatrix()}
    }
    // Enforce exactly vertical optical axis, retaining the already-correct
    // rotation around that axis (Blueprint landscape/portrait orientation).
    const right=new THREE.Vector3(1,0,0).applyQuaternion(pose.rotation)
    right.y=0
    if(right.lengthSq()<1e-10)right.set(1,0,0)
    right.normalize()
    const back=new THREE.Vector3(0,1,0)
    const up=new THREE.Vector3().crossVectors(back,right).normalize()
    pose.rotation.setFromRotationMatrix(new THREE.Matrix4().makeBasis(right,up,back))
    pose.up.copy(up)
    pose.target.copy(center)
    pose.position.x=center.x
    pose.position.z=center.z

    const sx=math.svgPixelsPerM.x / Math.hypot(wx.x-origin.x,wx.z-origin.z)
    const sy=math.svgPixelsPerM.y / Math.hypot(wy.x-origin.x,wy.z-origin.z)
    if(!(sx>0&&sy>0&&good163(sx)&&good163(sy)))throw Error('Invalid model metre scale')
    const ppm=(sx+sy)/2
    if(isPerspective163){
      const p=cam as THREE.PerspectiveCamera
      const focal=p.projectionMatrix.elements[5]
      if(!(focal>0&&good163(focal)))throw Error('Invalid camera FOV')
      const height=rect.height*focal/(2*ppm)
      if(!(height>0.1&&height<1e6))throw Error('Invalid calibrated height')
      pose.position.y=center.y+height
    }else{
      const o=cam as THREE.OrthographicCamera
      const span=Math.abs(o.top-o.bottom)
      if(!(span>0))throw Error('Invalid orthographic span')
      pose.zoom=ppm*span/rect.height
      pose.position.y=center.y+Math.max(10,Math.abs(original.position.y-center.y))
    }
    apply(pose)

    // Solve SCALE from both exact projected world-space basis vectors; never
    // infer scale from model bounds or the camera's pre-switch zoom.
    for(let i=0;i<5;i++){
      const p0=project163(origin,camera,rect),px=project163(wx,camera,rect),py=project163(wy,camera,rect)
      const px0={x:px.x-p0.x,y:px.y-p0.y},py0={x:py.x-p0.x,y:py.y-p0.y}
      const bx={x:math.desiredX.x-math.desiredZero.x,y:math.desiredX.y-math.desiredZero.y}
      const by={x:math.desiredY.x-math.desiredZero.x,y:math.desiredY.y-math.desiredZero.y}
      const den=px0.x*px0.x+px0.y*px0.y+py0.x*py0.x+py0.y*py0.y
      const ratio=(px0.x*bx.x+px0.y*bx.y+py0.x*by.x+py0.y*by.y)/den
      if(!(den>1e-8&&ratio>0.05&&ratio<20&&good163(ratio)))
        throw Error('3D axes orientation incompatible with Blueprint; cannot align by height')
      if(Math.abs(ratio-1)<1e-9)break
      if(isPerspective163)pose.position.y=center.y+(pose.position.y-center.y)/ratio
      else pose.zoom*=ratio
      apply(pose)
    }
    // Solve TRANSLATION in the projection (not in the physical camera). The
    // physical camera stays above the Blueprint viewport world-space centre.
    const p0=project163(origin,camera,rect)
    const offset:ViewOffset156={x:p0.x-math.desiredZero.x,y:p0.y-math.desiredZero.y,
      width:rect.width,height:rect.height}
    if(![offset.x,offset.y].every(good163)||Math.abs(offset.x)>rect.width*4||Math.abs(offset.y)>rect.height*4)
      throw Error('3D viewport principal point offset outside limits')
    cam.setViewOffset(offset.width,offset.height,offset.x,offset.y,offset.width,offset.height)
    const actual0=project163(origin,camera,rect),actualX=project163(wx,camera,rect),actualY=project163(wy,camera,rect)
    const maxErrorPx=Math.max(distance163(actual0,math.desiredZero),
      distance163(actualX,math.desiredX),distance163(actualY,math.desiredY))
    if(!(maxErrorPx<=0.75))throw Error(`Cannot align axes: ${maxErrorPx.toFixed(2)}px`)
    const data={version:163,reference:'Blueprint viewport at click',
      blueprintViewport:viewport,threeViewport:{left:rect.left,top:rect.top,width:rect.width,height:rect.height},
      blueprintCenter:math.center,physicalCamera:{x:pose.position.x,y:pose.position.z,z:pose.position.y},
      planeZ:center.y,cameraHeightOverPlane:pose.position.y-center.y,
      lensOffsetPx:{x:offset.x,y:offset.y},gridErrorPx:maxErrorPx}
    try{window.localStorage.setItem('strom.camera163.alignment',JSON.stringify(data))}catch{/* optional */}
    console.info('[Strom 163] Camera exactly above BP viewport centre; axes matched',data)
    return offset
  }catch(error){
    pose.position.copy(original.position);pose.rotation.copy(original.rotation)
    pose.target.copy(original.target);pose.up.copy(original.up);pose.zoom=original.zoom
    cam.clearViewOffset()
    if(oldAspect!==null&&isPerspective163){
      (cam as THREE.PerspectiveCamera).aspect=oldAspect;cam.updateProjectionMatrix()
    }
    if(oldView)cam.setViewOffset(oldView.fullWidth,oldView.fullHeight,
      oldView.offsetX,oldView.offsetY,oldView.width,oldView.height)
    apply(pose)
    console.warn('[Strom 163] Exact viewport fit rejected; old pose restored',error)
    return null
  }
}
