import { useEffect, useMemo, useState } from 'react'
import type { ThreeEvent } from '@react-three/fiber'
import * as THREE from 'three'
import type { PointM } from '../types'
import { readRoofSlopes148, roofHeight148, type RoofSlope148 } from '../building/roofSlopes148'

type Room148={id:string;vertices:PointM[];kind?:string}
type Sector148={roof:RoofSlope148;geometry:THREE.BufferGeometry}

function signedArea148(poly:PointM[]) {
  return poly.reduce((total,p,i)=>{const q=poly[(i+1)%poly.length];return total+p.x*q.y-q.x*p.y},0)/2
}
function clipHalfplane148(poly:PointM[], fn:(point:PointM)=>number):PointM[] {
  if(!poly.length)return []
  const clipped:PointM[]=[]
  for(let i=0;i<poly.length;i++) {
    const a=poly[i],b=poly[(i+1)%poly.length],da=fn(a),db=fn(b)
    const insideA=da<=0,insideB=db<=0
    if(insideA)clipped.push(a)
    if(insideA!==insideB) {
      const t=Math.min(1,Math.max(0,da/(da-db)))
      clipped.push({x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t})
    }
  }
  return clipped
}
/** Exact planar intersection of all roof slopes over every room-triangulation face.
 * Each resulting polygon belongs to exactly one roof record: no stacked coplanar meshes. */
export function roofSectors148(rooms:Room148[],slopes:RoofSlope148[]):Sector148[] {
  const output:Sector148[]=[]
  for(const room of rooms) {
    if(room.kind==='outer')continue
    const group=slopes.filter(s=>s.roomId===room.id)
    if(!group.length)continue
    const contour=room.vertices.filter((p,i,a)=>i===0||Math.hypot(p.x-a[i-1].x,p.y-a[i-1].y)>1e-7)
    if(contour.length<3)continue
    if(Math.hypot(contour[0].x-contour[contour.length-1].x,contour[0].y-contour[contour.length-1].y)<1e-7)contour.pop()
    if(contour.length<3||Math.abs(signedArea148(contour))<1e-5)continue
    const faces=THREE.ShapeUtils.triangulateShape(contour.map(p=>new THREE.Vector2(p.x,p.y)),[])
    for(let s=0;s<group.length;s++) {
      const roof=group[s],position:number[]=[]
      for(const face of faces) {
        let polygon=face.map(i=>contour[i])
        for(let other=0;other<group.length&&polygon.length>=3;other++) {
          if(s===other)continue
          // A deterministic tie break selects only one of two coplanar slopes.
          const bias=s>other?1e-7:-1e-7
          polygon=clipHalfplane148(polygon,p=>roofHeight148(roof,p)-roofHeight148(group[other],p)+bias)
        }
        if(polygon.length<3||Math.abs(signedArea148(polygon))<1e-10)continue
        for(let i=1;i<polygon.length-1;i++) {
          const tri=[polygon[0],polygon[i],polygon[i+1]]
          if(Math.abs(signedArea148(tri))<1e-10)continue
          if(signedArea148(tri)>0)tri.reverse() // upward-facing +Y in x/y/z coordinates
          for(const p of tri)position.push(p.x,roofHeight148(roof,p),p.y)
        }
      }
      if(!position.length)continue
      const geometry=new THREE.BufferGeometry()
      geometry.setAttribute('position',new THREE.Float32BufferAttribute(position,3))
      geometry.computeVertexNormals()
      output.push({roof,geometry})
    }
  }
  return output
}

export default function RoofMeshes148({floorId,levelId,rooms,revision,selectedId,onSelect,editable=true}: {
  floorId:string;levelId:string;rooms:Room148[];revision:number;selectedId:string;onSelect:(id:string)=>void;editable?:boolean
}) {
  const [hovered,setHovered]=useState('')
  const sectors=useMemo(()=>roofSectors148(rooms,readRoofSlopes148(floorId,window.localStorage).filter(s=>s.levelId===levelId)),
    [floorId,levelId,rooms,revision])
  useEffect(()=>()=>{for(const sector of sectors)sector.geometry.dispose()},[sectors])
  return <group>
    {sectors.map(({roof,geometry})=><mesh key={roof.id} geometry={geometry}
      onClick={editable?(event:ThreeEvent<MouseEvent>)=>{event.stopPropagation();onSelect(roof.id)}:undefined}
      onPointerOver={editable?(event:ThreeEvent<PointerEvent>)=>{event.stopPropagation();setHovered(roof.id)}:undefined}
      onPointerOut={editable?()=>setHovered(''):undefined}>
      <meshStandardMaterial color={selectedId===roof.id?'#428deb':hovered===roof.id?'#79baff':'#9fcddd'}
        transparent opacity={selectedId===roof.id?0.93:0.78} roughness={0.72} metalness={0.05}
        side={THREE.DoubleSide} depthWrite={false} />
    </mesh>)}
  </group>
}
