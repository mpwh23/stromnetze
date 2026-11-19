import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'

/** STROM156_BLUEPRINT_CAMERA_CENTER
 * The Blueprint's visible *viewport* centre is the camera's world-space X/Z.
 * The WebGL canvas is a DIFFERENT DOM rectangle. To preserve exact grid pixels,
 * move the 3D eye to the Blueprint centre and compensate its differing canvas
 * principal point with a temporary, off-axis camera viewOffset. Fade the
 * viewOffset away with the existing 5s ease-out camera flight.
 *
 * Architectural X/Y/Z = Three world X/Z/Y. Do not change model coordinates,
 * world-zero grid, look direction, orbit endpoint or geometry.
 */
export type ViewOffset156 = {x:number;y:number;width:number;height:number}
type Point156 = {x:number;y:number}
type Pose156 = {
  position:THREE.Vector3
  rotation:THREE.Quaternion
  target:THREE.Vector3
  up:THREE.Vector3
  zoom:number
}
type Camera156 = THREE.PerspectiveCamera | THREE.OrthographicCamera
const isFinite156=(v:number)=>Number.isFinite(v)

function planAtPixel156(frame:BlueprintFrame150,px:number,py:number):Point156|null {
  const s=frame.screen150o
  if(!s)return null
  const determinant=s.ax*s.by-s.ay*s.bx
  if(![s.x,s.y,s.ax,s.ay,s.bx,s.by,determinant].every(isFinite156)||Math.abs(determinant)<1e-9)return null
  const dx=px-s.x,dy=py-s.y
  return {
    x:(s.by*dx-s.bx*dy)/determinant,
    y:(-s.ay*dx+s.ax*dy)/determinant,
  }
}
function planToWorld156(scene:THREE.Object3D,p:Point156):THREE.Vector3 {
  // Same transformed floor marker and architectural Z=0 rule as grid 152 / fit 154.
  scene.updateMatrixWorld(true)
  let marker:THREE.Object3D|null=null
  scene.traverse(obj=>{
    if(!marker&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
  })
  const matrix=marker?(marker as THREE.Object3D).matrixWorld.clone():new THREE.Matrix4()
  matrix.elements[13]=0
  const v=new THREE.Vector3(p.x,0,p.y).applyMatrix4(matrix)
  v.y=0
  return v
}
function projection156(world:THREE.Vector3,camera:THREE.Camera,rect:DOMRect):Point156 {
  camera.updateMatrixWorld(true)
  const ndc=world.clone().project(camera)
  return {x:rect.left+rect.width*(ndc.x+1)/2,y:rect.top+rect.height*(1-ndc.y)/2}
}
function cameraWithView156(camera:THREE.Camera):Camera156|null {
  const p=camera as THREE.PerspectiveCamera
  if(p.isPerspectiveCamera===true)return p
  const o=camera as THREE.OrthographicCamera
  return o.isOrthographicCamera===true?o:null
}

/** Set the compensating off-axis lens shift; 1 at fade, 0 at flight end. */
export function applyViewOffset156(camera:THREE.Camera,view:ViewOffset156|undefined,remaining:number):void {
  const c=cameraWithView156(camera)
  if(!c||!view)return
  const t=Math.max(0,Math.min(1,remaining))
  if(t<=1e-8){c.clearViewOffset();return}
  c.setViewOffset(view.width,view.height,view.x*t,view.y*t,view.width,view.height)
}
export function clearViewOffset156(camera:THREE.Camera):void {
  const c=cameraWithView156(camera)
  if(c?.view?.enabled)c.clearViewOffset()
}

export function alignBlueprintCenter156<T extends Pose156>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:T,frame:BlueprintFrame150|null,apply:(pose:T)=>void,
):ViewOffset156|null {
  const c=cameraWithView156(camera)
  if(!c||!frame?.screen150o)return null
  const rect=canvas.getBoundingClientRect()
  if(!(rect.width>30&&rect.height>30))return null
  let vp:{screenLeft:number;screenTop:number;width:number;height:number}|undefined
  try{
    const raw=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(raw)vp=(JSON.parse(raw) as {viewport?:typeof vp}).viewport
  }catch{return null}
  if(!vp||![vp.screenLeft,vp.screenTop,vp.width,vp.height].every(isFinite156)||vp.width<50||vp.height<50)return null
  const bpCenterPx={x:vp.screenLeft+vp.width/2,y:vp.screenTop+vp.height/2}
  const planCenter=planAtPixel156(frame,bpCenterPx.x,bpCenterPx.y)
  if(!planCenter)return null
  const desiredWorld=planToWorld156(scene,planCenter)
  if(![desiredWorld.x,desiredWorld.z].every(isFinite156))return null
  // The 154 alignment has already produced a verified pixel-exact projection.
  // Rebase only the camera's horizontal eye/target, preserving every screen pixel.
  const savedPosition=pose.position.clone(),savedTarget=pose.target.clone()
  const savedView=c.view?.enabled?{...c.view}:null
  const originWorld=planToWorld156(scene,{x:0,y:0})
  const before=projection156(originWorld,camera,rect)
  try {
    clearViewOffset156(camera)
    pose.position.x=desiredWorld.x
    pose.position.z=desiredWorld.z
    pose.target.x=desiredWorld.x
    pose.target.z=desiredWorld.z
    apply(pose)
    const after=projection156(originWorld,camera,rect)
    const shift:ViewOffset156={
      x:after.x-before.x, // viewOffset has the OPPOSITE sign to an image translation
      y:after.y-before.y,
      width:rect.width,height:rect.height,
    }
    // With the measured viewport difference this is about -140/-42 CSS px.
    if(![shift.x,shift.y].every(isFinite156)||Math.abs(shift.x)>rect.width*2||Math.abs(shift.y)>rect.height*2)
      throw Error('off-axis viewport shift exceeds safety bounds')
    applyViewOffset156(camera,shift,1)
    const corrected=projection156(originWorld,camera,rect)
    const errorPx=Math.hypot(corrected.x-before.x,corrected.y-before.y)
    if(!(errorPx<0.25))throw Error(`View offset projection mismatch ${errorPx.toFixed(3)} CSS px`)
    const data={version:156,architecturalCamera:{x:pose.position.x,y:pose.position.z,z:pose.position.y},
      blueprintCenter:planCenter,oldCamera:{x:savedPosition.x,y:savedPosition.z,z:savedPosition.y},
      canvasRect:{left:rect.left,top:rect.top,width:rect.width,height:rect.height},
      bpCenterPx,viewOffsetPx:shift,gridPixelErrorAfterRebase:errorPx}
    try{window.localStorage.setItem('strom.camera156.center',JSON.stringify(data))}catch{/* optional */}
    console.info('[STROM 156] Camera centred on Blueprint, same projected grid',data)
    return shift
  }catch(error){
    pose.position.copy(savedPosition)
    pose.target.copy(savedTarget)
    clearViewOffset156(camera)
    if(savedView?.enabled){
      c.setViewOffset(savedView.fullWidth,savedView.fullHeight,
        savedView.offsetX,savedView.offsetY,savedView.width,savedView.height)
    }
    apply(pose)
    console.warn('[STROM 156] Camera rebasing safely skipped; retained 154 alignment',error)
    return null
  }
}
