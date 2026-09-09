import { useCallback, useEffect, useState } from 'react';
import { Waypoints, RefreshCw, Search } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';
import {
  warpApi,
  type MtproxylOperation,
  type WarpPreflight,
  type WarpScanResult,
  type WarpStatus,
} from '@/lib/api';
import { cn } from '@/lib/utils';

type WarpMode = 'socks' | 'iface' | 'upstream';
type EnableReview = {
  mode: WarpMode;
  preflight: WarpPreflight;
  disableMiddleProxy: boolean;
  disableDefaultUpstreams: boolean;
};

/** Маршрут до Telegram через WARP: в туннель уходят только подсети Telegram. */
export function WarpPage() {
  const [status, setStatus] = useState<WarpStatus | null>(null);
  const [scan, setScan] = useState<WarpScanResult | null>(null);
  const [unsupported, setUnsupported] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [scanError, setScanError] = useState<string | null>(null);
  const [pendingMode, setPendingMode] = useState<WarpMode | null>(null);
  const [picked, setPicked] = useState(false);
  const [enableReview, setEnableReview] = useState<EnableReview | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await warpApi.status();
      if (!res.supported) {
        setUnsupported(res.message || 'Возможность недоступна');
        setStatus(null);
      } else {
        setUnsupported(null);
        setStatus(res.status ?? null);
        // Результат разведки — вспомогательный: его отсутствие не ошибка.
        try {
          const sc = await warpApi.lastScan();
          setScan(sc.supported ? sc.scan ?? null : null);
          setScanError(null);
        } catch (e) {
          setScanError(e instanceof Error ? e.message : 'Не удалось прочитать результаты разведки');
        }
      }
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить состояние');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['warp:']);

  useEffect(() => {
    if (!running) return;
    const id = window.setInterval(() => {
      void warpApi.lastScan().then(res => setScan(res.scan ?? null)).catch(e => setScanError(String(e)));
    }, 3000);
    return () => window.clearInterval(id);
  }, [running]);

  // Всё, кроме настроек, идёт фоновой операцией: разведка занимает минуты.
  const act = async (fn: () => Promise<MtproxylOperation>) => {
    setBusy(true);
    setError(null);
    try {
      start(await fn());
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Команда не выполнилась');
    } finally {
      setBusy(false);
    }
  };

  const prepareEnable = async (mode: WarpMode) => {
    setBusy(true);
    setError(null);
    try {
      const preflight = await warpApi.preflight(mode);
      if (preflight.middle_proxy_enabled || preflight.default_upstreams.length || preflight.manual_engine_config) {
        setEnableReview({
          mode,
          preflight,
          disableMiddleProxy: false,
          disableDefaultUpstreams: false,
        });
      } else {
        setPendingMode(null);
        start(await warpApi.enable(mode));
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось проверить условия включения WARP');
    } finally {
      setBusy(false);
    }
  };

  const enable = async (mode: WarpMode) => {
    const desiredProto = mode === 'iface' ? 'wg' : status?.proto;
    const scanProtoCompatible = desiredProto === 'wg' || desiredProto === 'awg'
      ? scan?.proto === 'wg' || scan?.proto === 'awg'
      : scan?.proto === desiredProto;
    const hasScan = scan?.status === 'success' && scan.nodes.length > 0 && scanProtoCompatible;
    if (hasScan && (status?.endpoint || status?.location)) {
      await prepareEnable(mode);
    } else if (hasScan) {
      setPendingMode(mode);
      setPicked(false);
    } else {
      setPendingMode(mode);
      setPicked(false);
      await act(() => warpApi.scan(mode));
    }
  };

  const scanAll = async () => {
    setBusy(true);
    setError(null);
    try {
      await warpApi.save({ location: '', endpoint: '' });
      setPendingMode(null);
      setPicked(false);
      start(await warpApi.scan());
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить разведку без фильтра');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <Header title="Telegram через WARP" refreshing={loading} onRefresh={load} />

      <div className="p-4 lg:p-6 space-y-4 lg:space-y-6">
        <p className="text-sm text-text-secondary max-w-3xl">
          Нужно там, где серверы Telegram с хоста недоступны. В туннель Cloudflare
          WARP уходят только подсети Telegram — клиенты приходят на сервер как
          раньше. Эндпоинты ищет{' '}
          <a
            href="https://github.com/vernette/warpscout"
            target="_blank"
            rel="noopener noreferrer"
            className="text-accent hover:underline"
          >
            warpscout
          </a>
          , правила ставит MTProxyL.
        </p>

        {error && <ErrorAlert message={error} onRetry={load} />}
        {scanError && <ErrorAlert message={scanError} onRetry={load} />}
        <OperationProgress operation={operation} onDismiss={dismiss} />

        {unsupported && <Card className="p-6 text-sm text-text-secondary">{unsupported}</Card>}

        {status && (
          <>
            <StateCard status={status} />

            <SettingsForm status={status} onSaved={load} disabled={busy || running} />

            <Card className="p-4 space-y-3">
              <div className="text-sm font-medium text-text-primary">Включение</div>
              <p className="text-xs text-text-secondary">
                {scan?.status === 'success' && scan.nodes.length
                  ? 'Выбранный результат последней разведки используется без повторного поиска.'
                  : 'Перед первым включением панель запустит разведку; она занимает несколько минут.'}
              </p>
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  onClick={() => void enable('socks')}
                  disabled={busy || running}
                  variant={status.enabled && status.mode === 'socks' ? 'default' : 'outline'}
                  size="sm"
                  className="gap-2"
                >
                  <Waypoints size={14} /> Вариант A — SOCKS5 + redsocks
                </Button>
                <Button
                  onClick={() => void enable('iface')}
                  disabled={busy || running}
                  variant={status.enabled && status.mode === 'iface' ? 'default' : 'outline'}
                  size="sm"
                  className="gap-2"
                >
                  <Waypoints size={14} /> Вариант B — интерфейс WireGuard
                </Button>
                <Button
                  onClick={() => void enable('upstream')}
                  disabled={busy || running}
                  variant={status.enabled && status.mode === 'upstream' ? 'default' : 'outline'}
                  size="sm"
                  className="gap-2"
                >
                  <Waypoints size={14} /> Вариант C — socks5-upstream движка
                </Button>
                <Button
                  onClick={() => void act(() => warpApi.disable())}
                  disabled={busy || running || !status.enabled}
                  variant="outline"
                  size="sm"
                >
                  Выключить
                </Button>
                <Button
                  onClick={() => void act(() => warpApi.scan())}
                  disabled={busy || running}
                  variant="outline"
                  size="sm"
                  className="gap-2"
                >
                  <Search size={14} /> {status.location ? `Разведка: ${status.location}` : 'Разведка всех адресов'}
                </Button>
                {(status.location || status.endpoint) && (
                  <Button onClick={() => void scanAll()} disabled={busy || running}
                    variant="outline" size="sm" className="gap-2">
                    <Search size={14} /> Снять фильтр и разведать всё
                  </Button>
                )}
                <Button
                  onClick={() => void act(() => warpApi.reapply())}
                  disabled={busy || running || !status.enabled}
                  variant="outline"
                  size="sm"
                  className="gap-2"
                >
                  <RefreshCw size={14} /> Переприменить правила
                </Button>
              </div>
              <div className="flex flex-wrap gap-2">
                <Button size="sm" variant="outline" disabled={busy || running || !status.enabled}
                  onClick={() => void act(warpApi.apply)}>Применить сохранённый выбор</Button>
                <Button size="sm" variant="outline" disabled={busy || running || !status.enabled}
                  onClick={() => void act(warpApi.recover)}>Восстановить туннель</Button>
                <Button size="sm" variant="outline" disabled={busy || running}
                  onClick={() => void act(warpApi.install)}>Обновить warpscout</Button>
                <Button size="sm" variant="outline" disabled={busy || running}
                  onClick={() => void act(() => warpApi.watchdog(!status.watchdog_enabled))}>
                  Автовосстановление: {status.watchdog_enabled
                    ? status.enabled ? 'включено' : 'запустится вместе с WARP'
                    : 'выключено'}
                </Button>
              </div>
              {pendingMode && (
                <div className="space-y-2 text-sm">
                  <p>Выберите адрес или локацию в результатах разведки. Рекомендация не применяется автоматически.</p>
                  <Button disabled={busy || running || !picked} size="sm"
                    onClick={() => void prepareEnable(pendingMode)}>
                    Включить {pendingMode} с сохранённым выбором
                  </Button>
                </div>
              )}
              {enableReview && (
                <EnableReviewCard
                  review={enableReview}
                  busy={busy || running}
                  onChange={setEnableReview}
                  onCancel={() => setEnableReview(null)}
                  onConfirm={() => {
                    const review = enableReview;
                    setEnableReview(null);
                    setPendingMode(null);
                    void act(() => warpApi.enable(review.mode, {
                      disableMiddleProxy: review.disableMiddleProxy,
                      disableDefaultUpstreams: review.disableDefaultUpstreams,
                    }));
                  }}
                />
              )}
              <WarningMe />
            </Card>

            <ScanResults
              scan={scan}
              busy={busy || running}
              onPick={async (patch) => {
                setBusy(true);
                setError(null);
                try {
                  await warpApi.save({ ...patch, proto: scan?.proto });
                  setPicked(true);
                  await load();
                } catch (e) {
                  setError(e instanceof Error ? e.message : 'Не удалось сохранить');
                } finally {
                  setBusy(false);
                }
              }}
            />

            <VariantsHelp />
          </>
        )}
      </div>
    </div>
  );
}

function EnableReviewCard({
  review,
  busy,
  onChange,
  onCancel,
  onConfirm,
}: {
  review: EnableReview;
  busy: boolean;
  onChange: (review: EnableReview) => void;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const p = review.preflight;
  const middleBlocked = p.middle_proxy_enabled && !p.can_disable_middle_proxy;
  const routesBlocked = p.default_upstreams.length > 0 && !p.can_disable_default_upstreams;
  const ready =
    !middleBlocked &&
    !routesBlocked &&
    (!p.middle_proxy_enabled || review.disableMiddleProxy) &&
    (!p.default_upstreams.length || review.disableDefaultUpstreams);

  return (
    <div className="rounded-md border border-warning/40 bg-warning/5 p-3 space-y-3 text-sm">
      <div className="font-medium text-text-primary">Перед включением варианта {review.mode}</div>

      {p.middle_proxy_enabled && (
        <label className="flex items-start gap-2">
          <input
            type="checkbox"
            className="mt-1"
            checked={review.disableMiddleProxy}
            disabled={busy || !p.can_disable_middle_proxy}
            onChange={(e) => onChange({ ...review, disableMiddleProxy: e.target.checked })}
          />
          <span>
            <span className="block text-text-primary">Разрешаю выключить middle proxy</span>
            <span className="block text-xs text-text-secondary">
              WARP несовместим с ME. Движок перейдёт на прямую маршрутизацию,
              рекламная метка перестанет действовать. При выключении WARP ME автоматически не включается.
            </span>
          </span>
        </label>
      )}

      {p.default_upstreams.length > 0 && (
        <label className="flex items-start gap-2">
          <input
            type="checkbox"
            className="mt-1"
            checked={review.disableDefaultUpstreams}
            disabled={busy || !p.can_disable_default_upstreams}
            onChange={(e) => onChange({ ...review, disableDefaultUpstreams: e.target.checked })}
          />
          <span>
            <span className="block text-text-primary">
              Разрешаю временно выключить маршруты: {p.default_upstreams.join(', ')}
            </span>
            <span className="block text-xs text-text-secondary">
              Иначе часть соединений варианта C пойдёт мимо WARP. Эти маршруты
              включатся обратно при выключении WARP.
            </span>
          </span>
        </label>
      )}

      {middleBlocked && (
        <p className="text-xs text-warning">
          Панель не владеет конфигурацией движка. Выключите use_middle_proxy в конфиге цели,
          перезапустите её и повторите включение.
        </p>
      )}
      {routesBlocked && (
        <p className="text-xs text-warning">
          Маршруты цели нужно отключить в её конфигурации вручную.
        </p>
      )}
      {p.manual_engine_config && !middleBlocked && (
        <p className="text-xs text-warning">
          В режиме Reanimator панель поднимет туннель, но маршрут нужно добавить в конфиг
          цели вручную. Команда покажет необходимые параметры в журнале операции.
        </p>
      )}

      <div className="flex gap-2">
        <Button size="sm" disabled={busy || !ready} onClick={onConfirm}>Продолжить включение</Button>
        <Button size="sm" variant="outline" disabled={busy} onClick={onCancel}>Отмена</Button>
      </div>
    </div>
  );
}

// Результаты последней разведки: без них локацию приходилось искать
// warpscout'ом в консоли и вписывать в настройки руками.
function ScanResults({
  scan,
  busy,
  onPick,
}: {
  scan: WarpScanResult | null;
  busy: boolean;
  onPick: (patch: { location?: string; endpoint?: string }) => Promise<void>;
}) {
  const [visibleCount, setVisibleCount] = useState(20);
  useEffect(() => { setVisibleCount(20); }, [scan?.scanned_at]);
  if (!scan || scan.nodes.length === 0) {
    return (
      <Card className="p-4 space-y-2">
        <div className="text-sm font-medium text-text-primary">Результаты разведки</div>
        <p className="text-xs text-text-secondary">
          {scan?.status === 'running' ? 'Разведка выполняется. Рабочий туннель не переключается.'
            : scan?.status === 'error' ? scan.error || 'Ошибка разведки. Подробности — в журнале операции.'
            : scan?.scanned_at ? 'Рабочих узлов не найдено. Проверьте протокол и фильтр локации.'
            : 'Разведки ещё не было. Нажмите «Разведка», чтобы получить список узлов.'}
        </p>
        {scan?.filter && (
          <Button size="sm" variant="outline" disabled={busy}
            onClick={() => void onPick({ location: '', endpoint: '' })}>
            Снять фильтр {scan.filter} (затем запустить разведку)
          </Button>
        )}
      </Card>
    );
  }
  const when = scan.scanned_at ? new Date(scan.scanned_at * 1000).toLocaleString('ru-RU') : '—';
  return (
    <Card className="p-4 space-y-3">
      <div className="flex flex-wrap items-baseline gap-2">
        <div className="text-sm font-medium text-text-primary">Результаты разведки</div>
        <span className="text-xs text-text-secondary">
          {when}
          {` · адресов: ${scan.nodes.length}`}
          {scan.proto ? ` · ${scan.proto}` : ''}
          {scan.filter ? ` · фильтр ${scan.filter}` : ''}
        </span>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs text-text-secondary">
              <th className="py-1 pr-3 font-medium">Узел</th>
              <th className="py-1 pr-3 font-medium">Локация</th>
              <th className="py-1 pr-3 font-medium">Выход</th>
              <th className="py-1 pr-3 font-medium">Пинг</th>
              <th className="py-1 pr-3 font-medium">Эндпоинт</th>
              <th className="py-1 font-medium">Выбрать</th>
            </tr>
          </thead>
          <tbody>
            {scan.nodes.slice(0, visibleCount).map((n) => (
              <tr key={n.node + n.endpoint} className="border-t border-border">
                <td className="py-1.5 pr-3 font-mono">{n.node}{n.endpoint === scan.best_endpoint && ' ★'}</td>
                <td className="py-1.5 pr-3">{n.location}</td>
                <td className="py-1.5 pr-3 font-mono">{n.region}</td>
                <td className="py-1.5 pr-3 whitespace-nowrap">{n.tunnel_ping || n.ping}{n.loss && ` · потери ${n.loss}`}</td>
                <td className="py-1.5 pr-3 font-mono">{n.endpoint}</td>
                <td className="py-1.5">
                  <div className="flex flex-wrap gap-1.5">
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={busy}
                      onClick={() => void onPick({ location: n.node, endpoint: '' })}
                    >
                      Выбирать узел {n.node}
                    </Button>
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={busy}
                      onClick={() => void onPick({ endpoint: n.endpoint, location: scan.filter || '' })}
                    >
                      Использовать этот адрес
                    </Button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="text-xs text-text-secondary">
        {visibleCount < scan.nodes.length && <Button size="sm" variant="outline" onClick={() => setVisibleCount(n => n + 20)}>Показать ещё адреса ({scan.nodes.length - visibleCount})</Button>}
        {' '}★ — рекомендованный адрес. Выбор сохраняется отдельно; для работающего WARP нажмите «Применить сохранённый выбор».{' '}
        «Выбирать узел» сохраняет код узла Cloudflare и снимает точный адрес: при
        следующей разведке MTProxyL сможет взять другой IP или порт, ведущий на этот
        узел. «Использовать этот адрес» фиксирует показанный IP:порт и позволяет
        запускаться без полной разведки; если он перестанет отвечать, MTProxyL ищет замену
        с учётом сохранённого фильтра. Узел — точка входа Cloudflare, регион в соседней
        колонке — место выхода трафика WARP.
      </p>
    </Card>
  );
}

function StateCard({ status }: { status: WarpStatus }) {
  const variant =
    status.mode === 'iface'
      ? 'B — интерфейс WireGuard'
      : status.mode === 'upstream'
        ? 'C — socks5-upstream движка'
        : 'A — SOCKS5 + redsocks';
  const working =
    status.enabled &&
    status.exit.confirmed &&
    (status.mode === 'upstream' ? status.socks_active : status.nft_applied);

  return (
    <Card className="p-4 space-y-3">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div className="text-sm">
          <span className="text-text-primary font-medium">
            {status.enabled ? `Включён, вариант ${variant}` : 'Выключен'}
          </span>
          <div className="text-xs text-text-secondary mt-0.5">
            {status.enabled
              ? working
                ? 'Cloudflare подтверждает туннель, правила на месте'
                : 'Туннель или маршрут WARP не подтверждён'
              : 'Трафик до Telegram идёт напрямую'}
          </div>
        </div>
        <Badge variant={status.enabled ? (working ? 'success' : 'warning') : 'outline'}>
          {status.enabled ? (working ? 'работает' : 'проверьте') : 'выключен'}
        </Badge>
      </div>

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 text-sm">
        <Cell label="Выход" value={status.exit.confirmed ? `${status.exit.ip}` : '—'} />
        <Cell
          label="Локация выхода"
          value={status.exit.confirmed ? `${status.exit.loc} (${status.exit.colo})` : '—'}
        />
        <Cell label="Рабочий эндпоинт" value={status.enabled ? status.active_endpoint || '—' : '—'} />
        <Cell label="Закреплённый адрес" value={status.endpoint || 'автовыбор'} />
        <Cell label="Протокол туннеля" value={status.active_proto || status.proto} />
        <Cell label="Последняя проверка" value={status.health?.checked_at ? new Date(status.health.checked_at * 1000).toLocaleString('ru-RU') : '—'} />
        <Cell label="Восстановление" value={status.health?.last_recovery_at ? new Date(status.health.last_recovery_at * 1000).toLocaleString('ru-RU') : 'не требовалось'} />
        {status.health?.error && <Cell label="Причина сбоя" value={status.health.error} />}
        <Cell
          label="Уведено пакетов"
          value={status.matched_packets.toLocaleString('ru-RU')}
        />
        <Cell label="Подсетей Telegram" value={String(status.cidr_count)} />
        <Cell
          label={status.mode === 'iface' ? 'Интерфейс' : 'Туннель'}
          value={
            status.mode === 'iface'
              ? status.iface_active
                ? 'поднят'
                : 'нет'
              : status.mode === 'upstream'
                ? status.socks_active
                  ? 'socks ✓'
                  : 'socks ✗'
                : `${status.socks_active ? 'socks ✓' : 'socks ✗'} · ${
                    status.redirect_active ? 'redsocks ✓' : 'redsocks ✗'
                  }`
          }
        />
        <Cell label="warpscout" value={status.installed ? status.version || 'установлен' : 'нет'} />
      </div>
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

/** Про несовместимость с ME полезнее прочитать до включения, а не после. */
function WarningMe() {
  return (
    <p className="text-xs text-warning/90">
      WARP работает только с прямой маршрутизацией движка. Если включён middle proxy
      (<code>use_middle_proxy</code>), перед запуском появится отдельное согласие на его
      отключение. Для варианта C панель также покажет маршруты без области, которые
      нужно временно выключить, чтобы весь трафик Telegram шёл через WARP.
    </p>
  );
}

function VariantsHelp() {
  return (
    <CollapsibleSection title="Чем отличаются варианты" defaultOpen={false}>
      <div className="space-y-3 text-sm">
        <div>
          <div className="text-text-primary font-medium">Вариант A — SOCKS5 warpscout + redsocks</div>
          <p className="text-xs text-text-secondary mt-1">
            Туннель поднимает сам warpscout, ядро ни при чём. Умеет обфускацию
            (awg, masque) — проходит там, где обычный WireGuard режут по сигнатуре
            рукопожатия. Подводные камни: туннель один, без запасного узла — после
            обрыва службу поднимает systemd и заново ищет эндпоинт, это минута-другая;
            в тракте лишний процесс redsocks; заворачивается только TCP.
          </p>
        </div>
        <div>
          <div className="text-text-primary font-medium">Вариант B — интерфейс WireGuard</div>
          <p className="text-xs text-text-secondary mt-1">
            Обычный wg-туннель в ядре, маршрут выбирается по метке. Переподключается
            сам, лишних процессов нет. Подводные камни: только чистый WireGuard — там,
            где его блокируют по сигнатуре, рукопожатия не будет вовсе; нужен модуль
            ядра wireguard и пакет wireguard-tools.
          </p>
        </div>
        <div>
          <div className="text-text-primary font-medium">Вариант C — socks5-upstream движка</div>
          <p className="text-xs text-text-secondary mt-1">
            Правил в ядре нет вовсе: туннель поднимает warpscout, а telemt сам ходит
            через него по своему конфигу. Самый простой путь, если движок наш — в
            режиме менеджера MTProxyL пропишет маршрут сам. У чужой цели реаниматора
            он поднимет туннель и покажет в логе операции, что дописать в её конфиг.
            Подводные камни: через socks уходит весь исходящий трафик движка, и
            локальный mask-бэкенд приходится возвращать на прямой маршрут отдельной
            областью.
          </p>
        </div>
        <p className="text-xs text-text-secondary">
          Проще так: свой telemt — берите C; готовы править чужой конфиг руками —
          тоже C; иначе B, а если разведка не находит живых эндпоинтов (wg режут по
          сигнатуре) — A.
        </p>
      </div>
    </CollapsibleSection>
  );
}

function SettingsForm({ status, onSaved, disabled }: { status: WarpStatus; onSaved: () => void; disabled: boolean }) {
  const [location, setLocation] = useState(status.location);
  const [endpoint, setEndpoint] = useState(status.endpoint);
  const [proto, setProto] = useState(status.proto);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    setLocation(status.location);
    setEndpoint(status.endpoint);
    setProto(status.proto);
  }, [status.location, status.endpoint, status.proto]);

  const save = async () => {
    setSaving(true);
    setError(null);
    setSaved(false);
    try {
      await warpApi.save({ location: location.trim(), endpoint: endpoint.trim(), proto });
      setSaved(true);
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить');
    } finally {
      setSaving(false);
    }
  };

  return (
    <CollapsibleSection title="Где выходить и через что" defaultOpen>
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <label className="flex flex-col gap-1">
          <span className="text-xs text-text-secondary">Фильтр разведки и автовыбора</span>
          <Input
            value={location}
            onChange={(e) => setLocation(e.target.value)}
            placeholder="пусто — лучший по задержке"
            spellCheck={false}
          />
          <span className="text-[11px] text-text-secondary/80">
            Пусто — проверять все доступные адреса. Страны выхода задаются двумя
            буквами (DE, NL), узлы Cloudflare — тремя (FRA, AMS). Через запятую,
            можно смешивать. Фильтр не создаёт нужную локацию: если с этого сервера
            все рабочие адреса ведут в AMS, другие узлы в результатах не появятся.
            Для masque и masque-h2 фильтр не применяется: у них фиксированные
            anycast-адреса и один узел выхода.
          </span>
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-text-secondary">Эндпоинт</span>
          <Input
            value={endpoint}
            onChange={(e) => setEndpoint(e.target.value)}
            placeholder="188.114.98.58:2408"
            spellCheck={false}
          />
          <span className="text-[11px] text-text-secondary/80">
            Пусто — выбирать адрес разведкой по фильтру выше. Адрес, выбранный из
            результатов, используется при включении без повторной разведки.
          </span>
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-text-secondary">Протокол (варианты A и C)</span>
          <select
            value={proto}
            onChange={(e) => setProto(e.target.value)}
            className="h-9 rounded-md border border-border bg-surface px-3 text-sm text-text-primary"
          >
            <option value="awg">awg — обфусцированный, проходит чаще всего</option>
            <option value="wg">wg — обычный WireGuard, быстрее</option>
            <option value="masque">masque — поверх QUIC</option>
            <option value="masque-h2">masque-h2 — поверх HTTP/2</option>
          </select>
          <span className="text-[11px] text-text-secondary/80">
            Вариант B всегда идёт по чистому wg: awg и masque умеет только
            userspace-туннель warpscout.
          </span>
        </label>
      </div>

      {error && (
        <div className="mt-3">
          <ErrorAlert message={error} />
        </div>
      )}

      <div className="flex items-center gap-2 mt-3 flex-wrap">
        <Button onClick={save} disabled={saving || disabled} size="sm">
          {saving ? 'Сохраняем…' : 'Сохранить'}
        </Button>
        <span className={cn('text-xs', saved && !error ? 'text-success' : 'text-text-secondary')}>
          {saved && !error
            ? 'Сохранено. Нажмите «Применить сохранённый выбор» или включите WARP.'
            : 'Сохранение и разведка не переключают работающий туннель.'}
        </span>
      </div>
    </CollapsibleSection>
  );
}
