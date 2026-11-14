import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { ErrorAlert } from '@/components/ErrorAlert';
import { mtproxylApi, type MtddIpPeriod, type MtddIpStats } from '@/lib/api';

const fmtTime = (t: number | null) =>
  t ? new Date(t * 1000).toLocaleString('ru-RU', { timeZone: 'UTC', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) + ' UTC' : '—';

const mib = (b: number | null) => (b == null ? '—' : `${Math.round((b / 1048576) * 10) / 10} MiB`);

function Row({ label, seen, active, since }: { label: string; seen: number; active: number; since?: string }) {
  return (
    <tr className="border-t border-border">
      <td className="py-2 pr-4 font-medium">{label}</td>
      <td className="py-2 pr-4 tabular-nums">{seen}</td>
      <td className="py-2 pr-4 tabular-nums">{active}</td>
      <td className="py-2 text-text-secondary">{since ?? ''}</td>
    </tr>
  );
}

/**
 * Уникальные IP mtdd. Отдельно от онлайн-счётчиков telemt-формы: у mtdd две меры,
 * и строгую active (≥ порога трафика) легко принять за ip_active telemt.
 */
export function MtddIpsPage() {
  const [data, setData] = useState<MtddIpStats | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setBusy(true);
    try {
      setData(await mtproxylApi.getMtddIps());
      setError('');
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }, []);
  useEffect(() => { void load(); }, [load]);

  const period = (label: string, p: MtddIpPeriod) => (
    <Row label={label} seen={p.seen} active={p.active} since={`с ${fmtTime(p.started_at)}`} />
  );

  return (
    <div className="p-4 lg:p-6 space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Уникальные IP (mtdd)</h1>
        <p className="text-sm text-text-secondary mt-1">
          <b>seen</b> — адреса, прошедшие рукопожатие с секретом: это то же, что «уникальные IP» у telemt.
          {' '}<b>active</b> — адреса, у которых хотя бы одно соединение передало не меньше порога
          {data ? ` (${mib(data.min_bytes)})` : ''}: реальные пользователи прокси, и при рекламном теге — те, кто увидел
          спонсорский канал. Их кратно меньше, чем seen.
        </p>
      </div>
      {error && <ErrorAlert message={error} onRetry={() => { void load(); }} />}
      {data && !data.available && <p className="text-sm text-text-secondary">Эта сборка mtdd не ведёт историю уникальных IP — обновите движок.</p>}
      {data && data.available && (
        <Card>
          <CardHeader><CardTitle>Онлайн и история</CardTitle></CardHeader>
          <CardContent className="space-y-3">
            <table className="w-full text-sm">
              <thead><tr className="text-left text-text-secondary"><th className="pb-2 pr-4 font-normal">Период</th><th className="pb-2 pr-4 font-normal">seen</th><th className="pb-2 pr-4 font-normal">active</th><th className="pb-2 font-normal">Начало периода</th></tr></thead>
              <tbody>
                <Row label="Онлайн сейчас" seen={data.online.seen} active={data.online.active} since="точный подсчёт" />
                {period('Час', data.hour)}
                {period('День', data.day)}
                {period('Неделя', data.week)}
              </tbody>
            </table>
            <p className="text-xs text-text-secondary">
              Час, день и неделя — оценка HyperLogLog по календарным периодам ({data.timezone}, неделя с понедельника),
              ошибка около ±{data.relative_error != null ? Math.round(data.relative_error * 1000) / 10 : 3.2}%.
              Сбор идёт с {fmtTime(data.collection_started_at)}{data.persistent ? '' : ' и при перезапуске mtdd начинается заново'}.
              Сами адреса в истории не хранятся.
            </p>
            <Button variant="outline" disabled={busy} onClick={() => { void load(); }}>Обновить</Button>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
