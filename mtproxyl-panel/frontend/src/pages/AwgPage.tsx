import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowDown, ArrowUp, FileUp, RefreshCw, Search, Trash2 } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';
import { awgApi, type AwgScanFile, type AwgStatus, type MtproxylOperation } from '@/lib/api';
import { formatBytes } from '@/lib/utils';

const errText = (e: unknown, fallback: string) => (e instanceof Error ? e.message : fallback);

/** Имя конфига из имени файла — те же правила, что у MTProxyL. */
export function awgNameFromFile(file: string): string {
  const base = file.split('/').pop() ?? '';
  const name = base.replace(/\.conf$/i, '').replace(/[^A-Za-z0-9_-]/g, '_').replace(/^[_-]+/, '').slice(0, 32);
  return name || 'awg';
}

/** Импорт клиентского конфига AmneziaWG/WireGuard: Telegram через свой сервер. */
export function AwgPage() {
  const [status, setStatus] = useState<AwgStatus | null>(null);
  const [unsupported, setUnsupported] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await awgApi.status();
      if (!res.supported) {
        setUnsupported(res.message || 'Возможность недоступна');
        setStatus(null);
      } else {
        setUnsupported(null);
        setStatus(res.status ?? null);
      }
      setError(null);
    } catch (e) {
      setError(errText(e, 'Не удалось получить состояние'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['awg:']);
  const locked = busy || running;
  const blocked = Boolean(status && !status.enabled && (status.warp_enabled || status.donor_enabled));

  const act = async (fn: () => Promise<MtproxylOperation>) => {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      start(await fn());
    } catch (e) {
      setError(errText(e, 'Команда не выполнилась'));
    } finally {
      setBusy(false);
    }
  };

  const quick = async (fn: () => Promise<{ output: string }>, fallback: string) => {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      const res = await fn();
      setNotice(res.output.trim() || null);
      await load();
      return true;
    } catch (e) {
      setError(errText(e, fallback));
      return false;
    } finally {
      setBusy(false);
    }
  };

  const check = async () => {
    setBusy(true);
    setError(null);
    try {
      const res = await awgApi.check();
      setStatus(res.status ?? null);
    } catch (e) {
      setError(errText(e, 'Проверка не выполнилась'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <Header title="Telegram через свой AWG" refreshing={loading} onRefresh={load} />

      <div className="p-4 lg:p-6 space-y-4 lg:space-y-6">
        <p className="text-sm text-text-secondary max-w-3xl">
          Клиентский конфиг AmneziaWG или WireGuard от вашего сервера. Через туннель идут только
          подсети Telegram — SSH, обновления и остальной трафик сервера остаются напрямую.
          Middle proxy (ME) работает через адрес выхода туннеля.
        </p>

        {error && <ErrorAlert message={error} onRetry={load} />}
        <OperationProgress operation={operation} onDismiss={dismiss} />
        {unsupported && <Card className="p-6 text-sm text-text-secondary">{unsupported}</Card>}
        {notice && <Card className="p-4 text-xs text-text-secondary whitespace-pre-wrap font-mono">{notice}</Card>}

        {blocked && (
          <Card className="p-4 text-sm text-warning">
            {status?.warp_enabled
              ? 'Включён маршрут через WARP — сначала выключите его на странице «Telegram через WARP».'
              : 'Включён туннель до донора — сначала выключите его на странице «Туннель AWG до донора».'}
          </Card>
        )}

        {status?.enabled && (
          <StateCard
            status={status}
            locked={locked}
            onCheck={() => void check()}
            onDisable={() => void act(awgApi.disable)}
          />
        )}

        {status && (
          <ConfigsCard
            status={status}
            locked={locked || blocked}
            onEnable={(names, mtu, allowMe) => void act(() => awgApi.enable(names, mtu, allowMe))}
            onOrder={(names) => void act(() => awgApi.order(names))}
            onRemove={(name) => void quick(() => awgApi.remove(name), 'Не удалось удалить конфиг')}
          />
        )}

        {status && (
          <ImportCard
            locked={locked}
            onImportBody={(name, body) => quick(() => awgApi.importBody(name, body), 'Конфиг не импортирован')}
            onImportPath={(name, path) => quick(() => awgApi.importPath(name, path), 'Конфиг не импортирован')}
            onError={setError}
          />
        )}
      </div>
    </div>
  );
}

function StateCard({ status, locked, onCheck, onDisable }: {
  status: AwgStatus;
  locked: boolean;
  onCheck: () => void;
  onDisable: () => void;
}) {
  const active = status.configs.find((c) => c.name === status.active);
  const handshakeOk = status.tunnel_up && status.handshake_age !== null && status.handshake_age < 300;
  const working = handshakeOk && status.rules && status.check.result !== 'fail';
  const me = status.me_mode === 'natip'
    ? `через адрес выхода ${status.egress_ip}`
    : status.me_disabled
      ? 'выключен на время работы через AWG'
      : 'не используется';
  const engine = status.engine_routed === 'target'
    ? 'цель реаниматора'
    : status.engine_mode === 'manual'
      ? 'конфиг движка — вручную'
      : 'менеджер';
  const checkedAt = status.check.at ? new Date(status.check.at * 1000).toLocaleString('ru-RU') : '—';

  return (
    <Card className="p-4 space-y-3">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div className="text-sm">
          <span className="text-text-primary font-medium">
            Telegram идёт через «{status.active}»
            {(status.order?.length ?? 0) > 1 && status.order?.[0] !== status.active ? ' (запасной)' : ''}
          </span>
          <div className="text-xs text-text-secondary mt-0.5">
            {working ? 'Туннель поднят, маршрут применён' : 'Туннель или маршрут не подтверждён — нажмите «Проверить»'}
          </div>
        </div>
        <Badge variant={working ? 'success' : 'warning'}>{working ? 'работает' : 'проверьте'}</Badge>
      </div>

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 text-sm">
        <Cell label="Сервер" value={active ? `${active.endpoint}${active.awg_version ? ` · ${active.awg_version}` : ''}` : '—'} />
        <Cell label="Адрес в туннеле" value={active?.address || '—'} />
        <Cell label="Туннель" value={status.tunnel_up ? `${status.iface} поднят${status.mtu ? ` · MTU ${status.mtu}` : ''}` : 'не поднят'} />
        <Cell label="Рукопожатие" value={status.handshake_age !== null ? `${status.handshake_age} с назад` : 'нет'} />
        <Cell label="Выход в интернет" value={status.egress_ip || '—'} />
        <Cell label="Middle proxy" value={me} />
        <Cell label="Движок" value={engine} />
        <Cell label="Трафик туннеля" value={`↓ ${formatBytes(status.rx_bytes)} · ↑ ${formatBytes(status.tx_bytes)}`} />
        <Cell label="IPv6 до Telegram" value={status.ipv6 ? 'через туннель' : 'выключен, идёт IPv4'} />
        <Cell label="Последняя проверка" value={`${checkedAt}${status.check.result ? ` · ${status.check.result}` : ''}`} />
        {(status.order?.length ?? 0) > 1 && <Cell label="Порядок выходов" value={(status.order ?? []).join(' → ')} />}
        {status.last_switch?.at ? (
          <Cell label="Последнее переключение"
            value={`${new Date(status.last_switch.at * 1000).toLocaleString('ru-RU')} · ${status.last_switch.from} → ${status.last_switch.to} · ${status.last_switch.reason}`} />
        ) : null}
        {status.check.error && <Cell label="Причина" value={status.check.error} />}
      </div>
      {status.fail_since ? (
        <p className="text-xs text-warning">
          «{status.active}» не отвечает с {new Date(status.fail_since * 1000).toLocaleTimeString('ru-RU')}
          {(status.order?.length ?? 0) > 1 ? ' — через 3 минуты сбоя движок перейдёт на запасной.' : '.'}
        </p>
      ) : null}

      <div className="flex flex-wrap gap-2">
        <Button variant="outline" size="sm" disabled={locked} onClick={onCheck}>
          <RefreshCw size={14} className="mr-1.5" /> Проверить
        </Button>
        <Button variant="outline" size="sm" disabled={locked} onClick={() => {
          if (window.confirm('Выключить выход через AWG? Движок пойдёт к Telegram напрямую.')) onDisable();
        }}>
          Выключить
        </Button>
      </div>
    </Card>
  );
}

/** Порядок выходов: сначала текущий порядок, затем остальные конфиги. */
export function initialSelection(status: AwgStatus): string[] {
  const names = status.configs.map((c) => c.name);
  const order = (status.order ?? []).filter((n) => names.includes(n));
  if (order.length > 0) return order;
  if (status.active && names.includes(status.active)) return [status.active];
  return names.slice(0, 1);
}

function ConfigsCard({ status, locked, onEnable, onOrder, onRemove }: {
  status: AwgStatus;
  locked: boolean;
  onEnable: (names: string[], mtu: number, allowDisableMe: boolean) => void;
  onOrder: (names: string[]) => void;
  onRemove: (name: string) => void;
}) {
  const [selected, setSelected] = useState<string[]>(() => initialSelection(status));
  const [mtu, setMtu] = useState('');
  const [allowMe, setAllowMe] = useState(false);
  const statusKey = `${status.configs.map((c) => c.name).join(',')}|${(status.order ?? []).join(',')}|${status.active}`;

  useEffect(() => {
    setSelected(initialSelection(status));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [statusKey]);

  const mtuNum = mtu.trim() === '' ? 0 : Number(mtu);
  const mtuOk = mtuNum === 0 || (Number.isInteger(mtuNum) && mtuNum >= 1200 && mtuNum <= 1500);
  const currentOrder = (status.order ?? []).join(',');
  const orderChanged = selected.join(',') !== currentOrder;
  const ordered = [...selected, ...status.configs.map((c) => c.name).filter((n) => !selected.includes(n))];
  const byName = new Map(status.configs.map((c) => [c.name, c]));

  const toggle = (name: string) =>
    setSelected((cur) => (cur.includes(name) ? cur.filter((n) => n !== name) : [...cur, name]));
  const move = (name: string, delta: number) =>
    setSelected((cur) => {
      const i = cur.indexOf(name);
      const j = i + delta;
      if (i < 0 || j < 0 || j >= cur.length) return cur;
      const next = [...cur];
      [next[i], next[j]] = [next[j], next[i]];
      return next;
    });

  return (
    <Card className="p-4 space-y-3">
      <div>
        <h3 className="text-sm font-medium text-text-primary">Выходы</h3>
        <p className="text-xs text-text-secondary mt-0.5">
          Отмеченные — по порядку: первый основной, остальные запасные. Если основной не отвечает
          дольше 3 минут, движок перейдёт на следующий и вернётся, когда основной оживёт.
        </p>
      </div>
      {status.configs.length === 0 ? (
        <p className="text-sm text-text-secondary">Импортированных конфигов пока нет — загрузите файл или выберите найденный ниже.</p>
      ) : (
        <div className="space-y-1.5">
          {ordered.map((name) => {
            const c = byName.get(name);
            if (!c) return null;
            const pos = selected.indexOf(name);
            const isActive = status.enabled && status.active === name;
            return (
              <div key={name} className="flex items-center gap-2 text-sm min-w-0">
                <input type="checkbox" checked={pos >= 0} disabled={locked} onChange={() => toggle(name)}
                  aria-label={`Использовать ${name}`} />
                <span className="w-20 shrink-0 text-xs text-text-secondary whitespace-nowrap">
                  {pos === 0 ? 'основной' : pos > 0 ? `запасной ${pos}` : ''}
                </span>
                <span className="text-text-primary truncate">{name}</span>
                <span className="text-xs text-text-secondary truncate hidden sm:inline">
                  {c.endpoint} · {c.address}{c.awg_version ? ` · ${c.awg_version}` : c.obfuscation ? ' · AWG' : ''}
                </span>
                {isActive && <Badge variant="success">сейчас</Badge>}
                <span className="ml-auto flex items-center gap-1 shrink-0">
                  {pos >= 0 && (
                    <>
                      <button type="button" className="px-1 text-text-secondary hover:text-text-primary disabled:opacity-30"
                        title="Выше" disabled={locked || pos === 0} onClick={() => move(name, -1)}>
                        <ArrowUp size={14} />
                      </button>
                      <button type="button" className="px-1 text-text-secondary hover:text-text-primary disabled:opacity-30"
                        title="Ниже" disabled={locked || pos === selected.length - 1} onClick={() => move(name, 1)}>
                        <ArrowDown size={14} />
                      </button>
                    </>
                  )}
                  <button type="button" className="px-1 text-text-secondary hover:text-danger disabled:opacity-30"
                    title="Удалить конфиг" disabled={locked || isActive}
                    onClick={() => { if (window.confirm(`Удалить конфиг «${name}»?`)) onRemove(name); }}>
                    <Trash2 size={14} />
                  </button>
                </span>
              </div>
            );
          })}
        </div>
      )}

      {status.configs.length > 0 && status.enabled && (
        <div className="flex flex-wrap items-center gap-3 border-t border-border pt-3">
          <Button size="sm" disabled={locked || selected.length === 0 || !orderChanged} onClick={() => onOrder(selected)}>
            Сохранить порядок
          </Button>
          <span className="text-xs text-text-secondary">
            Туннель не перезапускается; если текущий выход убран из списка — переключится сразу.
          </span>
        </div>
      )}

      {status.configs.length > 0 && !status.enabled && (
        <div className="space-y-3 border-t border-border pt-3">
          <div className="flex flex-wrap items-end gap-3">
            <div>
              <div className="text-xs text-text-secondary mb-1">MTU (пусто — из конфига)</div>
              <Input className="w-32" value={mtu} placeholder="1280" disabled={locked}
                onChange={(e) => setMtu(e.target.value)} />
            </div>
            <Button size="sm" disabled={locked || selected.length === 0 || !mtuOk}
              onClick={() => onEnable(selected, mtuNum, allowMe)}>
              {selected.length > 1 ? `Включить «${selected[0]}» и ${selected.length - 1} запасн.` : `Включить «${selected[0] ?? ''}»`}
            </Button>
          </div>
          {!mtuOk && <p className="text-xs text-danger">MTU — от 1200 до 1500</p>}
          <label className="flex items-start gap-2 text-sm">
            <input type="checkbox" className="mt-1" checked={allowMe} disabled={locked}
              onChange={(e) => setAllowMe(e.target.checked)} />
            <span>
              <span className="block text-text-primary">Если middle proxy не поднимется — выключить его</span>
              <span className="block text-xs text-text-secondary">
                Ключи ME зависят от адреса и порта выхода; если сервер AWG их меняет, ME не работает.
                Без ME движок ходит к дата-центрам напрямую, рекламная метка не действует.
                Включится обратно при выключении выхода.
              </span>
            </span>
          </label>
          <p className="text-xs text-text-secondary">
            Движок перезапустится: открытые соединения клиентов переподключатся. Так же — при
            каждом переключении на запасной и обратно.
          </p>
        </div>
      )}
    </Card>
  );
}

function ImportCard({ locked, onImportBody, onImportPath, onError }: {
  locked: boolean;
  onImportBody: (name: string, body: string) => Promise<boolean>;
  onImportPath: (name: string, path: string) => Promise<boolean>;
  onError: (msg: string) => void;
}) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [found, setFound] = useState<AwgScanFile[] | null>(null);
  const [scanning, setScanning] = useState(false);
  const [path, setPath] = useState('');

  const scan = async () => {
    setScanning(true);
    try {
      setFound((await awgApi.scan()).files);
    } catch (e) {
      onError(errText(e, 'Поиск не выполнился'));
    } finally {
      setScanning(false);
    }
  };

  const upload = async (file: File) => {
    if (file.size > 64 * 1024) {
      onError('Файл больше 64 КБ — это не конфиг WireGuard');
      return;
    }
    await onImportBody(awgNameFromFile(file.name), await file.text());
  };

  const importPath = async (p: string) => {
    if (await onImportPath(awgNameFromFile(p), p)) {
      setPath('');
      if (found) void scan();
    }
  };

  return (
    <Card className="p-4 space-y-4">
      <h3 className="text-sm font-medium text-text-primary">Добавить конфиг</h3>

      <div className="flex flex-wrap gap-2">
        <input ref={fileRef} type="file" accept=".conf,text/plain" className="hidden"
          onChange={(e) => {
            const f = e.target.files?.[0];
            e.target.value = '';
            if (f) void upload(f);
          }} />
        <Button variant="outline" size="sm" disabled={locked} onClick={() => fileRef.current?.click()}>
          <FileUp size={14} className="mr-1.5" /> Загрузить файл .conf
        </Button>
        <Button variant="outline" size="sm" disabled={locked || scanning} onClick={() => void scan()}>
          <Search size={14} className="mr-1.5" /> {scanning ? 'Ищем…' : 'Найти на сервере'}
        </Button>
      </div>

      {found && (
        <div className="space-y-1.5">
          {found.length === 0 && (
            <p className="text-sm text-text-secondary">
              В /opt/mtproxyl, /root, /etc/amnezia и /etc/wireguard конфигов не найдено.
            </p>
          )}
          {found.map((f) => (
            <div key={f.path} className="flex items-center gap-2 text-sm">
              <span className="text-text-primary truncate" title={f.path}>{f.path}</span>
              <span className="text-xs text-text-secondary truncate">
                {f.valid ? `${f.endpoint}${f.awg_version ? ` · ${f.awg_version}` : ''}` : `не подходит: ${f.error}`}
              </span>
              {f.valid && (
                <Button variant="outline" size="sm" className="ml-auto" disabled={locked}
                  onClick={() => void importPath(f.path)}>
                  Импортировать
                </Button>
              )}
            </div>
          ))}
        </div>
      )}

      <div className="flex flex-wrap items-end gap-2">
        <div className="flex-1 min-w-[16rem]">
          <div className="text-xs text-text-secondary mb-1">Или полный путь к файлу на сервере</div>
          <Input value={path} placeholder="/root/my-server.conf" disabled={locked}
            onChange={(e) => setPath(e.target.value)} />
        </div>
        <Button variant="outline" size="sm" disabled={locked || !path.trim().startsWith('/')}
          onClick={() => void importPath(path.trim())}>
          Импортировать
        </Button>
      </div>
      <p className="text-xs text-text-secondary">
        DNS, Table и команды PostUp/PreUp из конфига не используются — маршруты задаёт MTProxyL.
        Ключи хранятся только на сервере, в панель они не возвращаются.
      </p>
    </Card>
  );
}

function Cell({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <div className="text-xs text-text-secondary">{label}</div>
      <div className="text-text-primary truncate" title={value}>
        {value}
      </div>
    </div>
  );
}
