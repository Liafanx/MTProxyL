import { StatusBadge } from '@/components/StatusBadge';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { fieldMeta } from '@/lib/telemetryLabels';
import { formatMs } from '@/lib/gated';
import type { MeRuntimeData } from '@/types/runtime';

interface MERuntimeSectionProps {
  data: MeRuntimeData | null;
}

export function MERuntimeSection({ data }: MERuntimeSectionProps) {
  if (!data || Object.keys(data).length === 0) return null;
  const quarantined = data.quarantined_endpoints ?? [];

  return (
    <CollapsibleSection
      title="Среда выполнения ME"
      defaultOpen={false}
      description="Внутренние счётчики работы с пулом ME. Нужны в основном при разборе проблем."
    >
      <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4">
        {Object.entries(data).map(([key, value]) => {
          if (value == null || typeof value === 'object') return null;
          const label = fieldMeta(key).label;
          if (typeof value === 'boolean') {
            return (
              <div key={key} className="flex min-w-0 items-center justify-between gap-2 rounded-lg bg-bg p-2 text-xs">
                <span className="truncate text-text-muted">{label}</span>
                <StatusBadge status={value} />
              </div>
            );
          }
          let display = String(value);
          if (typeof value === 'number') {
            display = key.includes('_secs') ? `${value} с` : key.includes('_ms') ? `${value} мс` : String(value);
          }
          return (
            <div key={key} className="min-w-0 rounded-lg bg-bg p-2 text-xs">
              <div className="truncate text-text-muted">{label}</div>
              <div className="font-semibold text-text">{display}</div>
            </div>
          );
        })}
      </div>
      {quarantined.length > 0 && (
        <div className="mt-3 rounded-lg bg-bg p-3">
          <h4 className="mb-2 text-micro font-semibold uppercase tracking-[0.06em] text-text-faint">
            Точки в карантине ({quarantined.length})
          </h4>
          <div className="flex flex-wrap gap-1">
            {quarantined.map((q) => (
              <span key={q.endpoint} className="rounded bg-warn/12 px-2 py-0.5 font-mono text-[11px] text-warn">
                {q.endpoint} · ещё {formatMs(q.remaining_ms, 0)}
              </span>
            ))}
          </div>
        </div>
      )}
    </CollapsibleSection>
  );
}
