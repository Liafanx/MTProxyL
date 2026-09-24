import { useEffect, useState } from 'react';
import { Save, Trash2 } from 'lucide-react';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Skeleton } from '@/components/ui/skeleton';
import { historyStorageApi, type HistoryLimits, type HistoryStorage } from '@/lib/api';
import { formatEpoch } from '@/lib/gated';
import { formatBytes, formatNumber, plural } from '@/lib/utils';

type ClearTarget = 'traffic' | 'fingerprints' | null;

function Stat({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="rounded-lg bg-bg px-3 py-2.5">
      <div className="text-micro text-text-faint">{label}</div>
      <div className="mt-0.5 text-meta font-semibold tabular-nums text-text">{value}</div>
      {hint && <div className="mt-0.5 text-micro text-text-faint">{hint}</div>}
    </div>
  );
}

function sinceText(since?: number): string | undefined {
  return since ? `с ${formatEpoch(since)}` : undefined;
}

/** Карточка «Данные панели»: сколько занимает история, пределы и очистка. */
export function HistoryStorageCard({ onError, onNotice }: { onError: (msg: string) => void; onNotice: (msg: string) => void }) {
  const [storage, setStorage] = useState<HistoryStorage | null>(null);
  const [loadError, setLoadError] = useState('');
  const [form, setForm] = useState<HistoryLimits>({ traffic_max_users: 0, fingerprints_max_records: 2000, fingerprints_retention_days: 30 });
  const [saving, setSaving] = useState(false);
  const [clearing, setClearing] = useState(false);
  const [confirm, setConfirm] = useState<ClearTarget>(null);

  const applyStorage = (s: HistoryStorage) => {
    setStorage(s);
    setForm(s.limits);
  };

  useEffect(() => {
    let cancelled = false;
    historyStorageApi.get()
      .then((s) => { if (!cancelled) applyStorage(s); })
      .catch((err) => { if (!cancelled) setLoadError(err instanceof Error ? err.message : 'Не удалось получить сведения о хранилище'); });
    return () => { cancelled = true; };
  }, []);

  const dirty = storage
    && (form.traffic_max_users !== storage.limits.traffic_max_users
      || form.fingerprints_max_records !== storage.limits.fingerprints_max_records
      || form.fingerprints_retention_days !== storage.limits.fingerprints_retention_days);

  const setNumber = (key: keyof HistoryLimits) => (event: React.ChangeEvent<HTMLInputElement>) => {
    const n = Number(event.target.value);
    setForm((prev) => ({ ...prev, [key]: Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0 }));
  };

  const save = async () => {
    setSaving(true);
    try {
      applyStorage(await historyStorageApi.setLimits(form));
      onNotice('Пределы хранения сохранены');
    } catch (err) {
      onError(err instanceof Error ? err.message : 'Не удалось сохранить пределы');
    } finally {
      setSaving(false);
    }
  };

  const clear = async () => {
    if (!confirm) return;
    setClearing(true);
    try {
      applyStorage(confirm === 'traffic' ? await historyStorageApi.clearTraffic() : await historyStorageApi.clearFingerprints());
      onNotice(confirm === 'traffic' ? 'История трафика очищена' : 'История TLS‑отпечатков очищена');
      setConfirm(null);
    } catch (err) {
      onError(err instanceof Error ? err.message : 'Не удалось очистить историю');
    } finally {
      setClearing(false);
    }
  };

  const disabled = storage && !storage.traffic.enabled && !storage.fingerprints.enabled;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Данные панели</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <p className="text-meta text-text-muted">
          История трафика по пользователям и TLS‑отпечатки клиентов хранятся на диске панели и переживают перезапуск движка.
          Двухчасовая история метрик для графиков живёт в памяти.
        </p>

        {loadError ? (
          <p className="text-meta text-warn">{loadError}</p>
        ) : !storage ? (
          <Skeleton className="h-24" />
        ) : disabled ? (
          <p className="text-meta text-text-muted">
            История на диске выключена: не задан <code className="font-mono text-[12px]">data_dir</code> или в конфиге <code className="font-mono text-[12px]">[history] enabled = false</code>.
          </p>
        ) : (
          <>
            <div className="grid grid-cols-2 gap-2 md:grid-cols-3">
              <Stat
                label="История трафика"
                value={storage.traffic.enabled ? formatBytes(storage.traffic.bytes) : 'выключена'}
                hint={storage.traffic.enabled ? `${formatNumber(storage.traffic.users)} ${plural(storage.traffic.users, ['пользователь', 'пользователя', 'пользователей'])}${storage.traffic.observed_since_epoch_secs ? ` · ${sinceText(storage.traffic.observed_since_epoch_secs)}` : ''}` : undefined}
              />
              <Stat
                label="TLS‑отпечатки"
                value={storage.fingerprints.enabled ? formatBytes(storage.fingerprints.bytes) : 'выключены'}
                hint={storage.fingerprints.enabled ? `${formatNumber(storage.fingerprints.records)} ${plural(storage.fingerprints.records, ['запись', 'записи', 'записей'])}${storage.fingerprints.observed_since_epoch_secs ? ` · ${sinceText(storage.fingerprints.observed_since_epoch_secs)}` : ''}` : undefined}
              />
              <Stat
                label="Метрики в памяти"
                value={formatBytes(storage.memory.bytes)}
                hint={`${formatNumber(storage.memory.points)} ${plural(storage.memory.points, ['точка', 'точки', 'точек'])} · ${Math.round(storage.memory.retention_secs / 3600)} ч`}
              />
            </div>

            <div className="grid gap-4 sm:grid-cols-3">
              <div className="space-y-1.5">
                <Label htmlFor="limit-traffic-users">Пользователей в истории трафика</Label>
                <Input id="limit-traffic-users" type="number" min={0} max={100000} value={form.traffic_max_users} onChange={setNumber('traffic_max_users')} />
                <p className="text-xs text-text-secondary">0 — без предела. Лишние удаляются по давности активности.</p>
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="limit-fp-records">Отпечатков в каждой группе</Label>
                <Input id="limit-fp-records" type="number" min={0} max={100000} value={form.fingerprints_max_records} onChange={setNumber('fingerprints_max_records')} />
                <p className="text-xs text-text-secondary">По отпечатку, IP, подсети и пользователю. 0 — без предела.</p>
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="limit-fp-days">Хранить отпечатки, дней</Label>
                <Input id="limit-fp-days" type="number" min={0} max={3650} value={form.fingerprints_retention_days} onChange={setNumber('fingerprints_retention_days')} />
                <p className="text-xs text-text-secondary">Записи, не видевшиеся дольше, удаляются. 0 — не удалять.</p>
              </div>
            </div>

            <div className="flex flex-wrap gap-2">
              <Button onClick={save} disabled={saving || !dirty}>
                <Save size={16} className="mr-1.5" />
                {saving ? 'Сохранение…' : 'Сохранить пределы'}
              </Button>
              {storage.traffic.enabled && (
                <Button type="button" variant="outline" className="text-danger hover:text-danger" disabled={clearing || storage.traffic.users === 0} onClick={() => setConfirm('traffic')}>
                  <Trash2 size={16} className="mr-1.5" />
                  Очистить историю трафика
                </Button>
              )}
              {storage.fingerprints.enabled && (
                <Button type="button" variant="outline" className="text-danger hover:text-danger" disabled={clearing || storage.fingerprints.records === 0} onClick={() => setConfirm('fingerprints')}>
                  <Trash2 size={16} className="mr-1.5" />
                  Очистить отпечатки
                </Button>
              )}
            </div>
            <p className="text-xs text-text-secondary">
              Файлы: <code className="font-mono text-[11px]">{storage.traffic.path || '—'}</code>, <code className="font-mono text-[11px]">{storage.fingerprints.path || '—'}</code>.
            </p>
          </>
        )}
      </CardContent>

      <ConfirmDialog
        open={confirm !== null}
        onClose={() => setConfirm(null)}
        onConfirm={clear}
        loading={clearing}
        title={confirm === 'traffic' ? 'Очистить историю трафика?' : 'Очистить TLS‑отпечатки?'}
        message={confirm === 'traffic'
          ? 'Графики трафика по времени на странице «Трафик» и в карточках пользователей начнутся с нуля. Накопленный трафик из MTProxyL не затрагивается.'
          : 'Накопленные панелью отпечатки будут удалены; в таблице останется только то, что сейчас помнит движок.'}
        confirmLabel="Очистить"
        loadingLabel="Очистка…"
      />
    </Card>
  );
}
