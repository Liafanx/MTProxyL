import { MetricCard } from '@/components/MetricCard';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { GatedNotice } from '@/components/GatedNotice';
import { KV, Panel } from '@/components/KeyValue';
import { StatePill, type PillState } from '@/components/ui/state-pill';
import { formatNumber, cn } from '@/lib/utils';
import { gatedData, formatEpoch, formatMs } from '@/lib/gated';
import { fieldMeta } from '@/lib/telemetryLabels';
import type { MeQualityData } from '@/types/runtime';

interface MEQualitySectionProps {
  data: MeQualityData | null;
}

const FAMILY_STATE: Record<string, { pill: PillState; label: string }> = {
  ok: { pill: 'ok', label: 'в норме' },
  healthy: { pill: 'ok', label: 'в норме' },
  degraded: { pill: 'warn', label: 'деградация' },
  suppressed: { pill: 'warn', label: 'подавлено' },
  failed: { pill: 'error', label: 'сбой' },
  down: { pill: 'error', label: 'недоступно' },
  recovering: { pill: 'warn', label: 'восстанавливается' },
};

export function MEQualitySection({ data }: MEQualitySectionProps) {
  if (!data) return null;
  const payload = gatedData(data);
  if (!payload) return <GatedNotice title="Качество ME" reason={data.reason} />;
  const gate = payload.drain_gate;
  const gateOk = gate ? gate.route_quorum_ok && gate.redundancy_ok : true;

  return (
    <CollapsibleSection
      title="Качество ME"
      description="Задержки и ошибки промежуточных серверов. По этим числам движок решает, через какой из них пускать трафик."
      badge={gate && !gateOk ? <StatePill state="warn">вывод заблокирован</StatePill> : undefined}
    >
      <div className="space-y-4">
        {payload.dc_rtt.length > 0 && (
          <div>
            <h4 className="mb-2 text-micro font-semibold uppercase tracking-[0.06em] text-text-faint">Состояние дата-центров</h4>
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="border-b border-border text-left text-text-muted">
                    <th className="py-2 px-2 font-medium">DC</th>
                    <th className="py-2 px-2 text-right font-medium">RTT</th>
                    <th className="py-2 px-2 text-right font-medium">Писатели</th>
                    <th className="py-2 px-2 text-right font-medium">Покрытие</th>
                  </tr>
                </thead>
                <tbody>
                  {payload.dc_rtt.map((dc) => (
                    <tr key={dc.dc} className="border-b border-border/50 last:border-0">
                      <td className="py-2 px-2 font-medium text-text">DC {dc.dc}</td>
                      <td className="py-2 px-2 text-right tabular-nums text-text">{formatMs(dc.rtt_ema_ms)}</td>
                      <td className="py-2 px-2 text-right tabular-nums text-text">{dc.alive_writers} / {dc.required_writers}</td>
                      <td className="py-2 px-2 text-right">
                        <span className={cn('font-semibold tabular-nums', dc.coverage_pct >= 90 ? 'text-ok' : dc.coverage_pct >= 50 ? 'text-warn' : 'text-error')}>
                          {dc.coverage_pct.toFixed(0)}%
                        </span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {(payload.family_states?.length || gate) && (
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            {payload.family_states && payload.family_states.length > 0 && (
              <Panel title="Семейства адресов">
                {payload.family_states.map((f) => {
                  const st = FAMILY_STATE[f.state] ?? { pill: 'muted' as PillState, label: f.state };
                  return (
                    <div key={f.family} className="flex items-center justify-between gap-2 py-1">
                      <div className="min-w-0">
                        <div className="text-meta font-semibold text-text">{f.family}</div>
                        <div className="text-micro text-text-faint">
                          с {formatEpoch(f.state_since_epoch_secs)}
                          {f.fail_streak > 0 && ` · сбоев подряд ${f.fail_streak}`}
                          {f.recover_success_streak > 0 && ` · успехов подряд ${f.recover_success_streak}`}
                          {f.suppressed_until_epoch_secs ? ` · подавлено до ${formatEpoch(f.suppressed_until_epoch_secs)}` : ''}
                        </div>
                      </div>
                      <StatePill state={st.pill}>{st.label}</StatePill>
                    </div>
                  );
                })}
              </Panel>
            )}
            {gate && (
              <Panel title="Гейт вывода поколений">
                <KV label="Кворум маршрутов" value={<StatePill state={gate.route_quorum_ok ? 'ok' : 'error'}>{gate.route_quorum_ok ? 'есть' : 'нет'}</StatePill>} />
                <KV label="Резервирование" value={<StatePill state={gate.redundancy_ok ? 'ok' : 'error'}>{gate.redundancy_ok ? 'есть' : 'нет'}</StatePill>} />
                {gate.block_reason && <KV label="Причина блокировки" value={gate.block_reason} mono />}
                <KV label="Обновлено" value={formatEpoch(gate.updated_at_epoch_secs)} />
              </Panel>
            )}
          </div>
        )}

        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          <Panel title="Счётчики">
            <div className="grid grid-cols-2 gap-2">
              {Object.entries(payload.counters).map(([key, value]) => (
                <MetricCard key={key} label={fieldMeta(key.replace(/_total$/, '')).label} value={formatNumber(value)} />
              ))}
            </div>
          </Panel>
          <Panel title="Отброшено маршрутом">
            <div className="grid grid-cols-2 gap-2">
              {Object.entries(payload.route_drops).map(([key, value]) => (
                <MetricCard key={key} label={fieldMeta(key.replace(/_total$/, '')).label} value={formatNumber(value)} variant={value > 0 ? 'warning' : 'default'} />
              ))}
            </div>
          </Panel>
        </div>
      </div>
    </CollapsibleSection>
  );
}
