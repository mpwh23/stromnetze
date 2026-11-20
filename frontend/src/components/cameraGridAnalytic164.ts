import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'
import type { ViewOffset156 } from './cameraBlueprintCenter156'

/** STROM164_ONE_EXACT_TRANSFORM
 * The EXACT displayed 3D grid is the geometric source of truth.  Its matrixWorld
 * is used unchanged.  Blueprint supplies one affine screen mapping in CSS px.
 * One inversion, one lens-scale formula, one lens-translation formula.
 * No bounds, guessed height, iteration, hardcoded pan, or second camera driver.
 * Architectural (X,Y,Z) == Three (X,Z,Y).
 */
type BlueprintBasis164={x:number;y:number;ax:number;ay:number;bx:number;by:number}
type Rect164={left:number;top:number;width:number;height:number}
type Pose164={position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;up:THREE.Vector3;zoom:number}
type Camera164=THREE.PerspectiveCamera|THREE.OrthographicCamera
const finite164=(...v:number[])=>v.every(Number.isFinite)
const distance164=(a:{x:number;y:number},b:{x:number;y:number})=>Math.hypot(a.x-b.x,a.y-b.y)

export function viewportToPlan164(s:BlueprintBasis164,v:Rect164){
  if(!finite164(s.x,s.y,s.ax,s.ay,s.bx,s.by,v.left,v.top,v.width,v.height)
     ||v.width<20||v.height<20)return null
  const determinant=s.ax*s.by-s.ay*s.bx
  const pxX=Math.hypot(s.ax,s.ay),pxY=Math.hypot(s.bx,s.by)
  const dot=s.ax*s.bx+s.ay*s.by
  // A single real camera cannot reproduce anisotropic/sheared blueprint pixels.
  // Reject instead of silently approximating these transforms.
  if(!(determinant>1e-8&&pxX>0.1&&pxY>0.1)
     ||Math.abs(pxX-pxY)>Math.max(pxX,pxY)*0.00005
     ||Math.abs(dot)>pxX*pxY*0.00005)return null
  const pixelCenter={x:v.left+v.width/2,y:v.top+v.height/2}
  const dx=pixelCenter.x-s.x,dy=pixelCenter.y-s.y
  const planCenter={x:(s.by*dx-s.bx*dy)/determinant,y:(-s.ay*dx+s.ax*dy)/determinant}
  return {planCenter,pixelCenter,pixelsPerMetre:pxX}
}

function worldToScreen164(p:THREE.Vector3,camera:THREE.Camera,rect:Rect164){
  camera.updateMatrixWorld(true)
  const ndc=p.clone().project(camera)
  return {x:rect.left+(ndc.x+1)*rect.width/2,y:rect.top+(1-ndc.y)*rect.height/2}
}
function cameraType164(camera:THREE.Camera):Camera164|null{
  const p=camera as THREE.PerspectiveCamera
  if(p.isPerspectiveCamera===true)return p
  const o=camera as THREE.OrthographicCamera
  return o.isOrthographicCamera===true?o:null
}

/** Returns a view offset only if the actual Three projection matches ALL
 * independently sampled Blueprint origin, 1 m and 5 m grid lines.
 * Called once, before removing the loading spinner.
 */
export function alignGridAnalytic164<T extends Pose164>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:T,frame:BlueprintFrame150|null,apply:(p:T)=>void,
):ViewOffset156|null{
  const cam=cameraType164(camera),bp=frame?.screen150o,viewport=frame?.viewport163
  if(!cam||!bp||!viewport){
    console.error('[STROM164] Click-time Blueprint/3D camera data missing')
    return null
  }
  const rect=canvas.getBoundingClientRect()
  if(!finite164(rect.left,rect.top,rect.width,rect.height)||rect.width<20||rect.height<20)return null
  const map=viewportToPlan164(bp,viewport)
  if(!map){console.error('[STROM164] Blueprint screen matrix is invalid or distorted');return null}

  // Use exactly the SAME world matrix as the rendered 3D grid, not the nearby
  // floor marker whose Y may differ by the selected storey elevation.
  const grid=scene.getObjectByName('strom152-blueprint-grid')
  if(!grid){console.error('[STROM164] Canonical 3D grid has not mounted');return null}
  grid.updateWorldMatrix(true,false)
  const matrix=grid.matrixWorld.clone()
  const world=(x:number,y:number)=>new THREE.Vector3(x,-0.018,y).applyMatrix4(matrix)
  const o=world(0,0),wx=world(1,0),wy=world(0,1)
  const cx=world(map.planCenter.x,map.planCenter.y)
  const u=wx.clone().sub(o),v=wy.clone().sub(o)
  const ux=Math.hypot(u.x,u.z),uy=Math.hypot(v.x,v.z)
  if(!(ux>1e-5&&uy>1e-5)||Math.abs(ux-uy)>Math.max(ux,uy)*0.00005
      ||Math.abs(u.dot(v))>ux*uy*0.00005
      ||Math.abs(u.y)>1e-6||Math.abs(v.y)>1e-6
      ||u.clone().cross(v).y>=0){
    console.error('[STROM164] 3D grid axes are not a horizontal uniform right-handed XY grid')
    return null
  }

  const old={position:pose.position.clone(),rotation:pose.rotation.clone(),up:pose.up.clone(),
    target:pose.target.clone(),zoom:pose.zoom}
  const oldView=cam.view?.enabled?{fullWidth:cam.view.fullWidth,fullHeight:cam.view.fullHeight,
    offsetX:cam.view.offsetX,offsetY:cam.view.offsetY,width:cam.view.width,height:cam.view.height}:null
  const isPerspective=(cam as THREE.PerspectiveCamera).isPerspectiveCamera===true
  const persp=cam as THREE.PerspectiveCamera
  const ortho=cam as THREE.OrthographicCamera
  const oldAspect=isPerspective?persp.aspect:0
  // STROM164B_ORTHOGRAPHIC_ASPECT: restore the entire original frustum on error.
  const oldOrtho=!isPerspective?{left:ortho.left,right:ortho.right,
    top:ortho.top,bottom:ortho.bottom}:null
  try{
    cam.clearViewOffset()
    if(isPerspective){
      persp.aspect=rect.width/rect.height
      persp.updateProjectionMatrix()
    }
    // The 2D Blueprint axes determine the camera yaw; its look vector remains
    // exactly (0,-1,0) in Three.  This also supports rotated SVG or floor grid.
    const unitX=u.clone().divideScalar(ux),unitY=v.clone().divideScalar(uy)
    const right=unitX.clone().multiplyScalar(bp.ax/map.pixelsPerMetre)
      .addScaledVector(unitY,bp.bx/map.pixelsPerMetre).normalize()
    const up=unitX.clone().multiplyScalar(-bp.ay/map.pixelsPerMetre)
      .addScaledVector(unitY,-bp.by/map.pixelsPerMetre).normalize()
    const back=new THREE.Vector3(0,1,0)
    if(right.clone().cross(up).distanceTo(back)>0.00005)
      throw Error('3D grid and Blueprint coordinate handedness differ')
    pose.rotation.setFromRotationMatrix(new THREE.Matrix4().makeBasis(right,up,back))
    pose.up.copy(up)
    pose.target.copy(cx)
    pose.position.x=cx.x
    pose.position.z=cx.z
    if(isPerspective){
      const focal=persp.projectionMatrix.elements[5]
      const height=rect.height*focal*ux/(2*map.pixelsPerMetre)
      if(!finite164(height)||height<=0.05)throw Error('Invalid camera height')
      pose.position.y=cx.y+height
    }else{
      const span=ortho.top-ortho.bottom
      if(!(span>0))throw Error('Invalid orthographic camera height range')
      // OrthographicCamera has independent horizontal and vertical world spans.
      // The 3D canvas can have a different aspect from the camera's constructor
      // (e.g. 1130/1100 canvas vs. 22/14 nominal camera). Zoom alone matches
      // only Y; X was off by precisely 445.040 CSS px at the 21-m sample.
      // The optical centre must be the Blueprint viewport centre on BOTH axes.
      const halfHorizontal=span*rect.width/(2*rect.height)
      if(!finite164(halfHorizontal)||halfHorizontal<=0)
        throw Error('Invalid orthographic camera aspect')
      ortho.left=-halfHorizontal
      ortho.right=halfHorizontal
      ortho.top=span/2
      ortho.bottom=-span/2
      pose.zoom=span*map.pixelsPerMetre/(rect.height*ux)
      pose.position.y=cx.y+Math.max(1,Math.abs(old.position.y-cx.y))
    }
    apply(pose)

    // One exact lens translation: the same plan centre must be drawn at the
    // SAME browser pixel in both independent DOM viewports.
    const screenCenter=worldToScreen164(cx,cam,rect)
    const offset:ViewOffset156={
      x:screenCenter.x-map.pixelCenter.x,
      y:screenCenter.y-map.pixelCenter.y,
      width:rect.width,height:rect.height,
    }
    if(!finite164(offset.x,offset.y))throw Error('Invalid canvas viewport displacement')
    cam.setViewOffset(offset.width,offset.height,offset.x,offset.y,offset.width,offset.height)

    // This is a verification, NOT a corrective fit.  Reject any mismatch.
    const samples=[[-5,-5],[0,0],[1,0],[0,1],[5,0],[0,5],[10,-10],[21,13]]
    let maximum=0
    for(const [x,y] of samples){
      const measured=worldToScreen164(world(x,y),cam,rect)
      const desired={x:bp.x+bp.ax*x+bp.bx*y,y:bp.y+bp.ay*x+bp.by*y}
      maximum=Math.max(maximum,distance164(measured,desired))
    }
    if(!(maximum<0.05))throw Error(`3D and Blueprint differ by ${maximum.toFixed(3)} CSS px`)

    const results={version:164,source:'same rendered 3D grid matrix and click-time Blueprint SVG',
      blueprintCenter:map.planCenter,blueprintViewport:viewport,
      threeCanvas:{left:rect.left,top:rect.top,width:rect.width,height:rect.height},
      cameraXYZ:{x:pose.position.x,y:pose.position.z,z:pose.position.y},
      gridWorldPlaneZ:cx.y,pixelsPerMetre:map.pixelsPerMetre,
      lensOffsetCssPx:{x:offset.x,y:offset.y},maxErrorCssPx:maximum}
    try{window.localStorage.setItem('strom.camera164.alignment',JSON.stringify(results))}catch{/* storage optional */}
    console.info('[STROM164] One-step Blueprint/3D grid alignment',results)
    return offset
  }catch(error){
    pose.position.copy(old.position);pose.rotation.copy(old.rotation);pose.up.copy(old.up)
    pose.target.copy(old.target);pose.zoom=old.zoom
    cam.clearViewOffset()
    if(isPerspective){persp.aspect=oldAspect;persp.updateProjectionMatrix()}
    if(oldOrtho){
      ortho.left=oldOrtho.left;ortho.right=oldOrtho.right
      ortho.top=oldOrtho.top;ortho.bottom=oldOrtho.bottom
      ortho.updateProjectionMatrix()
    }
    if(oldView)cam.setViewOffset(oldView.fullWidth,oldView.fullHeight,
      oldView.offsetX,oldView.offsetY,oldView.width,oldView.height)
    apply(pose)
    console.error('[STROM164] No approximation permitted; camera calibration rejected',error)
    return null
  }
}
