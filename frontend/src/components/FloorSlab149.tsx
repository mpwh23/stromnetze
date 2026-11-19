import { useMemo } from 'react'
import * as THREE from 'three'
import type { BuildingRoom } from '../building/model'

/** The finished floor stays at local Y=0. The structural floor extends DOWN by the level's slab thickness. */
export default function FloorSlab149({room,thicknessM,ghost150r=false}:{room:BuildingRoom;thicknessM:number;ghost150r?:boolean}) {
  const shape=useMemo(()=>{
    const s=new THREE.Shape()
    room.vertices.forEach((p,i)=>{if(i===0)s.moveTo(p.x,-p.y);else s.lineTo(p.x,-p.y)})
    s.closePath();return s
  },[room.vertices])
  // STROM150R_REAL_FLOOR_PROBE: measurement-only, invisible 3D reference. Same parent
  // matrix as the actual floor/rooms, including every storey transform; works with 0 mm slabs.
  // Stairwells are still open. Neither material nor physical meshes are modified.
  return <>
    <group name="strom150r-floor-reference"
      userData={{active150r:!ghost150r,vertices150r:room.vertices,roomId150r:room.id}} />
    {room.kind!=='outer'&&room.kind!=='stair'&&Number.isFinite(thicknessM)&&thicknessM>=0.001 &&
      <mesh rotation={[-Math.PI/2,0,0]} position={[0,-thicknessM,0]} receiveShadow>
        <extrudeGeometry args={[shape,{depth:thicknessM,bevelEnabled:false,steps:1}]} />
        <meshStandardMaterial color="#aebdce" roughness={0.93} side={THREE.DoubleSide}/>
      </mesh>}
  </>
}
