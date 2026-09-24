import { useMemo } from 'react';
import { Header } from '@/components/layout/Header';
import { ErrorAlert } from '@/components/ErrorAlert';
import { TelemetryField } from '@/components/TelemetryField';
import { HealthBanner } from '@/components/HealthBanner';
import { Panel } from '@/components/KeyValue';
import { TlsFingerprintsCard } from '@/components/TlsFingerprintsCard';
import { Skeleton } from '@/components/ui/skeleton';
import { StatePill, type PillState } from '@/components/ui/state-pill';
import { useWsSubscription, useEndpoint } from '@/hooks/useWebSocket';
import { formatNumber, plural } from '@/lib/utils';
import { fieldMeta } from '@/lib/telemetryLabels';
import { formatEpoch } from '@/lib/gated';

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

export function SecurityPage() {
  const { data: wsData, errors, connected, refresh } = useWsSubscription('security', ENDPOINTS, 10);
  const posture = useEndpoint<SecurityPostureData>(wsData, '/v1/security/posture');
  const whitelist = useEndpoint<WhitelistData>(wsData, '/v1/security/whitelist');
  const limits = useEndpoint<LimitsData>(wsData, '/v1/limits/effective');

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

            <TlsFingerprintsCard />
          </>
        )}
      </div>
    </div>
  );
}
