/** STROM171_STAIR_FLIGHT: ein Treppenlauf zwischen zwei Ebenen, zwei gekoppelte Treppenraeume.
 *
 * Der Treppenraum, aus dem der Lauf entstanden ist (z. B. EG aufwaerts), ist der Eigentuemer.
 * Der gekoppelte Raum auf der Nachbarebene (z. B. OG abwaerts) hat dieselbe Grundflaeche und liest
 * und schreibt Stufen und Kantenzuordnung des Eigentuemers. Im 3D wird der Lauf nur einmal
 * (beim Eigentuemer) gezeichnet, weil der gekoppelte Raum keine eigenen Stufen speichert.
 */
export type StairFlights171 = Record<string, string> // gekoppelter Raum -> Eigentuemer
export const stairFlightsKey171 = (floorId: string) => `strom.floorplan.layers.${floorId}.stairFlights171`
const SUFFIX171 = '.stairFlights171'

type Reader171 = Pick<Storage, 'getItem'>
type Lister171 = Pick<Storage, 'getItem' | 'key' | 'length'>

export function readStairFlights171(floorId: string, storage: Reader171): StairFlights171 {
  try {
    const value: unknown = JSON.parse(storage.getItem(stairFlightsKey171(floorId)) || '{}')
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
    const next: StairFlights171 = {}
    for (const [coupled, owner] of Object.entries(value)) if (typeof owner === 'string' && owner && owner !== coupled) next[coupled] = owner
    return next
  } catch { return {} }
}

export function saveStairFlights171(floorId: string, flights: StairFlights171) {
  window.localStorage.setItem(stairFlightsKey171(floorId), JSON.stringify(flights))
  window.dispatchEvent(new Event('strom:blueprint-levels-changed'))
}

/** Raum-ID, unter der Stufen und Kantenzuordnung gespeichert sind (gekoppelt -> Eigentuemer). */
export function stairLayoutOwner171(roomId: string, storage: Lister171 | undefined = typeof window === 'undefined' ? undefined : window.localStorage): string {
  if (!storage) return roomId
  try {
    for (let i = 0; i < storage.length; i += 1) {
      const key = storage.key(i)
      if (!key || !key.endsWith(SUFFIX171)) continue
      const value: unknown = JSON.parse(storage.getItem(key) || '{}')
      const owner = value && typeof value === 'object' ? (value as Record<string, unknown>)[roomId] : undefined
      if (typeof owner === 'string' && owner && owner !== roomId) return owner
    }
  } catch { /* unlesbarer Speicher: eigene Daten verwenden */ }
  return roomId
}

/** Partner eines Treppenraums auf der Nachbarebene (in beide Richtungen). */
export function stairFlightPartner171(flights: StairFlights171, roomId: string): string | null {
  if (flights[roomId]) return flights[roomId]
  for (const [coupled, owner] of Object.entries(flights)) if (owner === roomId) return coupled
  return null
}

export function baseStairName171(name: string) {
  return name.trim().replace(/\s*\((?:aufwärts|abwärts)\)$/i, '') || 'Treppe'
}
