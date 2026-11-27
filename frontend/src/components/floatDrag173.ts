/** STROM173_FLOAT_DRAG: alle schwebenden Fenster und Menues lassen sich verschieben.
 *
 * Ein Element meldet sich mit `ref={floatRef173('name')}` an. Gezogen wird an freien Flaechen
 * (Titel, Text, Hintergrund) oder am Griff `.float-grip173`; Knoepfe und Eingabefelder bleiben
 * normal bedienbar. Der Versatz wird per CSS `translate` gesetzt (unabhaengig von `transform`)
 * und je Fenster im Browser gespeichert. Doppelklick auf eine freie Flaeche setzt zurueck.
 */
type Offset173 = { x: number; y: number }
const STORE173 = 'strom.ui.floatOffsets173'
const NO_DRAG173 = 'button, input, select, textarea, a, label, option, summary, [contenteditable="true"], [draggable="true"], .no-float-drag173'
let offsets173: Record<string, Offset173> | null = null
const refs173 = new Map<string, (el: HTMLElement | null) => void>()
let installed173 = false

function load173(): Record<string, Offset173> {
  if (offsets173) return offsets173
  try {
    const value: unknown = JSON.parse(window.localStorage.getItem(STORE173) || '{}')
    offsets173 = {}
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      for (const [id, raw] of Object.entries(value as Record<string, unknown>)) {
        const o = raw as Partial<Offset173> | null
        if (o && Number.isFinite(o.x) && Number.isFinite(o.y)) offsets173[id] = { x: Number(o.x), y: Number(o.y) }
      }
    }
  } catch { offsets173 = {} }
  return offsets173
}
function save173() { try { window.localStorage.setItem(STORE173, JSON.stringify(load173())) } catch { /* Speicher voll: nur fuer diese Sitzung */ } }
function apply173(el: HTMLElement, id: string) {
  const o = load173()[id]
  if (o && (o.x || o.y)) el.style.setProperty('translate', `${o.x}px ${o.y}px`)
  else el.style.removeProperty('translate')
}
const clamp173 = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), Math.max(lo, hi))

/** Stabile Ref-Funktion je Fenster-ID. */
export function floatRef173(id: string): (el: HTMLElement | null) => void {
  let ref = refs173.get(id)
  if (!ref) {
    ref = (el: HTMLElement | null) => {
      if (!el) return
      el.dataset.float173 = id
      apply173(el, id)
      install173()
    }
    refs173.set(id, ref)
  }
  return ref
}

export function resetFloat173(id: string) {
  delete load173()[id]
  save173()
  document.querySelectorAll<HTMLElement>(`[data-float173="${CSS.escape(id)}"]`).forEach((el) => apply173(el, id))
}

function onPointerDown173(event: PointerEvent) {
  if (event.button !== 0) return
  const target = event.target as Element | null
  const el = target?.closest?.('[data-float173]') as HTMLElement | null
  if (!target || !el) return
  const grip = target.closest('.float-grip173')
  if (!grip && target.closest(NO_DRAG173)) return
  const id = el.dataset.float173 || ''
  const base = { ...(load173()[id] ?? { x: 0, y: 0 }) }
  const rect = el.getBoundingClientRect()
  const left0 = rect.left - base.x, top0 = rect.top - base.y
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
    // Mindestens 48 px des Fensters bleiben im sichtbaren Bereich.
    const x = clamp173(base.x + dx, 48 - rect.width - left0, window.innerWidth - 48 - left0)
    const y = clamp173(base.y + dy, -top0, window.innerHeight - 32 - top0)
    load173()[id] = { x: Math.round(x), y: Math.round(y) }
    apply173(el, id)
  }
  const up = () => {
    window.removeEventListener('pointermove', move, true)
    window.removeEventListener('pointerup', up, true)
    window.removeEventListener('pointercancel', up, true)
    if (!dragging) return
    document.documentElement.classList.remove('floating-dragging173')
    save173()
    // Der Klick nach dem Ziehen loest keine Aktion aus.
    const swallow = (e: MouseEvent) => { e.stopPropagation(); e.preventDefault() }
    window.addEventListener('click', swallow, { capture: true, once: true })
    window.setTimeout(() => window.removeEventListener('click', swallow, true), 0)
  }
  window.addEventListener('pointermove', move, true)
  window.addEventListener('pointerup', up, true)
  window.addEventListener('pointercancel', up, true)
  if (grip) event.preventDefault()
}

function onDoubleClick173(event: MouseEvent) {
  const target = event.target as Element | null
  const el = target?.closest?.('[data-float173]') as HTMLElement | null
  if (!target || !el || (!target.closest('.float-grip173') && target.closest(NO_DRAG173))) return
  const id = el.dataset.float173 || ''
  if (!load173()[id]) return
  delete load173()[id]
  save173()
  apply173(el, id)
}

function install173() {
  if (installed173 || typeof document === 'undefined') return
  installed173 = true
  document.addEventListener('pointerdown', onPointerDown173, true)
  document.addEventListener('dblclick', onDoubleClick173, true)
}
