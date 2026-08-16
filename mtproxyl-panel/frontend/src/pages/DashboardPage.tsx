import { Header } from '@/components/layout/Header';
import { MetricCard } from '@/components/MetricCard';
import { StatusDot } from '@/components/StatusDot';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { StartupStatus } from '@/components/StartupStatus';
import { ProxyControls } from '@/components/ProxyControls';
import { ConnectionErrors, type ClassCount } from '@/components/ConnectionErrors';
import { AvailabilityCard } from '@/components/AvailabilityCard';
import { MtproxylUpdateBanner } from '@/components/MtproxylUpdateCard';
import { useWsSubscription, useEndpoint } from '@/hooks/useWebSocket';
import { usePolling } from '@/hooks/usePolling';
import { telemt, mtproxylSettingsApi } from '@/lib/api';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { formatUptime, formatNumber, formatBytes } from '@/lib/utils';
import { Activity, Clock, Users, ArrowUpDown, Globe } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState } from 'react';

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

interface DcEntry {
  dc: number;
  rtt_ms: number | null;
  alive_writers: number;
  required_writers: number;
  coverage_pct: number;
}

interface DcsData {
  middle_proxy_enabled: boolean;
  dcs: DcEntry[];
}

interface UserTrafficData {
  total_octets: number;
  active_unique_ips: number;
}

const ENDPOINTS = [
  '/v1/health', '/v1/stats/summary', '/v1/system/info', '/v1/runtime/gates', '/v1/stats/dcs',
];

/**
 * Порог покрытия DC на случай, когда настройку прочитать не удалось: у CLI и
 * бота значение по умолчанию то же. Настоящий берём из DC_THRESHOLD в
 * settings.conf — он общий на панель, бота и меню.
 */
const DC_THRESHOLD_FALLBACK = 80;

export function DashboardPage() {
  const { data: wsData, errors, connected, refresh } = useWsSubscription('dashboard', ENDPOINTS, 5);

  const health = useEndpoint<HealthData>(wsData, '/v1/health');
  const summary = useEndpoint<SummaryData>(wsData, '/v1/stats/summary');
  const system = useEndpoint<SystemInfoData>(wsData, '/v1/system/info');
  const gates = useEndpoint<GatesData>(wsData, '/v1/runtime/gates');
  const dcs = useEndpoint<DcsData>(wsData, '/v1/stats/dcs');

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

  const dcThreshold = useDcThreshold();

  return (
    <div>
      <Header title="Дашборд" refreshing={!connected} onRefresh={refresh} />

      <div className="p-4 lg:p-6 space-y-4 lg:space-y-6">
        {firstError && <ErrorAlert message={firstError} onRetry={refresh} />}

        <MtproxylUpdateBanner />

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

        <AvailabilityCard />

        {/* Startup Status */}
        {gates && (
          <StartupStatus
            status={gates.startup_status}
            stage={gates.startup_stage}
            progressPct={gates.startup_progress_pct}
          />
        )}

        {/* Запуск/перезапуск/остановка движка — только при включённом мосте
            MTProxyL: он знает, контейнер это или чужая цель. */}
        <ProxyControls />

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

        {/* Дата-центры Telegram: связь движка с Telegram, а не доступность
            прокси снаружи. Числа те же, что показывает `mtproxyl dc`. */}
        {dcs && (
          <DcCard
            data={dcs}
            threshold={dcThreshold.value}
            editable={dcThreshold.editable}
            onSave={dcThreshold.save}
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
/**
 * Порог покрытия DC. Живёт в настройках MTProxyL, потому что по нему пишет и
 * телеграм-бот: два независимых порога расходились бы, и панель показывала бы
 * «просело» тогда, когда бот молчит. У MTProxyL старее 1.5.0 настройки нет —
 * тогда показываем значение по умолчанию и не даём его править.
 */
function useDcThreshold() {
  const [value, setValue] = useState(DC_THRESHOLD_FALLBACK);
  const [editable, setEditable] = useState(false);

  useEffect(() => {
    mtproxylSettingsApi
      .list()
      .then((list) => {
        const found = list.find((p) => p.key === 'DC_THRESHOLD');
        if (!found) return;
        const n = Number(found.value);
        if (Number.isInteger(n) && n >= 0 && n <= 100) setValue(n);
        setEditable(true);
      })
      .catch(() => undefined);
  }, []);

  const save = useCallback(async (next: number) => {
    await mtproxylSettingsApi.set('DC_THRESHOLD', String(next));
    setValue(next);
  }, []);

  return { value, editable, save };
}

function DcCard({
  data,
  threshold,
  editable,
  onSave,
}: {
  data: DcsData;
  threshold: number;
  editable: boolean;
  onSave: (next: number) => Promise<void>;
}) {
  const rows = data.dcs ?? [];
  const alive = rows.reduce((s, d) => s + (d.alive_writers || 0), 0);
  const required = rows.reduce((s, d) => s + (d.required_writers || 0), 0);
  const coverage = required > 0 ? Math.min(100, Math.round((alive * 100) / required)) : 100;
  // Нулевой порог — предупреждения выключены: цифры показываем, приговор нет.
  const ok = threshold <= 0 || coverage >= threshold;
  const rowOk = (cov: number) => (threshold <= 0 ? cov > 0 : cov >= threshold);
  if (!data.middle_proxy_enabled || rows.length === 0) return null;
  return (
    <CollapsibleSection
      title={`Дата-центры Telegram — покрытие ${coverage}%${ok ? '' : ' (просело)'}`}
    >
      <div className="overflow-x-auto -mx-4 px-4">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-text-secondary border-b border-border">
              <th className="py-2 pr-4 font-medium">DC</th>
              <th className="py-2 pl-4 font-medium text-right">RTT</th>
              <th className="py-2 pl-4 font-medium text-right">Писатели</th>
              <th className="py-2 pl-4 font-medium text-right">Покрытие</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((d) => {
              const cov = Math.round(d.coverage_pct ?? 0);
              return (
                <tr key={d.dc} className="border-b border-border last:border-0">
                  <td className="py-2 pr-4 text-text-primary">
                    <StatusDot status={rowOk(cov) ? 'ok' : 'warn'} size="sm" /> DC {d.dc}
                  </td>
                  <td className="py-2 pl-4 text-right font-mono text-xs">
                    {d.rtt_ms == null ? '—' : `${Math.round(d.rtt_ms)} мс`}
                  </td>
                  <td className="py-2 pl-4 text-right font-mono text-xs">
                    {d.alive_writers} / {d.required_writers}
                  </td>
                  <td className={`py-2 pl-4 text-right ${rowOk(cov) ? '' : 'text-warning'}`}>
                    {cov}%
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <p className="text-xs text-text-secondary/70 mt-2">
        Писателей живо {alive} из {required}. Это связь движка с Telegram, а не доступность
        прокси для клиентов.
      </p>
      <DcThresholdForm threshold={threshold} editable={editable} onSave={onSave} />
    </CollapsibleSection>
  );
}

/**
 * Порог, ниже которого покрытие считается просевшим. Тот же, по которому пишет
 * телеграм-бот, поэтому его правка отсюда меняет и уведомления. Ноль —
 * предупреждений нет ни здесь, ни в боте.
 */
function DcThresholdForm({
  threshold,
  editable,
  onSave,
}: {
  threshold: number;
  editable: boolean;
  onSave: (next: number) => Promise<void>;
}) {
  const [draft, setDraft] = useState(String(threshold));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    setDraft(String(threshold));
  }, [threshold]);

  if (!editable) {
    return (
      <p className="text-xs text-text-secondary/70 mt-1">
        Порог {threshold}% задаётся в MTProxyL: <code>mtproxyl dc threshold</code>.
      </p>
    );
  }

  const submit = async () => {
    const n = Number(draft.trim());
    if (!Number.isInteger(n) || n < 0 || n > 100) {
      setError('Порог: целое число от 0 до 100');
      return;
    }
    setSaving(true);
    setError(null);
    setSaved(false);
    try {
      await onSave(n);
      setSaved(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить порог');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="mt-3 flex items-center gap-2 flex-wrap text-xs text-text-secondary">
      <span>Порог, %:</span>
      <Input
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        inputMode="numeric"
        className="w-20 h-8"
      />
      <Button onClick={submit} disabled={saving || draft === String(threshold)} size="sm" variant="outline">
        {saving ? 'Сохраняем…' : 'Сохранить'}
      </Button>
      <span>0 — не предупреждать; тот же порог использует телеграм-бот.</span>
      {saved && !error && <span className="text-success">Сохранено</span>}
      {error && <span className="text-danger">{error}</span>}
    </div>
  );
}

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
