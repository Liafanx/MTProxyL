import { Header } from '@/components/layout/Header';
import { MetricCard } from '@/components/MetricCard';
import { ErrorAlert } from '@/components/ErrorAlert';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { StartupStatus } from '@/components/StartupStatus';
import { ProxyControls } from '@/components/ProxyControls';
import { ConnectionErrors, type ClassCount } from '@/components/ConnectionErrors';
import { AvailabilityCard } from '@/components/AvailabilityCard';
import { MtproxylUpdateBanner } from '@/components/MtproxylUpdateCard';
import { HealthBanner, type HealthFact } from '@/components/HealthBanner';
import { ProblemsCard, type ProblemItem } from '@/components/ProblemsCard';
import { StatePill, type PillState } from '@/components/ui/state-pill';
import { StatusBadge } from '@/components/StatusBadge';
import { useWsSubscription, useEndpoint } from '@/hooks/useWebSocket';
import { usePolling } from '@/hooks/usePolling';
import { useHistorySeries } from '@/hooks/useHistorySeries';
import { gaugeValues, rateValues, windowDelta } from '@/lib/history';
import { LoadCard } from '@/components/LoadCard';
import { useMtproxyl } from '@/hooks/useMtproxyl';
import { telemt, mtproxylSettingsApi, availabilityApi, type AvailabilityStatusResponse } from '@/lib/api';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { formatUptime, formatNumber, formatBytes, cn } from '@/lib/utils';
import { Activity, Clock, Users, ArrowUpDown, Globe, ShieldAlert } from 'lucide-react';
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

/** Запасное значение, если DC_THRESHOLD не прочитался: как у CLI и бота. */
const DC_THRESHOLD_FALLBACK = 80;

export function DashboardPage() {
  const { data: wsData, errors, connected, refresh } = useWsSubscription('dashboard', ENDPOINTS, 5);

  const health = useEndpoint<HealthData>(wsData, '/v1/health');
  const summary = useEndpoint<SummaryData>(wsData, '/v1/stats/summary');
  const system = useEndpoint<SystemInfoData>(wsData, '/v1/system/info');
  const gates = useEndpoint<GatesData>(wsData, '/v1/runtime/gates');
  const dcs = useEndpoint<DcsData>(wsData, '/v1/stats/dcs');
  const { enabled: mtproxylEnabled, mode: mtproxylMode } = useMtproxyl();

  const { data: usersData } = usePolling<UserTrafficData[]>(
    () => telemt.get('/v1/users'),
    10000
  );

  const { data: availability } = usePolling<AvailabilityStatusResponse>(
    () => availabilityApi.status(),
    60000,
  );

  const totalTraffic = useMemo(() => {
    if (!usersData) return 0;
    return usersData.reduce((sum, u) => sum + u.total_octets, 0);
  }, [usersData]);

  const totalActiveIPs = useMemo(() => {
    if (!usersData) return 0;
    return usersData.reduce((sum, u) => sum + u.active_unique_ips, 0);
  }, [usersData]);

  const history = useHistorySeries(
    ['connections', 'refusals', 'active_ips', 'traffic', 'current_connections', 'active_users'],
    '30m',
    10_000,
  );
  const connectionsSeries = rateValues(history.series.connections);
  const badSeries = rateValues(history.series.refusals);
  const trafficSeries = rateValues(history.series.traffic);
  const ipsSeries = gaugeValues(history.series.active_ips);
  const connectionsDelta = windowDelta(history.series.connections);
  const badDelta = windowDelta(history.series.refusals);
  const trafficDelta = windowDelta(history.series.traffic);
  const telemetryOff =
    history.series.connections?.state === 'ready' &&
    (history.series.current_connections?.state ?? 'empty') === 'empty';

  const isHealthy = health?.status === 'ok';
  const firstError = Object.values(errors)[0];

  const dcThreshold = useDcThreshold();
  const dcSummary = useMemo(() => summarizeDcs(dcs, dcThreshold.value), [dcs, dcThreshold.value]);

  const badRecent = badDelta ?? 0;
  const startupStatus = gates?.startup_status?.toLowerCase();
  const starting = startupStatus !== undefined && startupStatus !== 'ready' && startupStatus !== 'done';

  const hero = describeHealth({ health, connected, hasData: Boolean(summary), starting, dcOk: dcSummary?.ok ?? true, availability: availability?.status?.level });

  const facts: HealthFact[] = [];
  if (typeof system?.version === 'string') facts.push({ key: 'version', label: 'Версия', value: system.version });
  if (summary) facts.push({ key: 'uptime', label: 'Работает', value: formatUptime(summary.uptime_seconds) });
  if (summary) facts.push({ key: 'users', label: 'Пользователей', value: summary.configured_users });
  if (mtproxylEnabled && mtproxylMode) {
    facts.push({ key: 'mode', label: 'Режим', value: mtproxylMode === 'manager' ? 'Manager' : 'Reanimator' });
  }

  const problems: ProblemItem[] = [];
  if (!connected) {
    problems.push({ key: 'ws', severity: 'warn', label: 'Нет живого соединения с панелью', detail: 'Данные обновятся после переподключения WebSocket.' });
  }
  if (connected && health && !isHealthy) {
    problems.push({ key: 'health', severity: 'error', label: 'Telemt не отвечает', detail: `Состояние: ${health.status}`, to: '/logs' });
  }
  if (health?.read_only) {
    problems.push({ key: 'ro', severity: 'warn', label: 'API движка в режиме «только чтение»', detail: 'Изменения конфигурации и пользователей сейчас недоступны.', to: '/config' });
  }
  if (starting) {
    problems.push({ key: 'startup', severity: 'warn', label: 'Движок ещё запускается', detail: gates?.startup_stage ? `Этап: ${gates.startup_stage}` : undefined });
  }
  if (dcSummary && !dcSummary.ok) {
    problems.push({
      key: 'dc',
      severity: dcSummary.zero.length > 0 ? 'error' : 'warn',
      label: `Покрытие дата-центров ${dcSummary.coverage}%`,
      detail: dcSummary.zero.length > 0
        ? `Без писателей: ${dcSummary.zero.map((d) => `DC ${d}`).join(', ')}`
        : `Ниже порога ${dcThreshold.value}%`,
      to: '/upstreams',
    });
  }
  if (badRecent > 0) {
    problems.push({ key: 'bad', severity: 'info', label: `Ошибочных соединений за 15 минут: ${formatNumber(badRecent)}`, detail: 'Разбивка по классам ниже.', to: '/security' });
  }
  if (availability?.enabled && availability.status && availability.status.level !== 'green') {
    problems.push({
      key: 'availability',
      severity: availability.status.level === 'red' ? 'error' : 'warn',
      label: availability.status.level === 'red' ? 'Прокси не виден из России' : 'Прокси виден из России частично',
      detail: `${availability.status.percentage.toFixed(0)}% зондов дошли (${availability.status.success_probes}/${availability.status.total_probes})`,
      to: '/availability',
    });
  }

  return (
    <div>
      <Header title="Дашборд" refreshing={!connected} onRefresh={refresh} />

      <div className="p-4 lg:p-6 space-y-4 lg:space-y-5">
        {firstError && <ErrorAlert message={firstError} onRetry={refresh} />}

        <MtproxylUpdateBanner />

        <HealthBanner
          state={hero.state}
          title={hero.title}
          detail={hero.detail}
          facts={facts}
          aside={
            <>
              {!connected && <StatePill state="warn">переподключение</StatePill>}
              {health?.read_only && <StatePill state="warn">только чтение</StatePill>}
            </>
          }
        />

        {/* Metric Cards */}
        {summary && (
          <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6 lg:gap-4">
            <MetricCard
              label="Время работы"
              value={formatUptime(summary.uptime_seconds)}
              icon={<Clock size={14} />}
            />
            <MetricCard
              label="Всего соединений"
              value={formatNumber(summary.connections_total)}
              icon={<Activity size={14} />}
              variant="success"
              series={connectionsSeries}
              caption={connectionsDelta === null ? undefined : `+${formatNumber(connectionsDelta)} за 15 мин`}
            />
            <MetricCard
              label="Ошибочных соединений"
              value={formatNumber(summary.connections_bad_total)}
              icon={<ShieldAlert size={14} />}
              variant={summary.connections_bad_total > 0 ? 'warning' : 'default'}
              status={badRecent > 0 ? 'warn' : 'ok'}
              series={badSeries}
              caption={badDelta === null ? undefined : `+${formatNumber(badDelta)} за 15 мин`}
            />
            <MetricCard
              label="Пользователей"
              value={summary.configured_users}
              icon={<Users size={14} />}
            />
            <MetricCard
              label="Активных IP"
              value={formatNumber(totalActiveIPs)}
              icon={<Globe size={14} />}
              series={ipsSeries}
            />
            <MetricCard
              label="Всего трафика"
              value={formatBytes(totalTraffic)}
              icon={<ArrowUpDown size={14} />}
              series={trafficSeries}
              caption={trafficDelta === null ? undefined : `+${formatBytes(trafficDelta)} за 15 мин`}
            />
          </div>
        )}

        <ProblemsCard items={problems} />

        {!history.disabled && (
          <LoadCard
            connections={history.series.current_connections}
            activeUsers={history.series.active_users}
            telemetryOff={telemetryOff}
            loading={history.loading}
          />
        )}

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
                    <div className="text-micro text-text-muted">{label}</div>
                    <div className="text-xs lg:text-sm text-text truncate" title={String(value ?? '')}>
                      {typeof value === 'boolean' ? <StatusBadge status={value} /> : text}
                    </div>
                    {hint && <div className="text-[11px] text-text-faint">{hint}</div>}
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

function describeHealth(input: {
  health: HealthData | null;
  connected: boolean;
  hasData: boolean;
  starting: boolean;
  dcOk: boolean;
  availability?: 'green' | 'yellow' | 'red';
}): { state: PillState; title: string; detail?: string } {
  if (!input.hasData && !input.health) {
    return { state: 'muted', title: 'Ждём данные движка', detail: 'Панель подключается к API Telemt.' };
  }
  if (input.health && input.health.status !== 'ok') {
    return { state: 'error', title: 'Telemt недоступен', detail: `API ответил состоянием «${input.health.status}».` };
  }
  if (input.starting) {
    return { state: 'warn', title: 'Движок запускается', detail: 'Клиенты подключатся, когда запуск завершится.' };
  }
  if (input.availability === 'red') {
    return { state: 'error', title: 'Работает, но не виден из России', detail: 'Последняя проверка зондами не дошла до прокси.' };
  }
  if (!input.dcOk || input.availability === 'yellow' || !input.connected) {
    return { state: 'warn', title: 'Работает с замечаниями', detail: 'Подробности в списке проблем ниже.' };
  }
  return { state: 'ok', title: 'Telemt работает', detail: 'Клиенты принимаются, связь с Telegram в норме.' };
}

interface DcSummary {
  ok: boolean;
  coverage: number;
  alive: number;
  required: number;
  covered: number;
  zero: number[];
}

function summarizeDcs(data: DcsData | null, threshold: number): DcSummary | null {
  if (!data || !data.middle_proxy_enabled || !data.dcs?.length) return null;
  const rows = data.dcs;
  const alive = rows.reduce((s, d) => s + (d.alive_writers || 0), 0);
  const required = rows.reduce((s, d) => s + (d.required_writers || 0), 0);
  const covered = rows.reduce((sum, dc) => sum + Math.min(dc.alive_writers || 0, dc.required_writers || 0), 0);
  const coverage = required > 0 ? Math.round((covered * 100) / required) : 0;
  const zero = rows.filter((dc) => dc.required_writers > 0 && dc.alive_writers === 0).map((dc) => dc.dc);
  // Нулевой порог выключает процентный приговор, но пустой DC остаётся фактом.
  const ok = zero.length === 0 && (threshold <= 0 || coverage >= threshold);
  return { ok, coverage, alive, required, covered, zero };
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
  const summary = summarizeDcs(data, threshold);
  if (!summary) return null;
  const rowOk = (cov: number) => (threshold <= 0 ? cov > 0 : cov >= threshold);
  return (
    <section className="rounded-xl border border-border bg-surface p-4">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-[13px] font-semibold text-text">Дата-центры Telegram</h3>
        <StatePill state={summary.ok ? 'ok' : summary.zero.length > 0 ? 'error' : 'warn'}>
          покрытие {summary.coverage}%
        </StatePill>
      </div>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-5">
        {rows.map((d) => {
          const cov = Math.round(d.coverage_pct ?? 0);
          const ok = rowOk(cov);
          const empty = d.required_writers > 0 && d.alive_writers === 0;
          return (
            <div key={d.dc} className="flex gap-3 rounded-lg bg-bg p-3">
              <div className="flex h-14 w-2 shrink-0 flex-col justify-end overflow-hidden rounded-full bg-bar-track" aria-hidden="true">
                <div
                  className={cn('w-full rounded-full', empty ? 'bg-bar-fill-full' : ok ? 'bg-bar-fill' : 'bg-bar-fill-warn')}
                  style={{ height: `${Math.max(cov > 0 ? 6 : 0, Math.min(100, cov))}%` }}
                />
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline justify-between gap-2">
                  <span className="text-row font-semibold text-text">DC {d.dc}</span>
                  <span className={cn('font-mono text-[15px] font-bold tabular-nums', empty ? 'text-error' : ok ? 'text-text' : 'text-warn')}>{cov}%</span>
                </div>
                <div className="mt-1 text-micro text-text-muted">
                  {d.alive_writers} / {d.required_writers} пис.
                </div>
                <div className="text-micro text-text-faint">
                  {d.rtt_ms == null ? 'RTT —' : `RTT ${Math.round(d.rtt_ms)} мс`}
                </div>
              </div>
            </div>
          );
        })}
      </div>
      <p className="mt-3 text-micro leading-relaxed text-text-faint">
        В зачёт покрытия {summary.covered} из {summary.required}; живых всего {summary.alive}.
        {summary.zero.length > 0 && ` Без писателей: ${summary.zero.map((dc) => `DC ${dc}`).join(', ')}.`}
        {' '}Это связь движка с Telegram, а не доступность прокси для клиентов.
      </p>
      <DcThresholdForm threshold={threshold} editable={editable} onSave={onSave} />
    </section>
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
/** Порог покрытия DC из настроек MTProxyL — он общий с телеграм-ботом. */
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

/** Порог просадки: тот же, по которому пишет бот. Ноль — не предупреждать. */
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
