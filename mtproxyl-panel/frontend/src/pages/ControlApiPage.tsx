import { useCallback, useEffect, useState } from 'react';
import { Copy, KeyRound, Save } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { ErrorAlert } from '@/components/ErrorAlert';
import { StatusBadge } from '@/components/StatusBadge';
import { mtproxylControlApi, type ControlApiStatus } from '@/lib/api';

const ENDPOINTS: [string, string][] = [
  ['GET /v1/users', 'список пользователей (UserInfo) со ссылками и живыми данными движка'],
  ['POST /v1/users', 'создать: username, secret?, max_tcp_conns, max_unique_ips, data_quota_bytes, expiration_rfc3339, user_ad_tag, rate_limit_up_bps, rate_limit_down_bps, enabled → {user, secret}'],
  ['GET /v1/users/{имя}', 'пользователь (UserInfo)'],
  ['PATCH /v1/users/{имя}', 'JSON Merge Patch: только переданные поля, null снимает ограничение; username в теле — новое имя'],
  ['DELETE /v1/users/{имя}', 'удалить'],
  ['POST /v1/users/{имя}/enable | disable', 'включить или выключить'],
  ['POST /v1/users/{имя}/rotate-secret', 'новый секрет ({"secret"} — свой) — старые ссылки перестанут работать'],
  ['POST /v1/users/{имя}/reset-quota', 'обнулить израсходованную квоту'],
  ['POST /v1/users/{имя}/reset-traffic', 'сбросить накопленный трафик и историю IP'],
  ['GET /v1/users/{имя}/links', 'ссылки: classic, secure, tls, tls_domains, web'],
  ['GET /v1/status', 'состояние прокси'],
  ['POST /v1/proxy/restart', 'перезапустить прокси'],
];

/**
 * Внешний API управления MTProxyL: им управляют пользователями и их лимитами
 * из своих проектов. Служба отдельная от панели, по умолчанию выключена;
 * ключ показывается один раз — на сервере остаётся только его хеш.
 */
export function ControlApiPage() {
  const [status, setStatus] = useState<ControlApiStatus | null>(null);
  const [supported, setSupported] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [listen, setListen] = useState('');
  const [allow, setAllow] = useState('');
  const [key, setKey] = useState('');
  const [confirmRotate, setConfirmRotate] = useState(false);
  const [copied, setCopied] = useState(false);

  const load = useCallback(async () => {
    try {
      const r = await mtproxylControlApi.get();
      setSupported(r.supported);
      if (r.status) {
        setStatus(r.status);
        setListen(r.status.listen);
        setAllow(r.status.allow);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const toggle = () => run(async () => {
    const r = await mtproxylControlApi.toggle(!status?.enabled);
    if (r.key) setKey(r.key);
  });

  const rotate = () => run(async () => {
    setConfirmRotate(false);
    const r = await mtproxylControlApi.rotateKey();
    setKey(r.key);
  });

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(key);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    } catch {
      // Без https буфер обмена недоступен — ключ виден и так.
    }
  };

  if (!supported) {
    return (
      <div className="space-y-4">
        <h1 className="text-xl font-semibold">API управления</h1>
        <Card>
          <CardContent className="pt-4 text-sm text-text-secondary">
            Установленный MTProxyL не умеет API управления — обновите его: <code>mtproxyl update</code>.
          </CardContent>
        </Card>
      </div>
    );
  }

  const base = status?.url ?? 'http://127.0.0.1:9190';

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">API управления</h1>
      {error && <ErrorAlert message={error} />}

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-3">
            Состояние
            {status && (
              <StatusBadge
                status={status.enabled && status.active}
                labelOn="включён"
                labelOff={status.enabled ? 'служба не работает' : 'выключен'}
              />
            )}
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          <p className="text-text-secondary">
            Управление пользователями и их лимитами из внешних проектов по HTTP. Работает и без
            панели; запросы идут с ключом в заголовке <code>Authorization: Bearer &lt;ключ&gt;</code>.
          </p>
          {status?.enabled && (
            <p>Адрес: <code>{base}</code>{status.version && <span className="text-text-secondary"> · {status.version}</span>}</p>
          )}
          <div className="flex flex-wrap gap-2">
            <Button onClick={() => void toggle()} disabled={busy} variant={status?.enabled ? 'outline' : 'default'}>
              {status?.enabled ? 'Выключить' : 'Включить'}
            </Button>
            {status?.has_key && (
              <Button variant="outline" onClick={() => setConfirmRotate(true)} disabled={busy}>
                <KeyRound className="w-4 h-4 mr-1" /> Новый ключ
              </Button>
            )}
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Доступ</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm">
          <div className="space-y-1">
            <Label htmlFor="api-listen">Адрес и порт</Label>
            <div className="flex gap-2">
              <Input id="api-listen" value={listen} onChange={(e) => setListen(e.target.value)} placeholder="0.0.0.0:9190" />
              <Button variant="outline" disabled={busy || listen === status?.listen}
                onClick={() => void run(async () => { await mtproxylControlApi.set('API_LISTEN', listen.trim()); })}>
                <Save className="w-4 h-4" />
              </Button>
            </div>
            <p className="text-xs text-text-secondary">127.0.0.1 — только с этого сервера, 0.0.0.0 — снаружи.</p>
          </div>
          <div className="space-y-1">
            <Label htmlFor="api-allow">Разрешённые адреса</Label>
            <div className="flex gap-2">
              <Input id="api-allow" value={allow} onChange={(e) => setAllow(e.target.value)} placeholder="203.0.113.10, 10.0.0.0/8" />
              <Button variant="outline" disabled={busy || allow === status?.allow}
                onClick={() => void run(async () => { await mtproxylControlApi.set('API_ALLOW', allow.trim()); })}>
                <Save className="w-4 h-4" />
              </Button>
            </div>
            <p className="text-xs text-text-secondary">IP или подсети через запятую. Пусто — с любого адреса, только по ключу.</p>
          </div>
          <div className="space-y-1">
            <Label>HTTPS</Label>
            <div className="flex gap-2">
              {(['off', 'selfmask'] as const).map((v) => (
                <Button key={v} variant={status?.tls === v ? 'default' : 'outline'} disabled={busy || status?.tls === v}
                  onClick={() => void run(async () => { await mtproxylControlApi.set('API_TLS', v); })}>
                  {v === 'off' ? 'Без HTTPS' : 'Сертификат Selfmask'}
                </Button>
              ))}
            </div>
            <p className="text-xs text-text-secondary">Снаружи без HTTPS ключ идёт открытым текстом — включите сертификат Selfmask или ограничьте адреса.</p>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Методы</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm">
          <pre className="text-xs bg-background border border-border rounded-md p-3 overflow-x-auto font-mono">
{`curl -H "Authorization: Bearer <ключ>" ${base}/v1/users
curl -X POST -H "Authorization: Bearer <ключ>" ${base}/v1/users \\
  -d '{"username":"alice","data_quota_bytes":10737418240,"rate_limit_down_bps":20000000}'`}
          </pre>
          <ul className="space-y-1">
            {ENDPOINTS.map(([m, d]) => (
              <li key={m}><code className="text-xs">{m}</code> <span className="text-text-secondary">— {d}</span></li>
            ))}
          </ul>
          <p className="text-xs text-text-secondary">
            Формат совместим с API telemt: <code>{'{"ok":true,"data":…,"revision":…}'}</code> или{' '}
            <code>{'{"ok":false,"error":{"code","message"}}'}</code>; без ограничения — <code>null</code>,
            срок — RFC3339 с <code>+00:00</code>, скорость в бит/с. Подробно — api.md в репозитории.
          </p>
        </CardContent>
      </Card>

      <ConfirmDialog
        open={confirmRotate}
        title="Выдать новый ключ?"
        message="Прежний ключ сразу перестанет работать — его придётся заменить во всех проектах."
        confirmLabel="Выдать"
        loadingLabel="Выдаём…"
        loading={busy}
        onConfirm={() => void rotate()}
        onClose={() => setConfirmRotate(false)}
      />
      <Dialog open={key !== ''} onClose={() => setKey('')}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Ключ API</DialogTitle>
          </DialogHeader>
          <div className="space-y-2 text-sm">
            <p className="text-text-secondary">Показывается один раз — сохраните его. На сервере остаётся только хеш.</p>
            <code className="block break-all bg-background border border-border rounded-md p-3 text-xs">{key}</code>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => void copy()}>
              <Copy className="w-4 h-4 mr-1" /> {copied ? 'Скопирован' : 'Копировать'}
            </Button>
            <Button onClick={() => setKey('')}>Сохранил</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
