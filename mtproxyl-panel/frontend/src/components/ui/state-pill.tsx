import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

export type PillState = 'ok' | 'warn' | 'error' | 'muted'

const stateClasses: Record<PillState, string> = {
  ok: 'bg-ok/15 text-ok',
  warn: 'bg-warn/15 text-warn',
  error: 'bg-error/15 text-error',
  muted: 'bg-muted/15 text-muted',
}

const dotClasses: Record<PillState, string> = {
  ok: 'bg-ok',
  warn: 'bg-warn',
  error: 'bg-error',
  muted: 'bg-muted',
}

interface StatePillProps {
  state: PillState
  children: ReactNode
  title?: string
  className?: string
}

/** Единый бейдж состояния: ok / warn / error / muted. */
export function StatePill({ state, children, title, className }: StatePillProps) {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-micro font-semibold whitespace-nowrap',
        stateClasses[state],
        className,
      )}
      title={title}
    >
      <span className={cn('h-1.5 w-1.5 shrink-0 rounded-full', dotClasses[state])} aria-hidden="true" />
      {children}
    </span>
  )
}
