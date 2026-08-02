import { Header } from '@/components/layout/Header';
import { MetricCard } from '@/components/MetricCard';
import { StatusDot } from '@/components/StatusDot';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { StartupStatus } from '@/components/StartupStatus';
import { ConnectionErrors, type ClassCount } from '@/components/ConnectionErrors';
import { useWsSubscription, useEndpoint } from '@/hooks/useWebSocket';
import { usePolling } from '@/hooks/usePolling';
import { telemt } from '@/lib/api';
import { formatUptime, formatNumber, formatBytes } from '@/lib/utils';
import { Activity, Clock, Users, ArrowUpDown, Globe } from 'lucide-react';
import { useMemo } from 'react';

interface HealthData {
  status: string;
  read_only: boolean;
}

interface SummaryData {
  uptime_seconds: number;
  connections_total: number;
  connections_bad_total: number;
  // Per-class breakdowns are absent on telemt builds that predate them.
  connections_bad_by_class?: ClassCount[];
  handshake_failures_by_class?: ClassCount[];
  handshake_timeouts_total: number;
  configured_users: number;
}

interface SystemInfoData {
  [key: string]: unknown;
}

interface GatesData {
  startup_status?: string;
  startup_stage?: string;
  startup_progress_pct?: number;
  [key: string]: unknown;
}

interface UserTrafficData {
  total_octets: number;
  active_unique_ips: number;
}

const ENDPOINTS = ['/v1/health', '/v1/stats/summary', '/v1/system/info', '/v1/runtime/gates'];

export function DashboardPage() {
  const { data: wsData, errors, connected, refresh } = useWsSubscription('dashboard', ENDPOINTS, 5);

  const health = useEndpoint<HealthData>(wsData, '/v1/health');
  const summary = useEndpoint<SummaryData>(wsData, '/v1/stats/summary');
  const system = useEndpoint<SystemInfoData>(wsData, '/v1/system/info');
  const gates = useEndpoint<GatesData>(wsData, '/v1/runtime/gates');

  const { data: usersData } = usePolling<UserTrafficData[]>(
    () => telemt.get('/v1/users'),
    10000
  );

  const totalTraffic = useMemo(() => {
    if (!usersData) return 0;
    return usersData.reduce((sum, u) => sum + u.total_octets, 0);
  }, [usersData]);

  const totalActiveIPs = useMemo(() => {
    if (!usersData) return 0;
    return usersData.reduce((sum, u) => sum + u.active_unique_ips, 0);
  }, [usersData]);

  const isHealthy = health?.status === 'ok';
  const firstError = Object.values(errors)[0];

  return (
    <div>
      <Header title="Дашборд" refreshing={!connected} onRefresh={refresh} />

      <div className="p-4 lg:p-6 space-y-4 lg:space-y-6">
        {firstError && <ErrorAlert message={firstError} onRetry={refresh} />}

        {/* Health Banner */}
        <div
          className={`rounded-lg border p-3 lg:p-4 flex items-center gap-2 lg:gap-3 text-sm lg:text-base ${
            isHealthy
              ? 'bg-success/10 border-success/30'
              : 'bg-danger/10 border-danger/30'
          }`}
        >
          <StatusDot
            status={isHealthy ? 'ok' : 'error'}
            size="md"
            animated={!connected}
          />
          <span className={`font-medium ${isHealthy ? 'text-success' : 'text-danger'}`}>
            {isHealthy ? 'Telemt работает' : 'Telemt недоступен'}
          </span>
          {!connected && (
            <span className="ml-auto text-xs text-warning bg-warning/15 px-2 py-1 rounded shrink-0">
              Переподключение WS…
            </span>
          )}
          {health?.read_only && (
            <span className="ml-auto text-xs text-warning bg-warning/15 px-2 py-1 rounded shrink-0">
              ТОЛЬКО ЧТЕНИЕ
            </span>
          )}
        </div>

        {/* Startup Status */}
        {gates && (
          <StartupStatus
            status={gates.startup_status}
            stage={gates.startup_stage}
            progressPct={gates.startup_progress_pct}
          />
        )}

        {/* Metric Cards */}
        {summary && (
          <div className="grid grid-cols-2 lg:grid-cols-6 gap-3 lg:gap-4">
            <MetricCard
              label="Время работы"
              value={formatUptime(summary.uptime_seconds)}
              icon={<Clock size={14} className="lg:w-4 lg:h-4" />}
            />
            <MetricCard
              label="Всего соединений"
              value={formatNumber(summary.connections_total)}
              icon={<Activity size={14} className="lg:w-4 lg:h-4" />}
              variant="success"
            />
            <MetricCard
              label="Ошибочных соединений"
              value={formatNumber(summary.connections_bad_total)}
              variant={summary.connections_bad_total > 0 ? 'warning' : 'default'}
              status={summary.connections_bad_total > 0 ? 'warn' : 'ok'}
            />
            <MetricCard
              label="Пользователей"
              value={summary.configured_users}
              icon={<Users size={14} className="lg:w-4 lg:h-4" />}
            />
            <MetricCard
              label="Активных IP"
              value={formatNumber(totalActiveIPs)}
              icon={<Globe size={14} className="lg:w-4 lg:h-4" />}
            />
            <MetricCard
              label="Всего трафика"
              value={formatBytes(totalTraffic)}
              icon={<ArrowUpDown size={14} className="lg:w-4 lg:h-4" />}
            />
          </div>
        )}

        {/* Connection Errors breakdown */}
        {summary && (
          <ConnectionErrors
            badByClass={summary.connections_bad_by_class}
            handshakeFailuresByClass={summary.handshake_failures_by_class}
          />
        )}

        {/* System Info */}
        {system && (
          <CollapsibleSection title="Информация о системе">
            <div className="grid grid-cols-2 md:grid-cols-3 gap-2 lg:gap-3">
              {Object.entries(system).map(([key, value]) => {
                const { label, text, hint } = describeSystemField(key, value);
                return (
                  <div key={key} className="min-w-0">
                    <div className="text-xs text-text-secondary">{label}</div>
                    <div className="text-xs lg:text-sm text-text-primary truncate" title={String(value ?? '')}>
                      {typeof value === 'boolean' ? <StatusBadge status={value} /> : text}
                    </div>
                    {hint && <div className="text-[11px] text-text-secondary/70">{hint}</div>}
                  </div>
                );
              })}
            </div>
          </CollapsibleSection>
        )}

      </div>
    </div>
  );
}

/** Русские подписи для полей, которые движок отдаёт как есть. */
const SYSTEM_LABELS: Record<string, string> = {
  version: 'Версия движка',
  build_profile: 'Профиль сборки',
  config_hash: 'Хеш конфига',
  config_path: 'Путь к конфигу',
  config_reload_count: 'Перечитываний конфига',
  process_started_at_epoch_secs: 'Запущен',
  uptime_seconds: 'Работает',
  target_arch: 'Архитектура',
  target_os: 'Операционная система',
};

/** Значения, которые сами по себе ничего не говорят, поясняем. */
const VALUE_HINTS: Record<string, Record<string, string>> = {
  build_profile: {
    unknown: 'сборка не сообщает профиль — это нормально для релизов telemt',
    release: 'оптимизированная сборка',
    debug: 'отладочная сборка, медленнее релизной',
  },
};

function formatDuration(totalSeconds: number): string {
  const d = Math.floor(totalSeconds / 86400);
  const h = Math.floor((totalSeconds % 86400) / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const parts: string[] = [];
  if (d) parts.push(`${d} д`);
  if (h) parts.push(`${h} ч`);
  if (m || parts.length === 0) parts.push(`${m} мин`);
  return parts.join(' ');
}

/**
 * Приводит поле /v1/system к читаемому виду.
 *
 * Движок отдаёт сырые значения: время как epoch-секунды, аптайм в секундах,
 * профиль сборки как «unknown». Без обработки на дашборде получается список
 * чисел, по которому непонятно, что хорошо, а что плохо.
 */
function describeSystemField(
  key: string,
  value: unknown,
): { label: string; text: string; hint?: string } {
  const label = SYSTEM_LABELS[key] ?? key.replace(/_/g, ' ');
  const hint = typeof value === 'string' ? VALUE_HINTS[key]?.[value] : undefined;

  if (value === null || value === undefined || value === '') {
    return { label, text: '—' };
  }

  if (key === 'process_started_at_epoch_secs' && typeof value === 'number') {
    const when = new Date(value * 1000);
    return {
      label,
      text: when.toLocaleString('ru-RU'),
      hint: `${formatDuration(Math.max(0, Date.now() / 1000 - value))} назад`,
    };
  }

  if (key === 'uptime_seconds' && typeof value === 'number') {
    return { label, text: formatDuration(value) };
  }

  if (key === 'config_hash' && typeof value === 'string' && value.length > 16) {
    return { label, text: `${value.slice(0, 12)}…`, hint: 'меняется при правке конфига' };
  }

  // В режиме Manager движок работает в контейнере, и путь он сообщает свой,
  // внутренний. На хосте файла по этому пути нет — без пояснения это сбивает
  // с толку при попытке его открыть.
  if (key === 'config_path' && value === '/etc/telemt.toml') {
    return {
      label,
      text: String(value),
      hint: 'путь внутри контейнера; на хосте — /opt/mtproxyl/mtproxy/config.toml',
    };
  }

  return { label, text: String(value), hint };
}
