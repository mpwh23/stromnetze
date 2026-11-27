/** STROM174_LEVEL_VISIBILITY: Sichtbarkeit je Ebene ist die einzige Wahrheit (Blueprint, 3D Haus, Wanddetail).
 * Die aktive Ebene ist immer sichtbar. Vorgaben setzen die Schalter aller Ebenen:
 *  - solo:      nur die aktive Ebene
 *  - neighbors: aktive Ebene und die unmittelbar darueber/darunter
 *  - all:       alle Ebenen
 * Ein Auge schaltet genau eine Ebene um (es werden nicht mehr alle eingeblendet). */
export type VisibilityPreset174 = 'solo' | 'neighbors' | 'all'
export type DerivedPreset174 = VisibilityPreset174 | 'custom'
type Level174 = { id: string; visible?: boolean }

export function applyPreset174<T extends Level174>(layers: T[], activeId: string, preset: VisibilityPreset174): T[] {
  const index = layers.findIndex((layer) => layer.id === activeId)
  return layers.map((layer, i) => ({
    ...layer,
    visible: preset === 'all' || layer.id === activeId || (preset === 'neighbors' && index >= 0 && Math.abs(i - index) === 1),
  }))
}

/** Welche Vorgabe entspricht den aktuellen Schaltern? Bei Gleichstand (z. B. 2 Ebenen: Nachbar = Alle) entscheidet hint. */
export function derivePreset174(layers: Level174[], activeId: string, hint?: VisibilityPreset174): DerivedPreset174 {
  const shown = (list: Level174[]) => list.map((layer) => layer.id === activeId || layer.visible !== false).join()
  const now = shown(layers)
  const matches = (['solo', 'neighbors', 'all'] as const).filter((preset) => shown(applyPreset174(layers, activeId, preset)) === now)
  if (!matches.length) return 'custom'
  return hint && matches.includes(hint) ? hint : matches[0]
}

export function presetFromMode174(mode: unknown): VisibilityPreset174 {
  return mode === 'allGhostNoDims' ? 'all' : mode === 'adjacentGhostNoDims' || mode === 'adjacentGhostDims' ? 'neighbors' : 'solo'
}
export function modeFromPreset174(preset: VisibilityPreset174, dims = false) {
  return preset === 'all' ? 'allGhostNoDims' : preset === 'neighbors' ? (dims ? 'adjacentGhostDims' : 'adjacentGhostNoDims') : 'active'
}

/** Einmalige Umstellung: bisher bestimmte der Modus (nur aktuelle / Nachbarn / alle), welche Ebenen zu sehen waren.
 * Die Schalter werden so gesetzt, dass die Ansicht gleich bleibt. */
export function migrateVisibility174(floorId: string, storage: Pick<Storage, 'getItem' | 'setItem'>) {
  const prefix = `strom.floorplan.layers.${floorId}.`
  try {
    if (storage.getItem(prefix + 'visibility174')) return
    const raw: unknown = JSON.parse(storage.getItem(prefix + 'list') || 'null')
    if (Array.isArray(raw) && raw.length) {
      let active: unknown = null
      try { active = JSON.parse(storage.getItem(prefix + 'active') || 'null') } catch { active = null }
      const list = raw.filter((item): item is Record<string, unknown> => Boolean(item && typeof item === 'object'))
      const activeId = typeof active === 'string' && list.some((item) => item.id === active) ? active : String(list[0]?.id ?? '')
      let mode: unknown = 'active'
      try { mode = JSON.parse(storage.getItem(prefix + 'visibilityMode') || '"active"') } catch { mode = 'active' }
      const preset = presetFromMode174(mode)
      const index = list.findIndex((item) => item.id === activeId)
      const next = list.map((item, i) => ({
        ...item,
        visible: item.id === activeId || (item.visible !== false && (preset === 'all' || (preset === 'neighbors' && Math.abs(i - index) === 1))),
      }))
      storage.setItem(prefix + 'list', JSON.stringify(next))
    }
    storage.setItem(prefix + 'visibility174', '1')
  } catch { /* unlesbarer Speicher: unveraendert lassen */ }
}
