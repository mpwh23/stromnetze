import {blueprintToThree151} from '../building/coordinateReference151' // STROM151_COORDINATE_DATUM
import * as THREE from 'three'
import type { BlueprintFrame150 } from './cameraTransitions150'

/** STROM150R_REAL_FLOOR_PROBE: sample invisible markers mounted directly beside the
 * active 3D floor meshes. Their matrixWorld includes every actual parent group transform,
 * so no (x,0,z) or guessed elevation assumption is involved. */
type PointM150r = {x:number;y:number}
type FloorSample150r = {plan:PointM150r;world:THREE.Vector3}
type CameraPose150r = {
  position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;up:THREE.Vector3;zoom:number
}
type Screen150r = {x:number;y:number}
type FitResult150r = {pairs:number;source:string;initialErrorPx:number;finalErrorPx:number;floorY:number;zoomFactor:number;shiftM:number}
const finite150r=(x:number)=>Number.isFinite(x)

export function floorSamples150r(scene:THREE.Object3D):FloorSample150r[]{
  scene.updateMatrixWorld(true)
  const samples:FloorSample150r[]=[]
  scene.traverse(obj=>{
    if(obj.name!=='strom150r-floor-reference'||obj.userData?.active150r!==true)return
    const vertices:unknown=obj.userData.vertices150r
    if(!Array.isArray(vertices))return
    for(const raw of vertices){
      if(!raw||typeof raw!=='object')continue
      const point=raw as PointM150r
      if(!finite150r(point.x)||!finite150r(point.y))continue
      const xyz=blueprintToThree151({x:point.x,y:point.y,z:0})
      const world=new THREE.Vector3(xyz.x,xyz.y,xyz.z).applyMatrix4(obj.matrixWorld)
      if(finite150r(world.x)&&finite150r(world.y)&&finite150r(world.z))samples.push({plan:point,world})
    }
  })
  return samples
}
export function floorWorldPoints150r(scene:THREE.Object3D):THREE.Vector3[]{
  return floorSamples150r(scene).map(p=>p.world)
}

function project150r(point:THREE.Vector3,camera:THREE.Camera,rect:DOMRect):Screen150r{
  const v=point.clone().project(camera)
  return {x:rect.left+(v.x+1)*rect.width/2,y:rect.top+(1-v.y)*rect.height/2}
}
function bpPixel150r(point:PointM150r,screen:NonNullable<BlueprintFrame150['screen150o']>):Screen150r{
  return {x:screen.x+screen.ax*point.x+screen.bx*point.y,
    y:screen.y+screen.ay*point.x+screen.by*point.y}
}
type Envelope150r={xMin:number;xMax:number;yMin:number;yMax:number}
function envelope150r(points:readonly Screen150r[]):Envelope150r{
  return {xMin:Math.min(...points.map(p=>p.x)),xMax:Math.max(...points.map(p=>p.x)),
    yMin:Math.min(...points.map(p=>p.y)),yMax:Math.max(...points.map(p=>p.y))}
}
function envelopeError150r(a:Envelope150r,b:Envelope150r):number{
  return Math.max(Math.abs(a.xMin-b.xMin),Math.abs(a.xMax-b.xMax),
    Math.abs(a.yMin-b.yMin),Math.abs(a.yMax-b.yMax))
}
function envelopeCenter150r(b:Envelope150r):Screen150r{
  return {x:(b.xMin+b.xMax)/2,y:(b.yMin+b.yMax)/2}
}
/** 150p measures real SVG polygon points via each polygon's getScreenCTM().
 * Prefer these verified bounds over the older 150o estimated root-SVG matrix. */
function measuredBlueprint150r(frame:BlueprintFrame150|null):Envelope150r|null{
  try{
    const raw=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(!raw)return null
    const data=JSON.parse(raw) as {
      floorId?:string;measuredAt?:string;
      viewport?:{screenLeft:number;screenTop:number};
      drawing?:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}
    }
    if(!frame||data.floorId!==frame.floorId||!data.viewport||!data.drawing)return null
    const v=data.viewport,d=data.drawing
    const numbers=[v.screenLeft,v.screenTop,d.xMinPx,d.xMaxPx,d.yMinPx,d.yMaxPx]
    if(!numbers.every(finite150r)||d.xMaxPx-d.xMinPx<10||d.yMaxPx-d.yMinPx<10)return null
    if(data.measuredAt&&Math.abs(Date.now()-Date.parse(data.measuredAt))>60000)return null
    return {xMin:v.screenLeft+d.xMinPx,xMax:v.screenLeft+d.xMaxPx,
      yMin:v.screenTop+d.yMinPx,yMax:v.screenTop+d.yMaxPx}
  }catch{return null}
}

/** Match measured SVG polygon bounding extrema to actual transformed 3D floor extrema.
 * Top-view rotation is deliberately unchanged; only camera altitude/zoom and XZ pan
 * are altered. The existing 5s fade, 5s flight, exit path and final default camera stay.
 * Never blocks navigation if a measurement is unavailable. */
export function calibrateFloorStart150r(
  scene:THREE.Object3D,camera:THREE.Camera,canvas:HTMLCanvasElement,
  pose:CameraPose150r,frame:BlueprintFrame150|null,
  apply:(p:CameraPose150r)=>void,
):FitResult150r|null{
  const samples=floorSamples150r(scene)
  const rect=canvas.getBoundingClientRect()
  if(samples.length<3||rect.width<20||rect.height<20)return null
  const yMin=Math.min(...samples.map(p=>p.world.y)),yMax=Math.max(...samples.map(p=>p.world.y))
  // A selected floor must be a single plane. Never mix ghost levels or walls.
  if(yMax-yMin>0.075){console.warn('[STROM 150r] mixed floor elevations; matching skipped',yMin,yMax);return null}
  const floorY=(yMin+yMax)/2
  const measured=measuredBlueprint150r(frame)
  const mapping=frame?.screen150o
  if(!measured&&!mapping)return null
  const desired=measured||envelope150r(samples.map(p=>bpPixel150r(p.plan,mapping!)))
  if(!Object.values(desired).every(finite150r))return null
  const originalPosition=pose.position.clone(),originalTarget=pose.target.clone(),originalZoom=pose.zoom
  const perspective=camera as THREE.PerspectiveCamera
  const ortho=camera as THREE.OrthographicCamera
  let zoomFactor=1
  try{
    apply(pose)
    const initial=envelope150r(samples.map(p=>project150r(p.world,camera,rect)))
    const initialErrorPx=envelopeError150r(initial,desired)
    const desiredCenter=envelopeCenter150r(desired)
    const targetWidth=desired.xMax-desired.xMin,targetHeight=desired.yMax-desired.yMin
    if(!(targetWidth>20&&targetHeight>20))throw Error('Blueprint geometry too small')
    for(let iteration=0;iteration<3;iteration++){
      const actual=samples.map(p=>project150r(p.world,camera,rect))
      if(actual.some(p=>!finite150r(p.x)||!finite150r(p.y)))throw Error('3D projection not finite')
      const actualBounds=envelope150r(actual)
      const currentWidth=actualBounds.xMax-actualBounds.xMin
      const currentHeight=actualBounds.yMax-actualBounds.yMin
      if(!(currentWidth>1&&currentHeight>1))throw Error('3D geometry too small')
      // A top-down camera has one physical scale (no independent X/Y stretching).
      const ratio=(targetWidth/currentWidth+targetHeight/currentHeight)/2
      if(!(ratio>0.45&&ratio<2.5))throw Error('Camera scale difference out of bounds')
      if(perspective.isPerspectiveCamera){
        const distance=pose.position.y-floorY
        if(!(distance>0.2))throw Error('Camera is below selected floor')
        pose.position.y=floorY+distance/ratio
        pose.target.y=floorY
      }else if(ortho.isOrthographicCamera){
        pose.zoom*=ratio
      }else throw Error('Unsupported 3D camera type')
      zoomFactor*=ratio
      apply(pose)
      const adjusted=samples.map(p=>project150r(p.world,camera,rect))
      const now=envelopeCenter150r(envelope150r(adjusted))
      const delta={x:desiredCenter.x-now.x,y:desiredCenter.y-now.y}
      // Numerically derive the world->screen Jacobian of the ACTUAL camera,
      // instead of assuming CSS pixels per metre or an untransformed floor.
      const p=samples[0].world
      const a=project150r(p,camera,rect)
      const x=project150r(p.clone().add(new THREE.Vector3(1,0,0)),camera,rect)
      const z=project150r(p.clone().add(new THREE.Vector3(0,0,1)),camera,rect)
      const xx=x.x-a.x,xy=x.y-a.y,zx=z.x-a.x,zy=z.y-a.y
      const determinant=xx*zy-zx*xy
      if(!finite150r(determinant)||Math.abs(determinant)<0.000001)throw Error('Camera cannot be shifted on XZ plane')
      const shiftX=(delta.x*zy-zx*delta.y)/determinant
      const shiftZ=(xx*delta.y-xy*delta.x)/determinant
      if(Math.hypot(shiftX,shiftZ)>100)throw Error('Camera pan out of bounds')
      // Moving the camera by -shift moves the stationary model by +delta.
      pose.position.x-=shiftX;pose.position.z-=shiftZ
      pose.target.x-=shiftX;pose.target.z-=shiftZ
      apply(pose)
    }
    const finalActual=envelope150r(samples.map(p=>project150r(p.world,camera,rect)))
    const finalErrorPx=envelopeError150r(finalActual,desired)
    if(!finite150r(finalErrorPx)||finalErrorPx>Math.max(25,initialErrorPx*1.2))throw Error('Unstable projection calibration')
    const result:FitResult150r={pairs:samples.length,
      source:measured?'real SVG polygon extrema (150p)':'saved root-SVG projection (fallback)',
      initialErrorPx,finalErrorPx,
      floorY,zoomFactor,shiftM:Math.hypot(pose.position.x-originalPosition.x,pose.position.z-originalPosition.z)}
    console.info('[STROM 150r] echte 3D-Bodenpunkte gegen Blueprint ausgerichtet',result)
    try{window.localStorage.setItem('strom.camera150r.calibration',JSON.stringify(result))}catch{/* optional */}
    return result
  }catch(error){
    pose.position.copy(originalPosition);pose.target.copy(originalTarget);pose.zoom=originalZoom
    apply(pose)
    console.warn('[STROM 150r] camera match skipped; original start pose preserved',error)
    return null
  }
}
