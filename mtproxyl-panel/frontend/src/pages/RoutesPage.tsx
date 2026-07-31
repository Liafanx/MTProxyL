import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { mtproxylNetApi, type Upstream, type UpstreamSpec } from '@/lib/api';

const EMPTY_SPEC: UpstreamSpec = {
  name: '',
  type: 'socks5',
  address: '',
  user: '',
  password: '',
  weight: 10,
  iface: '',
};

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

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setRoutes(await mtproxylNetApi.upstreams());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить маршруты');
    } finally {
      setLoading(false);
    }
  }, []);

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
            Куда прокси отправляет трафик наружу: напрямую или через SOCKS5 (например WARP).
            Вес задаёт долю трафика между включёнными маршрутами. Это не то же самое, что
            «Апстримы и DC» — там показаны дата-центры самого движка.
          </p>
        </div>
        <Button onClick={() => setAddOpen(true)}>Добавить маршрут</Button>
      </div>

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
                <option value="socks5">socks5</option>
                <option value="direct">direct</option>
              </select>
            </div>
            {spec.type === 'socks5' && (
              <>
                <div className="space-y-1.5">
                  <Label htmlFor="r-addr">Адрес</Label>
                  <Input
                    id="r-addr"
                    value={spec.address}
                    onChange={(e) => setSpec({ ...spec, address: e.target.value })}
                    placeholder="127.0.0.1:1080"
                  />
                </div>
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
              </>
            )}
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label htmlFor="r-weight">Вес</Label>
                <Input
                  id="r-weight"
                  type="number"
                  min={0}
                  max={10000}
                  value={spec.weight}
                  onChange={(e) => setSpec({ ...spec, weight: Number(e.target.value) })}
                />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="r-iface">Интерфейс</Label>
                <Input
                  id="r-iface"
                  value={spec.iface}
                  onChange={(e) => setSpec({ ...spec, iface: e.target.value })}
                  placeholder="необязательно"
                />
              </div>
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
