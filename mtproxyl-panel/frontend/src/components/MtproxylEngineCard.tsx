import { useCallback, useEffect, useState } from 'react';
import { CheckCircle2, Download, RefreshCw, Undo2 } from 'lucide-react';
import { MetricCard } from '@/components/MetricCard';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { mtproxylApi, type MtproxylEngineVersions } from '@/lib/api';
import { useMtproxyl, useMtproxylOperation } from '@/hooks/useMtproxyl';
import { cn } from '@/lib/utils';

/** Версии движка telemt: что стоит, что лежит на диске, что опубликовано. */
export function MtproxylEngineCard() {
  const { enabled, mode } = useMtproxyl();
  const [info, setInfo] = useState<MtproxylEngineVersions | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [tag, setTag] = useState('');

  const load = useCallback(async () => {
    if (!enabled) return;
    setLoading(true);
    try {
      setInfo(await mtproxylApi.engineVersions());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить версии движка');
    } finally {
      setLoading(false);
    }
  }, [enabled]);

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['engine:']);

  useEffect(() => {
    void load();
  }, [load]);

  // Движком владеет только менеджер: в реаниматоре цель чужая, и её версию
  // меняет тот, кто её ставил.
  if (!enabled || mode === 'reanimator') return null;

  const update = async (t: string) => {
    try {
      setActionError(null);
      start(await mtproxylApi.engineUpdate(t));
    } catch (e) {
      setActionError(e instanceof Error ? e.message : 'Не удалось запустить установку');
    }
  };

  const rollback = async (t = '') => {
    try {
      setActionError(null);
      start(await mtproxylApi.engineRollback(t));
    } catch (e) {
      setActionError(e instanceof Error ? e.message : 'Не удалось запустить откат');
    }
  };

  const current = info?.current ?? '';
  const latest = info?.releases?.[0]?.tag ?? '';
  const isLatest = Boolean(latest) && latest.replace(/^v/, '') === current.replace(/^v/, '');
  // Откатываться есть куда, только если на диске лежит не только текущая.
  const rollbackTargets = (info?.local ?? []).filter(
    (v) => v.replace(/^v/, '') !== current.replace(/^v/, ''),
  );

  return (
    <div className="bg-surface rounded-lg p-4 lg:p-5 border border-border">
      <div className="flex items-center justify-between mb-3 lg:mb-4">
        <h2 className="text-xs lg:text-sm font-semibold text-text-primary">Версия движка</h2>
        <button
          onClick={() => void load()}
          disabled={loading || running}
          className={cn(
            'flex items-center gap-1.5 lg:gap-2 px-2.5 lg:px-3 py-1.5 rounded-md text-xs font-medium transition-colors',
            'bg-accent/15 text-accent hover:bg-accent/25',
            'disabled:opacity-50 disabled:cursor-not-allowed',
          )}
        >
          <RefreshCw size={12} className={cn('lg:w-3.5 lg:h-3.5', loading && 'animate-spin')} />
          Обновить список
        </button>
      </div>

      {error && <ErrorAlert message={error} />}
      {actionError && <ErrorAlert message={actionError} />}

      <div className="space-y-3 lg:space-y-4">
        <div className="grid grid-cols-2 gap-2 lg:gap-3">
          <MetricCard label="Установлена" value={current || '—'} />
          <MetricCard
            label="Носитель"
            value={info?.binary ? 'бинарник' : info ? 'docker' : '—'}
          />
        </div>

        {info && isLatest && (
          <div className="flex items-center gap-2 text-xs lg:text-sm text-success">
            <CheckCircle2 size={14} className="lg:w-4 lg:h-4" />
            Установлена последняя опубликованная версия
          </div>
        )}

        {info && info.releases.length > 0 && (
          <div>
            <p className="text-xs text-text-secondary mb-2">Опубликованные версии</p>
            <div className="space-y-1.5 max-h-64 overflow-y-auto">
              {info.releases.map((r) => {
                const isCurrent = r.tag.replace(/^v/, '') === current.replace(/^v/, '');
                return (
                  <div
                    key={r.tag}
                    className="flex items-center justify-between gap-3 rounded-md border border-border px-3 py-2"
                  >
                    <div className="min-w-0">
                      <p className="text-xs lg:text-sm font-mono text-text-primary truncate">
                        {r.tag}
                        {isCurrent && <span className="ml-2 text-success">— текущая</span>}
                      </p>
                      <p className="text-xs text-text-secondary truncate">
                        {r.name}
                        {r.date && ` · ${r.date}`}
                      </p>
                    </div>
                    <button
                      onClick={() => void update(r.tag)}
                      disabled={running || isCurrent}
                      className={cn(
                        'flex items-center gap-1.5 px-2.5 py-1.5 rounded-md text-xs font-medium transition-colors shrink-0',
                        'bg-accent/15 text-accent hover:bg-accent/25',
                        'disabled:opacity-40 disabled:cursor-not-allowed',
                      )}
                    >
                      <Download size={12} />
                      Поставить
                    </button>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        <div className="flex flex-col sm:flex-row gap-2">
          <input
            value={tag}
            onChange={(e) => setTag(e.target.value)}
            placeholder="Версия вручную, например v3.4.25"
            className="flex-1 px-3 py-2 rounded-md bg-background border border-border text-xs lg:text-sm text-text-primary font-mono"
          />
          <button
            onClick={() => void update(tag)}
            disabled={running || tag.trim() === ''}
            className={cn(
              'flex items-center justify-center gap-2 px-3 py-2 rounded-md text-xs lg:text-sm font-medium transition-colors',
              'bg-accent text-white hover:bg-accent/90',
              'disabled:opacity-50 disabled:cursor-not-allowed',
            )}
          >
            <Download size={14} />
            Поставить
          </button>
        </div>

        <div className="rounded-md border border-border p-3">
          <p className="text-xs lg:text-sm font-medium text-text-primary mb-1">Откат</p>
          <p className="text-xs text-text-secondary mb-2">
            {info?.binary
              ? 'Предыдущий бинарник лежит рядом с текущим — откат идёт без сети.'
              : 'Откат переключает на образ, который уже лежит на диске.'}
          </p>
          {rollbackTargets.length === 0 ? (
            <p className="text-xs text-text-secondary">Откатываться не к чему: на диске только текущая версия.</p>
          ) : info?.binary ? (
            <button
              onClick={() => void rollback()}
              disabled={running}
              className={cn(
                'flex items-center gap-1.5 px-3 py-2 rounded-md text-xs font-medium transition-colors',
                'bg-warning/15 text-warning hover:bg-warning/25',
                'disabled:opacity-50 disabled:cursor-not-allowed',
              )}
            >
              <Undo2 size={12} />
              Откатить на {rollbackTargets[0]}
            </button>
          ) : (
            <div className="flex flex-wrap gap-2">
              {rollbackTargets.map((v) => (
                <button
                  key={v}
                  onClick={() => void rollback(v)}
                  disabled={running}
                  className={cn(
                    'flex items-center gap-1.5 px-3 py-2 rounded-md text-xs font-mono transition-colors',
                    'bg-warning/15 text-warning hover:bg-warning/25',
                    'disabled:opacity-50 disabled:cursor-not-allowed',
                  )}
                >
                  <Undo2 size={12} />
                  {v}
                </button>
              ))}
            </div>
          )}
        </div>

        <p className="text-xs text-text-secondary">
          Смена версии перезапускает движок: активные соединения оборвутся, клиенты
          переподключатся сами.
        </p>

        <OperationProgress operation={operation} onDismiss={dismiss} />
      </div>
    </div>
  );
}
