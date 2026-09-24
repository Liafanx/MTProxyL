import { CollapsibleSection } from '@/components/CollapsibleSection';
import { KV, Panel } from '@/components/KeyValue';
import { StatePill, type PillState } from '@/components/ui/state-pill';
import { cn } from '@/lib/utils';
import { formatEpoch, formatMs } from '@/lib/gated';
import type { InitializationData } from '@/types/runtime';

interface InitializationSectionProps {
  data: InitializationData | null;
}

const STATUS: Record<string, { pill: PillState; label: string }> = {
  ready: { pill: 'ok', label: 'готов' },
  done: { pill: 'ok', label: 'готов' },
  ok: { pill: 'ok', label: 'готово' },
  starting: { pill: 'warn', label: 'запускается' },
  running: { pill: 'warn', label: 'выполняется' },
  pending: { pill: 'muted', label: 'ожидает' },
  degraded: { pill: 'warn', label: 'с ограничениями' },
  failed: { pill: 'error', label: 'ошибка' },
  skipped: { pill: 'muted', label: 'пропущено' },
};

function statusOf(raw: string) {
  return STATUS[raw.toLowerCase()] ?? { pill: 'muted' as PillState, label: raw };
}

export function InitializationSection({ data }: InitializationSectionProps) {
  if (!data) return null;
  const st = statusOf(data.status);
  const finished = data.status.toLowerCase() === 'ready' && !data.degraded;

  return (
    <CollapsibleSection
      title="Инициализация"
      defaultOpen={!finished}
      description="Как движок стартовал: этапы, попытки инициализации ME и время каждого компонента."
      badge={<StatePill state={data.degraded ? 'warn' : st.pill}>{data.degraded ? 'с ограничениями' : st.label}</StatePill>}
    >
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <Panel title="Запуск">
          <KV label="Этап" value={data.current_stage} mono />
          <KV label="Прогресс" value={`${Math.round(data.progress_pct)}%`} mono />
          <KV label="Транспорт" value={data.transport_mode} mono />
          <KV label="Начат" value={formatEpoch(data.started_at_epoch_secs)} />
          {data.ready_at_epoch_secs ? <KV label="Готов" value={formatEpoch(data.ready_at_epoch_secs)} /> : null}
          <KV label="Длительность" value={formatMs(data.total_elapsed_ms, 0)} mono />
        </Panel>
        <Panel title="Инициализация ME">
          <KV label="Состояние" value={<StatePill state={statusOf(data.me.status).pill}>{statusOf(data.me.status).label}</StatePill>} />
          <KV label="Этап" value={data.me.current_stage} mono />
          <KV label="Прогресс" value={`${Math.round(data.me.progress_pct)}%`} mono />
          <KV label="Попытка" value={`${data.me.init_attempt} из ${data.me.retry_limit}`} mono />
          {data.me.last_error && <KV label="Последняя ошибка" value={<span className="text-error">{data.me.last_error}</span>} />}
        </Panel>
      </div>
      {data.components.length > 0 && (
        <div className="mt-3 rounded-lg bg-bg p-3">
          <h4 className="mb-2 text-micro font-semibold uppercase tracking-[0.06em] text-text-faint">Компоненты</h4>
          <ol className="space-y-1">
            {data.components.map((c) => {
              const cs = statusOf(c.status);
              return (
                <li key={c.id} className="flex items-start gap-3 rounded px-2 py-1.5 hover:bg-surface-2">
                  <span className={cn('mt-1.5 h-2 w-2 shrink-0 rounded-full', cs.pill === 'ok' ? 'bg-ok' : cs.pill === 'warn' ? 'bg-warn' : cs.pill === 'error' ? 'bg-error' : 'bg-muted')} aria-hidden="true" />
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-baseline justify-between gap-x-3">
                      <span className="text-meta font-semibold text-text">{c.title || c.id}</span>
                      <span className="font-mono text-micro tabular-nums text-text-faint">
                        {c.duration_ms != null ? formatMs(c.duration_ms, 0) : '—'}
                        {c.attempts > 1 && ` · попыток ${c.attempts}`}
                      </span>
                    </div>
                    {c.details && <div className="text-micro text-text-muted">{c.details}</div>}
                  </div>
                  <StatePill state={cs.pill}>{cs.label}</StatePill>
                </li>
              );
            })}
          </ol>
        </div>
      )}
    </CollapsibleSection>
  );
}
