import { useEffect, useRef, useState } from 'react';
import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight, Search } from 'lucide-react';
import { GatedNotice } from '@/components/GatedNotice';
import { KV } from '@/components/KeyValue';
import { Chip } from '@/components/ui/chip';
import { Input } from '@/components/ui/input';
import { Skeleton } from '@/components/ui/skeleton';
import { StatePill } from '@/components/ui/state-pill';
import { usePolling } from '@/hooks/usePolling';
import { fingerprintsApi, type FingerprintRow, type FingerprintScope, type FingerprintSort, type FingerprintsPage } from '@/lib/api';
import { formatEpoch } from '@/lib/gated';
import { countryFlag } from '@/lib/flag';
import { cn, formatNumber, plural } from '@/lib/utils';

const SCOPES: Array<{ key: FingerprintScope; label: string; column: string }> = [
  { key: 'by_fingerprint', label: 'По отпечатку', column: 'JA4' },
  { key: 'by_ip', label: 'По IP', column: 'IP' },
  { key: 'by_cidr', label: 'По подсети', column: 'Подсеть' },
  { key: 'by_user', label: 'По пользователю', column: 'Пользователь' },
];

const PAGE_SIZE = 50;

interface Column {
  key: FingerprintSort;
  label: string;
  align?: 'right';
  geo?: boolean;
}

const COLUMNS: Column[] = [
  { key: 'key', label: '' },
  { key: 'country', label: 'Страна', geo: true },
  { key: 'total', label: 'Всего', align: 'right' },
  { key: 'auth_success', label: 'Успешных', align: 'right' },
  { key: 'bad_or_probe', label: 'Плохих / зондов', align: 'right' },
  { key: 'first_seen', label: 'Впервые', align: 'right' },
  { key: 'last_seen', label: 'Последний раз', align: 'right' },
];

function SortHeader({ column, active, order, onClick, label }: { column: Column; active: boolean; order: 'asc' | 'desc'; onClick: () => void; label: string }) {
  const Icon = order === 'asc' ? ArrowUp : ArrowDown;
  return (
    <th className={cn('py-1.5 px-2 font-medium first:pl-0 last:pr-0', column.align === 'right' && 'text-right')}>
      <button
        type="button"
        onClick={onClick}
        aria-sort={active ? (order === 'asc' ? 'ascending' : 'descending') : undefined}
        className={cn('inline-flex items-center gap-1 whitespace-nowrap hover:text-text', active ? 'text-text' : 'text-text-muted')}
      >
        {label}
        {active && <Icon size={12} />}
      </button>
    </th>
  );
}

function GeoCell({ row }: { row: FingerprintRow }) {
  if (!row.country) return <span className="text-text-faint">—</span>;
  const place = [row.city, row.country_name].filter(Boolean).join(', ');
  return (
    <span className="inline-flex items-center gap-1.5" title={row.asn_org ? `${place} · ${row.asn_org}` : place}>
      <span aria-hidden>{countryFlag(row.country)}</span>
      <span className="text-text">{row.country}</span>
      {row.asn_org && <span className="hidden max-w-[160px] truncate text-text-faint lg:inline">{row.asn_org}</span>}
    </span>
  );
}

export function TlsFingerprintsCard() {
  const [scope, setScope] = useState<FingerprintScope>('by_fingerprint');
  const [sort, setSort] = useState<FingerprintSort>('total');
  const [order, setOrder] = useState<'asc' | 'desc'>('desc');
  const [suspiciousOnly, setSuspiciousOnly] = useState(false);
  const [query, setQuery] = useState('');
  const [search, setSearch] = useState('');
  const [page, setPage] = useState(0);

  useEffect(() => {
    const id = window.setTimeout(() => setSearch(query.trim()), 300);
    return () => window.clearTimeout(id);
  }, [query]);
  useEffect(() => setPage(0), [scope, sort, order, suspiciousOnly, search]);

  const { data, error, loading, refresh } = usePolling<FingerprintsPage>(
    () => fingerprintsApi.query({ scope, sort, order, q: search, suspicious: suspiciousOnly, offset: page * PAGE_SIZE, limit: PAGE_SIZE }),
    60_000,
  );
  const mounted = useRef(false);
  useEffect(() => {
    if (!mounted.current) {
      mounted.current = true;
      return;
    }
    refresh();
  }, [scope, sort, order, suspiciousOnly, search, page, refresh]);

  const toggleSort = (key: FingerprintSort) => {
    if (key === sort) {
      setOrder((o) => (o === 'asc' ? 'desc' : 'asc'));
      return;
    }
    setSort(key);
    setOrder(key === 'key' || key === 'country' ? 'asc' : 'desc');
  };

  const suspiciousTotal = data ? SCOPES.reduce((n, s) => n + (data.suspicious?.[s.key] ?? 0), 0) : 0;
  const scopeMeta = SCOPES.find((s) => s.key === scope)!;
  const showGeo = data?.geoip && (scope === 'by_ip' || scope === 'by_cidr');
  const columns = COLUMNS.filter((c) => !c.geo || showGeo);
  const pages = data ? Math.max(1, Math.ceil(data.total / PAGE_SIZE)) : 1;
  const gateClosed = data && data.gate.seen && !data.gate.enabled;
  const empty = data && data.total === 0;

  return (
    <section className="rounded-xl border border-border bg-surface p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h3 className="text-[13px] font-semibold text-text">TLS‑отпечатки клиентов</h3>
          <p className="mt-0.5 text-micro text-text-muted">
            JA3/JA4 отпечатки ClientHello: кто подключается и сколько попыток похожи на зондирование.
            {data?.source === 'panel' && ' Панель копит записи дольше окна движка и переживает его перезапуск.'}
          </p>
        </div>
        {suspiciousTotal > 0 && <StatePill state="warn">подозрительных {formatNumber(suspiciousTotal)}</StatePill>}
      </div>

      <div className="mt-3">
        {loading && !data ? (
          <Skeleton className="h-32" />
        ) : error && !data ? (
          <p className="text-meta text-warn">Не удалось получить отпечатки: {error.message}</p>
        ) : !data ? null : gateClosed && empty ? (
          <GatedNotice title="TLS‑отпечатки" reason={data.gate.reason} runtimeEdge />
        ) : (
          <div className="space-y-3">
            {gateClosed && (
              <p className="rounded-lg border border-dashed border-border-strong px-3 py-2 text-micro text-text-muted">
                Гейт движка сейчас закрыт — показаны накопленные ранее записи, новые не поступают.
              </p>
            )}
            <div className="flex flex-wrap items-center gap-2">
              {SCOPES.map((s) => (
                <Chip key={s.key} active={scope === s.key} onClick={() => setScope(s.key)} count={formatNumber(data.counts?.[s.key] ?? 0)}>{s.label}</Chip>
              ))}
              <Chip active={suspiciousOnly} onClick={() => setSuspiciousOnly((v) => !v)}>Только подозрительные</Chip>
              <div className="relative ml-auto w-full sm:w-64">
                <Search size={14} className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-text-faint" />
                <Input
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder={`Поиск: ${scopeMeta.column.toLowerCase()}, JA3, JA4, страна`}
                  aria-label="Поиск по отпечаткам"
                  className="h-[34px] pl-8 text-xs"
                />
              </div>
            </div>

            {empty ? (
              <p className="py-3 text-center text-meta text-text-muted">Записей нет</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-xs">
                  <thead>
                    <tr className="border-b border-border text-left text-text-muted">
                      {columns.map((c) => (
                        <SortHeader key={c.key} column={c} label={c.key === 'key' ? scopeMeta.column : c.label} active={sort === c.key} order={order} onClick={() => toggleSort(c.key)} />
                      ))}
                      <th className="py-1.5 pl-2 pr-0 text-left font-medium">JA3</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.rows.map((r) => (
                      <tr key={r.key} className="border-b border-border/50 last:border-0">
                        <td className="py-1.5 pr-2 font-mono text-text" title={r.ja4_raw || r.ja4}>{r.key}</td>
                        {showGeo && <td className="py-1.5 px-2"><GeoCell row={r} /></td>}
                        <td className="py-1.5 px-2 text-right tabular-nums text-text">{formatNumber(r.total)}</td>
                        <td className="py-1.5 px-2 text-right tabular-nums text-ok">{formatNumber(r.auth_success)}</td>
                        <td className={r.bad_or_probe > 0 ? 'py-1.5 px-2 text-right tabular-nums font-semibold text-warn' : 'py-1.5 px-2 text-right tabular-nums text-text-faint'}>{formatNumber(r.bad_or_probe)}</td>
                        <td className="py-1.5 px-2 text-right tabular-nums text-text-muted whitespace-nowrap">{formatEpoch(r.first_seen_epoch_secs)}</td>
                        <td className="py-1.5 px-2 text-right tabular-nums text-text-muted whitespace-nowrap">{formatEpoch(r.last_seen_epoch_secs)}</td>
                        <td className="py-1.5 pl-2 font-mono text-text-muted" title={r.ja3_raw || r.ja3}>{r.ja3.slice(0, 12)}{r.ja3.length > 12 ? '…' : ''}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}

            <div className="flex flex-wrap items-center justify-between gap-2 text-micro text-text-faint">
              <span>
                {formatNumber(data.total)} {plural(data.total, ['запись', 'записи', 'записей'])}
                {data.total > PAGE_SIZE && ` · стр. ${page + 1} из ${pages}`}
              </span>
              {pages > 1 && (
                <span className="inline-flex items-center gap-1">
                  <button type="button" className="rounded-md p-1 hover:bg-surface-2 disabled:opacity-40" disabled={page === 0} onClick={() => setPage((p) => p - 1)} aria-label="Предыдущая страница"><ChevronLeft size={14} /></button>
                  <button type="button" className="rounded-md p-1 hover:bg-surface-2 disabled:opacity-40" disabled={page + 1 >= pages} onClick={() => setPage((p) => p + 1)} aria-label="Следующая страница"><ChevronRight size={14} /></button>
                </span>
              )}
            </div>

            <div className="grid grid-cols-2 gap-x-6 text-micro text-text-faint md:grid-cols-4">
              <KV label="Окно движка" value={data.engine.retention_secs ? `${Math.round(data.engine.retention_secs / 3600)} ч` : '—'} />
              <KV label="Ёмкость движка" value={formatNumber(data.engine.capacity)} mono />
              <KV label="Потеряно" value={formatNumber(data.engine.dropped_total)} mono />
              <KV label="Ошибок разбора" value={formatNumber(data.engine.parse_error_total)} mono />
            </div>
            {data.source === 'panel' && data.observed_since_epoch_secs ? (
              <p className="text-micro text-text-faint">Панель копит с {formatEpoch(data.observed_since_epoch_secs)}. Пределы и очистка — в «Настройках панели».</p>
            ) : null}
          </div>
        )}
      </div>
    </section>
  );
}
