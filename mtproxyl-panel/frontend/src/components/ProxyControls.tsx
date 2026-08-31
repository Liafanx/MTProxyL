import { useCallback, useEffect, useState } from 'react';
import { Play, RotateCw, Square } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { OperationProgress } from '@/components/OperationProgress';
import { StatusBadge } from '@/components/StatusBadge';
import { mtproxylApi, type MtproxylModeStatus, type ProxyAction } from '@/lib/api';
import { useMtproxyl, useMtproxylOperation } from '@/hooks/useMtproxyl';

/**
 * Запуск, перезапуск и остановка движка.
 *
 * Что именно останавливается, зависит от режима, и решает это CLI: у менеджера
 * это свой движок (контейнер или служба MTProxyL-Telemt), у реаниматора —
 * обнаруженная цель. Унаследованная от telemt_panel кнопка перезапуска дёргала
 * systemctl restart telemt.service и в режиме менеджера не работала вовсе.
 */
export function ProxyControls() {
  const { enabled } = useMtproxyl();
  const [status, setStatus] = useState<MtproxylModeStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<ProxyAction | null>(null);

  const load = useCallback(async () => {
    if (!enabled) return;
    try {
      setStatus(await mtproxylApi.getMode());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить состояние прокси');
    }
  }, [enabled]);

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['proxy:']);

  useEffect(() => {
    void load();
  }, [load]);

  if (!enabled) return null;

  const run = async (action: ProxyAction) => {
    try {
      start(await mtproxylApi.proxyAction(action));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось выполнить действие');
    }
  };

  const isManager = status?.mode !== 'reanimator';
  const what = isManager ? 'прокси' : 'цель';
  // Пока состояние не загружено, показываем обе кнопки: скрыть «Запустить» из-за
  // неизвестного состояния хуже, чем показать лишнюю.
  const up = status?.running ?? true;
  const down = status?.running === false;

  return (
    <div className="bg-surface border border-border rounded-lg p-4 space-y-3">
      <div className="flex items-center justify-between gap-4 flex-wrap">
        <div>
          <h3 className="text-sm font-medium text-text-secondary">
            Управление прокси
            {!isManager && <span className="ml-2 text-xs">(обнаруженная цель)</span>}
          </h3>
          {status && (
            <div className="text-xs text-text-secondary/70 mt-0.5">
              {isManager
                ? status.engine === 'binary'
                  ? 'Свой движок MTProxyL-Telemt'
                  : 'Свой контейнер MTProxyL'
                : `Цель: ${status.detected_mode}`}{' '}
              · {status.proxy_mode === 'web' ? 'WEB :443' : `порт ${status.port}`}
            </div>
          )}
        </div>
        {status?.running !== undefined && (
          <StatusBadge status={status.running} labelOn="Работает" labelOff="Остановлен" />
        )}
      </div>

      {error && <div className="text-sm text-danger">{error}</div>}
      <OperationProgress operation={operation} onDismiss={dismiss} />

      <div className="flex flex-wrap gap-2">
        <Button size="sm" disabled={running || (up && !down)} onClick={() => run('start')}>
          <Play size={14} className="mr-1.5" />
          Запустить
        </Button>
        <Button size="sm" variant="outline" disabled={running} onClick={() => setConfirm('restart')}>
          <RotateCw size={14} className="mr-1.5" />
          Перезапустить
        </Button>
        <Button
          size="sm"
          variant="danger"
          disabled={running || down}
          onClick={() => setConfirm('stop')}
        >
          <Square size={14} className="mr-1.5" />
          Остановить
        </Button>
      </div>

      <ConfirmDialog
        open={confirm !== null}
        onClose={() => setConfirm(null)}
        onConfirm={() => {
          const a = confirm;
          setConfirm(null);
          if (a) void run(a);
        }}
        title={confirm === 'stop' ? `Остановить ${what}` : `Перезапустить ${what}`}
        message={
          confirm === 'stop'
            ? `${isManager ? 'Прокси' : 'Цель'} будет остановлен, все активные соединения разорвутся, клиенты перестанут подключаться. Продолжить?`
            : `Активные соединения будут разорваны, клиенты переподключатся через несколько секунд. Продолжить?`
        }
        confirmLabel="Продолжить"
        loadingLabel="Выполнение…"
      />
    </div>
  );
}
