import { useCallback, useEffect, useMemo, useState } from 'react';
import { Cable, Download, KeyRound, RefreshCw, Trash2 } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { CopyButton } from '@/components/CopyButton';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';
import {
  donorApi,
  type DonorHostKey,
  type DonorStatus,
  type MtproxylOperation,
} from '@/lib/api';
import { formatBytes } from '@/lib/utils';

const errText = (e: unknown, fallback: string) => (e instanceof Error ? e.message : fallback);

/** Туннель AmneziaWG до сервера-донора: движок выходит к Telegram через него. */
export function DonorPage() {
  const [status, setStatus] = useState<DonorStatus | null>(null);
  const [unsupported, setUnsupported] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showSetup, setShowSetup] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await donorApi.status();
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

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['donor:']);
  const locked = busy || running;

  const act = async (fn: () => Promise<MtproxylOperation>) => {
    setBusy(true);
    setError(null);
    try {
      start(await fn());
      setShowSetup(false);
    } catch (e) {
      setError(errText(e, 'Команда не выполнилась'));
    } finally {
      setBusy(false);
    }
  };

  const check = async () => {
    setBusy(true);
    setError(null);
    try {
      const res = await donorApi.check();
      setStatus(res.status ?? null);
    } catch (e) {
      setError(errText(e, 'Проверка не выполнилась'));
    } finally {
      setBusy(false);
    }
  };

  const ready = status?.stage === 'ready';

  return (
    <div>
      <Header title="Туннель AWG до донора" refreshing={loading} onRefresh={load} />

      <div className="p-4 lg:p-6 space-y-4 lg:space-y-6">
        <p className="text-sm text-text-secondary max-w-3xl">
          Для серверов, откуда не открываются Telegram или его дата-центры. Движок
          выходит к Telegram через второй сервер — донор — по туннелю AmneziaWG.
          На доноре SOCKS5 слушает только адрес внутри туннеля. Адрес выхода один,
          поэтому middle proxy (ME) и рекламная метка работают — в отличие от WARP.
        </p>

        {error && <ErrorAlert message={error} onRetry={load} />}
        <OperationProgress operation={operation} onDismiss={dismiss} />
        {unsupported && <Card className="p-6 text-sm text-text-secondary">{unsupported}</Card>}

        {status?.warp_enabled && (
          <Card className="p-4 text-sm text-warning">
            Включён маршрут через WARP — сначала выключите его на странице «Telegram через WARP».
          </Card>
        )}

        {status && ready && (
          <>
            <StateCard status={status} />
            <ControlsCard
              status={status}
              locked={locked}
              onCheck={() => void check()}
              onAct={(fn) => void act(fn)}
              onReconfigure={() => setShowSetup((v) => !v)}
              reconfiguring={showSetup}
            />
          </>
        )}

        {status?.stage === 'pending' && (
          <ManualFinishCard status={status} locked={locked} onAct={(fn) => void act(fn)} onError={setError} />
        )}

        {status && (!ready || showSetup) && (
          <SetupCard status={status} locked={locked} onAct={(fn) => void act(fn)} onPrepared={load} onError={setError} />
        )}

        <HowItWorks />
      </div>
    </div>
  );
}

function StateCard({ status }: { status: DonorStatus }) {
  const handshakeOk = status.tunnel_up && status.handshake_age !== null && status.handshake_age < 180;
  const working = status.enabled && handshakeOk && status.check.result !== 'down' && status.check.result !== 'degraded';
  const routed =
    status.engine_routed === 'manager'
      ? 'через донор (upstream donor)'
      : status.engine_routed === 'target'
        ? 'через донор (конфиг цели)'
        : status.engine_mode === 'manual'
          ? 'маршрут в конфиг движка — вручную'
          : 'не переключён';
  const checkedAt = status.check.at ? new Date(status.check.at * 1000).toLocaleString('ru-RU') : '—';

  return (
    <Card className="p-4 space-y-3">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div className="text-sm">
          <span className="text-text-primary font-medium">
            {status.enabled ? `Движок выходит через ${status.host}` : `Выключен (донор ${status.host})`}
          </span>
          <div className="text-xs text-text-secondary mt-0.5">
            {status.enabled
              ? working
                ? 'Туннель поднят, донор отвечает'
                : 'Туннель или выход через донор не подтверждён — нажмите «Проверить»'
              : 'Движок ходит к Telegram напрямую'}
          </div>
        </div>
        <Badge variant={status.enabled ? (working ? 'success' : 'warning') : 'outline'}>
          {status.enabled ? (working ? 'работает' : 'проверьте') : 'выключен'}
        </Badge>
      </div>

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 text-sm">
        <Cell label="Донор" value={`${status.ssh_user}@${status.host}`} />
        {status.host_is_name && <Cell label="Адрес донора" value={status.resolved_ip ? `${status.resolved_ip} · по домену` : '—'} />}
        <Cell label="Порт AmneziaWG" value={status.awg_port ? `UDP ${status.awg_port} · MTU ${status.mtu}` : '—'} />
        <Cell label="Туннель" value={status.tunnel_up ? `${status.iface} поднят` : 'не поднят'} />
        <Cell
          label="Рукопожатие"
          value={status.handshake_age !== null ? `${status.handshake_age} с назад` : 'нет'}
        />
        <Cell label="SOCKS5 донора" value={status.socks || '—'} />
        <Cell label="Выход в интернет" value={status.check.egress_ip || status.public_ip || '—'} />
        <Cell label="Движок" value={routed} />
        <Cell label="Выключены на время" value={status.disabled_upstreams || '—'} />
        <Cell label="Трафик туннеля" value={`↓ ${formatBytes(status.rx_bytes)} · ↑ ${formatBytes(status.tx_bytes)}`} />
        <Cell label="Пинг до донора" value={status.check.rtt_ms !== null ? `${status.check.rtt_ms} мс` : '—'} />
        <Cell label="Последняя проверка" value={`${checkedAt}${status.check.result ? ` · ${status.check.result}` : ''}`} />
        <Cell label="Интерфейс на доноре" value={status.remote_iface || '—'} />
        {status.check.error && <Cell label="Причина" value={status.check.error} />}
      </div>
      {status.egress_ip && status.public_ip && status.egress_ip !== status.public_ip && (
        <p className="text-xs text-warning">
          У донора адрес интерфейса {status.egress_ip}, а наружу он выходит с {status.public_ip}:
          донор за NAT, middle proxy через него может не подняться.
        </p>
      )}
    </Card>
  );
}

function ControlsCard({
  status,
  locked,
  onCheck,
  onAct,
  onReconfigure,
  reconfiguring,
}: {
  status: DonorStatus;
  locked: boolean;
  onCheck: () => void;
  onAct: (fn: () => Promise<MtproxylOperation>) => void;
  onReconfigure: () => void;
  reconfiguring: boolean;
}) {
  const [allowRoutes, setAllowRoutes] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [remote, setRemote] = useState(status.setup_mode === 'auto');
  const [password, setPassword] = useState('');
  const [changingHost, setChangingHost] = useState(false);
  const [newHost, setNewHost] = useState(status.host);
  const needRoutes = !status.enabled && status.default_upstreams !== '' && status.engine_mode !== 'manual';

  return (
    <Card className="p-4 space-y-3">
      <div className="text-sm font-medium text-text-primary">Управление</div>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" className="gap-2" disabled={locked} onClick={onCheck}>
          <RefreshCw size={14} /> Проверить
        </Button>
        {status.enabled ? (
          <Button size="sm" variant="outline" disabled={locked} onClick={() => onAct(donorApi.disable)}>
            Выключить — движок пойдёт напрямую
          </Button>
        ) : (
          <Button
            size="sm"
            disabled={locked || status.warp_enabled || (needRoutes && !allowRoutes)}
            onClick={() => onAct(() => donorApi.enable(allowRoutes))}
          >
            Включить — движок пойдёт через донор
          </Button>
        )}
        <Button size="sm" variant="outline" disabled={locked} onClick={() => setChangingHost((v) => !v)}>
          Сменить адрес
        </Button>
        <Button size="sm" variant="outline" disabled={locked} onClick={onReconfigure}>
          {reconfiguring ? 'Скрыть перенастройку' : 'Перенастроить'}
        </Button>
        <Button size="sm" variant="outline" className="gap-2" disabled={locked} onClick={() => setRemoving((v) => !v)}>
          <Trash2 size={14} /> Удалить туннель
        </Button>
      </div>

      {needRoutes && (
        <RoutesConsent routes={status.default_upstreams} checked={allowRoutes} onChange={setAllowRoutes} disabled={locked} />
      )}

      {changingHost && (
        <div className="rounded-md border border-border p-3 space-y-3 text-sm">
          <div className="text-text-secondary">
            Новый IP или домен того же донора. Ключи, подсеть и интерфейс {status.remote_iface || ''} на
            доноре остаются прежними. С доменом туннель сам переходит на новый адрес из A-записи.
          </div>
          <div className="flex flex-wrap gap-2">
            <Input value={newHost} onChange={(e) => setNewHost(e.target.value)} placeholder="IP или домен донора"
              disabled={locked} className="max-w-xs" />
            <Button size="sm" disabled={locked || !newHost.trim()}
              onClick={() => { setChangingHost(false); onAct(() => donorApi.setHost(newHost.trim())); }}>
              Сохранить
            </Button>
          </div>
        </div>
      )}

      {removing && (
        <div className="rounded-md border border-warning/40 bg-warning/5 p-3 space-y-3 text-sm">
          <div className="text-text-primary">
            Туннель будет удалён, движок вернётся на прежние маршруты.
          </div>
          <label className="flex items-start gap-2">
            <input type="checkbox" className="mt-1" checked={remote} disabled={locked}
              onChange={(e) => setRemote(e.target.checked)} />
            <span>
              <span className="block text-text-primary">Удалить и на доноре {status.host}</span>
              <span className="block text-xs text-text-secondary">
                Интерфейс {status.remote_iface || 'туннеля'} и SOCKS5 на доноре. Пакеты AmneziaWG и dante остаются.
              </span>
            </span>
          </label>
          {remote && (
            <Input type="password" autoComplete="off" placeholder={`Пароль ${status.ssh_user}@${status.host} (пусто — по ключу)`}
              value={password} onChange={(e) => setPassword(e.target.value)} disabled={locked} className="max-w-sm" />
          )}
          <div className="flex gap-2">
            <Button size="sm" disabled={locked} onClick={() => { setRemoving(false); onAct(() => donorApi.remove(remote, password)); setPassword(''); }}>
              Удалить
            </Button>
            <Button size="sm" variant="outline" disabled={locked} onClick={() => setRemoving(false)}>Отмена</Button>
          </div>
        </div>
      )}
    </Card>
  );
}

function RoutesConsent({ routes, checked, onChange, disabled }: {
  routes: string;
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled: boolean;
}) {
  return (
    <label className="flex items-start gap-2 text-sm">
      <input type="checkbox" className="mt-1" checked={checked} disabled={disabled}
        onChange={(e) => onChange(e.target.checked)} />
      <span>
        <span className="block text-text-primary">Разрешаю выключить маршруты: {routes.split(',').join(', ')}</span>
        <span className="block text-xs text-text-secondary">
          Движок раскладывает трафик между всеми маршрутами без области — часть соединений
          пошла бы мимо донора. Они включатся обратно при выключении туннеля.
        </span>
      </span>
    </label>
  );
}

function SetupCard({ status, locked, onAct, onPrepared, onError }: {
  status: DonorStatus;
  locked: boolean;
  onAct: (fn: () => Promise<MtproxylOperation>) => void;
  onPrepared: () => Promise<void>;
  onError: (msg: string | null) => void;
}) {
  const [tab, setTab] = useState<'auto' | 'manual'>('auto');
  return (
    <Card className="p-4 space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <div className="text-sm font-medium text-text-primary mr-2">Настройка</div>
        <Button size="sm" variant={tab === 'auto' ? 'default' : 'outline'} onClick={() => setTab('auto')}>
          Автоматически
        </Button>
        <Button size="sm" variant={tab === 'manual' ? 'default' : 'outline'} onClick={() => setTab('manual')}>
          Вручную
        </Button>
      </div>
      {status.engine_mode === 'manual' && (
        <p className="text-xs text-warning">
          Конфиг движка панели не принадлежит: туннель поднимется, а маршрут socks5 нужно
          добавить в конфиг движка вручную — параметры будут в журнале операции.
        </p>
      )}
      {tab === 'auto'
        ? <AutoSetup status={status} locked={locked} onAct={onAct} onError={onError} />
        : <ManualSetup status={status} locked={locked} onPrepared={onPrepared} onError={onError} />}
    </Card>
  );
}

function AutoSetup({ status, locked, onAct, onError }: {
  status: DonorStatus;
  locked: boolean;
  onAct: (fn: () => Promise<MtproxylOperation>) => void;
  onError: (msg: string | null) => void;
}) {
  const [host, setHost] = useState(status.host || '');
  const [sshPort, setSshPort] = useState(String(status.ssh_port || 22));
  const [user, setUser] = useState(status.ssh_user || 'root');
  const [password, setPassword] = useState('');
  const [awgPort, setAwgPort] = useState('');
  const [mtu, setMtu] = useState('');
  const [keys, setKeys] = useState<DonorHostKey[] | null>(null);
  const [trusted, setTrusted] = useState(false);
  const [allowRoutes, setAllowRoutes] = useState(false);
  const [scanning, setScanning] = useState(false);

  // Другой адрес — другой сервер: подтверждение ключа сбрасывается.
  useEffect(() => { setKeys(null); setTrusted(false); }, [host, sshPort]);

  const hostKey = useMemo(() => {
    if (!keys?.length) return '';
    return (keys.find((k) => k.type === 'ED25519') ?? keys[0]).fingerprint;
  }, [keys]);
  const needRoutes = status.default_upstreams !== '' && status.engine_mode !== 'manual' && !status.enabled;

  const scan = async () => {
    setScanning(true);
    onError(null);
    try {
      const res = await donorApi.hostKeys(host.trim(), Number(sshPort) || 22);
      setKeys(res.fingerprints);
    } catch (e) {
      onError(errText(e, 'Донор не ответил по SSH'));
    } finally {
      setScanning(false);
    }
  };

  const submit = () => {
    const req = {
      host: host.trim(),
      ssh_port: Number(sshPort) || 22,
      user: user.trim() || 'root',
      password,
      awg_port: Number(awgPort) || 0,
      mtu: Number(mtu) || 0,
      host_key: hostKey,
      allow_disable_default_upstreams: allowRoutes,
    };
    setPassword('');
    onAct(() => donorApi.setup(req));
  };

  return (
    <div className="space-y-3 text-sm">
      <p className="text-xs text-text-secondary">
        Донор — Debian или Ubuntu на KVM (не OpenVZ/LXC), откуда открывается Telegram. MTProxyL
        зайдёт на него по SSH, поставит AmneziaWG и dante, сгенерирует ключи и параметры
        обфускации для обеих сторон, поднимет туннель, проверит выход и переключит движок.
        Пароль передаётся только на время настройки и нигде не сохраняется.
      </p>
      <div className="grid grid-cols-1 sm:grid-cols-3 lg:grid-cols-6 gap-2">
        <Input placeholder="IP или домен донора" value={host} onChange={(e) => setHost(e.target.value)} disabled={locked} />
        <Input placeholder="Порт SSH" value={sshPort} onChange={(e) => setSshPort(e.target.value)} disabled={locked} />
        <Input placeholder="Пользователь" value={user} onChange={(e) => setUser(e.target.value)} disabled={locked} />
        <Input type="password" autoComplete="off" placeholder="Пароль (пусто — по ключу)" value={password}
          onChange={(e) => setPassword(e.target.value)} disabled={locked} />
        <Input placeholder="UDP-порт (авто)" value={awgPort} onChange={(e) => setAwgPort(e.target.value)} disabled={locked} />
        <Input placeholder="MTU (1280)" value={mtu} onChange={(e) => setMtu(e.target.value)} disabled={locked} />
      </div>
      <p className="text-xs text-text-secondary">
        Защита от перебора SSH на доноре не помешает: получение ключа и настройка — по одному
        подключению. MTU меньше 1280 нужен, только если крупные пакеты между серверами теряются.
      </p>

      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" className="gap-2" disabled={locked || scanning || !host.trim()} onClick={() => void scan()}>
          <KeyRound size={14} /> {scanning ? 'Подключаемся…' : 'Получить ключ хоста'}
        </Button>
      </div>

      {keys && (
        <div className="rounded-md border border-border p-3 space-y-2">
          <div className="text-xs text-text-secondary">Ключи хоста {host.trim()}:</div>
          <ul className="font-mono text-xs space-y-0.5 break-all">
            {keys.map((k) => <li key={k.fingerprint}>{k.type} {k.fingerprint}</li>)}
          </ul>
          <div className="text-xs text-text-secondary">
            Сверьте на доноре: <code>ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub</code>
          </div>
          <label className="flex items-start gap-2">
            <input type="checkbox" className="mt-1" checked={trusted} disabled={locked}
              onChange={(e) => setTrusted(e.target.checked)} />
            <span className="text-text-primary">Ключ совпадает — доверяю этому серверу</span>
          </label>
        </div>
      )}

      {needRoutes && (
        <RoutesConsent routes={status.default_upstreams} checked={allowRoutes} onChange={setAllowRoutes} disabled={locked} />
      )}

      <Button className="gap-2" disabled={locked || !hostKey || !trusted || status.warp_enabled || (needRoutes && !allowRoutes)}
        onClick={submit}>
        <Cable size={14} /> Настроить донор и туннель
      </Button>
    </div>
  );
}

function ManualSetup({ status, locked, onPrepared, onError }: {
  status: DonorStatus;
  locked: boolean;
  onPrepared: () => Promise<void>;
  onError: (msg: string | null) => void;
}) {
  const [host, setHost] = useState(status.host || '');
  const [awgPort, setAwgPort] = useState('');
  const [mtu, setMtu] = useState('');
  const [working, setWorking] = useState(false);

  const prepare = async () => {
    setWorking(true);
    onError(null);
    try {
      await donorApi.manual(host.trim(), Number(awgPort) || 0, Number(mtu) || 0);
      await onPrepared();
    } catch (e) {
      onError(errText(e, 'Не удалось подготовить скрипт'));
    } finally {
      setWorking(false);
    }
  };

  return (
    <div className="space-y-3 text-sm">
      <p className="text-xs text-text-secondary">
        Пароль донора панели не нужен: MTProxyL подготовит скрипт, вы запустите его на доноре
        от root и вернёте сюда публичный ключ, который скрипт напечатает в конце.
      </p>
      <div className="grid grid-cols-1 sm:grid-cols-4 gap-2">
        <Input placeholder="IP или домен донора" value={host} onChange={(e) => setHost(e.target.value)} disabled={locked || working} />
        <Input placeholder="UDP-порт (авто)" value={awgPort} onChange={(e) => setAwgPort(e.target.value)} disabled={locked || working} />
        <Input placeholder="MTU (1280)" value={mtu} onChange={(e) => setMtu(e.target.value)} disabled={locked || working} />
        <Button size="sm" variant="outline" disabled={locked || working || !host.trim()} onClick={() => void prepare()}>
          {working ? 'Готовим…' : 'Подготовить скрипт'}
        </Button>
      </div>
    </div>
  );
}

function ManualFinishCard({ status, locked, onAct, onError }: {
  status: DonorStatus;
  locked: boolean;
  onAct: (fn: () => Promise<MtproxylOperation>) => void;
  onError: (msg: string | null) => void;
}) {
  const [script, setScript] = useState('');
  const [key, setKey] = useState('');
  const [allowRoutes, setAllowRoutes] = useState(false);
  const needRoutes = status.default_upstreams !== '' && status.engine_mode !== 'manual';

  useEffect(() => {
    donorApi.manualScript()
      .then((r) => setScript(r.script))
      .catch((e) => onError(errText(e, 'Не удалось получить скрипт для донора')));
  }, [status.awg_port, status.host, onError]);

  const download = () => {
    const url = URL.createObjectURL(new Blob([script], { type: 'text/x-shellscript' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = 'donor-setup.sh';
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <Card className="p-4 space-y-3 text-sm">
      <div className="flex items-center justify-between gap-2 flex-wrap">
        <div className="font-medium text-text-primary">Ручная настройка: донор {status.host}</div>
        <Badge variant="warning">ждёт ключ донора</Badge>
      </div>
      <ol className="list-decimal pl-5 space-y-1 text-text-secondary">
        <li>Скачайте скрипт и запустите его на доноре от root:
          <code className="block mt-1 text-xs">bash donor-setup.sh</code>
        </li>
        <li>Скрипт поставит AmneziaWG и dante, поднимет UDP {status.awg_port} и напечатает
          «Публичный ключ донора: …». Порт должен быть открыт снаружи.</li>
        <li>Вставьте ключ ниже и завершите настройку.</li>
      </ol>
      <div className="flex gap-2">
        <Button size="sm" variant="outline" className="gap-2" disabled={!script} onClick={download}>
          <Download size={14} /> Скачать donor-setup.sh
        </Button>
        {script && <CopyButton text={script} label="Скопировать скрипт" />}
      </div>
      {script && (
        <pre className="max-h-64 overflow-auto rounded-md bg-background p-3 text-xs font-mono whitespace-pre">{script}</pre>
      )}
      <Input placeholder="Публичный ключ донора (44 символа)" value={key} onChange={(e) => setKey(e.target.value.trim())}
        disabled={locked} className="font-mono" />
      {needRoutes && (
        <RoutesConsent routes={status.default_upstreams} checked={allowRoutes} onChange={setAllowRoutes} disabled={locked} />
      )}
      <Button disabled={locked || key.length !== 44 || status.warp_enabled || (needRoutes && !allowRoutes)}
        onClick={() => onAct(() => donorApi.finish(key, allowRoutes))}>
        Завершить настройку
      </Button>
    </Card>
  );
}

function HowItWorks() {
  return (
    <Card className="p-4 space-y-2 text-xs text-text-secondary">
      <div className="text-sm font-medium text-text-primary">Как это устроено</div>
      <p>
        На доноре — интерфейс AmneziaWG со своим UDP-портом и dante: SOCKS5 слушает только
        адрес внутри туннеля и пускает только этот сервер. Здесь — интерфейс mtpdonor; движку
        добавляется upstream socks5 на адрес донора в туннеле, прямые маршруты выключаются.
        Ключи и параметры обфускации (Jc, S1–S4, H1–H4, сигнатура I1–I5) генерируются для каждой
        пары заново. Telegram видит один адрес — адрес донора, и ключи middle proxy сходятся.
      </p>
      <p>
        В режиме Reanimator маршрут дописывается в конфиг цели с резервной копией; при
        выключении туннеля конфиг возвращается как был.
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
