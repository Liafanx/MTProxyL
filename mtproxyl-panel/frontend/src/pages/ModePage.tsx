import { useCallback, useEffect, useState } from 'react';
import { Server, Stethoscope } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { mtproxylApi, type MtproxylMode, type MtproxylModeStatus } from '@/lib/api';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';

/** Word the user must type to confirm, mirroring MTProxyL's own CLI prompt. */
const CONFIRM_WORD = 'yes';

const DETECTED_MODE_LABELS: Record<string, string> = {
  docker: 'Docker-контейнер',
  local: 'Локальный процесс / systemd',
  mtproxymax: 'MTProxyMax',
  config_only: 'Только конфигурационный файл',
  manual: 'Указано вручную',
  unknown: 'Не определено',
};

const MODES: { id: MtproxylMode; title: string; icon: typeof Server; description: string }[] = [
  {
    id: 'manager',
    title: 'Manager',
    icon: Server,
    description:
      'MTProxyL сам устанавливает свой telemt и полностью им владеет: конфиг, контейнер, пользователи, обновления движка.',
  },
  {
    id: 'reanimator',
    title: 'Reanimator',
    icon: Stethoscope,
    description:
      'MTProxyL подключается к уже установленному кем-то telemt и применяет только хостовые фиксы, не переписывая чужой конфиг.',
  },
];

export function ModePage() {
  const [status, setStatus] = useState<MtproxylModeStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [target, setTarget] = useState<MtproxylMode | null>(null);
  const [confirmText, setConfirmText] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setStatus(await mtproxylApi.getMode());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить режим');
    } finally {
      setLoading(false);
    }
  }, []);

  const { operation, start, running } = useMtproxylOperation(load);

  useEffect(() => {
    void load();
  }, [load]);

  const closeDialog = () => {
    setTarget(null);
    setConfirmText('');
  };

  const confirmSwitch = async () => {
    if (!target) return;
    try {
      start(await mtproxylApi.switchMode(target));
      setError(null);
      closeDialog();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переключить режим');
      closeDialog();
    }
  };

  const current = status?.mode;

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Режим работы</h1>
        <p className="text-sm text-text-secondary mt-1">
          Определяет, владеет ли MTProxyL своим экземпляром telemt или обслуживает чужой.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={load} />}
      <OperationProgress operation={operation} />

      {loading && !status ? (
        <div className="text-sm text-text-secondary">Загрузка…</div>
      ) : (
        <>
          <div className="grid gap-4 md:grid-cols-2">
            {MODES.map(({ id, title, icon: Icon, description }) => {
              const active = current === id;
              return (
                <Card
                  key={id}
                  className={active ? 'border-accent ring-1 ring-accent/40' : undefined}
                >
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <Icon size={18} className={active ? 'text-accent' : 'text-text-secondary'} />
                      {title}
                      {active && (
                        <span className="ml-auto text-xs font-medium text-accent bg-accent/15 px-2 py-0.5 rounded-full">
                          Текущий
                        </span>
                      )}
                    </CardTitle>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    <p className="text-sm text-text-secondary">{description}</p>
                    <Button
                      variant={active ? 'outline' : 'default'}
                      disabled={active || running}
                      onClick={() => setTarget(id)}
                      className="w-full"
                    >
                      {active ? 'Уже активен' : `Переключить в ${title}`}
                    </Button>
                  </CardContent>
                </Card>
              );
            })}
          </div>

          {status && current === 'reanimator' && (
            <Card>
              <CardHeader>
                <CardTitle>Обнаруженная цель</CardTitle>
              </CardHeader>
              <CardContent className="space-y-2 text-sm">
                <Row
                  label="Тип установки"
                  value={DETECTED_MODE_LABELS[status.detected_mode] ?? status.detected_mode}
                />
                <Row label="Конфиг" value={status.detected_config || 'не найден'} mono />
                <Row label="Порт" value={String(status.port)} />
              </CardContent>
            </Card>
          )}
        </>
      )}

      <Dialog open={target !== null} onClose={closeDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              Переключение в режим {target === 'manager' ? 'Manager' : 'Reanimator'}
            </DialogTitle>
          </DialogHeader>
          <div className="py-4 space-y-3">
            <p className="text-sm text-text-secondary">
              {target === 'manager'
                ? 'MTProxyL начнёт устанавливать и обслуживать собственный telemt. Если своей установки ещё нет, будет запущен установщик.'
                : 'Управление собственным контейнером из меню прекратится, а сам контейнер может быть остановлен и удалён, чтобы освободить порт для цели.'}
            </p>
            <p className="text-sm text-text-secondary">
              Операция затрагивает состояние сервера. Введите{' '}
              <code className="font-mono text-text-primary">{CONFIRM_WORD}</code> для подтверждения.
            </p>
            <Input
              value={confirmText}
              onChange={(e) => setConfirmText(e.target.value)}
              placeholder={CONFIRM_WORD}
              autoFocus
            />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={closeDialog}>
              Отмена
            </Button>
            <Button
              variant="danger"
              disabled={confirmText.trim() !== CONFIRM_WORD}
              onClick={confirmSwitch}
            >
              Переключить
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function Row({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex items-start justify-between gap-4">
      <span className="text-text-secondary shrink-0">{label}</span>
      <span className={mono ? 'font-mono text-xs text-text-primary break-all text-right' : 'text-text-primary text-right'}>
        {value}
      </span>
    </div>
  );
}
