import { useCallback, useEffect, useState } from 'react';
import { RefreshCw, ChevronDown, ChevronUp, CheckCircle2, XCircle, ExternalLink } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ErrorAlert } from '@/components/ErrorAlert';
import {
  availabilityApi,
  type AvailabilityResult,
  type AvailabilityProbe,
  type AvailabilityLevel,
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

        {!enabled ? (
          <Card className="p-6 text-sm text-text-secondary">
            Проверка доступности выключена в конфиге панели. Включите её в{' '}
            <code className="bg-surface-hover px-1 rounded">[globalping] enabled = true</code>{' '}
            и перезапустите панель.
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
