import { useCallback, useEffect, useState } from 'react';
import { Bot, Play, RefreshCw, Square, Trash2, UserPlus } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { OperationProgress } from '@/components/OperationProgress';
import { StatusDot } from '@/components/StatusDot';
import { useManagerOnly, useMtproxylOperation } from '@/hooks/useMtproxyl';
import { tgbotApi, type TgbotStatus } from '@/lib/api';
import { cn } from '@/lib/utils';

const NOTIFY_LABELS: Array<[string, string]> = [
  ['availability', 'Доступность ниже порога'],
  ['proxy', 'Прокси упал или поднялся'],
  ['limits', 'Лимиты пользователей'],
  ['backup', 'Итог автобэкапа'],
];

const INTERVAL_LABELS: Array<[string, string]> = [
  ['availability', 'Доступность'],
  ['proxy', 'Прокси'],
  ['limits', 'Лимиты'],
];

/**
 * Управление телеграм-ботом. Ставит и настраивает его тот же CLI, что и всё
 * остальное, — панель показывает состояние и нажимает кнопки. Доступно в обоих
 * режимах: от режима зависит только автобэкап внутри самого бота.
 */
export function TgbotPage() {
  const { allowed: isManager } = useManagerOnly();
  const [status, setStatus] = useState<TgbotStatus | null>(null);
  const [supported, setSupported] = useState(true);
  const [message, setMessage] = useState('');
  const [hint, setHint] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [logs, setLogs] = useState('');
  const [confirmRemove, setConfirmRemove] = useState(false);

  const [token, setToken] = useState('');
  const [admin, setAdmin] = useState('');
  const [newAdmin, setNewAdmin] = useState('');

  const load = useCallback(async () => {
    try {
      const res = await tgbotApi.status();
      setSupported(res.supported);
      setMessage(res.message ?? '');
      setStatus(res.status ?? null);
      setHint(res.hint ?? '');
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить состояние бота');
    }
  }, []);

  // Установка тянет venv и aiogram — это минуты. Слот операции общий на
  // панель, поэтому берём из него только своё и гасим результат на сервере:
  // иначе отчёт вернётся при следующем открытии страницы.
  const { operation, start, dismiss, running: installing } = useMtproxylOperation(load, ['tgbot:']);

  useEffect(() => {
    void load();
  }, [load]);

  const act = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не получилось');
    } finally {
      setBusy(false);
    }
  };

  const install = () =>
    act(async () => {
      start(await tgbotApi.install(token.trim(), Number(admin.trim() || 0)));
      setToken('');
      setAdmin('');
    });

  const showLogs = () =>
    act(async () => setLogs((await tgbotApi.logs(120)).lines || 'Журнал пуст'));

  const installed = status?.installed ?? false;
  const serviceUp = status?.active ?? false;
  // Пустые поля означают «переустановить с прежним токеном» — это возможно,
  // только если токен уже сохранён. Иначе установщику нечем заводить бота.
  const configured = status?.configured ?? false;
  const canInstall = configured || (token.trim() !== '' && admin.trim() !== '');

  if (!supported) {
    return (
      <div className="space-y-4">
        <PageTitle />
        <Card className="p-6 text-sm text-text-secondary">{message}</Card>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <PageTitle />
      {error && <ErrorAlert message={error} onRetry={() => void load()} />}
      <OperationProgress operation={operation} onDismiss={dismiss} />

      <Card>
        <CardHeader className="flex-row items-center justify-between">
          <CardTitle>Состояние</CardTitle>
          <Button variant="ghost" size="sm" onClick={() => void load()} className="gap-2">
            <RefreshCw className="h-4 w-4" /> Обновить
          </Button>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          <div className="flex items-center gap-2">
            <StatusDot status={!installed ? 'error' : serviceUp ? 'ok' : 'warn'} />
            <span className="font-medium">
              {!installed
                ? 'Не установлен'
                : !status?.configured
                  ? 'Установлен, но не настроен'
                  : serviceUp
                    ? 'Работает'
                    : 'Остановлен'}
            </span>
            {installed && !status?.enabled && (
              <span className="text-warning">· автозапуск выключен</span>
            )}
          </div>
          {installed && (
            <div className="grid gap-1 text-text-secondary">
              <div>
                Каталог: <code className="bg-surface-hover px-1 rounded">{status?.dir}</code>
              </div>
              <div>
                Служба: <code className="bg-surface-hover px-1 rounded">{status?.service}</code>
              </div>
              <div>Администраторов: {status?.config.admins?.length ?? 0}</div>
            </div>
          )}

          {installed && (
            <div className="flex flex-wrap gap-2 pt-1">
              <Button size="sm" disabled={busy} className="gap-2"
                onClick={() => void act(() => tgbotApi.service(serviceUp ? 'restart' : 'start'))}>
                {serviceUp ? <RefreshCw className="h-4 w-4" /> : <Play className="h-4 w-4" />}
                {serviceUp ? 'Перезапустить' : 'Запустить'}
              </Button>
              {serviceUp && (
                <Button size="sm" variant="outline" disabled={busy} className="gap-2"
                  onClick={() => void act(() => tgbotApi.service('stop'))}>
                  <Square className="h-4 w-4" /> Остановить
                </Button>
              )}
              <Button size="sm" variant="outline" disabled={busy}
                onClick={() => void act(() => tgbotApi.service('update'))}>
                Обновить код бота
              </Button>
              <Button size="sm" variant="outline" disabled={busy} onClick={() => void showLogs()}>
                Журнал службы
              </Button>
              <Button size="sm" variant="danger" disabled={busy} className="gap-2"
                onClick={() => setConfirmRemove(true)}>
                <Trash2 className="h-4 w-4" /> Удалить
              </Button>
            </div>
          )}
        </CardContent>
      </Card>

      {logs && (
        <Card>
          <CardHeader className="flex-row items-center justify-between">
            <CardTitle>Журнал службы</CardTitle>
            <Button variant="ghost" size="sm" onClick={() => setLogs('')}>Закрыть</Button>
          </CardHeader>
          <CardContent>
            <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-all rounded bg-surface-hover p-3 text-xs">
              {logs}
            </pre>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle>{installed ? 'Переустановка' : 'Установка'}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {hint && (
            <div className="rounded bg-surface-hover p-3 text-xs text-text-secondary whitespace-pre-line">
              {hint}
            </div>
          )}
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="tgbot-token">Токен бота</Label>
              <Input id="tgbot-token" value={token} placeholder="1234567890:AAH…"
                onChange={(e) => setToken(e.target.value)} autoComplete="off" />
            </div>
            <div className="space-y-1">
              <Label htmlFor="tgbot-admin">Ваш Telegram ID</Label>
              <Input id="tgbot-admin" value={admin} placeholder="123456789" inputMode="numeric"
                onChange={(e) => setAdmin(e.target.value.replace(/\D/g, ''))} />
            </div>
          </div>
          <p className="text-xs text-text-secondary">
            {configured
              ? 'Оставьте поля пустыми, чтобы переустановить бота с прежним токеном: обновятся код, зависимости и права sudo.'
              : 'Ставится в /opt/mtproxyl-tgbot: python в venv, отдельная служба от пользователя без прав. Занимает пару минут.'}
          </p>
          <Button disabled={busy || installing || !canInstall} onClick={() => void install()}>
            {installed ? 'Переустановить' : 'Установить бота'}
          </Button>
          {!canInstall && (
            <p className="text-xs text-warning">
              Заполните оба поля: без токена и вашего Telegram ID бота не завести.
            </p>
          )}
        </CardContent>
      </Card>

      {installed && status?.configured && (
        <>
          <Card>
            <CardHeader>
              <CardTitle>Уведомления</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2">
              <p className="text-xs text-text-secondary">
                Бот пишет при смене состояния, а не на каждой проверке.
              </p>
              {NOTIFY_LABELS.filter(([key]) => isManager || key !== 'backup').map(([key, title]) => {
                const on = status.config.notify?.[key] !== false;
                return (
                  <div key={key} className="flex items-center justify-between gap-3 border-b border-border py-2 last:border-0">
                    <span className="text-sm">{title}</span>
                    <Button size="sm" variant={on ? 'default' : 'outline'} disabled={busy}
                      onClick={() => void act(() => tgbotApi.set(`notify.${key}`, on ? 'false' : 'true'))}>
                      {on ? 'Включено' : 'Выключено'}
                    </Button>
                  </div>
                );
              })}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Как часто сверяться</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <p className="text-xs text-text-secondary">
                На квоту Globalping не влияет: бот читает готовый результат проверки.
              </p>
              {INTERVAL_LABELS.map(([key, title]) => (
                <IntervalRow key={key} title={title} minutes={status.config.intervals?.[key] ?? 15}
                  disabled={busy}
                  onSave={(v) => void act(() => tgbotApi.set(`intervals.${key}`, v))} />
              ))}
            </CardContent>
          </Card>

          {isManager && (
            <Card>
              <CardHeader>
                <CardTitle>Автобэкап в телеграм</CardTitle>
              </CardHeader>
              <CardContent className="space-y-3">
                <div className="flex items-center justify-between gap-3">
                  <span className="text-sm">Собирать по расписанию</span>
                  <Button size="sm" disabled={busy}
                    variant={status.config.autobackup?.enabled ? 'default' : 'outline'}
                    onClick={() => void act(() => tgbotApi.set('autobackup.enabled',
                      status.config.autobackup?.enabled ? 'false' : 'true'))}>
                    {status.config.autobackup?.enabled ? 'Включён' : 'Выключен'}
                  </Button>
                </div>
                <div className="flex items-center justify-between gap-3">
                  <span className="text-sm">Присылать файл в чат</span>
                  <Button size="sm" disabled={busy}
                    variant={status.config.autobackup?.send_file ? 'default' : 'outline'}
                    onClick={() => void act(() => tgbotApi.set('autobackup.send_file',
                      status.config.autobackup?.send_file ? 'false' : 'true'))}>
                    {status.config.autobackup?.send_file ? 'Да' : 'Нет'}
                  </Button>
                </div>
                <TimeRow time={status.config.autobackup?.time ?? '05:30'} disabled={busy}
                  onSave={(v) => void act(() => tgbotApi.set('autobackup.time', v))} />
              </CardContent>
            </Card>
          )}

          <Card>
            <CardHeader>
              <CardTitle>Администраторы</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <p className="text-xs text-text-secondary">
                Бот отвечает только этим Telegram ID. Список читается на каждом сообщении —
                добавленный получает доступ сразу.
              </p>
              {(status.config.admins ?? []).map((id) => (
                <div key={id} className="flex items-center justify-between gap-3 border-b border-border py-2 last:border-0">
                  <code className="text-sm">{id}</code>
                  <Button size="sm" variant="outline" disabled={busy}
                    onClick={() => void act(() => tgbotApi.admin(id, true))}>
                    Убрать
                  </Button>
                </div>
              ))}
              {(status.config.admins ?? []).length === 0 && (
                <p className="text-sm text-warning">Никого — бот никого не пустит.</p>
              )}
              <div className="flex gap-2">
                <Input value={newAdmin} placeholder="Telegram ID" inputMode="numeric"
                  onChange={(e) => setNewAdmin(e.target.value.replace(/\D/g, ''))} />
                <Button className="gap-2 shrink-0" disabled={busy || !newAdmin}
                  onClick={() => void act(async () => {
                    await tgbotApi.admin(Number(newAdmin));
                    setNewAdmin('');
                  })}>
                  <UserPlus className="h-4 w-4" /> Добавить
                </Button>
              </div>
            </CardContent>
          </Card>
        </>
      )}

      <ConfirmDialog
        open={confirmRemove}
        onClose={() => setConfirmRemove(false)}
        title="Удалить телеграм-бота?"
        message="Служба, каталог /opt/mtproxyl-tgbot и права sudo будут удалены. Токен придётся вводить заново."
        confirmLabel="Удалить"
        loading={busy}
        onConfirm={() => {
          setConfirmRemove(false);
          void act(() => tgbotApi.uninstall());
        }}
      />
    </div>
  );
}

function PageTitle() {
  return (
    <div className="flex items-center gap-2">
      <Bot className="h-5 w-5 text-accent" />
      <h1 className="text-xl font-semibold">Телеграм-бот</h1>
    </div>
  );
}

/** Поле «минут» с кнопкой сохранения: правка чисел на каждый нажатый символ
 *  дёргала бы CLI и переписывала конфиг бота. */
function IntervalRow({
  title, minutes, disabled, onSave,
}: {
  title: string;
  minutes: number;
  disabled: boolean;
  onSave: (value: string) => void;
}) {
  const [value, setValue] = useState(String(minutes));
  useEffect(() => setValue(String(minutes)), [minutes]);
  const dirty = value !== String(minutes);
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-sm">{title}</span>
      <div className="flex items-center gap-2">
        <Input className="w-24" value={value} inputMode="numeric"
          onChange={(e) => setValue(e.target.value.replace(/\D/g, ''))} />
        <span className="text-xs text-text-secondary">мин</span>
        <Button size="sm" disabled={disabled || !dirty || !value}
          className={cn(!dirty && 'invisible')} onClick={() => onSave(value)}>
          Сохранить
        </Button>
      </div>
    </div>
  );
}

function TimeRow({
  time, disabled, onSave,
}: {
  time: string;
  disabled: boolean;
  onSave: (value: string) => void;
}) {
  const [value, setValue] = useState(time);
  useEffect(() => setValue(time), [time]);
  const dirty = value !== time;
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-sm">Время сбора</span>
      <div className="flex items-center gap-2">
        <Input className="w-28" value={value} placeholder="05:30"
          onChange={(e) => setValue(e.target.value)} />
        <Button size="sm" disabled={disabled || !dirty}
          className={cn(!dirty && 'invisible')} onClick={() => onSave(value)}>
          Сохранить
        </Button>
      </div>
    </div>
  );
}
