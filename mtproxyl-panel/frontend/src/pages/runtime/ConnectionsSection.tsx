import { MetricCard } from '@/components/MetricCard';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { GatedNotice } from '@/components/GatedNotice';
import { StatePill } from '@/components/ui/state-pill';
import { formatNumber, formatBytes } from '@/lib/utils';
import { gatedData } from '@/lib/gated';
import type { ConnectionsData, ConnectionsTopUser } from '@/types/runtime';

interface ConnectionsSectionProps {
  data: ConnectionsData | null;
}

function TopTable({ title, rows, cumulative }: { title: string; rows: ConnectionsTopUser[]; cumulative: boolean }) {
  return (
    <div className="rounded-lg bg-bg p-3">
      <h4 className="mb-2 text-micro font-semibold uppercase tracking-[0.06em] text-text-faint">{title}</h4>
      <table className="w-full text-xs">
        <thead>
          <tr className="border-b border-border text-left text-text-muted">
            <th className="py-1.5 pr-2 font-medium">Пользователь</th>
            <th className="py-1.5 px-2 text-right font-medium">Соед.</th>
            <th className="py-1.5 pl-2 text-right font-medium">{cumulative ? 'Трафик всего' : 'Трафик'}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((u) => (
            <tr key={u.username} className="border-b border-border/50 last:border-0">
              <td className="py-1.5 pr-2 font-mono text-text">{u.username}</td>
              <td className="py-1.5 px-2 text-right tabular-nums text-text">{formatNumber(u.current_connections)}</td>
              <td className="py-1.5 pl-2 text-right tabular-nums text-text">{formatBytes(u.total_octets)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function ConnectionsSection({ data }: ConnectionsSectionProps) {
  if (!data) return null;
  const payload = gatedData(data);
  if (!payload) {
    return <GatedNotice title="Соединения" reason={data.reason} runtimeEdge />;
  }
  const { totals, top, cache, telemetry } = payload;
  const hasTop = top && (top.by_connections.length > 0 || top.by_throughput.length > 0);

  return (
    <CollapsibleSection
      title="Соединения"
      description="Сколько клиентов сейчас подключено и как они распределены между прямым путём и промежуточными серверами Telegram."
      badge={cache?.stale_cache_used ? <StatePill state="warn">устаревший кеш</StatePill> : undefined}
    >
      <div className="space-y-4">
        <div className="grid grid-cols-2 gap-2 lg:grid-cols-4">
          <MetricCard label="Всего соединений" value={formatNumber(totals.current_connections)} />
          <MetricCard label="Через ME" value={formatNumber(totals.current_connections_me)} />
          <MetricCard label="Прямые" value={formatNumber(totals.current_connections_direct)} />
          <MetricCard label="Активные пользователи" value={formatNumber(totals.active_users)} />
        </div>
        {hasTop && (
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            {top.by_connections.length > 0 && <TopTable title={`Топ по соединениям (${top.limit})`} rows={top.by_connections} cumulative={telemetry?.throughput_is_cumulative ?? true} />}
            {top.by_throughput.length > 0 && <TopTable title="Топ по трафику" rows={top.by_throughput} cumulative={telemetry?.throughput_is_cumulative ?? true} />}
          </div>
        )}
        {telemetry && !telemetry.user_enabled && (
          <p className="text-micro text-text-faint">Пользовательская телеметрия выключена: списки топ‑N пусты.</p>
        )}
      </div>
    </CollapsibleSection>
  );
}
