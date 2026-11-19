import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'
import { floorSamples150r } from './cameraFloorMatch150r'

/** STROM153_CAMERA_VIEWPORT_FIT: exact blueprint viewport extrema -> 3D camera.
 * The desired PIXEL centre is xMin+(xMax-xMin)/2, same for y. Pixel coordinates
 * must NEVER be put directly into camera.position, which is in THREE WORLD metres.
 * Instead, fit the 3D world-projected footprint (including floor level Z<>0)
 * to the saved Blueprint CSS-pixel viewport using camera projection/Jacobian.
 * The 3D scene uses Y-up: architectural height Z maps to Three.js world Y.
 */
type Point153 = {x:number;y:number}
type Extrema153={xMin:number;xMax:number;yMin:number;yMax:number}
type Pose153={position:THREE.Vector3;target:THREE.Vector3;zoom:number}
type BlueprintData153={
  floorId?:string;measuredAt?:string;
  viewport?:{screenLeft:number;screenTop:number;width:number;height:number};
  drawing?:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}
}
export type Fit153={source:string;blueprintCenter:Point153;projectedCenter:Point153;
  originalCenterErrorPx:number;finalCenterErrorPx:number;boundsErrorPx:number;
  widthRatio:number;heightRatio:number;floorZ:number;cameraZAboveFloor:number}
const finite=(n:number)=>Number.isFinite(n)
const mid=(min:number,max:number)=>min+(max-min)/2
const center=(r:Extrema153):Point153=>({x:mid(r.xMin,r.xMax),y:mid(r.yMin,r.yMax)})
function bounds(points:Point153[]):Extrema153{
  return {xMin:Math.min(...points.map(p=>p.x)),xMax:Math.max(...points.map(p=>p.x)),
    yMin:Math.min(...points.map(p=>p.y)),yMax:Math.max(...points.map(p=>p.y))}
}
function projected(point:THREE.Vector3,camera:THREE.Camera,rect:DOMRect):Point153{
  const v=point.clone().project(camera)
  return {x:rect.left+(v.x+1)*rect.width/2,y:rect.top+(1-v.y)*rect.height/2}
}
function blueprintBounds(frame:BlueprintFrame150|null,plans:Point153[]):{source:string;box:Extrema153}|null{
  if(!frame)return null
  try{
    const saved=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(saved){
      const item=JSON.parse(saved) as BlueprintData153
      const v=item.viewport,d=item.drawing
      if(item.floorId===frame.floorId&&v&&d&&
          [v.screenLeft,v.screenTop,d.xMinPx,d.xMaxPx,d.yMinPx,d.yMaxPx].every(finite)&&
          d.xMaxPx>d.xMinPx+1&&d.yMaxPx>d.yMinPx+1&&
          (!item.measuredAt||Math.abs(Date.now()-Date.parse(item.measuredAt))<120000)){
        return {source:'150p: tatsächliche Blueprint-Extrema bei Klick',box:{
          xMin:v.screenLeft+d.xMinPx,xMax:v.screenLeft+d.xMaxPx,
          yMin:v.screenTop+d.yMinPx,yMax:v.screenTop+d.yMaxPx}}
      }
    }
  }catch{/* prefer frame snapshot fallback */}
  const t=frame.screen150o
  if(!t)return null
  const pts=plans.filter(p=>finite(p.x)&&finite(p.y)).map(p=>({
    x:t.x+t.ax*p.x+t.bx*p.y,y:t.y+t.ay*p.x+t.by*p.y,
  }))
  if(pts.length<3)return null
  return {source:'150o: gespeicherte Blueprint-SVG-Abbildung',box:bounds(pts)}
}

export function alignBlueprintViewport153<TPose extends Pose153>(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:TPose,frame:BlueprintFrame150|null,apply:(p:TPose)=>void,
):Fit153|null{
  const samples=floorSamples150r(scene)
  if(samples.length<3)return null
  const rect=canvas.getBoundingClientRect()
  if(!(rect.width>40&&rect.height>40))return null
  const desired=blueprintBounds(frame,samples.map(s=>s.plan))
  if(!desired)return null
  const floorZ=Math.max(...samples.map(s=>s.world.y))
  const minZ=Math.min(...samples.map(s=>s.world.y))
  if(!finite(floorZ)||floorZ-minZ>0.075)return null // Never mix different storeys.
  const bp=desired.box
  const bpWidth=bp.xMax-bp.xMin,bpHeight=bp.yMax-bp.yMin
  if(!(bpWidth>3&&bpHeight>3))return null
  const bpCenter=center(bp)
  const originalPosition=pose.position.clone(),originalTarget=pose.target.clone(),originalZoom=pose.zoom
  const perspective=camera as THREE.PerspectiveCamera
  const ortho=camera as THREE.OrthographicCamera
  try{
    apply(pose)
    const points=()=>samples.map(s=>projected(s.world,camera,rect))
    const first=bounds(points()),firstCenter=center(first)
    const originalCenterErrorPx=Math.hypot(firstCenter.x-bpCenter.x,firstCenter.y-bpCenter.y)
    const originalWidth=first.xMax-first.xMin,originalHeight=first.yMax-first.yMin
    if(!(originalWidth>0.01&&originalHeight>0.01))throw Error('3D-Footprint not projectable')

    // One physical camera scale for both axes; a ratio disagreement is a model/
    // sample mismatch, never a reason to stretch the building non-uniformly.
    const widthRatio=bpWidth/originalWidth,heightRatio=bpHeight/originalHeight
    let zoomFactor=(bpWidth*originalWidth+bpHeight*originalHeight)/
       (originalWidth*originalWidth+originalHeight*originalHeight)
    if(!(zoomFactor>0.01&&zoomFactor<100&&finite(zoomFactor)))throw Error('Invalid zoom factor')
    if(perspective.isPerspectiveCamera){
      const dist=pose.position.y-floorZ
      if(!(dist>0.01))throw Error('Camera under/inside selected floor')
      const targetDist=Math.max(0.25,dist/zoomFactor)
      pose.position.y=floorZ+targetDist
      // Preserve architectural floor elevation (Z in Blueprint, Y in Three).
      pose.target.y=floorZ
    }else if(ortho.isOrthographicCamera){
      pose.zoom=Math.max(0.0001,Math.min(10000,pose.zoom*zoomFactor))
    }else throw Error('Unsupported camera projection')
    apply(pose)

    // Solve the exact screen-space pan with the Jacobian of the LIVE 3D camera;
    // works with translated floors, non-centred world origins and arbitrary CSS canvas rects.
    for(let i=0;i<3;i++){
      const now=center(bounds(points()))
      const deltaX=bpCenter.x-now.x,deltaY=bpCenter.y-now.y
      if(Math.hypot(deltaX,deltaY)<0.05)break
      const p=samples[0].world
      const base=projected(p,camera,rect)
      const stepX=projected(p.clone().add(new THREE.Vector3(1,0,0)),camera,rect)
      const stepY=projected(p.clone().add(new THREE.Vector3(0,0,1)),camera,rect)
      const a=stepX.x-base.x,b=stepY.x-base.x,c=stepX.y-base.y,d=stepY.y-base.y
      const determinant=a*d-b*c
      if(!finite(determinant)||Math.abs(determinant)<1e-9)throw Error('Cannot invert 3D projection')
      const dx=(d*deltaX-b*deltaY)/determinant
      const dz=(-c*deltaX+a*deltaY)/determinant
      if(!finite(dx)||!finite(dz)||Math.hypot(dx,dz)>1e5)throw Error('Camera displacement invalid')
      // Translating camera by -dx/-dz shifts fixed geometry by +delta pixels.
      pose.position.x-=dx;pose.position.z-=dz
      pose.target.x-=dx;pose.target.z-=dz
      apply(pose)
    }
    const final=bounds(points()),actualCenter=center(final)
    const finalCenterErrorPx=Math.hypot(actualCenter.x-bpCenter.x,actualCenter.y-bpCenter.y)
    const boundsErrorPx=Math.max(Math.abs(final.xMin-bp.xMin),Math.abs(final.xMax-bp.xMax),
        Math.abs(final.yMin-bp.yMin),Math.abs(final.yMax-bp.yMax))
    const cameraZAboveFloor=pose.position.y-floorZ
    if(!(cameraZAboveFloor>0.1&&finite(cameraZAboveFloor)&&finalCenterErrorPx<1.5))
      throw Error('Viewport center not reached reliably')
    const result:Fit153={source:desired.source,blueprintCenter:bpCenter,
      projectedCenter:actualCenter,originalCenterErrorPx,finalCenterErrorPx,
      boundsErrorPx,widthRatio,heightRatio,floorZ,cameraZAboveFloor}
    try{window.localStorage.setItem('strom.camera153.alignment',JSON.stringify(result))}catch{/*optional*/}
    console.info('[Strom 153] Blueprint/3D viewport-center',result)
    if(boundsErrorPx>3){
      console.warn('[Strom 153] Mittelpunkt abgeglichen, aber unterschiedliche Footprint-Abmessungen',
        {blueprint:bp,projected:final,widthRatio,heightRatio})
    }
    return result
  }catch(e){
    pose.position.copy(originalPosition);pose.target.copy(originalTarget);pose.zoom=originalZoom
    apply(pose)
    console.warn('[Strom 153] ursprüngliche Kamera beibehalten, Kalibrierung fehlgeschlagen',e)
    return null
  }
}
