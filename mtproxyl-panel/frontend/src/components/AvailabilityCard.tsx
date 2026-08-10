import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { availabilityApi, type AvailabilityLevel, type AvailabilityResult } from '@/lib/api';
import { cn } from '@/lib/utils';

const LEVEL_TEXT: Record<AvailabilityLevel, string> = {
  green: 'text-success',
  yellow: 'text-warning',
  red: 'text-danger',
};

const LEVEL_DOT: Record<AvailabilityLevel, string> = {
  green: 'bg-status-ok',
  yellow: 'bg-status-warn',
  red: 'bg-status-error',
};

const LEVEL_LABEL: Record<AvailabilityLevel, string> = {
  green: 'Доступен',
  yellow: 'Частично',
  red: 'Недоступен',
};

/** Сводка проверки доступности на дашборде. Подробности — на своей странице. */
export function AvailabilityCard() {
  const [enabled, setEnabled] = useState(true);
  const [status, setStatus] = useState<AvailabilityResult | null>(null);
  const [autoCheck, setAutoCheck] = useState(true);
  const [message, setMessage] = useState<string | undefined>();
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      const res = await availabilityApi.status();
      setEnabled(res.enabled);
      setStatus(res.status ?? null);
      setAutoCheck(res.auto_check ?? true);
      setMessage(res.message);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить статус');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
    // Проверка идёт раз в 15 минут, чаще опрашивать нечего.
    const id = setInterval(load, 60_000);
    return () => clearInterval(id);
  }, [load]);

  // Выключенную проверку на дашборде не показываем — это не состояние прокси.
  if (!enabled && !loading) return null;

  return (
    <div className="bg-surface border border-border rounded-lg p-4">
      <div className="flex items-center justify-between mb-3">
        <span className="text-xs text-text-secondary uppercase tracking-wider">
          Доступность из РФ
        </span>
        <div className="flex items-center gap-2">
          {!loading && (
            <span className={cn('text-xs', autoCheck ? 'text-text-secondary' : 'text-warning')}>
              автообновление {autoCheck ? 'вкл' : 'выкл'}
            </span>
          )}
          <Link to="/availability" className="text-xs text-accent hover:underline">
            Подробнее →
          </Link>
        </div>
      </div>
      <Body loading={loading} error={error} status={status} message={message} />
    </div>
  );
}

function Body({
  loading,
  error,
  status,
  message,
}: {
  loading: boolean;
  error: string | null;
  status: AvailabilityResult | null;
  message?: string;
}) {
  if (loading) {
    return <div className="text-sm text-text-secondary">Загрузка…</div>;
  }
  if (error) {
    return <div className="text-sm text-danger">{error}</div>;
  }
  if (status?.error) {
    return <div className="text-sm text-danger">{status.error}</div>;
  }
  if (!status) {
    return <div className="text-sm text-text-secondary">{message || 'Проверки ещё не проводились'}</div>;
  }

  return (
    <div className="flex items-center gap-3">
      <span className={cn('h-3 w-3 rounded-full shrink-0', LEVEL_DOT[status.level])} />
      <div className="min-w-0">
        <div className="flex items-baseline gap-2 flex-wrap">
          <span className={cn('text-2xl font-bold', LEVEL_TEXT[status.level])}>
            {status.percentage.toFixed(0)}%
          </span>
          <span className="text-sm text-text-primary">{LEVEL_LABEL[status.level]}</span>
        </div>
        <div className="text-xs text-text-secondary">
          {status.success_probes}/{status.total_probes} зондов • {timeAgo(status.checked_at)}
        </div>
      </div>
    </div>
  );
}

function timeAgo(iso: string): string {
  const min = Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
  if (min < 1) return 'только что';
  if (min < 60) return `${min} мин. назад`;
  const hours = Math.floor(min / 60);
  if (hours < 24) return `${hours} ч. назад`;
  return `${Math.floor(hours / 24)} дн. назад`;
}
