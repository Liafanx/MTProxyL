import { useCallback, useEffect, useState } from 'react';
import { Server, Stethoscope } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import {
  mtproxylApi,
  type ContainerDisposition,
  type MtproxylMode,
  type MtproxylModeStatus,
} from '@/lib/api';
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

const CONTAINER_STATE_LABELS: Record<string, string> = {
  running: 'работает',
  restarting: 'перезапускается',
  exited: 'остановлен',
  created: 'создан, но не запущен',
  paused: 'приостановлен',
  dead: 'в состоянии dead',
};

/** То же для движка-бинарника: там снимается служба, а не контейнер. */
const BINARY_ENGINE_CHOICES: { id: ContainerDisposition; title: string; hint: string }[] = [
  {
    id: 'remove',
    title: 'Остановить и снять службу (рекомендуется)',
    hint: 'Порт освобождается полностью. Бинарник, конфиг и настройки остаются — при возврате в Manager служба создаётся заново.',
  },
  {
    id: 'stop',
    title: 'Только остановить службу',
    hint: 'Порт освобождается, юнит остаётся на месте.',
  },
  {
    id: 'keep',
    title: 'Не трогать',
    hint: 'Движок продолжит работать и держать порт — цель реаниматора на этом порту не запустится.',
  },
];

/**
 * Судьба своего контейнера при уходе в реаниматор.
 *
 * Те же три варианта, что задаёт CLI. Панель раньше не спрашивала, а
 * MTPROXYL_ASSUME_YES выбирал за пользователя первый — контейнер удалялся молча.
 */
const CONTAINER_CHOICES: { id: ContainerDisposition; title: string; hint: string }[] = [
  {
    id: 'remove',
    title: 'Остановить и удалить (рекомендуется)',
    hint: 'Порт освобождается полностью. Настройки MTProxyL остаются — при возврате в Manager контейнер создаётся заново.',
  },
  {
    id: 'stop',
    title: 'Только остановить, контейнер оставить',
    hint: 'Порт освобождается, контейнер остаётся на диске. Автозапуск снимается, чтобы он не поднялся после перезагрузки.',
  },
  {
    id: 'keep',
    title: 'Не трогать',
    hint: 'Контейнер продолжит работать и держать порт — цель реаниматора на этом порту не запустится.',
  },
];

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
  // Умолчание совпадает с рекомендацией CLI, но теперь это видимый выбор, а не
  // то, что произойдёт молча.
  const [disposition, setDisposition] = useState<ContainerDisposition>('remove');

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

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['mode:']);

  useEffect(() => {
    void load();
  }, [load]);

  const closeDialog = () => {
    setTarget(null);
    setConfirmText('');
    setDisposition('remove');
  };

  const confirmSwitch = async () => {
    if (!target) return;
    try {
      start(
        await mtproxylApi.switchMode(target, target === 'reanimator' ? disposition : undefined),
      );
      setError(null);
      closeDialog();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переключить режим');
      closeDialog();
    }
  };

  const current = status?.mode;
  // Носитель движка менеджера: контейнер или служба MTProxyL-Telemt.
  const isBinaryEngine = status?.engine === 'binary';
  const engineWord = isBinaryEngine ? 'движок' : 'контейнер';
  // Спрашивать про контейнер имеет смысл, только когда он есть.
  const hasOwnContainer =
    status?.own_container !== undefined &&
    status.own_container !== 'absent' &&
    status.own_container !== 'unknown';

  return (
    <div className="p-4 lg:p-6 space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Режим работы</h1>
        <p className="text-sm text-text-secondary mt-1">
          Определяет, владеет ли MTProxyL своим экземпляром telemt или обслуживает чужой.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={load} />}
      <OperationProgress operation={operation} onDismiss={dismiss} />

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

          {status && current === 'manager' && (
            <Card>
              <CardHeader>
                <CardTitle>Движок</CardTitle>
              </CardHeader>
              <CardContent className="space-y-2 text-sm">
                <Row
                  label="Носитель"
                  value={isBinaryEngine ? 'Бинарник MTProxyL-Telemt (systemd)' : 'Docker-контейнер'}
                />
                <Row
                  label="Состояние"
                  value={
                    CONTAINER_STATE_LABELS[status.own_container ?? ''] ??
                    status.own_container ??
                    'неизвестно'
                  }
                />
                <Row label="Конфиг" value={status.engine_config || 'не найден'} mono />
                <Row
                  label="Транспорт"
                  value={status.proxy_mode === 'web' ? 'Только WEB' : status.proxy_mode === 'combined' ? 'MTProto + WEB' : 'Только MTProto'}
                />
                <Row label="Порт" value={status.proxy_mode === 'web' ? '443 (WEB)' : String(status.port)} />
              </CardContent>
            </Card>
          )}

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
                : `Управление собственным ${engineWord === 'движок' ? 'движком' : 'контейнером'} из меню прекратится. Конфиг цели MTProxyL не переписывает — применяет только хостовые фиксы.`}
            </p>

            {target === 'reanimator' && hasOwnContainer && (
              <div className="space-y-2 border border-border rounded-lg p-3">
                <div className="text-sm text-text-primary">
                  Что сделать со своим {engineWord === 'движок' ? 'движком' : 'контейнером'}?
                </div>
                <p className="text-xs text-text-secondary">
                  Сейчас он {CONTAINER_STATE_LABELS[status?.own_container ?? ''] ?? status?.own_container} и
                  занимает порт {status?.port}. Тот же порт возможно нужен цели реаниматора.
                </p>
                {(isBinaryEngine ? BINARY_ENGINE_CHOICES : CONTAINER_CHOICES).map(({ id, title, hint }) => (
                  <label key={id} className="flex items-start gap-2 cursor-pointer">
                    <input
                      type="radio"
                      name="container-disposition"
                      className="mt-1 shrink-0"
                      checked={disposition === id}
                      onChange={() => setDisposition(id)}
                    />
                    <span className="min-w-0">
                      <span className="text-sm text-text-primary">{title}</span>
                      <span className="block text-xs text-text-secondary">{hint}</span>
                    </span>
                  </label>
                ))}
              </div>
            )}

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
