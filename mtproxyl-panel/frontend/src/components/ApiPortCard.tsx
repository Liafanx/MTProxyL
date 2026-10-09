import { useEffect, useState } from 'react';
import { Save, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useMtproxyl } from '@/hooks/useMtproxyl';
import { mtproxylApiAuthApi, mtproxylSettingsApi } from '@/lib/api';

/** После смены порта движок и панель перезапускаются — страницу перечитываем. */
const RELOAD_MS = 8000;

/**
 * Порт и заголовок авторизации REST API движка, через который панель с ним
 * работает. Меняет их MTProxyL: в менеджере — свои настройки, в реаниматоре —
 * конфиг цели, — и сам переключает панель на новые значения.
 */
export function ApiPortCard({ onError, onNotice }: {
  onError: (msg: string) => void;
  onNotice: (msg: string) => void;
}) {
  const { enabled, mode } = useMtproxyl();
  const [current, setCurrent] = useState('');
  const [value, setValue] = useState('');
  const [saving, setSaving] = useState(false);
  const [authSet, setAuthSet] = useState<boolean | null>(null);
  const [auth, setAuth] = useState('');

  useEffect(() => {
    if (!enabled) return;
    mtproxylSettingsApi.list()
      .then((list) => {
        const v = list.find((p) => p.key === 'PROXY_API_PORT')?.value ?? '';
        setCurrent(v);
        setValue(v);
      })
      .catch(() => setCurrent(''));
    mtproxylApiAuthApi.get()
      .then((r) => setAuthSet(r.set))
      .catch(() => setAuthSet(null));
  }, [enabled]);

  if (!enabled || !current) return null;

  const valid = /^\d+$/.test(value) && Number(value) >= 1 && Number(value) <= 65535;

  const apply = async (run: () => Promise<unknown>, done: string, fail: string) => {
    setSaving(true);
    try {
      await run();
      onNotice(`${done}: движок перезапущен, панель переподключается — страница обновится сама.`);
      window.setTimeout(() => window.location.reload(), RELOAD_MS);
    } catch (e) {
      onError(e instanceof Error ? e.message : fail);
      setSaving(false);
    }
  };
  const save = () =>
    apply(() => mtproxylSettingsApi.set('PROXY_API_PORT', value), 'Порт API изменён', 'Не удалось сменить порт API');
  const authValid = auth.trim() !== '' && !/["'\\|]/.test(auth) && auth.length <= 512;
  const saveAuth = (v: string) =>
    apply(
      () => mtproxylApiAuthApi.set(v),
      v ? 'Заголовок авторизации задан' : 'Заголовок авторизации снят',
      'Не удалось изменить заголовок авторизации',
    );

  return (
    <Card>
      <CardHeader>
        <CardTitle>API движка</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <p className="text-sm text-text-secondary">
          Через этот порт панель работает с движком, он слушается только на localhost.
          {mode === 'reanimator'
            ? ' Порт запишется в [server.api] конфига цели.'
            : ''}{' '}
          Движок перезапустится — клиенты переподключатся, — а панель сама переключится на
          новый порт.
        </p>
        <div className="flex flex-wrap items-end gap-2">
          <div className="space-y-1">
            <Label htmlFor="api-port">Порт</Label>
            <Input
              id="api-port"
              inputMode="numeric"
              value={value}
              onChange={(e) => setValue(e.target.value.trim())}
              className="w-32"
            />
          </div>
          <Button disabled={saving || !valid || value === current} onClick={() => void save()}>
            <Save size={14} className="mr-2" />
            {saving ? 'Применение…' : 'Применить'}
          </Button>
        </div>
        {authSet !== null && (
          <div className="space-y-2 border-t border-border pt-3">
            <p className="text-sm text-text-secondary">
              Заголовок Authorization, который движок требует на API, — например{' '}
              <span className="font-mono">Bearer &lt;токен&gt;</span>. Сейчас{' '}
              {authSet ? 'задан' : 'не задан: API открыт только для localhost'}. Значение не
              показывается; панель получит новый заголовок сама.
            </p>
            <div className="flex flex-wrap items-end gap-2">
              <div className="space-y-1 min-w-0 flex-1 max-w-md">
                <Label htmlFor="api-auth">Новый заголовок</Label>
                <Input
                  id="api-auth"
                  type="password"
                  autoComplete="off"
                  value={auth}
                  placeholder={authSet ? 'задан — введите новый' : 'не задан'}
                  onChange={(e) => setAuth(e.target.value)}
                />
              </div>
              <Button disabled={saving || !authValid} onClick={() => void saveAuth(auth.trim())}>
                <Save size={14} className="mr-2" />
                Задать
              </Button>
              {authSet && (
                <Button variant="outline" disabled={saving} onClick={() => void saveAuth('')}>
                  <Trash2 size={14} className="mr-2" />
                  Снять
                </Button>
              )}
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
