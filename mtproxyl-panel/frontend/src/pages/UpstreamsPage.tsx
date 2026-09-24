import { useMemo } from 'react';
import { Header } from '@/components/layout/Header';
import { ErrorAlert } from '@/components/ErrorAlert';
import { MetricCard } from '@/components/MetricCard';
import { GatedNotice } from '@/components/GatedNotice';
import { KV, Panel } from '@/components/KeyValue';
import { StatePill } from '@/components/ui/state-pill';
import { Skeleton } from '@/components/ui/skeleton';
import { useWsSubscription, useEndpoint } from '@/hooks/useWebSocket';
import { formatNumber, cn } from '@/lib/utils';
import { formatAge, formatMs } from '@/lib/gated';
import type { Upstream, MinimalAllResponse, NetworkPathEntry } from '@/types/runtime';

interface UpstreamsData {
  enabled: boolean;
  reason?: string;
  zero?: Record<string, unknown>;
  summary?: {
    configured_total: number;
    healthy_total: number;
    unhealthy_total: number;
    direct_total: number;
    socks4_total: number;
    socks5_total: number;
    shadowsocks_total: number;
  };
  upstreams?: Upstream[];
}

interface DcStatus {
  dc: number;
  endpoints?: string[];
  endpoint_writers?: Array<{ endpoint: string; active_writers: number }>;
  available_endpoints: number;
  available_pct: number;
  required_writers: number;
  floor_min: number;
  floor_target: number;
  floor_max: number;
  floor_capped: boolean;
  alive_writers: number;
  coverage_pct: number;
  fresh_alive_writers: number;
  fresh_coverage_pct: number;
  rtt_ms: number | null;
  load: number;
}

interface DcStatusData {
  middle_proxy_enabled: boolean;
  reason?: string;
  dcs: DcStatus[];
}

interface MeWriter {
  writer_id: number;
  dc: number | null;
  endpoint: string;
  generation: number;
  state: string;
  draining: boolean;
  degraded: boolean;
  bound_clients: number;
  idle_for_secs: number | null;
  rtt_ema_ms: number | null;
  matches_active_generation: boolean;
  in_desired_map: boolean;
  drain_over_ttl: boolean;
}

interface MeWritersData {
  middle_proxy_enabled: boolean;
  reason?: string;
  summary?: {
    configured_dc_groups: number;
    configured_endpoints: number;
    available_endpoints: number;
    available_pct: number;
    required_writers: number;
    alive_writers: number;
    coverage_pct: number;
    fresh_alive_writers: number;
    fresh_coverage_pct: number;
  };
  writers?: MeWriter[];
}

const ENDPOINTS = ['/v1/stats/upstreams', '/v1/stats/dcs', '/v1/stats/me-writers', '/v1/stats/minimal/all'];

function coverageTone(pct: number): 'ok' | 'warn' | 'error' {
  return pct >= 90 ? 'ok' : pct >= 50 ? 'warn' : 'error';
}

function DcCard({ dc, path }: { dc: DcStatus; path?: NetworkPathEntry }) {
  const cov = Math.round(dc.coverage_pct);
  const tone = dc.required_writers > 0 && dc.alive_writers === 0 ? 'error' : coverageTone(cov);
  return (
    <div className="rounded-xl border border-border bg-surface p-4">
      <div className="flex items-start gap-3">
        <div className="flex h-16 w-2 shrink-0 flex-col justify-end overflow-hidden rounded-full bg-bar-track" aria-hidden="true">
          <div
            className={cn('w-full rounded-full', tone === 'error' ? 'bg-bar-fill-full' : tone === 'warn' ? 'bg-bar-fill-warn' : 'bg-bar-fill')}
            style={{ height: `${Math.max(cov > 0 ? 6 : 0, Math.min(100, cov))}%` }}
          />
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline justify-between gap-2">
            <span className="text-[15px] font-bold text-text">DC {dc.dc}</span>
            <span className={cn('font-mono text-[18px] font-bold tabular-nums', tone === 'error' ? 'text-error' : tone === 'warn' ? 'text-warn' : 'text-text')}>{cov}%</span>
          </div>
          <div className="mt-1 grid grid-cols-2 gap-x-3 text-micro text-text-muted">
            <span>писатели {dc.alive_writers} / {dc.required_writers}</span>
            <span>свежих {dc.fresh_alive_writers} ({Math.round(dc.fresh_coverage_pct)}%)</span>
            <span>RTT {formatMs(dc.rtt_ms, 0)}</span>
            <span>нагрузка {formatNumber(dc.load)}</span>
            <span>точек {dc.available_endpoints} ({Math.round(dc.available_pct)}%)</span>
            <span>
              floor {dc.floor_min}/{dc.floor_target}/{dc.floor_max}
              {dc.floor_capped && <span className="text-warn"> ↑cap</span>}
            </span>
          </div>
        </div>
      </div>
      {path && (path.selected_addr_v4 || path.selected_addr_v6) && (
        <div className="mt-2 border-t border-border pt-2 font-mono text-micro text-text-faint">
          {path.ip_preference && <span className="mr-2 uppercase">{path.ip_preference}</span>}
          {path.selected_addr_v4 && <span className="mr-2">{path.selected_addr_v4}</span>}
          {path.selected_addr_v6 && <span>{path.selected_addr_v6}</span>}
        </div>
      )}
      {dc.endpoint_writers && dc.endpoint_writers.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1">
          {dc.endpoint_writers.map((e) => (
            <span key={e.endpoint} className={cn('rounded px-1.5 py-0.5 font-mono text-[10px]', e.active_writers > 0 ? 'bg-ok/12 text-ok' : 'bg-surface-2 text-text-faint')}>
              {e.endpoint} · {e.active_writers}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

function WriterState({ w }: { w: MeWriter }) {
  if (w.draining) return <StatePill state={w.drain_over_ttl ? 'error' : 'warn'}>{w.drain_over_ttl ? 'вывод просрочен' : 'выводится'}</StatePill>;
  if (w.degraded) return <StatePill state="warn">деградация</StatePill>;
  if (!w.in_desired_map) return <StatePill state="muted">лишний</StatePill>;
  return <StatePill state="ok">{w.state || 'работает'}</StatePill>;
}

export function UpstreamsPage() {
  const { data: wsData, errors, connected, refresh } = useWsSubscription('upstreams', ENDPOINTS, 5);

  const upstreams = useEndpoint<UpstreamsData>(wsData, '/v1/stats/upstreams');
  const dcs = useEndpoint<DcStatusData>(wsData, '/v1/stats/dcs');
  const meWriters = useEndpoint<MeWritersData>(wsData, '/v1/stats/me-writers');
  const minimalAll = useEndpoint<MinimalAllResponse>(wsData, '/v1/stats/minimal/all');

  const firstError = Object.values(errors)[0];
  const loading = Object.keys(wsData).length === 0 && !firstError;
  const pathByDc = useMemo(() => {
    const map = new Map<number, NetworkPathEntry>();
    for (const p of minimalAll?.data?.network_path ?? []) map.set(p.dc, p);
    return map;
  }, [minimalAll]);
  const writers = useMemo(
    () => (meWriters?.writers ?? []).slice().sort((a, b) => (a.dc ?? 99) - (b.dc ?? 99) || a.writer_id - b.writer_id),
    [meWriters],
  );

  return (
    <div>
      <Header
        title="Апстримы и DC"
        description="Куда движок ходит за Telegram: исходящие маршруты, дата-центры и писатели ME."
        refreshing={!connected}
        onRefresh={refresh}
      />

      <div className="p-4 lg:p-6 space-y-6">
        {firstError && <ErrorAlert message={firstError} onRetry={refresh} />}
        {loading && (
          <div className="space-y-4">
            <div className="grid grid-cols-2 gap-3 md:grid-cols-4"><Skeleton className="h-24" /><Skeleton className="h-24" /><Skeleton className="h-24" /><Skeleton className="h-24" /></div>
            <Skeleton className="h-40" />
          </div>
        )}

        {upstreams && (
          <section className="space-y-3">
            <div>
              <h3 className="text-[15px] font-bold text-text">Серверы-апстримы</h3>
              <p className="mt-0.5 text-meta text-text-muted">
                Исходящие маршруты движка. Для каждого видны задержка и число сбоев — по ним выбирается путь.
              </p>
            </div>
            {!upstreams.enabled ? (
              <GatedNotice title="Апстримы" reason={upstreams.reason} />
            ) : (
              <>
                {upstreams.summary && (
                  <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
                    <MetricCard label="Настроено" value={formatNumber(upstreams.summary.configured_total)} />
                    <MetricCard label="Здоровых" value={formatNumber(upstreams.summary.healthy_total)} variant="success" />
                    <MetricCard label="Нездоровых" value={formatNumber(upstreams.summary.unhealthy_total)} variant={upstreams.summary.unhealthy_total > 0 ? 'warning' : 'default'} status={upstreams.summary.unhealthy_total > 0 ? 'warn' : 'ok'} />
                    <MetricCard
                      label="Прямых"
                      value={formatNumber(upstreams.summary.direct_total)}
                      caption={[
                        upstreams.summary.socks5_total && `socks5 ${upstreams.summary.socks5_total}`,
                        upstreams.summary.socks4_total && `socks4 ${upstreams.summary.socks4_total}`,
                        upstreams.summary.shadowsocks_total && `shadowsocks ${upstreams.summary.shadowsocks_total}`,
                      ].filter(Boolean).join(' · ') || 'прокси‑маршрутов нет'}
                    />
                  </div>
                )}
                {upstreams.upstreams && upstreams.upstreams.length > 0 ? (
                  <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
                    {upstreams.upstreams.map((u) => (
                      <div key={u.upstream_id} className="rounded-xl border border-border bg-surface p-4">
                        <div className="flex items-center justify-between gap-2">
                          <div className="flex min-w-0 items-center gap-2">
                            <code className="truncate font-mono text-sm text-text">{u.address || `upstream-${u.upstream_id}`}</code>
                            <span className="rounded bg-surface-2 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-text-muted">{u.route_kind}</span>
                          </div>
                          <StatePill state={u.healthy ? 'ok' : 'error'}>{u.healthy ? 'исправен' : 'нездоров'}</StatePill>
                        </div>
                        <div className="mt-2">
                          <KV label="Задержка" value={formatMs(u.effective_latency_ms)} mono />
                          <KV label="Сбоев подряд" value={u.fails} mono />
                          <KV label="Вес" value={u.weight} mono />
                          <KV label="Область" value={u.scopes || 'все'} mono />
                          <KV label="Проверка" value={`${formatAge(u.last_check_age_secs)} назад`} />
                        </div>
                        {u.dc?.length > 0 && (
                          <div className="mt-2 flex flex-wrap gap-1">
                            {u.dc.map((dc) => (
                              <span key={dc.dc} className="rounded bg-bg px-2 py-0.5 text-[10px]">
                                <span className="text-text-muted">DC {dc.dc}:</span> <span className="text-text">{formatMs(dc.latency_ema_ms)}</span>
                                <span className="ml-1 text-text-faint">({dc.ip_preference})</span>
                              </span>
                            ))}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                ) : (
                  <p className="text-meta text-text-muted">Апстримы не настроены: движок ходит в Telegram напрямую.</p>
                )}
              </>
            )}
          </section>
        )}

        {dcs && (
          <section className="space-y-3">
            <div>
              <h3 className="text-[15px] font-bold text-text">Дата-центры Telegram</h3>
              <p className="mt-0.5 text-meta text-text-muted">
                Связь движка с каждым DC. Клиент сам выбирает свой DC, поэтому просадка одного задевает только часть пользователей.
              </p>
            </div>
            {!dcs.middle_proxy_enabled ? (
              <GatedNotice title="Дата-центры" reason={dcs.reason ?? 'middle_proxy_disabled'} setting="general.use_middle_proxy" />
            ) : (
              <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
                {(dcs.dcs ?? []).map((dc) => <DcCard key={dc.dc} dc={dc} path={pathByDc.get(dc.dc)} />)}
              </div>
            )}
          </section>
        )}

        {meWriters && (
          <section className="space-y-3">
            <div>
              <h3 className="text-[15px] font-bold text-text">Писатели ME</h3>
              <p className="mt-0.5 text-meta text-text-muted">
                Соединения, через которые движок пишет в промежуточные серверы. Если живых меньше, чем требуется, пул считается неполным.
              </p>
            </div>
            {!meWriters.middle_proxy_enabled ? (
              <GatedNotice title="Писатели ME" reason={meWriters.reason ?? 'middle_proxy_disabled'} setting="general.use_middle_proxy" />
            ) : (
              <>
                {meWriters.summary && (
                  <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
                    <MetricCard label="Покрытие" value={`${Math.round(meWriters.summary.coverage_pct)}%`} status={coverageTone(meWriters.summary.coverage_pct)} caption={`${meWriters.summary.alive_writers} из ${meWriters.summary.required_writers} писателей`} />
                    <MetricCard label="Свежее покрытие" value={`${Math.round(meWriters.summary.fresh_coverage_pct)}%`} caption={`${meWriters.summary.fresh_alive_writers} свежих`} />
                    <MetricCard label="Точки" value={`${meWriters.summary.available_endpoints} / ${meWriters.summary.configured_endpoints}`} caption={`${Math.round(meWriters.summary.available_pct)}% доступно`} />
                    <MetricCard label="Групп DC" value={formatNumber(meWriters.summary.configured_dc_groups)} />
                  </div>
                )}
                {writers.length > 0 && (
                  <Panel title={`Писатели (${writers.length})`} className="overflow-x-auto">
                    <table className="w-full text-xs">
                      <thead>
                        <tr className="border-b border-border text-left text-text-muted">
                          <th className="py-1.5 pr-2 font-medium">ID</th>
                          <th className="py-1.5 px-2 font-medium">DC</th>
                          <th className="py-1.5 px-2 font-medium">Точка</th>
                          <th className="py-1.5 px-2 text-right font-medium">Пок.</th>
                          <th className="py-1.5 px-2 text-right font-medium">Клиентов</th>
                          <th className="py-1.5 px-2 text-right font-medium">RTT</th>
                          <th className="py-1.5 px-2 text-right font-medium">Простой</th>
                          <th className="py-1.5 pl-2 text-right font-medium">Состояние</th>
                        </tr>
                      </thead>
                      <tbody>
                        {writers.map((w) => (
                          <tr key={w.writer_id} className="border-b border-border/50 last:border-0">
                            <td className="py-1.5 pr-2 font-mono tabular-nums text-text-muted">{w.writer_id}</td>
                            <td className="py-1.5 px-2 font-semibold text-text">{w.dc ?? '—'}</td>
                            <td className="py-1.5 px-2 font-mono text-text">{w.endpoint}</td>
                            <td className={cn('py-1.5 px-2 text-right font-mono tabular-nums', w.matches_active_generation ? 'text-text' : 'text-text-faint')}>{w.generation}</td>
                            <td className="py-1.5 px-2 text-right tabular-nums text-text">{formatNumber(w.bound_clients)}</td>
                            <td className="py-1.5 px-2 text-right tabular-nums text-text">{formatMs(w.rtt_ema_ms, 0)}</td>
                            <td className="py-1.5 px-2 text-right tabular-nums text-text-muted">{w.idle_for_secs == null ? '—' : formatAge(w.idle_for_secs)}</td>
                            <td className="py-1.5 pl-2 text-right"><WriterState w={w} /></td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </Panel>
                )}
              </>
            )}
          </section>
        )}
      </div>
    </div>
  );
}
