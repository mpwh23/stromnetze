import { useEffect, useRef, useState, type ReactNode } from 'react'
import StromIcon from './StromIcon'
import { floatRef173 } from './floatDrag173'
import type { DerivedPreset174, VisibilityPreset174 } from '../building/levelVisibility174'

/** STROM173_LEVEL_MENU: ein Ebenenmenue fuer Blueprint und 3D-Ansichten (Vorlage: Blueprint). */
export type LevelMenuLevel173 = { id: string; name: string; visible: boolean; heightM: number; slabThicknessM: number }
export type LevelRowState173 = { visible: boolean; ghost: boolean }

type LevelMenuProps173 = {
  floatId: string
  className?: string
  levels: LevelMenuLevel173[]
  activeId: string
  zeroId: string
  radioName: string
  open: boolean
  onToggleOpen: () => void
  rowState: (id: string) => LevelRowState173
  eyeTitle?: (id: string, visible: boolean) => string
  onSelect: (id: string) => void
  onToggleVisible: (id: string) => void
  onRename: (id: string, name: string) => void
  onHeight: (id: string, millimetres: number) => void
  onSlab: (id: string, millimetres: number) => void
  onZero: (id: string) => void
  onMove: (dragId: string, targetId: string) => void
  onAdd: () => void
  onDelete: () => void
  note?: ReactNode
  preset?: DerivedPreset174
  onPreset?: (preset: VisibilityPreset174) => void
}

const mm173 = (m: number) => Math.round(m * 1000)

/** STROM176_UNIT_INPUT: Laenge mit Einheit lesen (m, dm, cm, mm; Komma oder Punkt). Ergebnis in mm, sonst null. */
export function parseLengthMm176(text: string): number | null {
  const clean = text.trim().toLowerCase().replace(/\s+/g, '').replace(',', '.')
  const match = /^([+-]?(?:\d+\.?\d*|\.\d+))(mm|cm|dm|m)?$/.exec(clean)
  if (!match) return null
  const factor = { mm: 1, cm: 10, dm: 100, m: 1000 }[(match[2] || 'mm') as 'mm' | 'cm' | 'dm' | 'm']
  const value = Number(match[1]) * factor
  return Number.isFinite(value) ? Math.round(value) : null
}

/** Zahl im Feld, 'mm' grau dahinter; beim Bearbeiten nur die Zahl. Enter/Verlassen uebernimmt, Escape verwirft. */
function MmField176({ valueMm, label, title, onCommit }: { valueMm: number; label: string; title: string; onCommit: (mm: number) => void }) {
  const [editing, setEditing] = useState(false)
  const [text, setText] = useState(String(valueMm))
  const justFocused = useRef(false) // Mausklick soll die Markierung beim Fokussieren nicht aufheben
  useEffect(() => { if (!editing) setText(String(valueMm)) }, [valueMm, editing])
  const commit = () => {
    setEditing(false)
    const mm = parseLengthMm176(text)
    if (mm === null) { setText(String(valueMm)); return }
    setText(String(mm))
    if (mm !== valueMm) onCommit(mm)
  }
  return (
    <span className={`mm-field176 ${editing ? 'editing' : ''}`} title={title}>
      <input type="text" inputMode="decimal" aria-label={label} value={editing ? text : String(valueMm)}
        onMouseDown={(event) => event.stopPropagation()} onClick={(event) => event.stopPropagation()} onDragStart={(event) => event.preventDefault()}
        onFocus={(event) => { setEditing(true); setText(String(valueMm)); justFocused.current = true; event.currentTarget.select() }}
        onMouseUp={(event) => { if (justFocused.current) { event.preventDefault(); justFocused.current = false } }}
        onChange={(event) => setText(event.target.value)}
        onBlur={commit}
        onKeyDown={(event) => {
          if (event.key === 'Enter') event.currentTarget.blur()
          if (event.key === 'Escape') { setText(String(valueMm)); setEditing(false); window.setTimeout(() => (event.target as HTMLInputElement).blur(), 0) }
        }} />
      {!editing && <span className="mm-unit176" aria-hidden="true">mm</span>}
    </span>
  )
}

export default function LevelMenu173(props: LevelMenuProps173) {
  const { floatId, className = '', levels, activeId, zeroId, radioName, open, rowState } = props
  const [dragged, setDragged] = useState('')
  const active = levels.find((level) => level.id === activeId) ?? levels[0]
  const eyeTitle = props.eyeTitle ?? ((id: string, visible: boolean) => id === activeId ? 'Aktive Ebene ist immer sichtbar'
    : visible ? 'Ebene eingeblendet - klicken zum Ausblenden' : 'Ebene ausgeblendet - klicken zum Einblenden')
  const presets174: { id: VisibilityPreset174; label: string; icon: string; title: string }[] = [
    { id: 'solo', label: 'Solo', icon: 'layers-current', title: 'Solo: nur die aktuelle Ebene einblenden' },
    { id: 'neighbors', label: 'Nachbar', icon: 'layers-neighbor', title: 'Nachbar: aktuelle Ebene und die unmittelbar darüber und darunter einblenden' },
    { id: 'all', label: 'Alle', icon: 'layers-all', title: 'Alle Ebenen einblenden' },
  ]
  return (
    <div ref={floatRef173(floatId)} className={`canvas-layer-menu level-menu173 ${className} ${open ? 'open' : ''}`.replace(/\s+/g, ' ').trim()} aria-label="Ebenen">
      <span className="float-grip173" title="Ebenenmenü verschieben (Doppelklick: zurück an den Standardplatz)" aria-hidden="true"><StromIcon name="drag-dots" size={16} /></span>
      <button type="button" title="Ebenen und Geschosshoehen bearbeiten" aria-expanded={open} onClick={props.onToggleOpen}>
        <StromIcon name="chevron-down" title="Ebenenmenue" /> {active ? `${active.name} · ${mm173(active.heightM)} mm` : 'Ebenen'}
      </button>
      {open && (
        <div className="layer-menu-panel">
          <div className="layer-zero-legend151" title="Die markierte Etage hat Z = 0 m; darüber positive, darunter negative Höhen.">
            <span>Nullhöhe</span><strong>Z = 0</strong>
          </div>
          <div className="layer-list">
            {levels.map((layer) => {
              const isActive = layer.id === activeId
              const state = rowState(layer.id)
              return (
                <div
                  key={layer.id}
                  data-level173={layer.id}
                  className={`layer-row ${isActive ? 'active' : ''} ${state.visible ? 'effectively-visible' : 'effectively-hidden'} ${state.ghost ? 'preview-visible' : ''}`}
                  draggable={false}
                  onClick={() => props.onSelect(layer.id)}
                  onDragOver={(event) => event.preventDefault()}
                  onDrop={(event) => { event.preventDefault(); props.onMove(dragged, layer.id); setDragged('') }}
                >
                  {/* STROM176_ZERO_ICON: Nullhoehe als Icon-Knopf, genau einer aktiv (wie ein Radiobutton). */}
                  <button type="button" role="radio" data-radio-group={radioName}
                    className={`layer-zero-marker151 layer-zero176 ${zeroId === layer.id ? 'active' : ''}`}
                    aria-checked={zeroId === layer.id} aria-label={`${layer.name} als Z=0-Ebene auswählen`}
                    title={levels.length === 1 ? 'Einzige Ebene: automatisch Nullhöhe (Z = 0)' : zeroId === layer.id ? 'Nullhöhe (Z = 0) liegt auf dieser Ebene' : 'Diese Ebene als Nullhöhe (Z = 0) festlegen'}
                    disabled={levels.length === 1 && zeroId === layer.id}
                    onMouseDown={(event) => event.stopPropagation()}
                    onClick={(event) => { event.stopPropagation(); if (zeroId !== layer.id) props.onZero(layer.id) }}>
                    <StromIcon name="zero-level" title="Nullhöhe" />
                  </button>
                  <button type="button" className={`layer-eye ${state.visible ? 'visible' : 'hidden'}`} title={eyeTitle(layer.id, state.visible)}
                    onClick={(event) => { event.stopPropagation(); props.onToggleVisible(layer.id) }}>
                    <StromIcon name={state.visible ? 'eye' : 'eye-off'} title={state.visible ? 'Ebene sichtbar' : 'Ebene ausgeblendet'} />
                  </button>
                  <input
                    aria-label="Ebenenname"
                    draggable={false}
                    value={layer.name}
                    onMouseDown={(event) => event.stopPropagation()}
                    onClick={(event) => event.stopPropagation()}
                    onDragStart={(event) => event.preventDefault()}
                    onFocus={() => { if (!isActive) props.onSelect(layer.id) }}
                    onChange={(event) => props.onRename(layer.id, event.target.value)}
                  />
                  <label className="layer-height-control">
                    <span>Höhe</span>
                    <MmField176 valueMm={mm173(layer.heightM)} label={`Geschosshoehe ${layer.name} in Millimetern`}
                      title="Geschosshöhe; Eingabe z. B. 2600, 2,6 m, 260 cm" onCommit={(mm) => props.onHeight(layer.id, mm)} />
                  </label>
                  <label className="layer-height-control layer-slab-control149">
                    <span>Bodendicke</span>
                    <MmField176 valueMm={mm173(layer.slabThicknessM)} label={`Bodendicke ${layer.name} in Millimetern`}
                      title="Bodendicke unter dem fertigen Fußboden; Eingabe z. B. 200, 20 cm, 0,2 m" onCommit={(mm) => props.onSlab(layer.id, mm)} />
                  </label>
                  <button
                    type="button"
                    className="layer-grip"
                    title="Ebene verschieben"
                    draggable
                    onClick={(event) => event.stopPropagation()}
                    onDragStart={(event) => { event.dataTransfer.effectAllowed = 'move'; setDragged(layer.id) }}
                    onDragEnd={() => setDragged('')}
                    onMouseDown={(event) => event.stopPropagation()}
                  ><StromIcon name="drag-dots" title="Ebene verschieben" /></button>
                </div>
              )
            })}
          </div>
          <div className="layer-menu-actions layer-menu-actions174" aria-label="Ebenenaktionen">
            {props.onPreset && (
              <div className="layer-visibility-presets174" role="group" aria-label="Ebenen einblenden">
                {presets174.map((item) => (
                  <button key={item.id} type="button" data-preset174={item.id} className={props.preset === item.id ? 'active' : ''}
                    aria-pressed={props.preset === item.id} title={item.title} onClick={() => props.onPreset?.(item.id)}>
                    <StromIcon name={item.icon} size={16} /> {item.label}
                  </button>
                ))}
              </div>
            )}
            <button type="button" className="layer-add round-icon" title="Neue Ebene" aria-label="Neue Ebene" onClick={props.onAdd}><StromIcon name="new-object" title="Neue Ebene" /></button>
            <button type="button" className="layer-delete round-icon" title="Ausgewaehlte Ebene loeschen" aria-label="Ausgewaehlte Ebene loeschen" disabled={levels.length <= 1} onClick={props.onDelete}><StromIcon name="trash" title="Ebene loeschen" /></button>
          </div>
          {props.note}
        </div>
      )}
    </div>
  )
}
