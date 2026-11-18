/**
 * STROM144_MESH_CLEANUP
 * A wall is one unioned solid. Remove exactly coincident triangles before they
 * reach the GPU. No vertices are moved, no mesh dimensions or holes are changed.
 */
export type WallTriangleStats144 = {
  positions: number[]
  inputTriangles: number
  removedDuplicates: number
  removedDegenerate: number
}

export function cleanWallSurface144(source: ArrayLike<number>): WallTriangleStats144 {
  if (source.length % 9 !== 0) throw new Error('Wand-Mesh hat keine vollstaendigen Dreiecke')
  const positions: number[] = []
  const seen = new Set<string>()
  let removedDuplicates = 0
  let removedDegenerate = 0
  const key = (x: number, y: number, z: number) => `${Math.round(x * 1000000)}:${Math.round(y * 1000000)}:${Math.round(z * 1000000)}`
  for (let i = 0; i < source.length; i += 9) {
    const a = [Number(source[i]), Number(source[i + 1]), Number(source[i + 2])]
    const b = [Number(source[i + 3]), Number(source[i + 4]), Number(source[i + 5])]
    const c = [Number(source[i + 6]), Number(source[i + 7]), Number(source[i + 8])]
    if (![...a, ...b, ...c].every(Number.isFinite)) { removedDegenerate++; continue }
    const ux=b[0]-a[0], uy=b[1]-a[1], uz=b[2]-a[2]
    const vx=c[0]-a[0], vy=c[1]-a[1], vz=c[2]-a[2]
    const area2=Math.hypot(uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx)
    if (area2 < 1e-11) { removedDegenerate++; continue }
    const signature = [key(...a as [number,number,number]), key(...b as [number,number,number]), key(...c as [number,number,number])].sort().join('|')
    if (seen.has(signature)) { removedDuplicates++; continue }
    seen.add(signature)
    positions.push(...a, ...b, ...c)
  }
  return { positions, inputTriangles: source.length / 9, removedDuplicates, removedDegenerate }
}
