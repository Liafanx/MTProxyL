import { useEffect, useState } from 'react';
import { Save } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useMtproxyl } from '@/hooks/useMtproxyl';
import { mtproxylSettingsApi } from '@/lib/api';

/** После смены порта движок и панель перезапускаются — страницу перечитываем. */
const RELOAD_MS = 8000;

/**
 * Порт REST API движка, через который панель с ним работает. Меняет его
 * MTProxyL: в менеджере — свою настройку, в реаниматоре — конфиг цели, — и сам
 * переключает панель на новый порт.
 */
export function ApiPortCard({ onError, onNotice }: {
  onError: (msg: string) => void;
  onNotice: (msg: string) => void;
}) {
  const { enabled, mode } = useMtproxyl();
  const [current, setCurrent] = useState('');
  const [value, setValue] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!enabled) return;
    mtproxylSettingsApi.list()
      .then((list) => {
        const v = list.find((p) => p.key === 'PROXY_API_PORT')?.value ?? '';
        setCurrent(v);
        setValue(v);
      })
      .catch(() => setCurrent(''));
  }, [enabled]);

  if (!enabled || !current) return null;

  const valid = /^\d+$/.test(value) && Number(value) >= 1 && Number(value) <= 65535;

  const save = async () => {
    setSaving(true);
    try {
      await mtproxylSettingsApi.set('PROXY_API_PORT', value);
      onNotice('Порт API изменён: движок перезапущен, панель переподключается — страница обновится сама.');
      window.setTimeout(() => window.location.reload(), RELOAD_MS);
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Не удалось сменить порт API');
      setSaving(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Порт API движка</CardTitle>
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
      </CardContent>
    </Card>
  );
}
