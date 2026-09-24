import { MetricCard } from '@/components/MetricCard';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { GatedNotice } from '@/components/GatedNotice';
import { KV, Panel } from '@/components/KeyValue';
import { StatePill } from '@/components/ui/state-pill';
import { formatNumber } from '@/lib/utils';
import { gatedData, formatAge } from '@/lib/gated';
import type { PoolStateData } from '@/types/runtime';

interface MEPoolStateSectionProps {
  data: PoolStateData | null;
}

export function MEPoolStateSection({ data }: MEPoolStateSectionProps) {
  if (!data) return null;
  const payload = gatedData(data);
  if (!payload) return <GatedNotice title="Состояние пула ME" reason={data.reason} />;
  const { generations, hardswap, writers, refill } = payload;

  return (
    <CollapsibleSection
      title="Состояние пула ME"
      description="ME — промежуточные серверы Telegram. Прокси держит их пул и обновляет поколениями: прогретое поколение подменяет активное без разрыва соединений."
      badge={hardswap.pending ? <StatePill state="warn">ожидает hardswap</StatePill> : undefined}
    >
      <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
        <Panel title="Поколения">
          <KV label="Активное" value={generations.active_generation} mono />
          <KV label="Прогретое" value={generations.warm_generation} mono />
          <KV label="Hardswap" value={hardswap.enabled ? (hardswap.pending ? `ожидает: поколение ${generations.pending_hardswap_generation}` : 'включён') : 'выключен'} />
          {hardswap.pending && generations.pending_hardswap_age_secs != null && (
            <KV label="Ожидает уже" value={formatAge(generations.pending_hardswap_age_secs)} />
          )}
          {generations.draining_generations.length > 0 && (
            <KV label="Выводятся" value={generations.draining_generations.join(', ')} mono />
          )}
        </Panel>
        <Panel title="Писатели">
          <KV label="Всего" value={writers.total} mono />
          <KV label="Живых вне вывода" value={writers.alive_non_draining} mono />
          <KV label="Деградировавших" value={writers.degraded} mono />
          <KV label="Выводимых" value={writers.draining} mono />
        </Panel>
        <Panel title="Контур и здоровье">
          <KV label="Активный контур" value={writers.contour.active} mono />
          <KV label="Прогретый контур" value={writers.contour.warm} mono />
          <KV label="Здоровые" value={writers.health.healthy} mono />
          <KV label="Деградировавшие" value={writers.health.degraded} mono />
        </Panel>
      </div>
      {refill.inflight_endpoints_total > 0 && (
        <div className="mt-3 rounded-lg bg-bg p-3">
          <h4 className="mb-2 text-micro font-semibold uppercase tracking-[0.06em] text-text-faint">Пополнение</h4>
          <div className="mb-3 grid grid-cols-2 gap-2">
            <MetricCard label="Точки в работе" value={formatNumber(refill.inflight_endpoints_total)} />
            <MetricCard label="DC в работе" value={formatNumber(refill.inflight_dc_total)} />
          </div>
          {refill.by_dc.length > 0 && (
            <div className="flex flex-wrap gap-1">
              {refill.by_dc.map((dc, i) => (
                <span key={i} className="rounded bg-surface px-2 py-0.5 text-[10px]">
                  <span className="text-text-muted">DC {dc.dc} ({dc.family}):</span>{' '}
                  <span className="text-text">{dc.inflight}</span>
                </span>
              ))}
            </div>
          )}
        </div>
      )}
    </CollapsibleSection>
  );
}
