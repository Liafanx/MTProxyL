import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { RotateCw, Loader2 } from 'lucide-react';
import { panelApi } from '@/lib/api';
import { useMtproxyl } from '@/hooks/useMtproxyl';
import { ConfirmDialog } from './ConfirmDialog';

interface StartupStatusProps {
  status?: string;
  stage?: string;
  progressPct?: number;
}

// Движок отдаёт эти значения по-английски и одним словом — переводим,
// незнакомое показываем как есть, чтобы не прятать новые состояния.
const STATUS_LABELS: Record<string, string> = {
  ready: 'готов',
  starting: 'запускается',
  degraded: 'работает с ограничениями',
  failed: 'ошибка запуска',
  stopped: 'остановлен',
};

const STAGE_LABELS: Record<string, string> = {
  init: 'инициализация',
  config: 'чтение конфигурации',
  bind: 'открытие портов',
  dc_connect: 'подключение к дата-центрам Telegram',
  warmup: 'прогрев',
  ready: 'готово',
  done: 'готово',
};

function translate(map: Record<string, string>, raw?: string): string {
  if (!raw) return 'неизвестно';
  return map[raw.toLowerCase()] ?? raw;
}

export function StartupStatus({ status, stage, progressPct }: StartupStatusProps) {
  const [restarting, setRestarting] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { enabled: mtproxylEnabled } = useMtproxyl();

  const isReady = status === 'ready' && progressPct === 100;

  // Эта кнопка делает systemctl restart telemt.service. При включённом мосте
  // MTProxyL движок может жить в Docker, и тогда systemctl ни при чём — там
  // перезапуском занимается блок «Управление прокси», который знает режим.
  // Две кнопки перезапуска рядом, из которых одна не работает, хуже одной.
  const showRestart = !mtproxylEnabled;

  const handleRestart = async () => {
    setShowConfirm(false);
    setRestarting(true);
    setError(null);
    try {
      await panelApi.post('/telemt/restart');
    } catch (err) {
      // Раньше ошибка уходила только в консоль: пользователь жал кнопку и не
      // получал ни перезапуска, ни объяснения.
      setError(err instanceof Error ? err.message : 'Не удалось перезапустить сервис');
    } finally {
      setTimeout(() => setRestarting(false), 5000);
    }
  };

  return (
    <>
      <div className="bg-surface border border-border rounded-lg p-4">
        <div className="flex items-center justify-between mb-3">
          <h3 className="text-sm font-medium text-text-primary">Состояние сервиса</h3>
          {showRestart && (
            <Button
              variant="outline"
              onClick={() => setShowConfirm(true)}
              disabled={restarting}
            >
              {restarting ? (
                <>
                  <Loader2 size={14} className="animate-spin mr-1.5" />
                  Перезапуск…
                </>
              ) : (
                <>
                  <RotateCw size={14} className="mr-1.5" />
                  Перезапустить
                </>
              )}
            </Button>
          )}
        </div>

        {error && <div className="mb-3 text-sm text-danger">{error}</div>}

        {!isReady && (
          <div className="space-y-2">
            <div className="flex justify-between text-xs">
              <span className="text-text-secondary">Статус:</span>
              <span className="text-text-primary font-medium">{translate(STATUS_LABELS, status)}</span>
            </div>
            <div className="flex justify-between text-xs">
              <span className="text-text-secondary">Этап:</span>
              <span className="text-text-primary font-medium">{translate(STAGE_LABELS, stage)}</span>
            </div>
            <div className="space-y-1">
              <div className="flex justify-between text-xs">
                <span className="text-text-secondary">Прогресс:</span>
                <span className="text-text-primary font-medium">{progressPct?.toFixed(0) || 0}%</span>
              </div>
              <div className="w-full bg-background rounded-full h-2 overflow-hidden">
                <div
                  className="bg-accent h-full transition-all duration-300"
                  style={{ width: `${progressPct || 0}%` }}
                />
              </div>
            </div>
          </div>
        )}

        {isReady && (
          <div className="flex items-center gap-2 text-sm text-success">
            <div className="w-2 h-2 bg-success rounded-full animate-pulse" />
            Сервис готов
          </div>
        )}
      </div>

      <ConfirmDialog
        open={showConfirm}
        onClose={() => setShowConfirm(false)}
        title="Перезапуск сервиса Telemt"
        message="Перезапустить сервис Telemt? Активные соединения будут разорваны."
        confirmLabel="Перезапустить"
        onConfirm={handleRestart}
      />
    </>
  );
}
