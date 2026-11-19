import { useMemo } from 'react'
import * as THREE from 'three'
import type { BuildingRoom } from '../building/model'

/** The finished floor stays at local Y=0. The structural floor extends DOWN by the level's slab thickness. */
export default function FloorSlab149({room,thicknessM}:{room:BuildingRoom;thicknessM:number}) {
  const shape=useMemo(()=>{
    const s=new THREE.Shape()
    room.vertices.forEach((p,i)=>{if(i===0)s.moveTo(p.x,-p.y);else s.lineTo(p.x,-p.y)})
    s.closePath();return s
  },[room.vertices])
  // Stairwells must remain open: a full floor plate here would block the 3D stairs.
  if(room.kind==='outer'||room.kind==='stair'||!Number.isFinite(thicknessM)||thicknessM<0.001)return null
  return <mesh rotation={[-Math.PI/2,0,0]} position={[0,-thicknessM,0]} receiveShadow>
    <extrudeGeometry args={[shape,{depth:thicknessM,bevelEnabled:false,steps:1}]} />
    <meshStandardMaterial color="#aebdce" roughness={0.93} side={THREE.DoubleSide}/>
  </mesh>
}
