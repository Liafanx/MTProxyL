import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { ManagerOnlyNotice } from '@/components/ManagerOnlyNotice';
import { useManagerOnly } from '@/hooks/useMtproxyl';
import { mtproxylNetApi, type Upstream, type UpstreamSpec } from '@/lib/api';

const EMPTY_SPEC: UpstreamSpec = {
  name: '',
  type: 'socks5',
  address: '',
  user: '',
  password: '',
  weight: 10,
  iface: '',
  scopes: '',
};

/** Вес движок читает как u16 — та же граница, что и в CLI. */
const MAX_WEIGHT = 65535;

/**
 * Что означает каждый тип маршрута и что от него требуется.
 *
 * Один список типов без пояснений заставляет угадывать, чем socks4 отличается
 * от socks5 и почему у shadowsocks вместо адреса URL.
 */
const TYPE_INFO: Record<string, { hint: string; addressLabel?: string; addressHint?: string }> = {
  socks5: {
    hint: 'SOCKS5-прокси. Логин и пароль — если прокси их требует.',
    addressLabel: 'Адрес (host:port)',
    addressHint: 'Привязка к интерфейсу сработает, только если адрес задан как IP:port.',
  },
  socks4: {
    hint: 'SOCKS4-прокси. Пароля в протоколе нет — только user_id.',
    addressLabel: 'Адрес (host:port)',
    addressHint: 'Привязка к интерфейсу сработает, только если адрес задан как IP:port.',
  },
  direct: {
    hint: 'Прямое соединение без прокси. Адрес не нужен.',
  },
  shadowsocks: {
    hint: 'Shadowsocks-туннель. Требует выключенного режима ME (general.use_middle_proxy = false); плагины не поддерживаются.',
    addressLabel: 'ss-URL',
    addressHint: 'Метод шифрования и пароль уже внутри URL — отдельные поля не нужны.',
  },
};

const TYPE_ORDER = ['socks5', 'socks4', 'direct', 'shadowsocks'];

export function RoutesPage() {
  const [routes, setRoutes] = useState<Upstream[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [addOpen, setAddOpen] = useState(false);
  const [spec, setSpec] = useState<UpstreamSpec>(EMPTY_SPEC);
  const [saving, setSaving] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<Upstream | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [testOutput, setTestOutput] = useState<{ name: string; output: string } | null>(null);
  const [testing, setTesting] = useState<string | null>(null);

  const { allowed, loading: modeLoading } = useManagerOnly();

  const typeInfo = TYPE_INFO[spec.type] ?? TYPE_INFO.direct;

  // Маршрут со scopes не обслуживает запросы без scope. Если такой окажется
  // единственным включённым, конфиг останется валидным, а трафик — без выхода;
  // предупреждаем до отправки, а не после.
  const scopesWouldStrandTraffic =
    spec.scopes.trim() !== '' &&
    routes.length > 0 &&
    routes.every((r) => !r.enabled || (r.scopes ?? '').trim() !== '');

  const load = useCallback(async () => {
    // В реаниматоре маршруты недоступны — MTProxyL не владеет конфигом цели.
    if (!allowed) {
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      setRoutes(await mtproxylNetApi.upstreams());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить маршруты');
    } finally {
      setLoading(false);
    }
  }, [allowed]);

  useEffect(() => {
    void load();
  }, [load]);

  const submit = async () => {
    setSaving(true);
    try {
      await mtproxylNetApi.upstreamAdd(spec);
      setAddOpen(false);
      setSpec(EMPTY_SPEC);
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось добавить маршрут');
    } finally {
      setSaving(false);
    }
  };

  const remove = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await mtproxylNetApi.upstreamRemove(deleteTarget.name);
      setDeleteTarget(null);
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось удалить маршрут');
      setDeleteTarget(null);
    } finally {
      setDeleting(false);
    }
  };

  const toggle = async (r: Upstream) => {
    try {
      await mtproxylNetApi.upstreamToggle(r.name, !r.enabled);
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переключить маршрут');
    }
  };

  const test = async (r: Upstream) => {
    setTesting(r.name);
    setTestOutput(null);
    try {
      const res = await mtproxylNetApi.upstreamTest(r.name);
      setTestOutput({ name: r.name, output: res.output || 'Проверка завершена без вывода' });
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Проверка не удалась');
    } finally {
      setTesting(null);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h1 className="text-xl font-semibold text-text-primary">Исходящие маршруты</h1>
          <p className="text-sm text-text-secondary mt-1">
            Куда прокси отправляет трафик наружу: напрямую, через SOCKS4/SOCKS5 (например WARP)
            или через Shadowsocks. Вес задаёт долю трафика между включёнными маршрутами,
            область — для каких запросов маршрут вообще применим. Это не то же самое, что
            «Апстримы и DC» — там показаны дата-центры самого движка.
          </p>
        </div>
        {allowed && <Button onClick={() => setAddOpen(true)}>Добавить маршрут</Button>}
      </div>

      {!modeLoading && !allowed && <ManagerOnlyNotice feature="Исходящие маршруты" />}

      {allowed && (
        <>
      {error && <ErrorAlert message={error} onRetry={load} />}

      <Card>
        <CardHeader>
          <CardTitle>Маршруты</CardTitle>
        </CardHeader>
        <CardContent>
          {loading && routes.length === 0 ? (
            <div className="text-sm text-text-secondary">Загрузка…</div>
          ) : routes.length === 0 ? (
            <div className="text-sm text-text-secondary">
              Маршруты не заданы — весь трафик идёт напрямую
            </div>
          ) : (
            <div className="overflow-x-auto -mx-4 px-4">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-text-secondary border-b border-border">
                    <th className="py-2 pr-4 font-medium">Имя</th>
                    <th className="py-2 pr-4 font-medium">Тип</th>
                    <th className="py-2 pr-4 font-medium">Адрес</th>
                    <th className="py-2 pr-4 font-medium">Вес</th>
                    <th className="py-2 pr-4 font-medium">Область</th>
                    <th className="py-2 pr-4 font-medium">Состояние</th>
                    <th className="py-2 font-medium text-right">Действия</th>
                  </tr>
                </thead>
                <tbody>
                  {routes.map((r) => (
                    <tr key={r.name} className="border-b border-border last:border-0">
                      <td className="py-2 pr-4 text-text-primary">{r.name}</td>
                      <td className="py-2 pr-4 text-text-secondary">{r.type}</td>
                      <td className="py-2 pr-4 font-mono text-xs break-all">
                        {r.address || '—'}
                        {r.iface && <span className="text-text-secondary"> ({r.iface})</span>}
                        {r.has_password && (
                          <span className="text-text-secondary"> · с паролем</span>
                        )}
                      </td>
                      <td className="py-2 pr-4 text-text-secondary">{r.weight}</td>
                      <td className="py-2 pr-4 text-text-secondary">
                        {r.scopes ? (
                          <span className="font-mono text-xs break-all">{r.scopes}</span>
                        ) : (
                          <span title="Обслуживает запросы без scope">все</span>
                        )}
                      </td>
                      <td className="py-2 pr-4">
                        <StatusBadge status={r.enabled} labelOn="ВКЛ" labelOff="ВЫКЛ" />
                      </td>
                      <td className="py-2">
                        <div className="flex items-center justify-end gap-2">
                          <Button
                            size="sm"
                            variant="outline"
                            disabled={testing === r.name}
                            onClick={() => test(r)}
                          >
                            {testing === r.name ? 'Проверка…' : 'Проверить'}
                          </Button>
                          <Button size="sm" variant="outline" onClick={() => toggle(r)}>
                            {r.enabled ? 'Выключить' : 'Включить'}
                          </Button>
                          <Button size="sm" variant="danger" onClick={() => setDeleteTarget(r)}>
                            Удалить
                          </Button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {testOutput && (
            <div className="mt-4">
              <div className="text-xs text-text-secondary mb-1">
                Проверка маршрута «{testOutput.name}»
              </div>
              <pre className="text-xs text-text-secondary bg-background border border-border rounded-md p-3 whitespace-pre-wrap break-words font-mono max-h-64 overflow-y-auto">
                {testOutput.output}
              </pre>
            </div>
          )}
        </CardContent>
      </Card>
        </>
      )}

      <Dialog open={addOpen} onClose={() => setAddOpen(false)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Новый маршрут</DialogTitle>
          </DialogHeader>
          <div className="py-4 space-y-3">
            <div className="space-y-1.5">
              <Label htmlFor="r-name">Имя</Label>
              <Input
                id="r-name"
                value={spec.name}
                onChange={(e) => setSpec({ ...spec, name: e.target.value })}
                placeholder="warp"
                autoFocus
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="r-type">Тип</Label>
              <select
                id="r-type"
                value={spec.type}
                onChange={(e) => setSpec({ ...spec, type: e.target.value })}
                className="w-full rounded border border-border bg-surface px-2 py-2 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-accent/50"
              >
                {TYPE_ORDER.map((t) => (
                  <option key={t} value={t}>
                    {t}
                  </option>
                ))}
              </select>
              <p className="text-xs text-text-secondary">{typeInfo.hint}</p>
            </div>
            {spec.type !== 'direct' && (
              <div className="space-y-1.5">
                <Label htmlFor="r-addr">{typeInfo.addressLabel ?? 'Адрес'}</Label>
                <Input
                  id="r-addr"
                  value={spec.address}
                  onChange={(e) => setSpec({ ...spec, address: e.target.value })}
                  placeholder={
                    spec.type === 'shadowsocks'
                      ? 'ss://2022-blake3-aes-256-gcm:ПАРОЛЬ@127.0.0.1:8388'
                      : '127.0.0.1:1080'
                  }
                />
                {typeInfo.addressHint && (
                  <p className="text-xs text-text-secondary">{typeInfo.addressHint}</p>
                )}
              </div>
            )}
            {spec.type === 'socks5' && (
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="r-user">Логин</Label>
                  <Input
                    id="r-user"
                    value={spec.user}
                    onChange={(e) => setSpec({ ...spec, user: e.target.value })}
                  />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="r-pass">Пароль</Label>
                  <Input
                    id="r-pass"
                    type="password"
                    value={spec.password}
                    onChange={(e) => setSpec({ ...spec, password: e.target.value })}
                  />
                </div>
              </div>
            )}
            {spec.type === 'socks4' && (
              <div className="space-y-1.5">
                <Label htmlFor="r-user">user_id</Label>
                <Input
                  id="r-user"
                  value={spec.user}
                  onChange={(e) => setSpec({ ...spec, user: e.target.value })}
                  placeholder="необязательно"
                />
              </div>
            )}
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label htmlFor="r-weight">Вес</Label>
                <Input
                  id="r-weight"
                  type="number"
                  min={0}
                  max={MAX_WEIGHT}
                  value={spec.weight}
                  onChange={(e) => setSpec({ ...spec, weight: Number(e.target.value) })}
                />
                <p className="text-xs text-text-secondary">
                  0–{MAX_WEIGHT}. Чем больше, тем чаще выбирается маршрут.
                </p>
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="r-iface">Интерфейс</Label>
                <Input
                  id="r-iface"
                  value={spec.iface}
                  onChange={(e) => setSpec({ ...spec, iface: e.target.value })}
                  placeholder="необязательно"
                />
                <p className="text-xs text-text-secondary">
                  Имя интерфейса или локальный IP для исходящих соединений.
                </p>
              </div>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="r-scopes">Область (scopes)</Label>
              <Input
                id="r-scopes"
                value={spec.scopes}
                onChange={(e) => setSpec({ ...spec, scopes: e.target.value })}
                placeholder="необязательно, например me,fetch,dc2"
              />
              <p className="text-xs text-text-secondary">
                Теги через запятую. Запрос со scope идёт только через маршруты с этим тегом,
                а запрос без scope — только через маршруты с пустой областью. Оставьте пустым,
                если маршрут должен обслуживать обычный трафик.
              </p>
              {scopesWouldStrandTraffic && (
                <p className="text-xs text-warning">
                  После добавления ни один включённый маршрут не останется без области —
                  обычному трафику будет некуда идти.
                </p>
              )}
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setAddOpen(false)} disabled={saving}>
              Отмена
            </Button>
            <Button onClick={submit} disabled={saving || !spec.name}>
              {saving ? 'Добавление…' : 'Добавить'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ConfirmDialog
        open={deleteTarget !== null}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Удаление маршрута"
        message={`Удалить маршрут «${deleteTarget?.name}»? Трафик перераспределится между остальными включёнными маршрутами.`}
        loading={deleting}
      />
    </div>
  );
}
