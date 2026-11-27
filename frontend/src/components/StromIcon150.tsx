import StromIcon from './StromIcon'

/** STROM169_ICONS: frueherer zweiter Iconsatz. Leitet nur noch auf das einheitliche Set weiter. */
export default function StromIcon150({ name, title, size = 20, className }: { name: string; title?: string; size?: number; className?: string }) {
  return <StromIcon name={name} title={title} size={size} className={className} />
}
