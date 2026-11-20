import type * as THREE from 'three'

/** STROM166_WALL_GROWTH
 * Gemeinsamer Zeitverlauf fuer Kameraflug und Wandhoehe beim Uebergang Blueprint <-> 3D.
 *
 * Hinweg  (t = 0 -> 1 in DURATION150):      Kamera easeOut(t), Wandhoehe easeInOut(t)
 * Rueckweg (genau rueckwaerts, doppelt so schnell): t = t0 * (1 - tau)
 *   -> Kamera laeuft mit Ease-in in die Draufsicht, die Waende sinken in den Blueprint.
 *
 * Waende, Tueren, Treppen und Daecher haengen in Gruppen, deren Hoehe (scale.y) hier gesetzt
 * wird. Boden, Deckenplatte, Raster und Kamera-Referenz bleiben unveraendert, damit die
 * Rasterdeckung aus 165 exakt bleibt und nichts in derselben Ebene flackert.
 */
export type GrowthKind166 = 'height' | 'level'
/** Kleinste Hoehe: 1 % (2,6 m -> 2,6 cm). Liegt knapp ueber dem Boden (1,5 cm), so dass die
 * Wandoberseiten in der Draufsicht voll sichtbar sind; bei 0 waere die Normalenmatrix singulaer. */
export const MIN_GROWTH166 = 0.01

type Entry166 = { object: THREE.Object3D; kind: GrowthKind166; faded: boolean }
const entries166 = new Set<Entry166>()
let growth166 = 1

export const easeOut166 = (t: number) => 1 - (1 - t) ** 3
export const easeInOut166 = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2)
const clamp01 = (t: number) => Math.min(1, Math.max(0, t))

/** Kamerafortschritt und Wandhoehe zum Zeitpunkt t des Hinwegs (0 = Draufsicht, 1 = 3D). */
export function progress166(t: number): { camera: number; height: number } {
  const k = clamp01(t)
  return { camera: easeOut166(k), height: easeInOut166(k) }
}
/** Zeitpunkt des Hinwegs, der auf dem Rueckweg nach tau (0..1) gezeigt wird. */
export function reverseTime166(t0: number, tau: number): number {
  return clamp01(t0) * (1 - clamp01(tau))
}

type Material166 = THREE.Material & { userData: { base166?: { opacity: number; transparent: boolean; depthWrite: boolean } } }
function materials166(object: THREE.Object3D): Material166[] {
  const mesh = object as THREE.Mesh
  const material = mesh.material as THREE.Material | THREE.Material[] | undefined
  if (!material) return []
  return (Array.isArray(material) ? material : [material]) as Material166[]
}
/** Weitere Etagen ("Alle Etagen") werden beim Absenken zusaetzlich ausgeblendet, damit die
 * Draufsicht am Ende genau die aktive Ebene des Blueprints zeigt. */
function fade166(entry: Entry166, alpha: number) {
  if (alpha >= 0.999) {
    if (!entry.faded) return
    entry.faded = false
    entry.object.visible = true
    entry.object.traverse(child => {
      for (const material of materials166(child)) {
        const base = material.userData.base166
        if (!base) continue
        if (material.transparent !== base.transparent) material.needsUpdate = true
        material.opacity = base.opacity
        material.transparent = base.transparent
        material.depthWrite = base.depthWrite
        delete material.userData.base166
      }
    })
    return
  }
  entry.faded = true
  entry.object.visible = alpha > 0.002
  entry.object.traverse(child => {
    for (const material of materials166(child)) {
      if (!material.userData.base166) {
        material.userData.base166 = { opacity: material.opacity, transparent: material.transparent, depthWrite: material.depthWrite }
      }
      if (!material.transparent) { material.transparent = true; material.needsUpdate = true }
      material.opacity = material.userData.base166.opacity * alpha
      material.depthWrite = false
    }
  })
}
function apply166(entry: Entry166) {
  const scale = growth166 >= 1 ? 1 : MIN_GROWTH166 + (1 - MIN_GROWTH166) * Math.max(0, growth166)
  if (entry.object.scale.y !== scale) {
    entry.object.scale.y = scale
    entry.object.updateMatrix()
    entry.object.updateMatrixWorld(true)
  }
  if (entry.kind === 'level') fade166(entry, growth166)
}

/** Wandhoehe 0 (flach im Blueprint) bis 1 (volle Hoehe). */
export function setGrowth166(value: number) {
  growth166 = Number.isFinite(value) ? clamp01(value) : 1
  for (const entry of entries166) apply166(entry)
}
export function currentGrowth166() { return growth166 }
export function registerGrowth166(object: THREE.Object3D, kind: GrowthKind166): () => void {
  const entry: Entry166 = { object, kind, faded: false }
  entries166.add(entry)
  apply166(entry)
  return () => {
    entries166.delete(entry)
    if (kind === 'level') fade166(entry, 1)
  }
}
