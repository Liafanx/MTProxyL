import { MetricCard } from '@/components/MetricCard';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { GatedNotice } from '@/components/GatedNotice';
import { KV, Panel } from '@/components/KeyValue';
import { StatePill } from '@/components/ui/state-pill';
import { formatNumber } from '@/lib/utils';
import { formatAge, formatMs } from '@/lib/gated';
import type { UpstreamQualityData } from '@/types/runtime';

interface UpstreamQualitySectionProps {
  data: UpstreamQualityData | null;
}

export function UpstreamQualitySection({ data }: UpstreamQualitySectionProps) {
  if (!data) return null;
  if (!data.enabled) return <GatedNotice title="Качество апстримов" reason={data.reason} />;
  const s = data.summary;
  const c = data.counters;
  const successPct = c && c.connect_attempt_total > 0 ? (c.connect_success_total / c.connect_attempt_total) * 100 : null;

  return (
    <CollapsibleSection
      title="Качество апстримов"
      description="Задержки и доля ошибок по каждому исходящему маршруту. Апстрим с ошибками выше порога выводится из ротации."
      badge={s && s.unhealthy_total > 0 ? <StatePill state="warn">нездоровых {s.unhealthy_total}</StatePill> : undefined}
    >
      <div className="space-y-3">
        {s && (
          <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
            <MetricCard label="Настроено" value={formatNumber(s.configured_total)} />
            <MetricCard label="Здоровых" value={formatNumber(s.healthy_total)} variant="success" />
            <MetricCard label="Нездоровых" value={formatNumber(s.unhealthy_total)} variant={s.unhealthy_total > 0 ? 'warning' : 'default'} />
            <MetricCard
              label="Прямых"
              value={formatNumber(s.direct_total)}
              caption={[s.socks5_total && `socks5 ${s.socks5_total}`, s.socks4_total && `socks4 ${s.socks4_total}`, s.shadowsocks_total && `shadowsocks ${s.shadowsocks_total}`].filter(Boolean).join(' · ') || 'прокси‑маршрутов нет'}
            />
          </div>
        )}
        {(c || data.policy) && (
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            {c && (
              <Panel title="Подключения за всё время">
                <KV label="Попыток" value={formatNumber(c.connect_attempt_total)} mono />
                <KV label="Успешных" value={successPct === null ? formatNumber(c.connect_success_total) : `${formatNumber(c.connect_success_total)} (${successPct.toFixed(1)}%)`} mono />
                <KV label="Неудачных" value={formatNumber(c.connect_fail_total)} mono />
                <KV label="Жёстких ошибок (failfast)" value={formatNumber(c.connect_failfast_hard_error_total)} mono />
              </Panel>
            )}
            {data.policy && (
              <Panel title="Политика подключения">
                <KV label="Повторов" value={data.policy.connect_retry_attempts} mono />
                <KV label="Пауза между повторами" value={formatMs(data.policy.connect_retry_backoff_ms, 0)} mono />
                <KV label="Бюджет на подключение" value={formatMs(data.policy.connect_budget_ms, 0)} mono />
                <KV label="Порог нездоровья" value={`${data.policy.unhealthy_fail_threshold} сбоев`} mono />
                <KV label="Failfast на жёстких ошибках" value={data.policy.connect_failfast_hard_errors ? 'да' : 'нет'} />
              </Panel>
            )}
          </div>
        )}
        <div className="grid grid-cols-1 gap-2">
          {data.upstreams?.map((u) => (
            <div key={u.upstream_id} className="rounded-lg bg-bg p-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex min-w-0 items-center gap-2">
                  <code className="truncate font-mono text-sm text-text">{u.address || `upstream-${u.upstream_id}`}</code>
                  <span className="rounded bg-surface-2 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-text-muted">{u.route_kind}</span>
                </div>
                <StatePill state={u.healthy ? 'ok' : 'error'}>{u.healthy ? 'исправен' : `сбоев ${u.fails}`}</StatePill>
              </div>
              <div className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs md:grid-cols-4">
                <div><span className="text-text-muted">Задержка: </span><span className="font-semibold tabular-nums text-text">{formatMs(u.effective_latency_ms)}</span></div>
                <div><span className="text-text-muted">Вес: </span><span className="font-semibold text-text">{u.weight}</span></div>
                <div><span className="text-text-muted">Область: </span><span className="font-semibold text-text">{u.scopes || 'все'}</span></div>
                <div><span className="text-text-muted">Проверка: </span><span className="font-semibold text-text">{formatAge(u.last_check_age_secs)} назад</span></div>
              </div>
              {u.dc.length > 0 && (
                <div className="mt-2 flex flex-wrap gap-1">
                  {u.dc.map((dc, i) => (
                    <span key={i} className="rounded bg-surface px-2 py-0.5 text-[10px]">
                      <span className="text-text-muted">DC {dc.dc}:</span>{' '}
                      <span className="text-text">{formatMs(dc.latency_ema_ms)}</span>
                      <span className="ml-1 text-text-faint">({dc.ip_preference})</span>
                    </span>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
      </div>
    </CollapsibleSection>
  );
}
