import * as THREE from 'three'

/** STROM165_ONE_CAMERA_OWNER
 * Reine Geometrie fuer den Uebergang Blueprint <-> 3D. Kein DOM, kein React,
 * keine Kamera wird hier veraendert. Architektur (X,Y,Z) == Three (X,Z,Y).
 *
 * Eine Draufsicht ist vollstaendig bestimmt durch
 *   - die Bildschirmmatrix des Blueprints (CSS-Pixel),
 *   - das sichtbare Blueprint-Rechteck,
 *   - das Rechteck des 3D-Canvas,
 *   - die Weltmatrix des tatsaechlich gezeichneten 3D-Rasters.
 * Daraus folgen Blickpunkt, Blickrichtung, Abstand und die Linsenverschiebung.
 */
export type BlueprintScreen165={x:number;y:number;ax:number;ay:number;bx:number;by:number}
export type Rect165={left:number;top:number;width:number;height:number}
export type ViewOffset165={x:number;y:number;width:number;height:number}
export type PlanPoint165={x:number;y:number}
/** Senkrechte Draufsicht. distanceBase gilt fuer den normalen Blickwinkel der 3D-Ansicht. */
export type TopView165={
  pivot:THREE.Vector3
  quaternion:THREE.Quaternion
  distanceBase:number
  offset:ViewOffset165
  pixelsPerMetre:number
  planCenter:PlanPoint165
}
/** Frei gedrehte 3D-Ansicht: Kamera schaut aus distance auf pivot. */
export type OrbitView165={pivot:THREE.Vector3;quaternion:THREE.Quaternion;distance:number}
export type Pose165={position:THREE.Vector3;quaternion:THREE.Quaternion;fov:number;offsetFactor:number;distance:number}

/** Hoehe der Rasterlinien innerhalb der Rastergruppe (CanonicalGrid152). */
export const GRID_PLANE_Y165=-0.018
const RADIANS165=Math.PI/180
const finite165=(...values:number[])=>values.every(Number.isFinite)

export function planToWorld165(grid:THREE.Matrix4,x:number,y:number):THREE.Vector3{
  return new THREE.Vector3(x,GRID_PLANE_Y165,y).applyMatrix4(grid)
}
export function blueprintPixel165(bp:BlueprintScreen165,x:number,y:number):PlanPoint165{
  return {x:bp.x+bp.ax*x+bp.bx*y,y:bp.y+bp.ay*x+bp.by*y}
}
export function pixelToPlan165(bp:BlueprintScreen165,px:number,py:number):PlanPoint165|null{
  const determinant=bp.ax*bp.by-bp.ay*bp.bx
  if(!finite165(determinant)||Math.abs(determinant)<1e-9)return null
  const dx=px-bp.x,dy=py-bp.y
  return {x:(bp.by*dx-bp.bx*dy)/determinant,y:(-bp.ay*dx+bp.ax*dy)/determinant}
}
/** Bildschirmposition (CSS-Pixel) eines Weltpunkts mit der uebergebenen Kamera. */
export function worldToPixel165(point:THREE.Vector3,camera:THREE.Camera,canvas:Rect165):PlanPoint165{
  const ndc=point.clone().project(camera)
  return {x:canvas.left+(ndc.x+1)*canvas.width/2,y:canvas.top+(1-ndc.y)*canvas.height/2}
}

/** Liefert die Draufsicht oder einen Klartext-Grund, warum keine exakte Loesung existiert. */
export function solveTopView165(bp:BlueprintScreen165,viewport:Rect165,canvas:Rect165,
  grid:THREE.Matrix4,baseFovDeg:number):TopView165|string{
  if(!finite165(bp.x,bp.y,bp.ax,bp.ay,bp.bx,bp.by))return 'Blueprint-Matrix unvollstaendig'
  if(!finite165(viewport.left,viewport.top,viewport.width,viewport.height)||viewport.width<20||viewport.height<20)
    return 'Blueprint-Viewport zu klein'
  if(!finite165(canvas.left,canvas.top,canvas.width,canvas.height)||canvas.width<20||canvas.height<20)
    return '3D-Canvas zu klein'
  if(!(baseFovDeg>1&&baseFovDeg<170))return 'Blickwinkel der 3D-Kamera ungueltig'
  const determinant=bp.ax*bp.by-bp.ay*bp.bx
  const pxX=Math.hypot(bp.ax,bp.ay),pxY=Math.hypot(bp.bx,bp.by)
  const skew=bp.ax*bp.bx+bp.ay*bp.by
  // Eine echte Kamera kann weder verzerrte noch gespiegelte Blueprint-Pixel abbilden.
  if(!(determinant>1e-8&&pxX>0.1&&pxY>0.1))return 'Blueprint-Matrix gespiegelt oder entartet'
  if(Math.abs(pxX-pxY)>Math.max(pxX,pxY)*1e-4||Math.abs(skew)>pxX*pxY*1e-4)
    return 'Blueprint-Matrix verzerrt'
  const pixelsPerMetre=(pxX+pxY)/2
  const pixelCenter={x:viewport.left+viewport.width/2,y:viewport.top+viewport.height/2}
  const planCenter=pixelToPlan165(bp,pixelCenter.x,pixelCenter.y)
  if(!planCenter)return 'Blueprint-Matrix nicht umkehrbar'

  const origin=planToWorld165(grid,0,0)
  const u=planToWorld165(grid,1,0).sub(origin),v=planToWorld165(grid,0,1).sub(origin)
  const lengthU=Math.hypot(u.x,u.z),lengthV=Math.hypot(v.x,v.z)
  if(!(lengthU>1e-5&&lengthV>1e-5)||Math.abs(lengthU-lengthV)>Math.max(lengthU,lengthV)*1e-4
      ||Math.abs(u.dot(v))>lengthU*lengthV*1e-4||Math.abs(u.y)>1e-6||Math.abs(v.y)>1e-6
      ||u.clone().cross(v).y>=0)
    return '3D-Raster ist kein waagerechtes, gleichmaessiges X/Y-Raster'
  const unitX=u.clone().divideScalar(lengthU),unitY=v.clone().divideScalar(lengthV)
  // Bildschirm rechts / oben, ausgedrueckt in Planrichtungen (auch bei gedrehtem SVG).
  const right=unitX.clone().multiplyScalar(bp.ax/pixelsPerMetre).addScaledVector(unitY,bp.bx/pixelsPerMetre).normalize()
  const up=unitX.clone().multiplyScalar(-bp.ay/pixelsPerMetre).addScaledVector(unitY,-bp.by/pixelsPerMetre).normalize()
  const back=new THREE.Vector3(0,1,0)
  if(right.clone().cross(up).distanceTo(back)>1e-4)return 'Blueprint und 3D-Raster haben verschiedene Drehsinne'
  const quaternion=new THREE.Quaternion().setFromRotationMatrix(new THREE.Matrix4().makeBasis(right,up,back))
  // Pixel je Welt-Einheit im Abstand d: H / (2 d tan(fov/2)). Gesucht: pixelsPerMetre / lengthU.
  const distanceBase=canvas.height*lengthU/(2*pixelsPerMetre*Math.tan(baseFovDeg*RADIANS165/2))
  if(!finite165(distanceBase)||distanceBase<=0.01)return 'Kameraabstand nicht berechenbar'
  // Die Kamera blickt genau auf pivot; ohne Verschiebung laege pivot in der Canvas-Mitte.
  // Die Linsenverschiebung legt ihn auf die Mitte des sichtbaren Blueprints.
  const offset:ViewOffset165={
    x:canvas.left+canvas.width/2-pixelCenter.x,
    y:canvas.top+canvas.height/2-pixelCenter.y,
    width:canvas.width,height:canvas.height,
  }
  return {pivot:planToWorld165(grid,planCenter.x,planCenter.y),quaternion,distanceBase,offset,pixelsPerMetre,planCenter}
}

/** Draufsicht ohne Blueprint-Daten (3D wurde ohne Uebergang geoeffnet). */
export function fallbackTopView165(bounds:{cx:number;cy:number;width:number;height:number},canvas:Rect165,
  grid:THREE.Matrix4,baseFovDeg:number):TopView165{
  const tangent=Math.max(0.02,Math.tan(baseFovDeg*RADIANS165/2))
  const aspect=Math.max(0.3,canvas.width/Math.max(1,canvas.height))
  const distanceBase=Math.max(3,1.14*Math.max(bounds.height/(2*tangent),bounds.width/(2*aspect*tangent)))
  const quaternion=new THREE.Quaternion().setFromRotationMatrix(new THREE.Matrix4().makeBasis(
    new THREE.Vector3(1,0,0),new THREE.Vector3(0,0,-1),new THREE.Vector3(0,1,0)))
  return {pivot:planToWorld165(grid,bounds.cx,bounds.cy),quaternion,distanceBase,
    offset:{x:0,y:0,width:canvas.width,height:canvas.height},
    pixelsPerMetre:canvas.height/(2*distanceBase*tangent),planCenter:{x:bounds.cx,y:bounds.cy}}
}

/** Mindestabstand der Kamera waehrend der Blende. Aus dieser Hoehe liegen auch 3 m hohe
 * Waende je 1000 px Abstand zur Bildmitte weniger als 3 CSS-Pixel neben ihrer Blueprint-Linie. */
export const MIN_START_DISTANCE165=1000

/** Blickwinkel am Anfang (s=0, fast parallel) bis zum normalen Blickwinkel (s=1).
 * Der Abstand waechst im selben Mass, sodass der Bildmassstab der Rasterebene gleich bleibt. */
export function lensAt165(baseFovDeg:number,startFovDeg:number,s:number,distanceBase=0):{fov:number;stretch:number}{
  const base=Math.tan(baseFovDeg*RADIANS165/2)
  let start=Math.tan(Math.min(baseFovDeg,Math.max(0.01,startFovDeg))*RADIANS165/2)
  // Stark hineingezoomt waere die Kamera sonst zu nah: Blickwinkel weiter verengen.
  if(distanceBase>0)start=Math.min(start,base*distanceBase/MIN_START_DISTANCE165)
  const k=Math.min(1,Math.max(0,s))
  const tangent=start+(base-start)*k
  return {fov:2*Math.atan(tangent)/RADIANS165,stretch:base/tangent}
}

/** Kamerapose zwischen Draufsicht (s=0) und freier 3D-Ansicht (s=1).
 * Die Kamera blickt in jedem Zwischenschritt genau auf den wandernden Blickpunkt. */
export function poseAt165(top:TopView165,orbit:OrbitView165,s:number,baseFovDeg:number,startFovDeg:number):Pose165{
  const k=Math.min(1,Math.max(0,s))
  const lens=lensAt165(baseFovDeg,startFovDeg,k,top.distanceBase)
  const pivot=top.pivot.clone().lerp(orbit.pivot,k)
  const quaternion=top.quaternion.clone().slerp(orbit.quaternion,k)
  const distance=(top.distanceBase+(orbit.distance-top.distanceBase)*k)*lens.stretch
  const forward=new THREE.Vector3(0,0,-1).applyQuaternion(quaternion)
  return {position:pivot.addScaledVector(forward,-distance),quaternion,fov:lens.fov,offsetFactor:1-k,distance}
}

/** Groesste Abweichung (CSS-Pixel) zwischen Blueprint und gezeichnetem 3D-Raster.
 * Geprueft werden Ursprung, 1 m, 5 m sowie Mitte und Ecken des sichtbaren Blueprints. */
export function gridErrorPx165(bp:BlueprintScreen165,viewport:Rect165,canvas:Rect165,
  grid:THREE.Matrix4,camera:THREE.Camera):{max:number;worst:PlanPoint165}|null{
  const samples:PlanPoint165[]=[{x:0,y:0},{x:1,y:0},{x:0,y:1},{x:5,y:0},{x:0,y:5}]
  for(const [fx,fy] of [[0.5,0.5],[0,0],[1,0],[0,1],[1,1]]){
    const plan=pixelToPlan165(bp,viewport.left+viewport.width*fx,viewport.top+viewport.height*fy)
    if(!plan)return null
    samples.push(plan)
  }
  let max=0,worst=samples[0]
  for(const sample of samples){
    const want=blueprintPixel165(bp,sample.x,sample.y)
    const have=worldToPixel165(planToWorld165(grid,sample.x,sample.y),camera,canvas)
    const error=Math.hypot(want.x-have.x,want.y-have.y)
    if(!Number.isFinite(error))return null
    if(error>max){max=error;worst=sample}
  }
  return {max,worst}
}
