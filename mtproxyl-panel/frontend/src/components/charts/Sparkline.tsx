import { cn } from '@/lib/utils'

export type SparklineTone = 'accent' | 'ok' | 'warn' | 'error' | 'muted'

export const SPARKLINE_AREA_ALPHA = 0.08
const LINE_ALPHA = 0.5

interface SparklineProps {
  values: number[]
  width?: number
  height?: number
  className?: string
  tone?: SparklineTone
  /** Заливка под линией и растяжение на весь контейнер — фон плитки. */
  area?: boolean
}

/** Чистый SVG без библиотек: линия рядом со значением или фон плитки. */
export function Sparkline({ values, width = 96, height = 28, className, tone = 'accent', area = false }: SparklineProps) {
  if (values.length < 2) {
    return <svg width={width} height={height} className={className} aria-hidden="true" />
  }

  const min = Math.min(...values)
  const max = Math.max(...values)
  const range = max - min || 1
  const stepX = width / (values.length - 1)
  const pad = area ? 2 : 0
  const usable = height - pad * 2

  const points = values.map((v, i) => {
    const x = i * stepX
    const y = pad + (1 - (v - min) / range) * usable
    return `${x.toFixed(1)},${y.toFixed(1)}`
  })

  const line = `M${points.join('L')}`

  return (
    <svg
      width={area ? undefined : width}
      height={area ? undefined : height}
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio={area ? 'none' : undefined}
      className={cn(area && 'h-full w-full', className)}
      aria-hidden="true"
    >
      {area && (
        <path d={`${line}L${width},${height}L0,${height}Z`} fill={`rgb(var(--${tone}) / ${SPARKLINE_AREA_ALPHA})`} />
      )}
      <path
        d={line}
        fill="none"
        stroke={area ? `rgb(var(--${tone}) / ${LINE_ALPHA})` : `rgb(var(--${tone}))`}
        strokeWidth={1.5}
        strokeLinejoin="round"
        strokeLinecap="round"
        vectorEffect={area ? 'non-scaling-stroke' : undefined}
      />
    </svg>
  )
}
