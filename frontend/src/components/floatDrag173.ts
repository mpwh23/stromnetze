/** STROM173_FLOAT_DRAG + STROM175_FLOAT_SCREEN: schwebende Fenster und Menues verschiebbar.
 *
 * Ein Element meldet sich mit `ref={floatRef173('name')}` an. Gezogen wird an freien Flaechen
 * (Titel, Text, Hintergrund) oder am Griff `.float-grip173`; Knoepfe und Eingabefelder bleiben
 * normal bedienbar. Seit 175 wird die Position in BILDSCHIRM-Koordinaten gespeichert (position: fixed):
 * Fenster mit gleicher ID (z. B. "levels" in Blueprint, 3D Haus, Wanddetail) bleiben beim
 * Ansichtswechsel genau an ihrem Platz. Rechts abgelegte Fenster halten den Abstand zum rechten Rand.
 * Doppelklick auf eine freie Flaeche oder den Griff: zurueck an den Standardplatz.
 */
type Pos175 = { left?: number; right?: number; top: number }
const STORE175 = 'strom.ui.floatPositions175'
const OLD173 = 'strom.ui.floatOffsets173'
const OLD_IDS175: Record<string, string> = { levels: 'blueprint-levels', roof: 'blueprint-roof' }
const NO_DRAG = 'button, input, select, textarea, a, label, option, summary, [contenteditable="true"], [draggable="true"], .no-float-drag173'
const STYLE_KEYS = ['position', 'top', 'left', 'right', 'bottom', 'margin', 'translate']
let positions: Record<string, Pos175> | null = null
const refs = new Map<string, (el: HTMLElement | null) => void | (() => void)>()
const mounted = new Set<HTMLElement>()
// Zuletzt gesehene Bildschirmposition je ID (nur Sitzung): haelt auch nie verschobene Fenster beim Ansichtswechsel.
const lastSeen = new Map<string, Pos175>()
let watch: number | null = null
let installed = false

function load(): Record<string, Pos175> {
  if (positions) return positions
  positions = {}
  try {
    const value: unknown = JSON.parse(window.localStorage.getItem(STORE175) || '{}')
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      for (const [id, raw] of Object.entries(value as Record<string, unknown>)) {
        const p = raw as Partial<Pos175> | null
        if (!p || !Number.isFinite(p.top)) continue
        if (Number.isFinite(p.right)) positions[id] = { right: Number(p.right), top: Number(p.top) }
        else if (Number.isFinite(p.left)) positions[id] = { left: Number(p.left), top: Number(p.top) }
      }
    }
  } catch { positions = {} }
  return positions
}
function save() { try { window.localStorage.setItem(STORE175, JSON.stringify(load())) } catch { /* nur fuer diese Sitzung */ } }
function clear(el: HTMLElement) { for (const key of STYLE_KEYS) el.style.removeProperty(key) }

function keepVisible(el: HTMLElement) {
  const r = el.getBoundingClientRect()
  const w = window.innerWidth, h = window.innerHeight
  let dx = 0, dy = 0
  if (r.right < 48) dx = 48 - r.right
  if (r.left > w - 48) dx = w - 48 - r.left
  if (r.top < 0) dy = -r.top
  if (r.top > h - 32) dy = h - 32 - r.top
  if (!dx && !dy) return
  const top = parseFloat(el.style.top) + dy
  el.style.setProperty('top', `${Math.round(top)}px`)
  if (el.style.right && el.style.right !== 'auto') el.style.setProperty('right', `${Math.round(parseFloat(el.style.right) - dx)}px`)
  else el.style.setProperty('left', `${Math.round(parseFloat(el.style.left) + dx)}px`)
}

function toPos(r: DOMRect): Pos175 {
  return r.left + r.width / 2 > window.innerWidth / 2
    ? { right: Math.round(window.innerWidth - r.right), top: Math.round(r.top) }
    : { left: Math.round(r.left), top: Math.round(r.top) }
}
function targetPos(el: HTMLElement, id: string): Pos175 | undefined {
  const stored = load()[id]
  if (stored) return stored
  for (const other of mounted) {
    if (other === el || !other.isConnected || other.dataset.float173 !== id) continue
    const r = other.getBoundingClientRect()
    if (r.width || r.height) return toPos(r)
  }
  return lastSeen.get(id)
}

function place(el: HTMLElement, id: string) {
  const pos = targetPos(el, id)
  clear(el)
  if (!pos) return
  el.style.setProperty('position', 'fixed')
  el.style.setProperty('bottom', 'auto')
  el.style.setProperty('margin', '0')
  el.style.setProperty('top', `${pos.top}px`)
  if (pos.right !== undefined) { el.style.setProperty('right', `${pos.right}px`); el.style.setProperty('left', 'auto') }
  else { el.style.setProperty('left', `${pos.left}px`); el.style.setProperty('right', 'auto') }
  // Bildet ein Vorfahr einen eigenen Bezugsrahmen, einmal nachkorrigieren.
  const r = el.getBoundingClientRect()
  const dy = pos.top - r.top
  const dx = pos.right !== undefined ? (window.innerWidth - pos.right) - r.right : (pos.left ?? 0) - r.left
  if (Math.abs(dy) > 0.5) el.style.setProperty('top', `${Math.round(pos.top + dy)}px`)
  if (Math.abs(dx) > 0.5) {
    if (pos.right !== undefined) el.style.setProperty('right', `${Math.round(pos.right - dx)}px`)
    else el.style.setProperty('left', `${Math.round((pos.left ?? 0) + dx)}px`)
  }
  keepVisible(el)
}

function migrate(el: HTMLElement, id: string) {
  if (load()[id]) return
  try {
    const old = JSON.parse(window.localStorage.getItem(OLD173) || '{}') as Record<string, { x?: number; y?: number }>
    const o = old[OLD_IDS175[id] ?? id] ?? old[id]
    if (!o || !Number.isFinite(o.x) || !Number.isFinite(o.y) || (!o.x && !o.y)) return
    const r = el.getBoundingClientRect()
    const left = r.left + Number(o.x), top = r.top + Number(o.y)
    load()[id] = left + r.width / 2 > window.innerWidth / 2 ? { right: Math.round(window.innerWidth - left - r.width), top: Math.round(top) } : { left: Math.round(left), top: Math.round(top) }
    save()
  } catch { /* alte Position ignorieren */ }
}

/** Stabile Ref-Funktion je Fenster-ID. */
export function floatRef173(id: string): (el: HTMLElement | null) => void | (() => void) {
  let ref = refs.get(id)
  if (!ref) {
    ref = (el: HTMLElement | null) => {
      if (!el) return
      el.dataset.float173 = id
      mounted.add(el)
      install()
      migrate(el, id)
      place(el, id)
      window.requestAnimationFrame(() => { if (el.isConnected) place(el, id) })
      if (watch === null) watch = window.setInterval(() => mounted.forEach((item) => {
        if (!item.isConnected) return
        const r = item.getBoundingClientRect()
        if (r.width || r.height) lastSeen.set(item.dataset.float173 || '', toPos(r))
      }), 400)
      return () => {
        const r = el.getBoundingClientRect()
        if (r.width || r.height) lastSeen.set(id, toPos(r))
        mounted.delete(el)
      }
    }
    refs.set(id, ref)
  }
  return ref
}

export function resetFloat173(id: string) {
  lastSeen.delete(id)
  delete load()[id]
  save()
  document.querySelectorAll<HTMLElement>(`[data-float173="${CSS.escape(id)}"]`).forEach((el) => clear(el))
}

function onPointerDown(event: PointerEvent) {
  if (event.button !== 0) return
  const target = event.target as Element | null
  const el = target?.closest?.('[data-float173]') as HTMLElement | null
  if (!target || !el) return
  const grip = target.closest('.float-grip173')
  if (!grip && target.closest(NO_DRAG)) return
  const id = el.dataset.float173 || ''
  const rect = el.getBoundingClientRect()
  const start = { x: event.clientX, y: event.clientY }
  let dragging = false
  const move = (e: PointerEvent) => {
    const dx = e.clientX - start.x, dy = e.clientY - start.y
    if (!dragging) {
      if (Math.hypot(dx, dy) < 4) return
      dragging = true
      document.documentElement.classList.add('floating-dragging173')
      window.getSelection()?.removeAllRanges()
    }
    e.preventDefault()
    const left = Math.min(Math.max(rect.left + dx, 48 - rect.width), window.innerWidth - 48)
    const top = Math.min(Math.max(rect.top + dy, 0), window.innerHeight - 32)
    load()[id] = { left: Math.round(left), top: Math.round(top) }
    place(el, id)
  }
  const up = () => {
    window.removeEventListener('pointermove', move, true)
    window.removeEventListener('pointerup', up, true)
    window.removeEventListener('pointercancel', up, true)
    if (!dragging) return
    document.documentElement.classList.remove('floating-dragging173')
    // Rechte Bildschirmhaelfte: Abstand zum rechten Rand merken (haelt bei Fenstergroesse).
    load()[id] = toPos(el.getBoundingClientRect())
    lastSeen.set(id, load()[id])
    save()
    place(el, id)
    const swallow = (e: MouseEvent) => { e.stopPropagation(); e.preventDefault() }
    window.addEventListener('click', swallow, { capture: true, once: true })
    window.setTimeout(() => window.removeEventListener('click', swallow, true), 0)
  }
  window.addEventListener('pointermove', move, true)
  window.addEventListener('pointerup', up, true)
  window.addEventListener('pointercancel', up, true)
  if (grip) event.preventDefault()
}

function onDoubleClick(event: MouseEvent) {
  const target = event.target as Element | null
  const el = target?.closest?.('[data-float173]') as HTMLElement | null
  if (!target || !el || (!target.closest('.float-grip173') && target.closest(NO_DRAG))) return
  const id = el.dataset.float173 || ''
  if (!load()[id] && !lastSeen.has(id)) return
  delete load()[id]
  lastSeen.delete(id)
  save()
  document.querySelectorAll<HTMLElement>(`[data-float173="${CSS.escape(id)}"]`).forEach((item) => clear(item))
  // Standardplatz gilt jetzt auch als zuletzt gesehen (sonst springt das Fenster beim naechsten Wechsel zurueck)
  document.querySelectorAll<HTMLElement>(`[data-float173="${CSS.escape(id)}"]`).forEach((item) => { const r = item.getBoundingClientRect(); if (r.width || r.height) lastSeen.set(id, toPos(r)) })
}

function install() {
  if (installed || typeof document === 'undefined') return
  installed = true
  document.addEventListener('pointerdown', onPointerDown, true)
  document.addEventListener('dblclick', onDoubleClick, true)
  window.addEventListener('resize', () => mounted.forEach((el) => { if (el.isConnected) place(el, el.dataset.float173 || '') }))
}
