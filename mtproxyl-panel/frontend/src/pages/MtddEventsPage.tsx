import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { ErrorAlert } from '@/components/ErrorAlert';
import { mtddApi, type MtddEventsDoc } from '@/lib/api';

const fmtTime = (s?: string) => {
  if (!s) return '—';
  const d = new Date(s);
  return Number.isNaN(d.getTime())
    ? s
    : d.toLocaleString('ru-RU', { timeZone: 'UTC', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
};

const ACTION_LABELS: Record<string, string> = {
  'user.create': 'Создан пользователь',
  'user.update': 'Изменён пользователь',
  'user.delete': 'Удалён пользователь',
  'user.rotate_secret': 'Новый секрет',
  'user.enable': 'Включён',
  'user.disable': 'Выключен',
  'user.reset_quota': 'Сброшена квота',
  'ad_tag.override': 'Подменён рекламный тег',
  'ad_tag.reset': 'Снята подмена тега',
};

/**
 * Журнал изменений mtdd (/v1/events): кольцевой буфер последних успешных
 * правок в памяти движка. Сбрасывается при его перезапуске — это не замена
 * логам панели, а ответ на «кто это сделал».
 */
export function MtddEventsPage() {
  const [doc, setDoc] = useState<MtddEventsDoc | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [limit, setLimit] = useState(50);

  const load = useCallback(async () => {
    setBusy(true);
    try {
      setDoc(await mtddApi.events(limit));
      setError('');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [limit]);

  useEffect(() => {
    void load();
    const t = window.setInterval(() => { void load(); }, 15000);
    return () => window.clearInterval(t);
  }, [load]);

  const events = doc?.events ?? [];

  return (
    <div className="p-4 lg:p-6 space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Журнал движка (mtdd)</h1>
        <p className="text-sm text-text-secondary mt-1">
          Последние изменения пользователей и рекламного тега. Значения полей и секреты в журнал
          не попадают — только имена изменённых полей. Буфер живёт в памяти и очищается при
          перезапуске mtdd.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={() => { void load(); }} />}

      <Card>
        <CardHeader>
          <CardTitle>События</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {events.length === 0 ? (
            <p className="text-sm text-text-secondary">Событий нет: журнал ведётся с запуска движка.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-text-secondary">
                    <th className="pb-2 pr-4 font-normal">Время (UTC)</th>
                    <th className="pb-2 pr-4 font-normal">Действие</th>
                    <th className="pb-2 pr-4 font-normal">Пользователь</th>
                    <th className="pb-2 pr-4 font-normal">Поля</th>
                    <th className="pb-2 font-normal">Источник</th>
                  </tr>
                </thead>
                <tbody>
                  {events.map((e) => (
                    <tr key={e.id} className="border-t border-border align-top">
                      <td className="py-2 pr-4 whitespace-nowrap tabular-nums">{fmtTime(e.at)}</td>
                      <td className="py-2 pr-4">{ACTION_LABELS[e.action] ?? e.action}</td>
                      <td className="py-2 pr-4 font-mono">{e.user ?? '—'}</td>
                      <td className="py-2 pr-4 text-text-secondary">{(e.fields ?? []).join(', ') || '—'}</td>
                      <td className="py-2 text-text-secondary">{e.source ?? '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <div className="flex flex-wrap items-center gap-3">
            <label className="flex items-center gap-2 text-sm text-text-secondary">
              Показывать
              <select
                value={limit}
                onChange={(e) => setLimit(Number(e.target.value))}
                className="min-h-[32px] rounded-md border border-border bg-surface px-2 text-sm text-text"
              >
                {[20, 50, 100, 256].map((n) => <option key={n} value={n}>{n}</option>)}
              </select>
            </label>
            <Button variant="outline" disabled={busy} onClick={() => { void load(); }}>Обновить</Button>
            {doc && (
              <span className="text-xs text-text-secondary">
                Всего: {events.length}
                {doc.capacity ? ` · в буфере до ${doc.capacity}` : ''}
              </span>
            )}
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
