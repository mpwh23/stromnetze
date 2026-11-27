import { useState, type ReactNode } from 'react'
import StromIcon from './StromIcon'
import { floatRef173 } from './floatDrag173'

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
}

const mm173 = (m: number) => Math.round(m * 1000)

export default function LevelMenu173(props: LevelMenuProps173) {
  const { floatId, className = '', levels, activeId, zeroId, radioName, open, rowState } = props
  const [dragged, setDragged] = useState('')
  const active = levels.find((level) => level.id === activeId) ?? levels[0]
  const eyeTitle = props.eyeTitle ?? ((_id: string, visible: boolean) => visible
    ? 'Ebene aktuell sichtbar - klicken zum manuellen Ausblenden'
    : 'Ebene aktuell ausgeblendet - klicken zum manuellen Einblenden')
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
                  <label className="layer-zero-marker151" title={levels.length === 1 ? 'Einzige Ebene: automatisch Z=0' : 'Diese Ebene als Z=0 festlegen'}
                    onMouseDown={(event) => event.stopPropagation()} onClick={(event) => event.stopPropagation()}>
                    <input type="radio" name={radioName}
                      aria-label={`${layer.name} als Z=0-Ebene auswählen`}
                      checked={zeroId === layer.id}
                      disabled={levels.length === 1}
                      onChange={() => props.onZero(layer.id)} />
                    <span aria-hidden="true">0</span>
                  </label>
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
                  <label className="layer-height-control" title="Geschosshoehe dieser Ebene in Millimetern">
                    <span>Höhe (mm)</span>
                    <input
                      key={`${layer.id}-${mm173(layer.heightM)}`}
                      aria-label={`Geschosshoehe ${layer.name} in Millimetern`}
                      type="number" min="100" max="10000" step="10"
                      defaultValue={mm173(layer.heightM)}
                      onMouseDown={(event) => event.stopPropagation()}
                      onClick={(event) => event.stopPropagation()}
                      onDragStart={(event) => event.preventDefault()}
                      onBlur={(event) => props.onHeight(layer.id, Number(event.currentTarget.value))}
                      onKeyDown={(event) => { if (event.key === 'Enter') event.currentTarget.blur() }}
                    />
                  </label>
                  <label className="layer-height-control layer-slab-control149" title="Bodendicke der Etage unterhalb des fertigen Fußbodens, in Millimetern">
                    <span>Bodendicke (mm)</span>
                    <input
                      key={`${layer.id}-slab-${mm173(layer.slabThicknessM)}`}
                      aria-label={`Bodendicke ${layer.name} in Millimetern`}
                      type="number" min="0" max="1500" step="10"
                      defaultValue={mm173(layer.slabThicknessM)}
                      onMouseDown={(event) => event.stopPropagation()}
                      onClick={(event) => event.stopPropagation()}
                      onDragStart={(event) => event.preventDefault()}
                      onBlur={(event) => props.onSlab(layer.id, Number(event.currentTarget.value))}
                      onKeyDown={(event) => { if (event.key === 'Enter') event.currentTarget.blur() }}
                    />
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
          <div className="layer-menu-actions" aria-label="Ebenenaktionen">
            <button type="button" className="layer-add round-icon" title="Neue Ebene" aria-label="Neue Ebene" onClick={props.onAdd}><StromIcon name="new-object" title="Neue Ebene" /></button>
            <button type="button" className="layer-delete round-icon" title="Ausgewaehlte Ebene loeschen" aria-label="Ausgewaehlte Ebene loeschen" disabled={levels.length <= 1} onClick={props.onDelete}><StromIcon name="trash" title="Ebene loeschen" /></button>
          </div>
          {props.note}
        </div>
      )}
    </div>
  )
}
