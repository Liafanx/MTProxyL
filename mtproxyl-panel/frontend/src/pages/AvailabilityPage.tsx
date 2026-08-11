import { useCallback, useEffect, useState } from 'react';
import { RefreshCw, ChevronDown, ChevronUp, CheckCircle2, XCircle, ExternalLink, Target } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { ErrorAlert } from '@/components/ErrorAlert';
import {
  availabilityApi,
  type AvailabilityResult,
  type AvailabilityProbe,
  type AvailabilityLevel,
  type AvailabilityQuota,
  type AvailabilityTargetResponse,
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
      setMessage(res.message);
      setError(null);
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
      setQuota(res.quota);
      setAutoCheck(res.auto_check ?? autoCheck);
      setMessage(res.message);
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

        {enabled && <AutoCheckToggle enabled={autoCheck} onChange={setAutoCheck} />}

        {enabled && <QuotaBanner quota={quota} />}

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

/**
 * Проверка по расписанию. Выключенная не отменяет «Проверить сейчас» — она для
 * тех, кто хочет проверять руками и не тратить квоту фоном.
 */
function AutoCheckToggle({
  enabled,
  onChange,
}: {
  enabled: boolean;
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
          {enabled
            ? 'Проверка идёт сама раз в 15 минут'
            : 'Проверки идут только по кнопке «Проверить сейчас»'}
        </div>
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
    <div className="bg-surface border border-border rounded-lg p-3 lg:p-4 min-h-[44px] flex flex-col justify-center">
      <span className="text-xs lg:text-sm text-text-secondary mb-1.5 lg:mb-2">{label}</span>
      <div
        className={cn(small ? 'text-sm truncate' : 'text-xl lg:text-2xl font-bold', valueClass)}
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
              <pre className="mt-2 p-3 bg-black/30 rounded-lg overflow-x-auto max-h-48 overflow-y-auto whitespace-pre-wrap break-all">
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
