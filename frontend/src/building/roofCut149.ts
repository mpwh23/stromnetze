import type {PointM} from '../types'
import type {BuildingModel, BuildingWall} from './model'
import {wallSolidPieces} from './model'
import type {RoofSlope148} from './roofSlopes148'
import {roofHeight148} from './roofSlopes148'

/** Clip the physical WALL boundary, not the room floors, against the lowest roof plane
 * of its adjoining rooms. All coordinates are local to the finished floor.
 * The original watertight merged wall triangles and door/window voids are retained. */
type V3={x:number;y:number;z:number}
type Sector={polygon:PointM[];roof:RoofSlope148; wallId:string}
const EPS=1e-8
const area=(p:PointM[])=>p.reduce((a,v,i)=>{const w=p[(i+1)%p.length];return a+v.x*w.y-w.x*v.y},0)/2
const add3=(a:V3,b:V3,t:number):V3=>({x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t,z:a.z+(b.z-a.z)*t})
const add2=(a:PointM,b:PointM,t:number):PointM=>({x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t})
function split3(p:V3[],f:(v:V3)=>number):[V3[],V3[]] {
  const values=p.map(f)
  if(values.every(v=>v<=EPS))return [p,[]]
  if(values.every(v=>v>=-EPS))return [[],p]
  const half=(inside:boolean):V3[]=>{
    const out:V3[]=[]
    for(let i=0;i<p.length;i++){
      const a=p[i],b=p[(i+1)%p.length],da=values[i],db=values[(i+1)%p.length]
      const hit=inside?da<=EPS:da>=-EPS
      if(hit)out.push(a)
      if((da<-EPS&&db>EPS)||(da>EPS&&db<-EPS))out.push(add3(a,b,da/(da-db)))
    }
    return out
  }
  return [half(true),half(false)]
}

function clip2(poly:PointM[],fn:(p:PointM)=>number):PointM[] {
  if(!poly.length)return []
  const result:PointM[]=[]
  for(let i=0;i<poly.length;i++){
    const a=poly[i],b=poly[(i+1)%poly.length],da=fn(a),db=fn(b)
    if(da<=EPS)result.push(a)
    if((da< -EPS && db>EPS)||(da>EPS&&db< -EPS))result.push(add2(a,b,da/(da-db)))
  }
  return result
}
function emit(poly:V3[],out:number[],reverse=false){
  if(poly.length<3)return
  for(let i=1;i<poly.length-1;i++){
    const triangle=reverse?[poly[0],poly[i+1],poly[i]]:[poly[0],poly[i],poly[i+1]]
    const a=triangle[0],b=triangle[1],c=triangle[2]
    const ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z
    if(Math.hypot(uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx)<1e-9)continue
    for(const v of triangle)out.push(v.x,v.y,v.z)
  }
}
function wallRect149(w:BuildingWall,from:number,to:number):PointM[] {
  const dx=(w.end.x-w.start.x)/w.lengthM,dz=(w.end.y-w.start.y)/w.lengthM
  const ox=-dz*w.thicknessM/2,oz=dx*w.thicknessM/2
  return [
    {x:w.start.x+dx*from+ox,y:w.start.y+dz*from+oz},
    {x:w.start.x+dx*to+ox,y:w.start.y+dz*to+oz},
    {x:w.start.x+dx*to-ox,y:w.start.y+dz*to-oz},
    {x:w.start.x+dx*from-ox,y:w.start.y+dz*from-oz},
  ]
}
/** One convex roof-dominance zone across each physical wall footprint, including the outside half. */
function regions149(model:BuildingModel,roofs:RoofSlope148[]):Sector[] {
  const out:Sector[]=[]
  for(const w of model.walls){
    if(w.lengthM<0.001||w.thicknessM<0.001)continue
    const ids=new Set([w.roomId,...(w.roomIds||[])])
    const possible=roofs.filter(r=>ids.has(r.roomId))
    if(!possible.length)continue
    const footprint=wallRect149(w,0,w.lengthM)
    for(let i=0;i<possible.length;i++){
      const roof=possible[i];let poly=footprint
      for(let j=0;j<possible.length;j++)if(i!==j){
        const other=possible[j],bias=i>j?0.000001:-0.000001
        poly=clip2(poly,p=>roofHeight148(roof,p)-roofHeight148(other,p)+bias)
      }
      if(poly.length>=3&&Math.abs(area(poly))>1e-9&&Math.min(...poly.map(p=>roofHeight148(roof,p)))<model.floorHeightM-1e-6){
        out.push({polygon:poly,roof,wallId:w.id})
      }
    }
  }
  return out
}
/** True triangle intersection. Re-triangulates at all wall/roof and slope/slope crossing lines. */
export function clipSolidWalls149(model:BuildingModel,positions:readonly number[],roofs:RoofSlope148[]):number[] {
  if(!roofs.length)return [...positions]
  const regions=regions149(model,roofs)
  if(!regions.length)return [...positions]
  const output:number[]=[]
  for(let n=0;n+8<positions.length;n+=9){
    let pending:V3[][]=[[{x:positions[n],y:positions[n+1],z:positions[n+2]},
      {x:positions[n+3],y:positions[n+4],z:positions[n+5]},
      {x:positions[n+6],y:positions[n+7],z:positions[n+8]}]]
    // Partition by all roof-influenced wall footprint sectors; no duplicated faces.
    for(const region of regions){
      const bbox=region.polygon
      const minx=Math.min(...bbox.map(v=>v.x))-EPS,maxx=Math.max(...bbox.map(v=>v.x))+EPS
      const minz=Math.min(...bbox.map(v=>v.y))-EPS,maxz=Math.max(...bbox.map(v=>v.y))+EPS
      const later:V3[][]=[]
      for(const polygon of pending){
        if(Math.max(...polygon.map(v=>v.x))<minx||Math.min(...polygon.map(v=>v.x))>maxx||
          Math.max(...polygon.map(v=>v.z))<minz||Math.min(...polygon.map(v=>v.z))>maxz){later.push(polygon);continue}
        let inside=polygon
        const outside:V3[][]=[]
        const sign=area(region.polygon)>=0?1:-1
        for(let e=0;e<region.polygon.length && inside.length>=3;e++){
          const a=region.polygon[e],b=region.polygon[(e+1)%region.polygon.length]
          const [inPoly,outPoly]=split3(inside,v=>-sign*((b.x-a.x)*(v.z-a.y)-(b.y-a.y)*(v.x-a.x)))
          if(outPoly.length>=3)outside.push(outPoly)
          inside=inPoly
        }
        later.push(...outside)
        if(inside.length>=3){
          const [keep]=split3(inside,v=>v.y-roofHeight148(region.roof,{x:v.x,y:v.z}))
          if(keep.length>=3)later.push(keep)
        }
      }
      pending=later
    }
    pending.forEach(p=>emit(p,output))
  }
  // Generate the cut surface (roof cap) only where a wall contains material at that altitude.
  // wallSolidPieces excludes all existing door and window voids.
  for(const wall of model.walls){
    const zones=regions.filter(r=>r.wallId===wall.id)
    if(!zones.length)continue
    for(const part of wallSolidPieces(wall)){
      const rect=wallRect149(wall,part.fromM,part.toM)
      for(const region of zones){
        let poly=rect
        const sign=area(region.polygon)>=0?1:-1
        for(let i=0;i<region.polygon.length;i++){
          const a=region.polygon[i],b=region.polygon[(i+1)%region.polygon.length]
          poly=clip2(poly,p=>-sign*((b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)))
        }
        poly=clip2(poly,p=>part.bottomM-roofHeight148(region.roof,p))
        poly=clip2(poly,p=>roofHeight148(region.roof,p)-(part.topM-0.000001))
        if(poly.length<3||Math.abs(area(poly))<1e-9)continue
        const isCCW=area(poly)>0
        const vertices=poly.map(p=>({x:p.x,y:roofHeight148(region.roof,p),z:p.y}))
        emit(vertices,output,isCCW)
      }
    }
  }
  return output
}
