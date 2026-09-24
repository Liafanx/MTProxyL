import { Link } from 'react-router-dom';
import { AlertTriangle, CheckCircle2, ChevronRight, Info } from 'lucide-react';
import { cn } from '@/lib/utils';

export type ProblemSeverity = 'error' | 'warn' | 'info';

export interface ProblemItem {
  key: string;
  severity: ProblemSeverity;
  label: string;
  detail?: string;
  to?: string;
}

const SEVERITY_TEXT: Record<ProblemSeverity, string> = {
  error: 'text-error',
  warn: 'text-warn',
  info: 'text-text-faint',
};

const ORDER: Record<ProblemSeverity, number> = { error: 0, warn: 1, info: 2 };

function ProblemRow({ item }: { item: ProblemItem }) {
  const Icon = item.severity === 'info' ? Info : AlertTriangle;
  const body = (
    <>
      <Icon size={16} className={cn('mt-0.5 shrink-0', SEVERITY_TEXT[item.severity])} />
      <span className="min-w-0 flex-1">
        <span className="block text-row font-semibold text-text">{item.label}</span>
        {item.detail && <span className="mt-0.5 block text-meta leading-relaxed text-text-muted">{item.detail}</span>}
      </span>
      {item.to && <ChevronRight size={16} className="mt-0.5 shrink-0 text-text-faint" />}
    </>
  );
  const className = 'flex min-h-[44px] items-start gap-2.5 rounded-lg bg-bg px-3 py-2.5';
  return item.to ? (
    <Link to={item.to} className={cn(className, 'transition-colors hover:bg-surface-2')}>
      {body}
    </Link>
  ) : (
    <div className={className}>{body}</div>
  );
}

/** Что требует внимания прямо сейчас. Пустой список — тоже состояние. */
export function ProblemsCard({ items }: { items: ProblemItem[] }) {
  const sorted = [...items].sort((a, b) => ORDER[a.severity] - ORDER[b.severity]);
  const errors = sorted.filter((i) => i.severity === 'error').length;
  const warns = sorted.filter((i) => i.severity === 'warn').length;
  return (
    <section className="rounded-xl border border-border bg-surface p-4">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h3 className="text-[13px] font-semibold text-text">Проблемы</h3>
        {sorted.length > 0 && (
          <span className="text-micro font-semibold text-text-muted">
            {errors > 0 && <span className="text-error">{errors} критич.</span>}
            {errors > 0 && warns > 0 && ' · '}
            {warns > 0 && <span className="text-warn">{warns} предупр.</span>}
          </span>
        )}
      </div>
      {sorted.length === 0 ? (
        <div className="flex items-center gap-2.5 rounded-lg bg-bg px-3 py-3 text-row text-text-muted">
          <CheckCircle2 size={16} className="shrink-0 text-ok" />
          Проблем не обнаружено
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-2 md:grid-cols-2 2xl:grid-cols-3">
          {sorted.map((item) => (
            <ProblemRow key={item.key} item={item} />
          ))}
        </div>
      )}
    </section>
  );
}
