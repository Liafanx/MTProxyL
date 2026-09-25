import { useCallback, useEffect, useMemo, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { ErrorAlert } from '@/components/ErrorAlert';
import { mtproxylNetApi, mtproxylUsersApi, type ShapingConfig, type ShapingStatus } from '@/lib/api';

const EMPTY: ShapingConfig = {
  enabled: false, mode: 'manual', channel_mbps: 1000, reserve_percent: 10,
  expected_users: 10, manual_total_mbps: 900, manual_ip_mbps: 90,
  profile_exempt: [], ip_exempt: [],
};

const mbps = (bps: number) => (bps / 1_000_000).toLocaleString('ru-RU', { maximumFractionDigits: 2 });
const splitList = (value: string) => value.split(/[\n,]/).map((v) => v.trim()).filter(Boolean);
type NumericKey = 'channel_mbps' | 'reserve_percent' | 'expected_users' | 'manual_total_mbps' | 'manual_ip_mbps';
const numberKeys: NumericKey[] = ['channel_mbps', 'reserve_percent', 'expected_users', 'manual_total_mbps', 'manual_ip_mbps'];
const numberDrafts = (config: ShapingConfig): Record<NumericKey, string> => ({
  channel_mbps: String(config.channel_mbps), reserve_percent: String(config.reserve_percent),
  expected_users: String(config.expected_users), manual_total_mbps: String(config.manual_total_mbps),
  manual_ip_mbps: String(config.manual_ip_mbps),
});

export function ShapingPage() {
  const [status, setStatus] = useState<ShapingStatus | null>(null);
  const [form, setForm] = useState<ShapingConfig>(EMPTY);
  const [drafts, setDrafts] = useState(() => numberDrafts(EMPTY));
  const [profiles, setProfiles] = useState<string[]>([]);
  const [availableProfiles, setAvailableProfiles] = useState<string[]>([]);
  const [profileError, setProfileError] = useState('');
  const [ips, setIps] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const load = useCallback(async (replaceForm = true) => {
    try {
      const next = await mtproxylNetApi.shaping();
      setStatus(next);
      if (replaceForm) {
        setForm(next.config);
        setDrafts(numberDrafts(next.config));
        setProfiles(next.config.profile_exempt);
        setIps(next.config.ip_exempt.join(', '));
      }
      setError('');
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  }, []);

  const loadProfiles = useCallback(async () => {
    try {
      const users = await mtproxylUsersApi.list();
      setAvailableProfiles([...new Set(users.map((user) => user.label))].sort((a, b) => a.localeCompare(b, 'ru')));
      setProfileError('');
    } catch (e) { setProfileError(e instanceof Error ? e.message : String(e)); }
  }, []);

  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void loadProfiles(); }, [loadProfiles]);
  useEffect(() => {
    if (!status?.config.enabled) return;
    const timer = window.setInterval(() => { void load(false); }, 30000);
    return () => window.clearInterval(timer);
  }, [status?.config.enabled, status?.config.mode, load]);

  const setNumber = (key: NumericKey) => (e: React.ChangeEvent<HTMLInputElement>) => {
    setDrafts((old) => ({ ...old, [key]: e.target.value }));
  };
  const numbers = Object.fromEntries(numberKeys.map((key) => [key, Number(drafts[key])])) as Pick<ShapingConfig, NumericKey>;
  const total = form.mode === 'manual' ? numbers.manual_total_mbps : numbers.channel_mbps * (1 - numbers.reserve_percent / 100);
  const divisor = form.mode === 'dynamic' ? Math.max(numbers.expected_users, status?.state.active_ips ?? 0) : numbers.expected_users;
  const personal = form.mode === 'manual' ? numbers.manual_ip_mbps : total / divisor;
  const validation = useMemo(() => {
    if (form.mode !== 'manual') {
      if (!/^\d+$/.test(drafts.channel_mbps) || numbers.channel_mbps < 1 || numbers.channel_mbps > 100000) return 'Ширина канала: 1–100000 Мбит/с';
      if (!/^\d+$/.test(drafts.reserve_percent) || numbers.reserve_percent > 90) return 'Резерв: 0–90%';
      if (!/^\d+$/.test(drafts.expected_users) || numbers.expected_users < 2 || numbers.expected_users > 100000) return 'Минимум пользователей: 2–100000';
    } else {
      if (!/^\d+$/.test(drafts.manual_total_mbps) || numbers.manual_total_mbps < 1 || numbers.manual_total_mbps > 100000) return 'Общий потолок: 1–100000 Мбит/с';
      if (!drafts.manual_ip_mbps.trim() || !Number.isFinite(numbers.manual_ip_mbps) || numbers.manual_ip_mbps < 0.1 || numbers.manual_ip_mbps > numbers.manual_total_mbps) return 'Лимит IP: от 0,1 Мбит/с до общего потолка';
    }
    if (profiles.some((x) => !/^[A-Za-z0-9_.-]{1,64}$/.test(x))) return 'Недопустимое название профиля';
    if (splitList(ips).some((x) => {
      const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\/(\d{1,2}))?$/.exec(x);
      return !m || m.slice(1, 5).some((n) => Number(n) > 255 || (n.length > 1 && n.startsWith('0'))) || (m[5] !== undefined && Number(m[5]) > 32);
    })) return 'Исключения IP: только IPv4 или IPv4/CIDR';
    return '';
  }, [form.mode, drafts, numbers.channel_mbps, numbers.reserve_percent, numbers.expected_users, numbers.manual_total_mbps, numbers.manual_ip_mbps, profiles, ips]);

  const apply = async (enabled: boolean) => {
    if (validation) { setError(validation); return; }
    setBusy(true); setError(''); setNotice('');
    try {
      const config = { ...form, ...numbers, enabled, profile_exempt: profiles, ip_exempt: [...new Set(splitList(ips))] };
      if (form.mode === 'manual') {
        config.channel_mbps = form.channel_mbps;
        config.reserve_percent = form.reserve_percent;
        config.expected_users = form.expected_users;
      } else {
        config.manual_total_mbps = form.manual_total_mbps;
        config.manual_ip_mbps = form.manual_ip_mbps;
      }
      await mtproxylNetApi.setShaping(config);
      await load();
      setNotice(enabled ? 'Ограничение скорости применено' : 'Ограничение скорости выключено');
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };

  return (
    <div className="p-4 lg:p-6 space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Ограничение скорости</h1>
        <p className="text-sm text-text-secondary mt-1">Ограничивается отдача клиентам по IPv4. Несколько соединений с одного IP считаются одним пользователем.</p>
      </div>
      {error && <ErrorAlert message={error} onRetry={() => { void load(); }} />}
      {notice && <div className="bg-accent/10 border border-accent/30 rounded-lg p-3 text-sm">{notice}</div>}
      {status && <Card>
        <CardHeader><CardTitle>Состояние</CardTitle></CardHeader>
        <CardContent className="space-y-1 text-sm">
          <p>{status.config.enabled ? 'Включено' : 'Выключено'} · общий потолок {mbps(status.rates.total_bps)} Мбит/с · на один IP {mbps(status.rates.ip_bps)} Мбит/с</p>
          <p className="text-text-secondary">Активных уникальных IP: {status.state.active_ips ?? 0} · отслеживаемых IP: {status.tracked_ips ?? 0} · интерфейс: {status.interface || '—'} · tc: {status.tc_active ? 'активен' : 'не активен'}</p>
          {status.state.last_sample_epoch && <p className="text-text-secondary">Последний замер: {new Date(status.state.last_sample_epoch * 1000).toLocaleString('ru-RU')}</p>}
          {status.state.last_error && <p className="text-danger">{status.state.last_error}</p>}
        </CardContent>
      </Card>}
      <Card>
        <CardHeader><CardTitle>Настройки</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-1"><Label htmlFor="shaping-mode">Расчёт лимита одного IP</Label>
            <select id="shaping-mode" className="w-full rounded-lg border border-border bg-surface px-3 py-2 text-text-primary" value={form.mode} onChange={(e) => setForm((old) => ({ ...old, mode: e.target.value as ShapingConfig['mode'] }))}>
              <option value="manual">Вручную</option><option value="fixed">По ширине канала и ожидаемому числу</option><option value="dynamic">По текущему числу активных IP</option>
            </select>
          </div>
          {form.mode === 'manual' ? <div className="grid gap-4 md:grid-cols-2">
            <div className="space-y-1"><Label htmlFor="shaping-total">Общий потолок, Мбит/с</Label><Input id="shaping-total" type="number" min="1" max="100000" value={drafts.manual_total_mbps} onChange={setNumber('manual_total_mbps')} /></div>
            <div className="space-y-1"><Label htmlFor="shaping-ip">На один IPv4, Мбит/с</Label><Input id="shaping-ip" type="number" min="0.1" step="0.1" value={drafts.manual_ip_mbps} onChange={setNumber('manual_ip_mbps')} /></div>
          </div> : <div className="grid gap-4 md:grid-cols-3">
            <div className="space-y-1"><Label htmlFor="shaping-channel">Ширина канала, Мбит/с</Label><Input id="shaping-channel" type="number" min="1" max="100000" value={drafts.channel_mbps} onChange={setNumber('channel_mbps')} /></div>
            <div className="space-y-1"><Label htmlFor="shaping-reserve">Резерв, %</Label><Input id="shaping-reserve" type="number" min="0" max="90" value={drafts.reserve_percent} onChange={setNumber('reserve_percent')} /></div>
            <div className="space-y-1"><Label htmlFor="shaping-users">{form.mode === 'dynamic' ? 'Минимальное число пользователей' : 'Ожидаемое число пользователей'}</Label><Input id="shaping-users" type="number" min="2" max="100000" value={drafts.expected_users} onChange={setNumber('expected_users')} /></div>
          </div>}
          <p className="text-sm text-text-secondary">Предварительно: общий потолок {validation ? '—' : total.toLocaleString('ru-RU')} Мбит/с; на один IP {validation ? '—' : personal.toLocaleString('ru-RU', { maximumFractionDigits: 2 })} Мбит/с{form.mode === 'dynamic' ? ` при делителе ${divisor}` : ''}.</p>
          <div className="grid gap-4 md:grid-cols-2">
            <div className="space-y-1"><Label htmlFor="shaping-profiles">Профили без лимита на IP</Label><select id="shaping-profiles" className="w-full rounded-lg border border-border bg-surface px-3 py-2 text-text-primary" value="" onChange={(e) => { if (e.target.value) setProfiles((old) => [...old, e.target.value]); }}><option value="">Выберите профиль из telemt</option>{availableProfiles.filter((name) => !profiles.includes(name)).map((name) => <option key={name} value={name}>{name}</option>)}</select><div className="flex flex-wrap gap-2">{profiles.map((name) => <button key={name} type="button" className="rounded-md border border-border px-2 py-1 text-xs text-text-primary" onClick={() => setProfiles((old) => old.filter((item) => item !== name))} title="Убрать исключение">{name} ×</button>)}</div>{profileError && <p className="text-xs text-danger">Не удалось загрузить профили: {profileError} <button type="button" className="underline" onClick={() => { void loadProfiles(); }}>Повторить</button></p>}<p className="text-xs text-text-secondary">IP профиля остаются внутри общего потолка; если один IP используют разные профили, действует лимит.</p></div>
            <div className="space-y-1"><Label htmlFor="shaping-ips">IPv4/CIDR вне общего потолка</Label><Input id="shaping-ips" placeholder="203.0.113.5, 198.51.100.0/24" value={ips} onChange={(e) => setIps(e.target.value)} /><p className="text-xs text-text-secondary">Исключённые адреса способны занять весь физический канал.</p></div>
          </div>
          <p className="text-xs text-text-secondary">Один IP получает один общий лимит на все свои TCP-соединения, даже если к одному профилю подключены многие IP. Список берётся из API telemt каждые 30 секунд: новые адреса до следующего замера временно делят один общий класс с таким же лимитом. На общем WEB/Selfmask-порту правила могут затронуть и веб-трафик.</p>
          {validation && <p className="text-sm text-danger">{validation}</p>}
          <div className="flex flex-wrap gap-2"><Button disabled={busy || !!validation} onClick={() => { void apply(true); }}>Сохранить и включить</Button><Button variant="outline" disabled={busy || !status?.config.enabled} onClick={() => { void apply(false); }}>Выключить</Button></div>
        </CardContent>
      </Card>
    </div>
  );
}
