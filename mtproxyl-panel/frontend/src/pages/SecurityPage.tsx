import { useMemo, useState } from 'react';
import { Header } from '@/components/layout/Header';
import { ErrorAlert } from '@/components/ErrorAlert';
import { TelemetryField } from '@/components/TelemetryField';
import { GatedNotice } from '@/components/GatedNotice';
import { HealthBanner } from '@/components/HealthBanner';
import { KV, Panel } from '@/components/KeyValue';
import { Chip } from '@/components/ui/chip';
import { Skeleton } from '@/components/ui/skeleton';
import { StatePill, type PillState } from '@/components/ui/state-pill';
import { useWsSubscription, useEndpoint } from '@/hooks/useWebSocket';
import { usePolling } from '@/hooks/usePolling';
import { telemt } from '@/lib/api';
import { formatNumber, plural } from '@/lib/utils';
import { fieldMeta } from '@/lib/telemetryLabels';
import { formatEpoch, gatedData, type Gated } from '@/lib/gated';

interface SecurityPostureData {
  api_read_only: boolean;
  api_whitelist_enabled: boolean;
  api_whitelist_entries: number;
  api_auth_header_enabled: boolean;
  proxy_protocol_enabled: boolean;
  log_level: string;
  telemetry_core_enabled: boolean;
  telemetry_user_enabled: boolean;
  telemetry_me_level: string;
}

interface WhitelistData {
  enabled: boolean;
  entries_total: number;
  entries: string[];
  generated_at_epoch_secs: number;
}

interface LimitsData {
  [key: string]: unknown;
}

interface TlsRow {
  scope?: string;
  ja3: string;
  ja3_raw: string;
  ja4: string;
  ja4_raw: string;
  total: number;
  auth_success: number;
  bad_or_probe: number;
  first_seen_epoch_secs: number;
  last_seen_epoch_secs: number;
}

interface TlsFingerprintsPayload {
  limit: number;
  retention_secs: number;
  capacity: number;
  dropped_total: number;
  parse_error_total: number;
  by_fingerprint: TlsRow[];
  by_ip: TlsRow[];
  by_cidr: TlsRow[];
  by_user: TlsRow[];
}

type TlsScope = 'by_fingerprint' | 'by_ip' | 'by_cidr' | 'by_user';

const TLS_SCOPES: Array<{ key: TlsScope; label: string; column: string }> = [
  { key: 'by_fingerprint', label: 'По отпечатку', column: 'JA4' },
  { key: 'by_ip', label: 'По IP', column: 'IP' },
  { key: 'by_cidr', label: 'По подсети', column: 'Подсеть' },
  { key: 'by_user', label: 'По пользователю', column: 'Пользователь' },
];

const ENDPOINTS = ['/v1/security/posture', '/v1/security/whitelist', '/v1/limits/effective'];

const POSTURE_ORDER: (keyof SecurityPostureData)[] = [
  'api_read_only',
  'api_whitelist_enabled',
  'api_whitelist_entries',
  'api_auth_header_enabled',
  'proxy_protocol_enabled',
  'log_level',
  'telemetry_core_enabled',
  'telemetry_user_enabled',
  'telemetry_me_level',
];

const LIMIT_GROUPS: Record<string, string> = {
  timeouts: 'Таймауты',
  upstream: 'Апстримы',
  middle_proxy: 'Middle proxy',
  user_ip_policy: 'Политика IP пользователей',
  user_tcp_policy: 'Политика TCP пользователей',
};

/** Вердикт по доступу к API: открыт ли он наружу без защиты. */
function apiVerdict(p: SecurityPostureData): { state: PillState; title: string; detail: string } {
  const protectedByHeader = p.api_auth_header_enabled;
  const protectedByList = p.api_whitelist_enabled && p.api_whitelist_entries > 0;
  if (!protectedByHeader && !protectedByList) {
    return {
      state: 'error',
      title: 'API движка не защищён',
      detail: 'Ни заголовок авторизации, ни белый список не включены. Убедитесь, что порт API закрыт снаружи.',
    };
  }
  if (p.api_whitelist_enabled && p.api_whitelist_entries === 0) {
    return {
      state: 'warn',
      title: 'Белый список включён, но пуст',
      detail: 'При включённой проверке пустой список не пропустит никого, включая панель.',
    };
  }
  if (protectedByHeader && protectedByList) {
    return { state: 'ok', title: 'API защищён заголовком и белым списком', detail: p.api_read_only ? 'Режим только чтения: изменения через API запрещены.' : 'Изменения через API разрешены.' };
  }
  return {
    state: 'ok',
    title: protectedByHeader ? 'API защищён заголовком авторизации' : 'API ограничен белым списком',
    detail: p.api_read_only ? 'Режим только чтения: изменения через API запрещены.' : 'Изменения через API разрешены.',
  };
}

function TlsTable({ rows, column, suspiciousOnly }: { rows: TlsRow[]; column: string; suspiciousOnly: boolean }) {
  const visible = rows.filter((r) => !suspiciousOnly || r.bad_or_probe > 0);
  if (visible.length === 0) return <p className="py-3 text-center text-meta text-text-muted">Записей нет</p>;
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-xs">
        <thead>
          <tr className="border-b border-border text-left text-text-muted">
            <th className="py-1.5 pr-2 font-medium">{column}</th>
            <th className="py-1.5 px-2 font-medium">JA3</th>
            <th className="py-1.5 px-2 text-right font-medium">Всего</th>
            <th className="py-1.5 px-2 text-right font-medium">Успешных</th>
            <th className="py-1.5 px-2 text-right font-medium">Плохих / зондов</th>
            <th className="py-1.5 pl-2 text-right font-medium">Последний раз</th>
          </tr>
        </thead>
        <tbody>
          {visible.map((r, i) => (
            <tr key={`${r.scope ?? r.ja4}-${i}`} className="border-b border-border/50 last:border-0">
              <td className="py-1.5 pr-2 font-mono text-text" title={r.ja4_raw}>{r.scope ?? r.ja4}</td>
              <td className="py-1.5 px-2 font-mono text-text-muted" title={r.ja3_raw}>{r.ja3.slice(0, 12)}{r.ja3.length > 12 ? '…' : ''}</td>
              <td className="py-1.5 px-2 text-right tabular-nums text-text">{formatNumber(r.total)}</td>
              <td className="py-1.5 px-2 text-right tabular-nums text-ok">{formatNumber(r.auth_success)}</td>
              <td className={r.bad_or_probe > 0 ? 'py-1.5 px-2 text-right tabular-nums font-semibold text-warn' : 'py-1.5 px-2 text-right tabular-nums text-text-faint'}>{formatNumber(r.bad_or_probe)}</td>
              <td className="py-1.5 pl-2 text-right tabular-nums text-text-muted">{formatEpoch(r.last_seen_epoch_secs)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function SecurityPage() {
  const { data: wsData, errors, connected, refresh } = useWsSubscription('security', ENDPOINTS, 10);
  const posture = useEndpoint<SecurityPostureData>(wsData, '/v1/security/posture');
  const whitelist = useEndpoint<WhitelistData>(wsData, '/v1/security/whitelist');
  const limits = useEndpoint<LimitsData>(wsData, '/v1/limits/effective');

  const tls = usePolling<Gated<TlsFingerprintsPayload>>(
    () => telemt.get('/v1/runtime/tls-fingerprints?limit=50'),
    30_000,
  );
  const [scope, setScope] = useState<TlsScope>('by_fingerprint');
  const [suspiciousOnly, setSuspiciousOnly] = useState(false);
  const tlsPayload = gatedData(tls.data);

  const firstError = Object.values(errors)[0];
  const loading = Object.keys(wsData).length === 0 && !firstError;
  const verdict = posture ? apiVerdict(posture) : null;

  const limitGroups = useMemo(() => {
    if (!limits) return [];
    const scalars: Array<[string, unknown]> = [];
    const groups: Array<{ title: string; entries: Array<[string, unknown]> }> = [];
    for (const [key, value] of Object.entries(limits)) {
      if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
        groups.push({ title: LIMIT_GROUPS[key] ?? fieldMeta(key).label, entries: Object.entries(value as Record<string, unknown>) });
      } else {
        scalars.push([key, value]);
      }
    }
    return scalars.length ? [{ title: 'Общее', entries: scalars }, ...groups] : groups;
  }, [limits]);

  const suspiciousTotal = tlsPayload
    ? TLS_SCOPES.reduce((n, s) => n + tlsPayload[s.key].filter((r) => r.bad_or_probe > 0).length, 0)
    : 0;

  return (
    <div>
      <Header
        title="Безопасность"
        description="Доступ к API движка, белый список, действующие лимиты и TLS‑отпечатки клиентов."
        refreshing={!connected}
        onRefresh={refresh}
      />

      <div className="p-4 lg:p-6 space-y-5">
        {firstError && <ErrorAlert message={firstError} onRetry={refresh} />}

        {loading ? (
          <div className="space-y-4">
            <Skeleton className="h-24" />
            <div className="grid grid-cols-1 gap-3 md:grid-cols-2"><Skeleton className="h-56" /><Skeleton className="h-56" /></div>
          </div>
        ) : (
          <>
            {verdict && posture && (
              <HealthBanner
                state={verdict.state}
                title={verdict.title}
                detail={verdict.detail}
                facts={[
                  { key: 'log', label: 'Лог', value: posture.log_level },
                  { key: 'core', label: 'Телеметрия ядра', value: posture.telemetry_core_enabled ? 'вкл' : 'выкл' },
                  { key: 'user', label: 'По пользователям', value: posture.telemetry_user_enabled ? 'вкл' : 'выкл' },
                  { key: 'me', label: 'Уровень ME', value: posture.telemetry_me_level },
                ]}
              />
            )}

            <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
              {posture && (
                <section className="rounded-xl border border-border bg-surface p-4">
                  <h3 className="text-[13px] font-semibold text-text">Состояние безопасности</h3>
                  <p className="mb-3 mt-0.5 text-micro text-text-muted">Как движок настроен относительно доступа к API и сбора телеметрии.</p>
                  {POSTURE_ORDER.map((key) => (
                    <TelemetryField key={key} fieldKey={key} value={posture[key]} variant="row" />
                  ))}
                </section>
              )}

              <section className="rounded-xl border border-border bg-surface p-4">
                <div className="flex items-center justify-between gap-2">
                  <h3 className="text-[13px] font-semibold text-text">Белый список API</h3>
                  {whitelist && (
                    <StatePill state={whitelist.enabled ? 'ok' : 'muted'}>
                      {whitelist.enabled ? `${formatNumber(whitelist.entries_total)} ${plural(whitelist.entries_total, ['запись', 'записи', 'записей'])}` : 'не задан'}
                    </StatePill>
                  )}
                </div>
                <p className="mb-3 mt-0.5 text-micro text-text-muted">
                  Адреса и подсети, которым движок отвечает на запросы к API. Пустой список при включённой проверке означает, что не пройдёт никто.
                </p>
                {whitelist && whitelist.entries.length > 0 ? (
                  <div className="flex flex-wrap gap-2">
                    {whitelist.entries.map((ip) => (
                      <span key={ip} className="rounded-md bg-bg px-2.5 py-1 font-mono text-sm text-text">{ip}</span>
                    ))}
                  </div>
                ) : (
                  <div className="rounded-lg bg-bg px-4 py-6 text-center text-meta text-text-muted">Список пуст</div>
                )}
                {whitelist?.generated_at_epoch_secs ? (
                  <p className="mt-3 text-micro text-text-faint">Собрано {formatEpoch(whitelist.generated_at_epoch_secs)}</p>
                ) : null}
              </section>
            </div>

            {limits && (
              <section className="rounded-xl border border-border bg-surface p-4">
                <h3 className="text-[13px] font-semibold text-text">Действующие лимиты</h3>
                <p className="mb-3 mt-0.5 text-micro text-text-muted">
                  То, что движок применяет прямо сейчас, с учётом персональных настроек пользователей и правил по подсетям. Ноль означает «без ограничения».
                </p>
                {limitGroups.length === 0 ? (
                  <div className="text-meta text-text-muted">Лимиты не заданы</div>
                ) : (
                  <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
                    {limitGroups.map((g) => (
                      <Panel key={g.title} title={g.title}>
                        {g.entries.map(([key, value]) => (
                          <TelemetryField key={key} fieldKey={key} value={value} variant="row" />
                        ))}
                      </Panel>
                    ))}
                  </div>
                )}
              </section>
            )}

            <section className="rounded-xl border border-border bg-surface p-4">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <h3 className="text-[13px] font-semibold text-text">TLS‑отпечатки клиентов</h3>
                  <p className="mt-0.5 text-micro text-text-muted">
                    JA3/JA4 отпечатки ClientHello: кто подключается и сколько попыток похожи на зондирование.
                  </p>
                </div>
                {tlsPayload && suspiciousTotal > 0 && <StatePill state="warn">подозрительных {suspiciousTotal}</StatePill>}
              </div>
              <div className="mt-3">
                {tls.loading && !tls.data ? (
                  <Skeleton className="h-32" />
                ) : tls.error ? (
                  <p className="text-meta text-warn">Не удалось получить отпечатки: {tls.error.message}</p>
                ) : !tlsPayload ? (
                  <GatedNotice title="TLS‑отпечатки" reason={tls.data?.reason} runtimeEdge />
                ) : (
                  <div className="space-y-3">
                    <div className="flex flex-wrap items-center gap-2">
                      {TLS_SCOPES.map((s) => (
                        <Chip key={s.key} active={scope === s.key} onClick={() => setScope(s.key)} count={tlsPayload[s.key].length}>{s.label}</Chip>
                      ))}
                      <Chip active={suspiciousOnly} onClick={() => setSuspiciousOnly((v) => !v)}>Только подозрительные</Chip>
                    </div>
                    <TlsTable rows={tlsPayload[scope]} column={TLS_SCOPES.find((s) => s.key === scope)!.column} suspiciousOnly={suspiciousOnly} />
                    <div className="grid grid-cols-2 gap-x-6 text-micro text-text-faint md:grid-cols-4">
                      <KV label="Хранится" value={`${Math.round(tlsPayload.retention_secs / 3600)} ч`} />
                      <KV label="Ёмкость" value={formatNumber(tlsPayload.capacity)} mono />
                      <KV label="Потеряно" value={formatNumber(tlsPayload.dropped_total)} mono />
                      <KV label="Ошибок разбора" value={formatNumber(tlsPayload.parse_error_total)} mono />
                    </div>
                  </div>
                )}
              </div>
            </section>
          </>
        )}
      </div>
    </div>
  );
}
