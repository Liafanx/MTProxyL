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
import { warpApi, type MtproxylOperation, type WarpStatus } from '@/lib/api';
import { cn } from '@/lib/utils';

/** Маршрут до Telegram через WARP: в туннель уходят только подсети Telegram. */
export function WarpPage() {
  const [status, setStatus] = useState<WarpStatus | null>(null);
  const [unsupported, setUnsupported] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
        <OperationProgress operation={operation} onDismiss={dismiss} />

        {unsupported && <Card className="p-6 text-sm text-text-secondary">{unsupported}</Card>}

        {status && (
          <>
            <StateCard status={status} />

            <Card className="p-4 space-y-3">
              <div className="text-sm font-medium text-text-primary">Включение</div>
              <p className="text-xs text-text-secondary">
                Разведка занимает несколько минут — за ней можно следить в панели операции выше.
              </p>
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  onClick={() => void act(() => warpApi.enable('socks'))}
                  disabled={busy || running}
                  variant={status.enabled && status.mode === 'socks' ? 'default' : 'outline'}
                  size="sm"
                  className="gap-2"
                >
                  <Waypoints size={14} /> Вариант A — SOCKS5 + redsocks
                </Button>
                <Button
                  onClick={() => void act(() => warpApi.enable('iface'))}
                  disabled={busy || running}
                  variant={status.enabled && status.mode === 'iface' ? 'default' : 'outline'}
                  size="sm"
                  className="gap-2"
                >
                  <Waypoints size={14} /> Вариант B — интерфейс WireGuard
                </Button>
                <Button
                  onClick={() => void act(() => warpApi.enable('upstream'))}
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
                  <Search size={14} /> Разведка
                </Button>
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
              <WarningMe />
            </Card>

            <VariantsHelp />
            <SettingsForm status={status} onSaved={load} />
          </>
        )}
      </div>
    </div>
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
                : 'Правила есть, но выход через WARP не подтверждён'
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
        <Cell label="Эндпоинт" value={status.endpoint || 'выбирается разведкой'} />
        <Cell label="Протокол" value={status.proto} />
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
      Работает только с прямой маршрутизацией движка. Если включён middle proxy
      (<code>use_middle_proxy</code>, он же режим рекламной метки), MTProxyL
      откажется включать WARP: ключи ME-рукопожатия считаются от адреса и порта,
      а общий выход Cloudflare меняет и то и другое — связь с дата-центрами
      пропадёт целиком.
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

function SettingsForm({ status, onSaved }: { status: WarpStatus; onSaved: () => void }) {
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
    <CollapsibleSection title="Где выходить и через что" defaultOpen={false}>
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <label className="flex flex-col gap-1">
          <span className="text-xs text-text-secondary">Локация выхода</span>
          <Input
            value={location}
            onChange={(e) => setLocation(e.target.value)}
            placeholder="пусто — лучший по задержке"
            spellCheck={false}
          />
          <span className="text-[11px] text-text-secondary/80">
            Страны двумя буквами (DE, NL, FI), узлы Cloudflare тремя, по коду
            аэропорта (FRA, AMS, HEL). Через запятую, можно смешивать. Чем уже
            список, тем выше шанс, что живых эндпоинтов не найдётся вовсе.
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
            Пусто — искать разведкой. Закреплённый избавляет от полной разведки при
            старте; если он замолчит, MTProxyL всё равно найдёт новый.
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
        <Button onClick={save} disabled={saving} size="sm">
          {saving ? 'Сохраняем…' : 'Сохранить'}
        </Button>
        <span className={cn('text-xs', saved && !error ? 'text-success' : 'text-text-secondary')}>
          {saved && !error
            ? 'Сохранено — применится при следующей разведке'
            : 'Применяется при следующей разведке или включении'}
        </span>
      </div>
    </CollapsibleSection>
  );
}
