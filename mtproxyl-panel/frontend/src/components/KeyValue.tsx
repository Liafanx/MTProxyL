import type { ReactNode } from 'react';
import { cn } from '@/lib/utils';

interface KVProps {
  label: string;
  value: ReactNode;
  hint?: string;
  mono?: boolean;
  stacked?: boolean;
  className?: string;
}

/** Строка «подпись — значение» внутри карточки. */
export function KV({ label, value, hint, mono = false, stacked = false, className }: KVProps) {
  return (
    <div className={cn('grid items-start gap-x-3 gap-y-1 py-1', stacked ? 'grid-cols-1' : 'grid-cols-[minmax(0,1fr)_minmax(0,2fr)]', className)}>
      <div className="min-w-0">
        <span className="text-meta text-text-muted">{label}</span>
        {hint && <div className="text-micro text-text-faint">{hint}</div>}
      </div>
      <span className={cn('min-w-0 text-meta text-text [overflow-wrap:anywhere]', stacked ? 'text-left' : 'text-right font-semibold', mono && 'font-mono tabular-nums')}>{value}</span>
    </div>
  );
}

export function Panel({ title, children, className, action }: { title: string; children: ReactNode; className?: string; action?: ReactNode }) {
  return (
    <div className={cn('rounded-lg bg-bg p-3', className)}>
      <div className="mb-2 flex items-center justify-between gap-2">
        <h4 className="text-micro font-semibold uppercase tracking-[0.06em] text-text-faint">{title}</h4>
        {action}
      </div>
      {children}
    </div>
  );
}
