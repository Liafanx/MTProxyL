import { useCallback, useEffect, useMemo, useState } from 'react';
import { ArrowDown, ArrowUp } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ErrorAlert } from '@/components/ErrorAlert';
import { StatusBadge } from '@/components/StatusBadge';
import { Header } from '@/components/layout/Header';
import { formatBytes } from '@/lib/utils';
import { mtproxylNetApi, type TrafficReport, type TrafficUser } from '@/lib/api';

type SortKey = 'total' | 'in' | 'out' | 'connections' | 'user';

/**
 * Откуда взяты числа и насколько им можно верить.
 *
 * У режимов разные источники, и разница не косметическая: в менеджере у нас
 * своя база, которая переживает перезапуск движка, а у чужой цели мы читаем
 * её же счётчики — они обнуляются вместе с ней. Показать одинаковую таблицу и
 * промолчать об этом значило бы выдать сессионные числа за накопленные.
 */
function sourceNote(report: TrafficReport): string {
  switch (report.source) {
    case 'db':
      return 'Считает MTProxyL: накопленное не сбрасывается при перезапуске движка.';
    case 'metrics':
      return 'Метрики цели, накопленные MTProxyL: счётчики самой цели обнуляются при её перезапуске, поэтому разницу мы копим у себя.';
    case 'api':
      return 'API цели, накопленное MTProxyL. Направления API не разделяет, поэтому показан только общий объём.';
    default:
      return 'Источник данных недоступен.';
  }
}

export function TrafficPage() {
  const [report, setReport] = useState<TrafficReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [sortKey, setSortKey] = useState<SortKey>('total');
  const [asc, setAsc] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setReport(await mtproxylNetApi.traffic());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить статистику трафика');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    // setTimeout, а не setInterval — см. usePolling.ts: следующий опрос
    // планируется только после завершения предыдущего, без накопления.
    let cancelled = false;
    let timeoutId: ReturnType<typeof setTimeout> | undefined;

    const tick = async () => {
      await load();
      if (!cancelled) {
        timeoutId = setTimeout(tick, 15_000);
      }
    };

    void tick();

    return () => {
      cancelled = true;
      if (timeoutId) clearTimeout(timeoutId);
    };
  }, [load]);

  const directional = report?.directional ?? false;

  const sorted = useMemo(() => {
    const rows = [...(report?.users ?? [])];
    rows.sort((a, b) => {
      if (sortKey === 'user') return a.user.localeCompare(b.user, 'ru');
      return Number(a[sortKey]) - Number(b[sortKey]);
    });
    const ordered = asc ? rows : rows.reverse();
    // Сводка по удалённым — не пользователь, ей место в конце при любой
    // сортировке, иначе она встаёт в середину списка живых.
    return [...ordered.filter((u) => !u.deleted), ...ordered.filter((u) => u.deleted)];
  }, [report, sortKey, asc]);

  const toggleSort = (key: SortKey) => {
    if (key === sortKey) {
      setAsc((v) => !v);
    } else {
      setSortKey(key);
      // Имена удобнее читать по алфавиту, числа — от большего к меньшему.
      setAsc(key === 'user');
    }
  };

  return (
    <div>
      <Header title="Трафик" refreshing={loading} onRefresh={load} />

      <div className="p-4 lg:p-6 space-y-4">
        {error && <ErrorAlert message={error} onRetry={load} />}

        {report?.error && (
          <div className="bg-warning/10 border border-warning/30 rounded-lg p-3 text-sm text-text-primary">
            Статистика недоступна: {report.error}
          </div>
        )}

        {loading && !report ? (
          <div className="text-sm text-text-secondary">Загрузка…</div>
        ) : (
          report && (
            <>
              <Card>
                <CardHeader>
                  <CardTitle>Всего</CardTitle>
                </CardHeader>
                <CardContent className="space-y-3">
                  <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                    {directional ? (
                      <>
                        <Metric
                          label="Скачано"
                          value={formatBytes(report.totals.in)}
                          icon={<ArrowDown size={14} className="text-accent" />}
                        />
                        <Metric
                          label="Отправлено"
                          value={formatBytes(report.totals.out)}
                          icon={<ArrowUp size={14} className="text-accent" />}
                        />
                      </>
                    ) : (
                      <Metric label="Передано" value={formatBytes(report.totals.total)} />
                    )}
                    <Metric label="Соединений" value={String(report.totals.connections)} />
                    <Metric
                      label="Пользователей"
                      value={String(report.users.filter((u) => !u.deleted).length)}
                    />
                  </div>
                  {report.persistent && directional && (
                    <div className="text-xs text-text-secondary">
                      За текущую сессию: ↓ {formatBytes(report.totals.session_in)} · ↑{' '}
                      {formatBytes(report.totals.session_out)}
                    </div>
                  )}
                  <p className="text-xs text-text-secondary/70">{sourceNote(report)}</p>
                </CardContent>
              </Card>

              <Card>
                <CardHeader>
                  <CardTitle>По пользователям</CardTitle>
                </CardHeader>
                <CardContent>
                  {sorted.length === 0 ? (
                    <div className="text-sm text-text-secondary">Данных пока нет</div>
                  ) : (
                    <div className="overflow-x-auto -mx-4 px-4">
                      <table className="w-full text-sm">
                        <thead>
                          <tr className="text-left text-text-secondary border-b border-border">
                            <SortHeader
                              label="Пользователь"
                              k="user"
                              sortKey={sortKey}
                              asc={asc}
                              onSort={toggleSort}
                            />
                            {directional && (
                              <>
                                <SortHeader
                                  label="Скачано"
                                  k="in"
                                  sortKey={sortKey}
                                  asc={asc}
                                  onSort={toggleSort}
                                  align="right"
                                />
                                <SortHeader
                                  label="Отправлено"
                                  k="out"
                                  sortKey={sortKey}
                                  asc={asc}
                                  onSort={toggleSort}
                                  align="right"
                                />
                              </>
                            )}
                            <SortHeader
                              label="Всего"
                              k="total"
                              sortKey={sortKey}
                              asc={asc}
                              onSort={toggleSort}
                              align="right"
                            />
                            <SortHeader
                              label="Соед."
                              k="connections"
                              sortKey={sortKey}
                              asc={asc}
                              onSort={toggleSort}
                              align="right"
                            />
                            <th className="py-2 pl-4 font-medium text-right">Состояние</th>
                          </tr>
                        </thead>
                        <tbody>
                          {sorted.map((u) => (
                            <Row key={u.user} user={u} directional={directional} />
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </CardContent>
              </Card>
            </>
          )
        )}
      </div>
    </div>
  );
}

function Row({ user, directional }: { user: TrafficUser; directional: boolean }) {
  const session = user.session_in + user.session_out;
  return (
    <tr className="border-b border-border last:border-0">
      <td className="py-2 pr-4 text-text-primary">
        <span className={user.deleted ? 'text-text-secondary italic' : undefined}>{user.user}</span>
        {user.deleted && (
          <div className="text-xs text-text-secondary">
            Трафик израсходован и остаётся в итоге
          </div>
        )}
        {!user.deleted && session > 0 && (
          <div className="text-xs text-text-secondary">
            за сессию {formatBytes(session)}
          </div>
        )}
      </td>
      {directional && (
        <>
          <td className="py-2 pl-4 text-right font-mono text-xs">{formatBytes(user.in)}</td>
          <td className="py-2 pl-4 text-right font-mono text-xs">{formatBytes(user.out)}</td>
        </>
      )}
      <td className="py-2 pl-4 text-right font-mono text-xs text-text-primary">
        {formatBytes(user.total)}
      </td>
      <td className="py-2 pl-4 text-right text-text-secondary">{user.connections}</td>
      <td className="py-2 pl-4 text-right">
        {user.deleted ? (
          <span className="text-xs text-text-secondary">удалён</span>
        ) : (
          <StatusBadge status={user.enabled} labelOn="ВКЛ" labelOff="ВЫКЛ" />
        )}
      </td>
    </tr>
  );
}

interface SortHeaderProps {
  label: string;
  k: SortKey;
  sortKey: SortKey;
  asc: boolean;
  onSort: (k: SortKey) => void;
  align?: 'left' | 'right';
}

function SortHeader({ label, k, sortKey, asc, onSort, align = 'left' }: SortHeaderProps) {
  const activeSort = k === sortKey;
  return (
    <th className={`py-2 ${align === 'right' ? 'pl-4 text-right' : 'pr-4'} font-medium`}>
      <button
        type="button"
        onClick={() => onSort(k)}
        className={`inline-flex items-center gap-1 hover:text-text-primary transition-colors ${
          activeSort ? 'text-text-primary' : ''
        }`}
      >
        {label}
        <span className="text-xs">{activeSort ? (asc ? '▲' : '▼') : '↕'}</span>
      </button>
    </th>
  );
}

function Metric({ label, value, icon }: { label: string; value: string; icon?: React.ReactNode }) {
  return (
    <div>
      <div className="text-xs text-text-secondary mb-1 flex items-center gap-1">
        {icon}
        {label}
      </div>
      <div className="text-lg font-semibold text-text-primary">{value}</div>
    </div>
  );
}
