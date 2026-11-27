import { memo } from 'react'
import { iconAlias169, iconSet169 } from './iconSet169'

type StromIconProps = {
  name: string
  title?: string
  size?: number
  className?: string
}

const escape169 = (text: string) => text.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c] as string))

/** STROM169_ICONS: einheitliche SVG-Icons ohne Nachladen (vorher Sprite-Datei + zweiter Iconsatz). */
function StromIcon({ name, title, size = 20, className = '' }: StromIconProps) {
  const key = iconSet169[name] ? name : iconAlias169[name]
  const entry = key ? iconSet169[key] : undefined
  const body = entry ? entry[1] : ''
  return (
    <svg
      className={`strom-icon strom-ui-icon ${className}`.trim()}
      data-icon={key || name}
      data-tone={entry ? entry[0] : 'nav'}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      role={title ? 'img' : undefined}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      focusable="false"
      dangerouslySetInnerHTML={{ __html: (title ? `<title>${escape169(title)}</title>` : '') + body }}
    />
  )
}

// STROM173: Ohne erneutes Zeichnen bei unveraenderten Angaben. Vorher ersetzte jedes Neuzeichnen
// der Elternkomponente die SVG-Pfade; ein Klick, waehrenddessen ging verloren.
export default memo(StromIcon)
