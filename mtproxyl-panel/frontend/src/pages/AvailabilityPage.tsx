import { useCallback, useEffect, useMemo, useState } from 'react';
import { RefreshCw, ChevronDown, ChevronUp, CheckCircle2, XCircle, ExternalLink, Target, Activity } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Chip } from '@/components/ui/chip';
import { Input } from '@/components/ui/input';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { ErrorAlert } from '@/components/ErrorAlert';
import {
  availabilityApi,
  type AvailabilityResult,
  type AvailabilityProbe,
  type AvailabilityLevel,
  type AvailabilityQuota,
  type AvailabilitySchedule,
  type AvailabilityTargetResponse,
  type AvailabilityHistoryPoint,
  type AvailabilityHistoryResponse,
} from '@/lib/api';
import { cn } from '@/lib/utils';

const LEVEL_TEXT_CLASS: Record<AvailabilityLevel, string> = {
  green: 'text-success',
  yellow: 'text-warning',
  red: 'text-danger',
};

const LEVEL_LABEL: Record<AvailabilityLevel, string> = {
  green: 'доступен',
  yellow: 'частично доступен',
  red: 'недоступен',
};

export function AvailabilityPage() {
  const [enabled, setEnabled] = useState(true);
  const [result, setResult] = useState<AvailabilityResult | null>(null);
  const [quota, setQuota] = useState<AvailabilityQuota | undefined>();
  const [autoCheck, setAutoCheck] = useState(true);
  const [schedule, setSchedule] = useState<AvailabilitySchedule>({});
  const [history, setHistory] = useState<AvailabilityHistoryPoint[]>([]);
  const [historyLimit, setHistoryLimit] = useState(1000);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | undefined>();
  const [loading, setLoading] = useState(true);
  const [checking, setChecking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<number | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await availabilityApi.details();
      setEnabled(res.enabled);
      setResult(res.result ?? null);
      setQuota(res.quota);
      setAutoCheck(res.auto_check ?? true);
      setSchedule(res);
      setMessage(res.message);
      setError(null);
      try {
        const historyRes = await availabilityApi.history();
        setHistory(historyRes.points ?? []);
        setHistoryLimit(historyRes.limit || res.history_limit || 1000);
        setHistoryError(null);
      } catch (historyErr) {
        setHistoryError(historyErr instanceof Error ? historyErr.message : 'Не удалось загрузить историю');
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось загрузить результаты проверки');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const check = async () => {
    setChecking(true);
    setError(null);
    try {
      const res = await availabilityApi.check();
      setEnabled(res.enabled);
      setResult(res.result ?? null);
      setMessage(res.message);
      // Проверка отвечает одним результатом — квоту и расписание она не
      // пересчитывает, а потраченные кредиты показать надо.
      void load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить проверку');
    } finally {
      setChecking(false);
    }
  };

  return (
    <div>
      <Header title="Доступность из России" refreshing={loading} onRefresh={load} />

      <div className="p-4 lg:p-6 space-y-4 lg:space-y-6">
        <div className="flex items-start justify-between gap-4 flex-wrap">
          <p className="text-sm text-text-secondary max-w-2xl">
            Проверка через{' '}
            <a
              href="https://globalping.io"
              target="_blank"
              rel="noopener noreferrer"
              className="text-accent hover:underline"
            >
              Globalping API
            </a>{' '}
            — HTTPS HEAD запросы с российских резидентских (eyeball) зондов.
            Критерий успеха — получение TLS-сертификата, то же рукопожатие,
            что делает клиент Telegram.
          </p>
          <Button onClick={check} disabled={checking || !enabled} className="gap-2 shrink-0">
            <RefreshCw size={14} className={cn(checking && 'animate-spin')} />
            {checking ? 'Проверяем…' : 'Проверить сейчас'}
          </Button>
        </div>

        {error && <ErrorAlert message={error} onRetry={load} />}

        {enabled && (
          <AutoCheckToggle enabled={autoCheck} schedule={schedule} onChange={setAutoCheck} />
        )}

        {enabled && <QuotaBanner quota={quota} />}

        {enabled && (
          <AvailabilityHistoryCard
            points={history}
            limit={historyLimit}
            threshold={schedule.threshold}
            error={historyError}
            onChanged={(next) => {
              setHistory(next.points ?? []);
              setHistoryLimit(next.limit);
              setHistoryError(null);
            }}
          />
        )}

        {enabled && <TokenForm hasToken={quota?.has_token ?? false} onSaved={load} />}

        {enabled && <TargetForm onSaved={load} />}

        {!enabled ? (
          <Card className="p-6 text-sm text-text-secondary">
            {message || 'Проверка доступности недоступна'}
          </Card>
        ) : !result ? (
          <Card className="p-6 text-sm text-text-secondary text-center">
            {message || 'Проверки ещё не проводились'}
          </Card>
        ) : (
          <>
            <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 lg:gap-4">
              <StatCard
                label="Доступность"
                value={`${result.percentage.toFixed(0)}%`}
                valueClass={LEVEL_TEXT_CLASS[result.level]}
                extra={
                  <span className={cn('text-xs', LEVEL_TEXT_CLASS[result.level])}>
                    {LEVEL_LABEL[result.level]}
                  </span>
                }
              />
              <StatCard
                label="Успешные зонды"
                value={`${result.success_probes} / ${result.total_probes}`}
              />
              <StatCard label="Цель проверки" value={result.target} small />
              <StatCard
                label="Время проверки"
                value={new Date(result.checked_at).toLocaleString('ru-RU')}
                small
                extra={
                  result.measurement_id ? (
                    <a
                      href={`https://api.globalping.io/v1/measurements/${result.measurement_id}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-xs text-accent hover:underline flex items-center gap-1"
                    >
                      JSON в Globalping <ExternalLink size={12} />
                    </a>
                  ) : undefined
                }
              />
            </div>

            {result.error && <ErrorAlert message={result.error} />}

            {result.probes && result.probes.length > 0 && (
              <Card className="overflow-hidden">
                <div className="p-4 border-b border-border">
                  <h3 className="text-sm font-medium text-text-primary">
                    Результаты по зондам ({result.probes.length})
                  </h3>
                </div>
                <div className="divide-y divide-border">
                  {result.probes.map((probe, idx) => (
                    <ProbeRow
                      key={idx}
                      probe={probe}
                      expanded={expanded === idx}
                      onToggle={() => setExpanded(expanded === idx ? null : idx)}
                    />
                  ))}
                </div>
              </Card>
            )}
          </>
        )}
      </div>
    </div>
  );
}

/** Русское склонение для числительных: 1 минута, 2 минуты, 5 минут. */
function plural(n: number, one: string, few: string, many: string): string {
  const mod10 = n % 10;
  const mod100 = n % 100;
  if (mod10 === 1 && mod100 !== 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}

/** Расписание берём из ответа CLI: период задаётся в MTProxyL, не здесь. */
function scheduleLine(s: AvailabilitySchedule): string {
  const parts: string[] = [];
  if (s.interval && s.interval > 0) {
    parts.push(`Проверка идёт сама раз в ${s.interval} ${plural(s.interval, 'минуту', 'минуты', 'минут')}`);
  } else {
    parts.push('Проверка идёт сама по расписанию');
  }
  if (s.probes && s.probes > 0) {
    parts.push(`${s.probes} ${plural(s.probes, 'зонд', 'зонда', 'зондов')} за раз`);
  }
  if (s.next_run) {
    const at = new Date(s.next_run);
    if (!Number.isNaN(at.getTime())) {
      parts.push(`следующая в ${at.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })}`);
    }
  }
  return parts.join(' · ');
}

/**
 * Проверка по расписанию. Выключенная не отменяет «Проверить сейчас» — она для
 * тех, кто хочет проверять руками и не тратить квоту фоном.
 */
function AutoCheckToggle({
  enabled,
  schedule,
  onChange,
}: {
  enabled: boolean;
  schedule: AvailabilitySchedule;
  onChange: (v: boolean) => void;
}) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const toggle = async () => {
    const next = !enabled;
    setSaving(true);
    setError(null);
    try {
      const res = await availabilityApi.setAutoCheck(next);
      onChange(res.auto_check);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="flex items-center justify-between gap-3 bg-surface border border-border rounded-lg p-3 flex-wrap">
      <div className="text-sm">
        <span className="text-text-primary">Автопроверка</span>
        <span className={cn('ml-2 font-medium', enabled ? 'text-success' : 'text-text-secondary')}>
          {enabled ? 'включена' : 'выключена'}
        </span>
        <div className="text-xs text-text-secondary mt-0.5">
          {enabled ? scheduleLine(schedule) : 'Проверки идут только по кнопке «Проверить сейчас»'}
        </div>
        {enabled && schedule.timer_active === false && (
          <div className="text-xs text-warning mt-0.5">
            Таймер не запущен — по расписанию проверок не будет
          </div>
        )}
        {error && <div className="text-xs text-danger mt-1">{error}</div>}
      </div>
      <Button onClick={toggle} disabled={saving} size="sm" variant="outline">
        {saving ? 'Сохраняем…' : enabled ? 'Выключить' : 'Включить'}
      </Button>
    </div>
  );
}

/**
 * Остаток часовой квоты. Globalping считает кредиты по зондам, и когда
 * «Проверить сейчас» отказывает, причина почти всегда здесь — без этой строки
 * отказ выглядел бы поломкой.
 */
function QuotaBanner({ quota }: { quota?: AvailabilityQuota }) {
  if (!quota) return null;

  const low = quota.remaining < 20;
  const resetMin = Math.ceil(quota.reset_in_seconds / 60);

  return (
    <div className="text-xs text-text-secondary flex items-center gap-2 flex-wrap">
      <span>
        Квота Globalping:{' '}
        <span className={cn('font-medium', low ? 'text-warning' : 'text-text-primary')}>
          {quota.remaining} из {quota.budget}
        </span>{' '}
        кредитов на час (один зонд — один кредит)
      </span>
      {quota.spent > 0 && resetMin > 0 && <span>• обновление через {resetMin} мин</span>}
      <span>• лимит держит сам сервис: закончится — скажет ответом на проверку</span>
    </div>
  );
}

/**
 * Токен Globalping. Обратно не приходит — только признак, что он сохранён:
 * возить секрет в браузер на каждую загрузку страницы незачем.
 */
function TokenForm({ hasToken, onSaved }: { hasToken: boolean; onSaved: () => void }) {
  const [value, setValue] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const submit = async (token: string) => {
    setSaving(true);
    setError(null);
    setSaved(false);
    try {
      await availabilityApi.setToken(token);
      setValue('');
      setSaved(true);
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить токен');
    } finally {
      setSaving(false);
    }
  };

  return (
    <CollapsibleSection
      title="Токен Globalping"
      defaultOpen={false}
      badge={<Badge variant={hasToken ? 'success' : 'outline'}>{hasToken ? 'задан' : 'не задан'}</Badge>}
    >
      <p className="text-xs text-text-secondary mb-3">
        Бесплатный токен удваивает часовой лимит — 500 кредитов вместо 250. Получить:{' '}
        <a
          href="https://dash.globalping.io/"
          target="_blank"
          rel="noopener noreferrer"
          className="text-accent hover:underline"
        >
          dash.globalping.io
        </a>{' '}
        → Tokens. Обратно токен не показывается, только заменяется.
      </p>
      <div className="flex items-center gap-2 flex-wrap">
        <Input
          type="password"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder={hasToken ? 'заменить на новый' : 'вставьте токен'}
          spellCheck={false}
          className="max-w-[280px]"
        />
        <Button onClick={() => submit(value.trim())} disabled={saving || !value.trim()} size="sm">
          {saving ? 'Сохраняем…' : 'Сохранить'}
        </Button>
        {hasToken && (
          <Button onClick={() => submit('')} disabled={saving} size="sm" variant="outline">
            Убрать
          </Button>
        )}
        {saved && !error && <span className="text-xs text-success">Сохранено</span>}
      </div>
      {error && (
        <div className="mt-2">
          <ErrorAlert message={error} />
        </div>
      )}
    </CollapsibleSection>
  );
}

/**
 * Что именно проверять. Автоопределение верно для обычной установки и слепо
 * там, где адрес прокси знает только оператор: прокси за CDN, второй домен на
 * том же сервере, проброшенный порт. Пустое поле — «определить самому», в
 * подсказке при этом стоит то, что подставится.
 */
function TargetForm({ onSaved }: { onSaved: () => void }) {
  const [data, setData] = useState<AvailabilityTargetResponse | null>(null);
  const [host, setHost] = useState('');
  const [port, setPort] = useState('');
  const [sni, setSni] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const apply = useCallback((res: AvailabilityTargetResponse) => {
    setData(res);
    setHost(res.override.host ?? '');
    setPort(res.override.port ? String(res.override.port) : '');
    setSni(res.override.sni ?? '');
  }, []);

  useEffect(() => {
    availabilityApi
      .target()
      .then(apply)
      .catch((e) => setError(e instanceof Error ? e.message : 'Не удалось загрузить цель проверки'));
  }, [apply]);

  const save = async () => {
    setSaving(true);
    setError(null);
    setSaved(false);
    try {
      const portNum = port.trim() ? Number(port.trim()) : undefined;
      if (portNum !== undefined && (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535)) {
        setError('Порт должен быть числом от 1 до 65535');
        return;
      }
      const res = await availabilityApi.saveTarget({
        host: host.trim() || undefined,
        port: portNum,
        sni: sni.trim() || undefined,
      });
      apply(res);
      setSaved(true);
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить цель проверки');
    } finally {
      setSaving(false);
    }
  };

  const reset = async () => {
    setHost('');
    setPort('');
    setSni('');
    setSaving(true);
    setError(null);
    setSaved(false);
    try {
      apply(await availabilityApi.saveTarget({}));
      setSaved(true);
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сбросить цель проверки');
    } finally {
      setSaving(false);
    }
  };

  const overridden = Boolean(data?.override.host || data?.override.port || data?.override.sni);
  const resolved = data?.resolved;

  return (
    <CollapsibleSection
      title="Что проверять"
      defaultOpen={false}
      badge={
        <Badge variant={overridden ? 'default' : 'outline'}>
          {overridden ? 'задано вручную' : 'определяется автоматически'}
        </Badge>
      }
    >
      <p className="text-xs text-text-secondary mb-3">
        Пустое поле — определить автоматически; в подсказке показано, что подставится.
        Пригодится, когда прокси доступен по другому домену, чем определяет сервер.
      </p>

      {resolved?.error && <ErrorAlert message={resolved.error} />}

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <label className="flex flex-col gap-1">
          <span className="text-xs text-text-secondary">Адрес или домен</span>
          <Input
            value={host}
            onChange={(e) => setHost(e.target.value)}
            placeholder={resolved?.host || 'определяется автоматически'}
            spellCheck={false}
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-text-secondary">Порт</span>
          <Input
            value={port}
            onChange={(e) => setPort(e.target.value)}
            placeholder={resolved?.port ? String(resolved.port) : '443'}
            inputMode="numeric"
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-text-secondary">Fake SNI</span>
          <Input
            value={sni}
            onChange={(e) => setSni(e.target.value)}
            placeholder={resolved?.sni || 'без SNI'}
            spellCheck={false}
          />
        </label>
      </div>

      {error && (
        <div className="mt-3">
          <ErrorAlert message={error} />
        </div>
      )}

      <div className="flex items-center gap-2 mt-3 flex-wrap">
        <Button onClick={save} disabled={saving} size="sm" className="gap-2">
          <Target size={14} />
          {saving ? 'Сохраняем…' : 'Сохранить'}
        </Button>
        <Button onClick={reset} disabled={saving || !overridden} size="sm" variant="outline">
          Вернуть автоопределение
        </Button>
        {saved && !error && (
          <span className="text-xs text-success">
            Сохранено — применится со следующей проверкой
          </span>
        )}
      </div>
    </CollapsibleSection>
  );
}

type HistoryScope = 50 | 200 | 'all';

/**
 * Временной график строится по проценту, но каждая точка показывает свою
 * фактическую дробь successful/total. Это важно: число доступных российских
 * зондов меняется от проверки к проверке и не обязано совпадать с настройкой.
 */
function AvailabilityHistoryCard({
  points,
  limit,
  threshold,
  error,
  onChanged,
}: {
  points: AvailabilityHistoryPoint[];
  limit: number;
  threshold?: number;
  error: string | null;
  onChanged: (result: AvailabilityHistoryResponse) => void;
}) {
  const [scope, setScope] = useState<HistoryScope>(50);
  const [selected, setSelected] = useState<AvailabilityHistoryPoint | null>(null);
  const [limitValue, setLimitValue] = useState(String(limit));
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  useEffect(() => setLimitValue(String(limit)), [limit]);

  const ordered = useMemo(
    () => points
      .filter((point) => !Number.isNaN(new Date(point.checked_at).getTime()))
      .slice()
      .sort((a, b) => new Date(a.checked_at).getTime() - new Date(b.checked_at).getTime()),
    [points],
  );
  const visible = useMemo(
    () => (scope === 'all' ? ordered : ordered.slice(-scope)),
    [ordered, scope],
  );
  const chartPoints = useMemo(() => compactChartPoints(visible, 2000), [visible]);

  useEffect(() => {
    setSelected(visible[visible.length - 1] ?? null);
  }, [visible]);

  const saveLimit = async () => {
    const next = Number(limitValue);
    if (!Number.isInteger(next) || next < 1 || next > 100000) {
      setSaveError('Укажите целое число от 1 до 100000');
      return;
    }
    if (next < limit && ordered.length > next && !window.confirm(
      `Оставить только ${next} последних проверок? Более старые точки будут удалены без возможности восстановления.`,
    )) {
      return;
    }
    setSaving(true);
    setSaveError(null);
    try {
      onChanged(await availabilityApi.setHistoryLimit(next));
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Не удалось изменить размер истории');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Card className="p-4 lg:p-5 space-y-4">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h3 className="text-sm font-medium text-text-primary flex items-center gap-2">
            <Activity size={16} className="text-accent" />
            История доступности
          </h3>
          <p className="text-xs text-text-secondary mt-1">
            Процент нормализует проверки с разным числом зондов; наведите или нажмите точку,
            чтобы увидеть фактический результат. Уменьшение лимита удаляет старые точки.
          </p>
        </div>
        <div className="flex items-end gap-2 flex-wrap">
          <label className="flex flex-col gap-1">
            <span className="text-[11px] text-text-secondary">Хранить проверок</span>
            <Input
              type="number"
              min={1}
              max={100000}
              value={limitValue}
              onChange={(e) => setLimitValue(e.target.value)}
              className="w-32 h-9"
            />
          </label>
          <Button
            size="sm"
            variant="outline"
            disabled={saving || limitValue === String(limit)}
            onClick={saveLimit}
          >
            {saving ? 'Сохраняем…' : 'Применить'}
          </Button>
        </div>
      </div>

      {saveError && <ErrorAlert message={saveError} />}
      {error && <ErrorAlert message={`История недоступна: ${error}`} />}

      {!error && ordered.length === 0 ? (
        <div className="h-40 flex items-center justify-center text-sm text-text-secondary border border-dashed border-border rounded-lg">
          График появится после первой проверки
        </div>
      ) : !error ? (
        <>
          <div className="flex items-center justify-between gap-3 flex-wrap">
            <div className="flex items-center gap-1" aria-label="Период графика">
              {([50, 200, 'all'] as HistoryScope[]).map((value) => (
                <Chip key={String(value)} active={scope === value} onClick={() => setScope(value)}>
                  {value === 'all' ? 'Все' : `Последние ${value}`}
                </Chip>
              ))}
            </div>
            <span className="text-xs text-text-secondary">
              Показано {visible.length} из {ordered.length} · лимит {limit}
            </span>
          </div>

          <AvailabilityChart points={chartPoints} threshold={threshold} selected={selected} onSelect={setSelected} />

          {chartPoints.length > 1 && (
            <label className="block">
              <span className="sr-only">Выбрать точку истории</span>
              <input
                type="range"
                min={0}
                max={chartPoints.length - 1}
                value={Math.max(0, chartPoints.indexOf(selected ?? chartPoints[chartPoints.length - 1]))}
                onChange={(e) => setSelected(chartPoints[Number(e.target.value)])}
                className="w-full accent-accent cursor-pointer"
                aria-label="Выбрать точку истории"
              />
            </label>
          )}

          {chartPoints.length < visible.length && (
            <p className="text-[11px] text-text-secondary">
              Для быстрого отображения {visible.length} проверок график уплотнён до {chartPoints.length} точек
              с сохранением минимумов и максимумов каждого периода.
            </p>
          )}

          {selected && <HistoryPointSummary point={selected} />}
        </>
      ) : null}
    </Card>
  );
}

const CHART_WIDTH = 920;
const CHART_HEIGHT = 270;
const CHART_LEFT = 52;
const CHART_RIGHT = 16;
const CHART_TOP = 18;
const CHART_BOTTOM = 38;

// Большую увеличенную историю нельзя превращать в десятки тысяч SVG-узлов:
// браузер начнёт тормозить при каждом движении мыши. Из каждого временного
// окна оставляем минимум и максимум в исходном порядке — короткие провалы и
// восстановления при этом не исчезают.
function compactChartPoints(points: AvailabilityHistoryPoint[], maxPoints: number): AvailabilityHistoryPoint[] {
  if (points.length <= maxPoints || maxPoints < 4) return points;
  const result: AvailabilityHistoryPoint[] = [points[0]];
  const middle = points.slice(1, -1);
  const buckets = Math.max(1, Math.floor((maxPoints - 2) / 2));
  const bucketSize = middle.length / buckets;
  const value = (point: AvailabilityHistoryPoint) =>
    point.error || point.total_probes === 0 ? -1 : point.percentage;

  for (let bucket = 0; bucket < buckets; bucket += 1) {
    const start = Math.floor(bucket * bucketSize);
    const end = Math.min(middle.length, Math.floor((bucket + 1) * bucketSize));
    if (start >= end) continue;
    let minIndex = start;
    let maxIndex = start;
    for (let index = start + 1; index < end; index += 1) {
      if (value(middle[index]) < value(middle[minIndex])) minIndex = index;
      if (value(middle[index]) > value(middle[maxIndex])) maxIndex = index;
    }
    if (minIndex === maxIndex) {
      result.push(middle[minIndex]);
    } else if (minIndex < maxIndex) {
      result.push(middle[minIndex], middle[maxIndex]);
    } else {
      result.push(middle[maxIndex], middle[minIndex]);
    }
  }
  result.push(points[points.length - 1]);
  return result;
}

function AvailabilityChart({
  points,
  threshold,
  selected,
  onSelect,
}: {
  points: AvailabilityHistoryPoint[];
  threshold?: number;
  selected: AvailabilityHistoryPoint | null;
  onSelect: (point: AvailabilityHistoryPoint) => void;
}) {
  const times = points.map((point) => new Date(point.checked_at).getTime());
  let minTime = times[0];
  let maxTime = times[0];
  for (const time of times) {
    if (time < minTime) minTime = time;
    if (time > maxTime) maxTime = time;
  }
  const plotWidth = CHART_WIDTH - CHART_LEFT - CHART_RIGHT;
  const plotHeight = CHART_HEIGHT - CHART_TOP - CHART_BOTTOM;
  const xAt = (index: number) =>
    maxTime === minTime
      ? CHART_LEFT + plotWidth / 2
      : CHART_LEFT + ((times[index] - minTime) / (maxTime - minTime)) * plotWidth;
  const yAt = (percentage: number) =>
    CHART_TOP + ((100 - Math.max(0, Math.min(100, percentage))) / 100) * plotHeight;

  const plotted = points.map((point, index) => ({
    point,
    x: xAt(index),
    y: yAt(point.percentage),
    measured: point.total_probes > 0 && !point.error,
  }));
  const segments: typeof plotted[] = [];
  let segment: typeof plotted = [];
  for (const point of plotted) {
    if (point.measured) {
      segment.push(point);
    } else if (segment.length) {
      segments.push(segment);
      segment = [];
    }
  }
  if (segment.length) segments.push(segment);

  const selectedPlot = plotted.find((item) => item.point === selected);
  const chooseNearest = (event: React.PointerEvent<SVGSVGElement>) => {
    const rect = event.currentTarget.getBoundingClientRect();
    const cursorX = ((event.clientX - rect.left) / rect.width) * CHART_WIDTH;
    let nearest = plotted[0];
    for (const candidate of plotted) {
      if (Math.abs(candidate.x - cursorX) < Math.abs(nearest.x - cursorX)) nearest = candidate;
    }
    onSelect(nearest.point);
  };

  return (
    <div>
      <svg
        viewBox={`0 0 ${CHART_WIDTH} ${CHART_HEIGHT}`}
        className="w-full select-none touch-pan-y"
        style={{ aspectRatio: `${CHART_WIDTH}/${CHART_HEIGHT}` }}
        role="img"
        aria-label="График процента доступности по времени"
        onPointerMove={chooseNearest}
        onPointerDown={chooseNearest}
      >
        {[100, 75, 50, 25, 0].map((value) => {
          const y = yAt(value);
          return (
            <g key={value}>
              <line
                x1={CHART_LEFT}
                x2={CHART_WIDTH - CHART_RIGHT}
                y1={y}
                y2={y}
                stroke="rgb(var(--border))"
                strokeWidth="1"
                strokeDasharray={value === 0 ? undefined : '3 5'}
              />
              <text x={CHART_LEFT - 8} y={y + 4} textAnchor="end" fill="rgb(var(--text-muted))" fontSize="11">
                {value}%
              </text>
            </g>
          );
        })}

        {threshold !== undefined && threshold >= 0 && threshold <= 100 && (
          <g>
            <line
              x1={CHART_LEFT}
              x2={CHART_WIDTH - CHART_RIGHT}
              y1={yAt(threshold)}
              y2={yAt(threshold)}
              stroke="rgb(var(--warn))"
              strokeWidth="1.5"
              strokeDasharray="6 5"
            />
            <text
              x={CHART_WIDTH - CHART_RIGHT - 3}
              y={yAt(threshold) - 5}
              textAnchor="end"
              fill="rgb(var(--warn))"
              fontSize="10"
            >
              порог {threshold}%
            </text>
          </g>
        )}

        <defs>
          <linearGradient id="availability-area" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0" stopColor="rgb(var(--accent))" stopOpacity="0.28" />
            <stop offset="1" stopColor="rgb(var(--accent))" stopOpacity="0.02" />
          </linearGradient>
        </defs>

        {segments.map((line, index) => (
          <g key={index}>
            {line.length > 1 && (
              <path
                d={`M${line[0].x},${yAt(0)} ${line.map((item) => `L${item.x},${item.y}`).join(' ')} L${line[line.length - 1].x},${yAt(0)} Z`}
                fill="url(#availability-area)"
              />
            )}
            <polyline
              points={line.map((item) => `${item.x},${item.y}`).join(' ')}
              fill="none"
              stroke="rgb(var(--accent))"
              strokeWidth="2"
              strokeLinejoin="round"
              strokeLinecap="round"
            />
          </g>
        ))}

        {plotted.map((item, index) => {
          if (!item.measured) {
            return (
              <g key={`${item.point.checked_at}-${index}`}>
                <circle cx={item.x} cy={yAt(0)} r="5" fill="rgb(var(--error))" />
                <title>{`${formatHistoryTime(item.point.checked_at)} — ошибка проверки: ${item.point.error || 'нет ответивших зондов'}`}</title>
              </g>
            );
          }
          if (plotted.length > 250 && item.point !== selected) return null;
          return (
            <circle
              key={`${item.point.checked_at}-${index}`}
              cx={item.x}
              cy={item.y}
              r={item.point === selected ? 6 : 3}
              fill={historyPointColor(item.point)}
              stroke="rgb(var(--surface))"
              strokeWidth="2"
            >
              <title>{`${formatHistoryTime(item.point.checked_at)} — ${item.point.percentage.toFixed(0)}%, ${item.point.success_probes}/${item.point.total_probes} зондов`}</title>
            </circle>
          );
        })}

        {selectedPlot && (
          <line
            x1={selectedPlot.x}
            x2={selectedPlot.x}
            y1={CHART_TOP}
            y2={CHART_TOP + plotHeight}
            stroke="rgb(var(--text))"
            strokeWidth="1"
            strokeDasharray="3 4"
            opacity="0.55"
            pointerEvents="none"
          />
        )}

        <text x={CHART_LEFT} y={CHART_HEIGHT - 9} fill="rgb(var(--text-muted))" fontSize="11">
          {formatHistoryAxis(points[0].checked_at)}
        </text>
        <text
          x={CHART_WIDTH - CHART_RIGHT}
          y={CHART_HEIGHT - 9}
          textAnchor="end"
          fill="rgb(var(--text-muted))"
          fontSize="11"
        >
          {formatHistoryAxis(points[points.length - 1].checked_at)}
        </text>
      </svg>
      <div className="flex items-center gap-4 flex-wrap text-micro text-text-muted mt-1">
        <span className="flex items-center gap-1.5"><i className="w-2.5 h-2.5 rounded-full bg-ok" />80–100%</span>
        <span className="flex items-center gap-1.5"><i className="w-2.5 h-2.5 rounded-full bg-warn" />50–79%</span>
        <span className="flex items-center gap-1.5"><i className="w-2.5 h-2.5 rounded-full bg-error" />0–49% или ошибка</span>
      </div>
    </div>
  );
}

function HistoryPointSummary({ point }: { point: AvailabilityHistoryPoint }) {
  const failed = Boolean(point.error) || point.total_probes === 0;
  return (
    <div className="bg-surface-hover/60 border border-border rounded-lg px-3 py-2 text-xs flex items-center justify-between gap-3 flex-wrap">
      <div>
        <span className="text-text-primary font-medium">{formatHistoryTime(point.checked_at)}</span>
        <span className="text-text-secondary ml-2">{point.target || 'цель не определена'}</span>
      </div>
      {failed ? (
        <span className="text-danger">Ошибка проверки: {point.error || 'нет ответивших зондов'}</span>
      ) : (
        <span style={{ color: historyPointColor(point) }} className="font-medium">
          {point.percentage.toFixed(0)}% · {point.success_probes} из {point.total_probes} зондов
        </span>
      )}
    </div>
  );
}

function historyPointColor(point: AvailabilityHistoryPoint): string {
  if (point.error || point.total_probes === 0 || point.percentage < 50) return 'rgb(var(--error))';
  if (point.percentage < 80) return 'rgb(var(--warn))';
  return 'rgb(var(--ok))';
}

function formatHistoryTime(value: string): string {
  return new Date(value).toLocaleString('ru-RU', {
    day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
}

function formatHistoryAxis(value: string): string {
  return new Date(value).toLocaleString('ru-RU', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
  });
}

function StatCard({
  label,
  value,
  valueClass,
  small,
  extra,
}: {
  label: string;
  value: string;
  valueClass?: string;
  small?: boolean;
  extra?: React.ReactNode;
}) {
  return (
    <div className="flex min-h-[96px] min-w-0 flex-col rounded-xl border border-border bg-surface p-3 md:p-3.5">
      <span className="line-clamp-2 min-h-[26px] break-words text-[10.5px] font-semibold uppercase leading-[1.25] tracking-[0.02em] text-text-muted">{label}</span>
      <div
        className={cn('mt-auto pt-2', small ? 'truncate text-sm font-semibold text-text' : 'truncate font-mono text-[22px] font-bold leading-none tabular-nums md:text-[24px]', valueClass)}
        title={value}
      >
        {value}
      </div>
      {extra}
    </div>
  );
}

function ProbeRow({
  probe,
  expanded,
  onToggle,
}: {
  probe: AvailabilityProbe;
  expanded: boolean;
  onToggle: () => void;
}) {
  const isEyeball = probe.tags?.includes('eyeball-network');

  return (
    <div>
      <button
        onClick={onToggle}
        className="w-full flex items-center justify-between gap-2 p-4 hover:bg-surface-hover transition-colors text-left min-h-[44px]"
      >
        <div className="flex items-center gap-3 min-w-0">
          {probe.tls_success ? (
            <CheckCircle2 size={18} className="text-success shrink-0" />
          ) : (
            <XCircle size={18} className="text-danger shrink-0" />
          )}
          <div className="min-w-0">
            <span className="font-medium text-text-primary">
              {probe.city || '—'}, {probe.country || '—'}
            </span>
            <span className="text-text-secondary text-sm ml-2 hidden sm:inline">
              {probe.region} • {probe.network || `AS${probe.asn}`}
            </span>
          </div>
        </div>
        <div className="flex items-center gap-2 shrink-0">
          {isEyeball && (
            <Badge variant="default" className="hidden sm:inline-flex">
              eyeball
            </Badge>
          )}
          <Badge variant={probe.tls_success ? 'success' : 'danger'}>
            {probe.tls_success ? 'TLS ✓' : 'TLS ✗'}
          </Badge>
          {expanded ? (
            <ChevronUp size={16} className="text-text-secondary" />
          ) : (
            <ChevronDown size={16} className="text-text-secondary" />
          )}
        </div>
      </button>

      {expanded && (
        <div className="px-4 pb-4 space-y-3 bg-surface-hover/40">
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
            <InfoCell label="Город" value={probe.city} />
            <InfoCell label="Страна" value={probe.country} />
            <InfoCell label="Регион" value={probe.region} />
            <InfoCell label="Континент" value={probe.continent} />
            <InfoCell label="ASN" value={probe.asn ? `AS${probe.asn}` : undefined} />
            <InfoCell label="Сеть" value={probe.network} />
            <InfoCell label="Теги" value={probe.tags?.join(', ')} />
            <InfoCell label="HTTP статус" value={probe.http_status_code?.toString()} />
          </div>

          {probe.tls_info && (
            <div className="bg-success/10 border border-success/20 rounded-lg p-3 text-xs space-y-1">
              <div className="text-success font-medium mb-1">TLS сертификат</div>
              <div>
                <span className="text-text-secondary">Авторизован: </span>
                {probe.tls_info.authorized ? 'да' : 'нет'}
              </div>
              {probe.tls_info.issuer?.CN && (
                <div>
                  <span className="text-text-secondary">Издатель: </span>
                  {probe.tls_info.issuer.CN}
                </div>
              )}
              {probe.tls_info.subject?.CN && (
                <div>
                  <span className="text-text-secondary">Субъект: </span>
                  {probe.tls_info.subject.CN}
                </div>
              )}
              {probe.tls_info.expiresAt && (
                <div>
                  <span className="text-text-secondary">Истекает: </span>
                  {new Date(probe.tls_info.expiresAt).toLocaleDateString('ru-RU')}
                </div>
              )}
            </div>
          )}

          {probe.error && (
            <div className="bg-danger/10 border border-danger/20 rounded-lg p-3 text-xs text-danger">
              {probe.error}
            </div>
          )}

          {probe.raw_output && (
            <details className="text-xs">
              <summary className="cursor-pointer text-text-secondary hover:text-text-primary py-1">
                Полный ответ
              </summary>
              <pre className="mt-2 p-3 bg-surface-sunken rounded-lg overflow-x-auto max-h-48 overflow-y-auto whitespace-pre-wrap break-all">
                {probe.raw_output}
              </pre>
            </details>
          )}
        </div>
      )}
    </div>
  );
}

function InfoCell({ label, value }: { label: string; value?: string | null }) {
  return (
    <div>
      <div className="text-text-secondary text-xs">{label}</div>
      <div className="text-text-primary">{value || '—'}</div>
    </div>
  );
}
