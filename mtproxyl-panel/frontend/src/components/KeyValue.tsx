import type { ReactNode } from 'react';
import { cn } from '@/lib/utils';

interface KVProps {
  label: string;
  value: ReactNode;
  hint?: string;
  mono?: boolean;
  className?: string;
}

/** Строка «подпись — значение» внутри карточки. */
export function KV({ label, value, hint, mono = false, className }: KVProps) {
  return (
    <div className={cn('flex items-start justify-between gap-3 py-1', className)}>
      <div className="min-w-0">
        <span className="text-meta text-text-muted">{label}</span>
        {hint && <div className="text-micro text-text-faint">{hint}</div>}
      </div>
      <span className={cn('shrink-0 text-right text-meta font-semibold text-text', mono && 'font-mono tabular-nums')}>{value}</span>
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
