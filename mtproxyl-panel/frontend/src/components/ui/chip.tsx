import type { ButtonHTMLAttributes, ReactNode } from 'react'
import { cn } from '@/lib/utils'

export interface ChipProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'type'> {
  active?: boolean
  icon?: ReactNode
  count?: number | string
  children: ReactNode
}

/** Плоская «таблетка» для фильтров и переключателей периода. */
export function Chip({ active, icon, count, className, children, ...rest }: ChipProps) {
  return (
    <button
      type="button"
      aria-pressed={active}
      className={cn(
        'inline-flex h-[34px] shrink-0 items-center gap-1.5 rounded-full px-3.5 text-xs font-semibold',
        'transition-colors disabled:cursor-not-allowed disabled:opacity-50',
        active ? 'bg-text text-bg' : 'bg-surface-2 text-text-muted hover:bg-surface-3 hover:text-text',
        className,
      )}
      {...rest}
    >
      {icon}
      {children}
      {count !== undefined && (
        <span className={cn('tabular-nums', active ? 'opacity-70' : 'opacity-80')}>· {count}</span>
      )}
    </button>
  )
}

export type CountBadgeTone = 'accent' | 'error' | 'warn' | 'muted'

const TONE_CLASSES: Record<CountBadgeTone, string> = {
  accent: 'bg-accent-strong text-accent-text',
  error: 'bg-error-strong text-error-text',
  warn: 'bg-warn/15 text-warn',
  muted: 'bg-surface-2 text-text-muted',
}

export function CountBadge({ tone = 'accent', children, className }: { tone?: CountBadgeTone; children: ReactNode; className?: string }) {
  return (
    <span
      className={cn(
        'inline-flex h-[19px] min-w-[20px] items-center justify-center rounded-full px-1.5',
        'font-mono text-[10.5px] font-semibold tabular-nums leading-none',
        TONE_CLASSES[tone],
        className,
      )}
    >
      {children}
    </span>
  )
}
