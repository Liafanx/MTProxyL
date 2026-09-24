import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'
import { Sparkline, type SparklineTone } from '@/components/charts/Sparkline'

interface MetricCardProps {
  label: string
  value: string | number
  icon?: ReactNode
  variant?: 'default' | 'success' | 'warning' | 'danger'
  status?: 'ok' | 'warn' | 'error'
  caption?: string
  series?: number[]
  className?: string
}

const TONE: Record<NonNullable<MetricCardProps['variant']>, SparklineTone> = {
  default: 'accent',
  success: 'ok',
  warning: 'warn',
  danger: 'error',
}

const TONE_TEXT: Record<SparklineTone, string> = {
  accent: 'text-accent',
  ok: 'text-ok',
  warn: 'text-warn',
  error: 'text-error',
  muted: 'text-text-muted',
}

const CHART_FADE = 'linear-gradient(to right, transparent 0%, rgba(0,0,0,0.55) 42%, #000 72%)'

/** KPI-плитка: подпись, крупное значение, при наличии серии — спарклайн фоном. */
export function MetricCard({ label, value, icon, variant = 'default', status, caption, series, className }: MetricCardProps) {
  const tone = status === 'warn' ? 'warn' : status === 'error' ? 'error' : TONE[variant]
  const hasSeries = (series?.length ?? 0) >= 2
  return (
    <div
      className={cn(
        'relative flex min-h-[96px] min-w-0 flex-col overflow-hidden rounded-xl border border-border bg-surface p-3 md:p-3.5',
        className,
      )}
    >
      {hasSeries && (
        <span
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 bottom-0 h-[64%]"
          style={{ maskImage: CHART_FADE, WebkitMaskImage: CHART_FADE }}
        >
          <Sparkline values={series!} tone={tone} area />
        </span>
      )}
      <span className="relative flex items-start gap-1.5">
        {status && (
          <span
            className={cn(
              'inline-block h-2 w-2 shrink-0 rounded-full',
              status === 'ok' && 'bg-ok',
              status === 'warn' && 'bg-warn',
              status === 'error' && 'bg-error',
            )}
            aria-hidden="true"
          />
        )}
        {icon && <span className={cn('shrink-0', TONE_TEXT[tone])}>{icon}</span>}
        <span className="line-clamp-2 min-h-[26px] min-w-0 flex-1 break-words text-[10.5px] font-semibold uppercase leading-[1.25] tracking-[0.02em] text-text-muted">
          {label}
        </span>
      </span>
      <span className="relative mt-auto block truncate pt-2 font-mono text-[22px] font-bold leading-none tabular-nums text-text md:text-[24px]">
        {value}
      </span>
      {caption && <span className="relative mt-1.5 truncate text-micro text-text-muted">{caption}</span>}
    </div>
  )
}
