type StromIconProps = {
  name: string
  title?: string
  size?: number
  className?: string
}

/** SVG-only design library; no icon fonts. */
export default function StromIcon({ name, title, size = 20, className = '' }: StromIconProps) {
  // Distinguish Stage from production even when an older Vite config still has base=/strom/.
  const basePath = typeof window === 'undefined'
    ? import.meta.env.BASE_URL
    : window.location.pathname.startsWith('/strom-test/') ? '/strom-test/'
      : window.location.pathname.startsWith('/strom/') ? '/strom/'
        : import.meta.env.BASE_URL
  return (
    <svg
      className={`strom-ui-icon ${className}`}
      width={size}
      height={size}
      viewBox="0 0 80 80"
      role={title ? 'img' : undefined}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      focusable="false"
    >
      {title && <title>{title}</title>}
      <use href={`${basePath}strom-icons-v7.svg#${name}`} />
    </svg>
  )
}
