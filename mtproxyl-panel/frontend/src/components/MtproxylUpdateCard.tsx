import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { ArrowUpCircle, CheckCircle2, Download, RefreshCw } from 'lucide-react';
import { MetricCard } from '@/components/MetricCard';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { mtproxylApi, type MtproxylUpdateInfo } from '@/lib/api';
import { useMtproxyl, useMtproxylOperation } from '@/hooks/useMtproxyl';
import { cn } from '@/lib/utils';

/** Проверка обновления MTProxyL. Общая для карточки и для баннера дашборда. */
function useMtproxylUpdate(enabled: boolean) {
  const [info, setInfo] = useState<MtproxylUpdateInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const load = useCallback(
    async (refresh = false) => {
      if (!enabled) return;
      setLoading(true);
      try {
        setInfo(await mtproxylApi.update(refresh));
        setError(null);
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Не удалось проверить обновление');
      } finally {
        setLoading(false);
      }
    },
    [enabled],
  );

  useEffect(() => {
    void load();
  }, [load]);

  return { info, error, loading, load };
}

/** Раздел «Версия MTProxyL» на странице обновления. */
export function MtproxylUpdateCard() {
  const { enabled } = useMtproxyl();
  const { info, error, loading, load } = useMtproxylUpdate(enabled);
  const [applyError, setApplyError] = useState<string | null>(null);
  const { operation, start, dismiss, running } = useMtproxylOperation(
    () => load(true),
    ['update:'],
  );

  if (!enabled) return null;

  const apply = async () => {
    try {
      setApplyError(null);
      start(await mtproxylApi.applyUpdate());
    } catch (e) {
      setApplyError(e instanceof Error ? e.message : 'Не удалось запустить обновление');
    }
  };

  return (
    <div className="bg-surface rounded-lg p-4 lg:p-5 border border-border">
      <div className="flex items-center justify-between mb-3 lg:mb-4">
        <h2 className="text-xs lg:text-sm font-semibold text-text-primary">Версия MTProxyL</h2>
        <button
          onClick={() => load(true)}
          disabled={loading || running}
          className={cn(
            'flex items-center gap-1.5 lg:gap-2 px-2.5 lg:px-3 py-1.5 rounded-md text-xs font-medium transition-colors',
            'bg-accent/15 text-accent hover:bg-accent/25',
            'disabled:opacity-50 disabled:cursor-not-allowed',
          )}
        >
          <RefreshCw size={12} className={cn('lg:w-3.5 lg:h-3.5', loading && 'animate-spin')} />
          Проверить
        </button>
      </div>

      {error && <ErrorAlert message={error} />}
      {applyError && <ErrorAlert message={applyError} />}

      <div className="space-y-3 lg:space-y-4">
        <div className="grid grid-cols-2 gap-2 lg:gap-3">
          <MetricCard label="Текущая версия" value={info?.current || '—'} />
          <MetricCard label="Опубликована" value={info?.latest || '—'} />
        </div>

        {/* Ветка важна: установка из dev обновляется из dev, а не из релизов. */}
        {info?.branch && info.branch !== 'main' && (
          <p className="text-xs text-text-secondary">
            Обновления берутся из ветки <span className="font-mono">{info.branch}</span>.
          </p>
        )}

        {info?.error && (
          <p className="text-xs text-warning">Проверить не удалось: {info.error}</p>
        )}

        {info?.update_available && (
          <div className="bg-accent/10 border border-accent/30 rounded-md p-3 lg:p-4">
            <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
              <div className="min-w-0">
                <p className="text-xs lg:text-sm font-medium text-accent">
                  Доступна версия {info.latest}
                </p>
                {info.release_url && (
                  <p className="text-xs text-text-secondary mt-1">
                    <a
                      href={info.release_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-accent hover:underline"
                    >
                      заметки о релизе
                    </a>
                  </p>
                )}
              </div>
              <button
                onClick={apply}
                disabled={running}
                className={cn(
                  'flex items-center justify-center gap-2 px-3 lg:px-4 py-2 rounded-md text-xs lg:text-sm font-medium transition-colors w-full sm:w-auto',
                  'bg-accent text-white hover:bg-accent/90',
                  'disabled:opacity-50 disabled:cursor-not-allowed',
                )}
              >
                <Download size={14} className="lg:w-4 lg:h-4" />
                Обновить
              </button>
            </div>
            {/* Панель — отдельный компонент со своей версией: обновление
                скрипта её не трогает, и наоборот. */}
            <p className="text-xs text-text-secondary mt-3">
              Обновится сам MTProxyL — скрипт и его библиотеки. Настройки, секреты
              и работающий прокси не затрагиваются.
            </p>
          </div>
        )}

        {info && !info.update_available && !info.error && (
          <div className="flex items-center gap-2 text-xs lg:text-sm text-success">
            <CheckCircle2 size={14} className="lg:w-4 lg:h-4" />
            Установлена последняя версия
          </div>
        )}

        <OperationProgress operation={operation} onDismiss={dismiss} />
      </div>
    </div>
  );
}

/** Уведомление о новой версии MTProxyL на дашборде. */
export function MtproxylUpdateBanner() {
  const { enabled } = useMtproxyl();
  const { info } = useMtproxylUpdate(enabled);

  if (!enabled || !info?.update_available) return null;

  return (
    <Link
      to="/update"
      className="flex items-center gap-3 bg-accent/10 border border-accent/30 rounded-lg p-3 hover:bg-accent/15 transition-colors"
    >
      <ArrowUpCircle size={18} className="text-accent shrink-0" />
      <span className="text-xs lg:text-sm text-text-primary">
        Вышла версия MTProxyL <span className="font-medium text-accent">{info.latest}</span>
        <span className="text-text-secondary"> — установлена {info.current}. Обновить</span>
      </span>
    </Link>
  );
}
