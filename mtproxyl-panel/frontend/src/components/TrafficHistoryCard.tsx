import { useCallback, useState } from 'react';
import { Link } from 'react-router-dom';
import { TimeBars } from '@/components/charts/TimeBars';
import { Chip } from '@/components/ui/chip';
import { Skeleton } from '@/components/ui/skeleton';
import { usePolling } from '@/hooks/usePolling';
import { trafficHistoryApi, type TrafficHistoryRange, type TrafficHistorySummary } from '@/lib/api';
import { formatBytes, cn } from '@/lib/utils';

interface TrafficHistoryCardProps {
  username?: string;
  title?: string;
  description?: string;
  defaultRange?: TrafficHistoryRange;
}

const RANGES: Array<{ key: TrafficHistoryRange; label: string }> = [
  { key: '24h', label: '24 ч' },
  { key: '7d', label: '7 дней' },
  { key: '30d', label: '30 дней' },
  { key: 'month', label: 'Месяц' },
  { key: '1y', label: 'Год' },
];

function axisLabel(ts: number, range: TrafficHistoryRange): string {
  const d = new Date(ts * 1000);
  return range === '24h'
    ? d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' })
    : d.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit', timeZone: 'UTC' });
}

function comparison(s: TrafficHistorySummary): string | null {
  if (s.previous_total_bytes === undefined) return null;
  const diff = s.total_bytes - s.previous_total_bytes;
  const sign = diff > 0 ? '+' : diff < 0 ? '−' : '';
  return `к предыдущему периоду: ${sign}${formatBytes(Math.abs(diff))}`;
}

/** История трафика из хранилища панели: по всем пользователям или по одному. */
export function TrafficHistoryCard({ username, title = 'Трафик по времени', description, defaultRange = '7d' }: TrafficHistoryCardProps) {
  const [range, setRange] = useState<TrafficHistoryRange>(defaultRange);
  const fetcher = useCallback(
    () => (username ? trafficHistoryApi.user(username, range) : trafficHistoryApi.summary(range)),
    [username, range],
  );
  const { data, error } = usePolling(fetcher, 60_000, `${username ?? ''}:${range}`);
  const visibleData = data?.range === range && (data.username ?? '') === (username ?? '') ? data : null;
  const disabled = error?.message.includes('history_disabled') || error?.message.includes('выключена');

  return (
    <section className="rounded-xl border border-border bg-surface p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="text-[13px] font-semibold text-text">{title}</h3>
          <p className="mt-0.5 text-micro text-text-muted">
            {description ?? 'Панель считает байты по данным движка каждые 10 секунд и хранит их у себя: 15‑минутные корзины двое суток, часовые месяц, суточные больше года.'}
          </p>
        </div>
        <div className="flex flex-wrap gap-1.5">
          {RANGES.map((r) => (
            <Chip key={r.key} active={range === r.key} onClick={() => setRange(r.key)}>{r.label}</Chip>
          ))}
        </div>
      </div>

      {disabled ? (
        <p className="mt-3 text-meta text-text-muted">История трафика выключена в конфиге панели ([history] enabled = false).</p>
      ) : error && !visibleData ? (
        <p className="mt-3 text-meta text-warn">Не удалось получить историю: {error.message}</p>
      ) : visibleData ? (
        <div className={cn('mt-3 grid gap-3', !username && visibleData.top_users && visibleData.top_users.length > 0 && 'lg:grid-cols-[minmax(0,2fr)_minmax(220px,1fr)]')}>
          <div className="min-w-0">
            <div className="grid grid-cols-3 gap-2">
              <Value label="Сегодня" value={formatBytes(visibleData.today_bytes)} />
              <Value label="За период" value={formatBytes(visibleData.total_bytes)} />
              <Value label="Предыдущий период" value={visibleData.previous_total_bytes === undefined ? '—' : formatBytes(visibleData.previous_total_bytes)} />
            </div>
            <div className="mt-3">
              <TimeBars
                points={visibleData.points}
                from={visibleData.requested_from_epoch_secs}
                to={visibleData.requested_to_epoch_secs}
                emptyLabel={visibleData.state === 'empty' ? 'История накапливается: первые байты появятся через несколько минут' : 'За период трафика не было'}
              />
            </div>
            <div className="mt-1 flex justify-between text-[10px] text-text-faint">
              <span>{axisLabel(visibleData.requested_from_epoch_secs, range)}</span>
              <span>{axisLabel(visibleData.requested_to_epoch_secs, range)}</span>
            </div>
            <div className="mt-2 flex flex-wrap items-center justify-between gap-2 text-micro text-text-muted">
              <span>{comparison(visibleData) ?? 'предыдущий период ещё не накоплен'}</span>
              {visibleData.state === 'partial' && visibleData.observed_since_epoch_secs && (
                <span className="text-accent">наблюдение с {new Date(visibleData.observed_since_epoch_secs * 1000).toLocaleDateString('ru-RU')}</span>
              )}
            </div>
          </div>
          {!username && visibleData.top_users && visibleData.top_users.length > 0 && (
            <div className="min-w-0 rounded-lg bg-bg p-3">
              <h4 className="text-micro font-semibold uppercase tracking-[0.06em] text-text-faint">Топ за период</h4>
              <ol className="mt-2 flex flex-col gap-1">
                {visibleData.top_users.map((u, i) => (
                  <li key={u.username}>
                    <Link
                      to={`/users/${encodeURIComponent(u.username)}`}
                      className="grid min-h-8 grid-cols-[18px_minmax(0,1fr)_auto] items-center gap-2 rounded-md px-1.5 text-xs transition-colors hover:bg-surface-2"
                    >
                      <span className="text-[10px] tabular-nums text-text-faint">{i + 1}</span>
                      <strong className="truncate font-medium text-text">{u.username}</strong>
                      <span className="tabular-nums text-text-muted">{formatBytes(u.bytes)}</span>
                    </Link>
                  </li>
                ))}
              </ol>
            </div>
          )}
        </div>
      ) : <Skeleton className="mt-3 h-40" />}
    </section>
  );
}

function Value({ label, value }: { label: string; value: string }) {
  return (
    <span className="min-w-0 rounded-lg bg-bg px-2.5 py-2">
      <small className="block truncate text-[10px] text-text-muted">{label}</small>
      <strong className="mt-1 block truncate font-mono text-[15px] font-bold tabular-nums text-text">{value}</strong>
    </span>
  );
}
