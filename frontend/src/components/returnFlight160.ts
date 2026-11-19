import type * as THREE from 'three'

/** STROM160_REVERSE_FROM_SAVED_TOP_VIEW
 * Pure interpolation for the reverse camera flight. No camera reset, no
 * recomputation of the Blueprint field of view, no OrbitControls.update().
 */
export type ReturnLens160 = {x: number; y: number; width: number; height: number}
export type ReturnPose160 = {
  position: THREE.Vector3
  rotation: THREE.Quaternion
  target: THREE.Vector3
  up: THREE.Vector3
  zoom: number
}
export function clonePose160(p: ReturnPose160): ReturnPose160 {
  return {
    position: p.position.clone(), rotation: p.rotation.clone(),
    target: p.target.clone(), up: p.up.clone(), zoom: p.zoom,
  }
}
export function easeOut160(t: number): number {
  const clamped = Math.max(0, Math.min(1, t))
  return 1 - (1 - clamped) ** 3
}
export function interpolatePose160(a: ReturnPose160, b: ReturnPose160, k: number): ReturnPose160 {
  const f = Math.max(0, Math.min(1, k))
  return {
    position: a.position.clone().lerp(b.position, f),
    rotation: a.rotation.clone().slerp(b.rotation, f),
    target: a.target.clone().lerp(b.target, f),
    up: a.up.clone().lerp(b.up, f).normalize(),
    zoom: a.zoom + (b.zoom - a.zoom) * f,
  }
}
