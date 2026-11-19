import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'

/** STROM154_GRID_PIXEL_ALIGNMENT
 * Match the actual Blueprint coordinate grid, NOT the building/floor envelope.
 * This is a single, pre-fade camera setup; the original 5s fade, 5s flight,
 * target 3D pose, orbit handling and reverse flight are deliberately unchanged.
 *
 * Blueprint SVG screen transform captured at the click:
 * screen = [x,y] + [[ax,bx],[ay,by]] * [planX,planY].
 * The 3D grid uses the matrixWorld of the same floor reference as Grid152,
 * but lies on architectural Z=0 (Three.js world Y=0).
 */
export type Alignment154 = {
  source: string
  camera: 'perspective'|'orthographic'
  viewport: {left:number;top:number;width:number;height:number}
  blueprintZero: {x:number;y:number}
  projectedZero: {x:number;y:number}
  blueprintPixelsPerMetre: {x:number;y:number}
  threePixelsPerMetre: {x:number;y:number}
  midpointPlan: {x:number;y:number}
  heightAboveZ0Metres:number
  maxAxisDifferencePx:number
  axisDifferencePx:{zero:number;x1:number;y1:number}
}
type Pose154 = {
  position:THREE.Vector3
  rotation:THREE.Quaternion
  target:THREE.Vector3
  up:THREE.Vector3
  zoom:number
}
type Screen154 = {x:number;y:number}
const finite154=(v:number)=>Number.isFinite(v)
const length154=(p:Screen154)=>Math.hypot(p.x,p.y)
const sub154=(a:Screen154,b:Screen154)=>({x:a.x-b.x,y:a.y-b.y})
const dot154=(a:Screen154,b:Screen154)=>a.x*b.x+a.y*b.y
const difference154=(a:Screen154,b:Screen154)=>length154(sub154(a,b))

function gridMatrix154(scene:THREE.Object3D):{matrix:THREE.Matrix4;source:string}{
  // This is intentionally the SAME marker selection/matrix rule as CanonicalGrid152.
  scene.updateMatrixWorld(true)
  let marker:THREE.Object3D|null=null
  scene.traverse(obj=>{
    if(!marker&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
  })
  const matrix=marker?(marker as THREE.Object3D).matrixWorld.clone():new THREE.Matrix4()
  // CanonicalGrid152 places its grid at the architectural Z=0 datum.
  // The marker's XY plan translation/rotation is preserved, only elevation is reset.
  matrix.elements[13]=0
  return {matrix,source:marker?'actual CanonicalGrid152 floor-reference matrix':'identity (no floor reference)'}
}
function project154(p:THREE.Vector3,camera:THREE.Camera,rect:DOMRect):Screen154{
  const v=p.clone().project(camera)
  return {x:rect.left+(v.x+1)*rect.width/2,y:rect.top+(1-v.y)*rect.height/2}
}

/** Return null without blocking navigation if the original click snapshot is absent. */
export function alignBlueprintGrid154<T extends Pose154>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:T,frame:BlueprintFrame150|null,apply:(p:T)=>void,
):Alignment154|null{
  const b=frame?.screen150o
  if(!b||![b.x,b.y,b.ax,b.ay,b.bx,b.by].every(finite154)){
    console.warn('[Strom 154] Blueprint-Matrix beim Klick fehlt; 3D-Betrieb bleibt freigegeben')
    return null
  }
  const rect=canvas.getBoundingClientRect()
  if(!(rect.width>40&&rect.height>40))return null
  const determinant=b.ax*b.by-b.bx*b.ay
  const sx=Math.hypot(b.ax,b.ay),sy=Math.hypot(b.bx,b.by)
  if(!(determinant>1e-5&&sx>1&&sy>1))return null
  const saved={position:pose.position.clone(),rotation:pose.rotation.clone(),
    target:pose.target.clone(),up:pose.up.clone(),zoom:pose.zoom}
  const ortho=camera as THREE.OrthographicCamera
  const persp=camera as THREE.PerspectiveCamera
  const priorAspect=persp.isPerspectiveCamera?persp.aspect:undefined
  try{
    const reference=gridMatrix154(scene)
    const toWorld=(x:number,y:number)=>{
      const v=new THREE.Vector3(x,0,y).applyMatrix4(reference.matrix)
      // Identical to Grid152 zero plane. Architectural Z=0 is Three world Y=0.
      v.y=0
      return v
    }
    const zero=toWorld(0,0),wx=toWorld(1,0),wy=toWorld(0,1)
    const worldX=wx.clone().sub(zero),worldY=wy.clone().sub(zero)
    const wxLength=Math.hypot(worldX.x,worldX.z),wyLength=Math.hypot(worldY.x,worldY.z)
    if(!(wxLength>0.0001&&wyLength>0.0001))throw Error('Degenerate actual 3D grid transform')

    // Blueprint's zero and one-metre axis marks, in SCREEN (not world) pixels.
    const desiredZero:Screen154={x:b.x,y:b.y}
    const desiredX:Screen154={x:b.x+b.ax,y:b.y+b.ay}
    const desiredY:Screen154={x:b.x+b.bx,y:b.y+b.by}

    // The camera must be above the WORLD point represented by the centre
    // of the 3D viewport, not above the building bounds or (0,0).
    const canvasCx=rect.left+rect.width/2,canvasCy=rect.top+rect.height/2
    const dx=canvasCx-b.x,dy=canvasCy-b.y
    const planCx=( b.by*dx-b.bx*dy)/determinant
    const planCy=(-b.ay*dx+b.ax*dy)/determinant
    const worldCenter=toWorld(planCx,planCy)
    pose.target.set(worldCenter.x,0,worldCenter.z)
    pose.position.x=worldCenter.x
    pose.position.z=worldCenter.z

    // The start camera is already exactly top-down (from CameraFlight150).
    // Use its REAL projection matrix/FOV and real WebGL canvas size, never
    // the polygon bounding box. A constant m/px scale covers the full viewport.
    const worldMetresPerPlanMetre=(wxLength+wyLength)/2
    const targetPixelsPerWorldMetre=(sx/wxLength+sy/wyLength)/2
    if(persp.isPerspectiveCamera){
      const actualAspect=rect.width/rect.height
      if(Math.abs(persp.aspect-actualAspect)>0.0001){
        persp.aspect=actualAspect
        persp.updateProjectionMatrix()
      }
      const focalY=persp.projectionMatrix.elements[5]
      if(!(focalY>0&&finite154(focalY)))throw Error('Invalid 3D perspective field of view')
      // CSS pixels / world-metre at Z=0 = H*focalY/(2*cameraHeight).
      const height=rect.height*focalY/(2*targetPixelsPerWorldMetre)
      if(!(height>0.05&&height<1e6&&finite154(height)))throw Error('Invalid camera altitude from FOV')
      pose.position.y=height
    }else if(ortho.isOrthographicCamera){
      const verticalSize=Math.abs(ortho.top-ortho.bottom)
      if(!(verticalSize>0))throw Error('Invalid 3D orthographic frustum')
      pose.zoom=targetPixelsPerWorldMetre*verticalSize/rect.height
      pose.position.y=Math.max(10,Math.abs(saved.position.y),worldMetresPerPlanMetre*2)
    }else throw Error('Unsupported 3D camera projection')
    apply(pose)

    // Pixel-exact final correction using the LIVE Three.js projection,
    // including camera zoom, canvas position and projection matrix offsets.
    // 3D X and Y basis must coincide with the Blueprint 1-metre basis.
    for(let iteration=0;iteration<4;iteration++){
      const p0=project154(zero,camera,rect)
      const px=project154(wx,camera,rect)
      const py=project154(wy,camera,rect)
      const basisX=sub154(px,p0),basisY=sub154(py,p0)
      const bpX=sub154(desiredX,desiredZero),bpY=sub154(desiredY,desiredZero)
      // Least-squares uniform scale, shared by X and Y: never distort the house.
      const denominator=dot154(basisX,basisX)+dot154(basisY,basisY)
      const ratio=(dot154(bpX,basisX)+dot154(bpY,basisY))/denominator
      if(!(denominator>1e-10&&ratio>0.05&&ratio<20&&finite154(ratio)))
        throw Error('3D coordinate axes cannot be matched with this camera orientation')
      if(Math.abs(ratio-1)>0.00001){
        if(persp.isPerspectiveCamera)pose.position.y/=ratio
        else pose.zoom*=ratio
        apply(pose)
      }
      const s0=project154(zero,camera,rect)
      const sx1=project154(wx,camera,rect),sy1=project154(wy,camera,rect)
      const ax=sx1.x-s0.x,bx=sy1.x-s0.x,ay=sx1.y-s0.y,by=sy1.y-s0.y
      const det=ax*by-bx*ay
      if(!finite154(det)||Math.abs(det)<1e-9)throw Error('3D grid Jacobian not invertible')
      const errorX=desiredZero.x-s0.x,errorY=desiredZero.y-s0.y
      const panPlanX=(by*errorX-bx*errorY)/det
      const panPlanY=(-ay*errorX+ax*errorY)/det
      const panWorld=worldX.clone().multiplyScalar(panPlanX)
        .add(worldY.clone().multiplyScalar(panPlanY))
      pose.position.sub(panWorld)
      pose.target.sub(panWorld)
      apply(pose)
      if(Math.hypot(errorX,errorY)<0.01&&Math.abs(ratio-1)<0.00001)break
    }
    const p0=project154(zero,camera,rect),px=project154(wx,camera,rect),py=project154(wy,camera,rect)
    const err0=difference154(p0,desiredZero),errX=difference154(px,desiredX),errY=difference154(py,desiredY)
    const maxError=Math.max(err0,errX,errY)
    if(!finite154(maxError)||maxError>8){
      throw Error(`3D grid does not match Blueprint (max error ${maxError.toFixed(2)} px)`)
    }
    const result:Alignment154={
      source:reference.source,
      camera:persp.isPerspectiveCamera?'perspective':'orthographic',
      viewport:{left:rect.left,top:rect.top,width:rect.width,height:rect.height},
      blueprintZero:desiredZero,projectedZero:p0,
      blueprintPixelsPerMetre:{x:sx,y:sy},
      threePixelsPerMetre:{x:difference154(px,p0),y:difference154(py,p0)},
      midpointPlan:{x:planCx,y:planCy},
      heightAboveZ0Metres:pose.position.y,
      maxAxisDifferencePx:maxError,
      axisDifferencePx:{zero:err0,x1:errX,y1:errY},
    }
    try{window.localStorage.setItem('strom.camera154.gridAlignment',JSON.stringify(result))}catch{/* optional */}
    console.info('[Strom 154] Blueprint- und 3D-Raster exakt auf X=0/Y=0 und 1-m-Achsen ausgerichtet',result)
    return result
  }catch(error){
    pose.position.copy(saved.position)
    pose.rotation.copy(saved.rotation)
    pose.target.copy(saved.target)
    pose.up.copy(saved.up)
    pose.zoom=saved.zoom
    if(persp.isPerspectiveCamera&&priorAspect!==undefined&&persp.aspect!==priorAspect){
      persp.aspect=priorAspect;persp.updateProjectionMatrix()
    }
    apply(pose)
    console.warn('[Strom 154] Rasterkalibrierung übersprungen, vorhandene Startansicht beibehalten',error)
    return null
  }
}
