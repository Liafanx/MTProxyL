import { useCallback, useEffect, useState } from 'react';
import { Trash2 } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import { formatBytes } from '@/lib/utils';
import { mtproxylApi, type MtproxylStats, type MtproxylStatsScope } from '@/lib/api';
import { useMtproxyl } from '@/hooks/useMtproxyl';

/**
 * Сброс накопленного. Уходят только счётчики трафика и история адресов —
 * настройки, секреты и пользователи остаются на месте.
 */
export function StatsResetCard() {
  const { enabled } = useMtproxyl();
  const [stats, setStats] = useState<MtproxylStats | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [label, setLabel] = useState('');

  const load = useCallback(async () => {
    if (!enabled) return;
    try {
      setStats(await mtproxylApi.stats());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить накопленное');
    }
  }, [enabled]);

  useEffect(() => {
    void load();
  }, [load]);

  if (!enabled) return null;

  const reset = async (scope: MtproxylStatsScope, confirmText: string, arg = '') => {
    if (!window.confirm(confirmText)) return;
    setBusy(true);
    try {
      const res = await mtproxylApi.statsReset(scope, arg);
      setNotice(res.output.trim().split('\n').pop() || 'Готово');
      setError(null);
      if (scope === 'user') setLabel('');
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сбросить');
    } finally {
      setBusy(false);
    }
  };

  const orphans = (stats?.traffic.orphans ?? 0) + (stats?.ips.orphans ?? 0);

  return (
    <Card>
      <CardHeader>
        <CardTitle>Сбросить накопленное</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        {error && <ErrorAlert message={error} />}
        {notice && <p className="text-sm text-success">{notice}</p>}

        <div className="grid grid-cols-2 md:grid-cols-3 gap-4 text-sm">
          <div>
            <p className="text-text-secondary text-xs">Пользователей в базе трафика</p>
            <p className="text-text-primary">{stats?.traffic.users ?? '—'}</p>
          </div>
          <div>
            <p className="text-text-secondary text-xs">Записей истории IP</p>
            <p className="text-text-primary">{stats?.ips.records ?? '—'}</p>
          </div>
          {stats && stats.mode !== 'reanimator' && (
            <div>
              <p className="text-text-secondary text-xs">Всего</p>
              <p className="text-text-primary">
                ↓ {formatBytes(stats.traffic.in_bytes)} ↑ {formatBytes(stats.traffic.out_bytes)}
              </p>
            </div>
          )}
        </div>

        <p className="text-xs text-text-secondary">
          Уходят только счётчики и история адресов. Настройки, секреты и сами
          пользователи остаются на месте.
        </p>

        <div className="flex flex-wrap gap-2">
          <Button
            variant="danger"
            size="sm"
            disabled={busy}
            onClick={() => reset('all', 'Сбросить трафик и историю IP?')}
          >
            <Trash2 size={14} className="mr-1.5" />
            Всё
          </Button>
          <Button
            variant="outline"
            size="sm"
            disabled={busy}
            onClick={() => reset('traffic', 'Сбросить счётчики трафика?')}
          >
            Только трафик
          </Button>
          <Button
            variant="outline"
            size="sm"
            disabled={busy}
            onClick={() => reset('ips', 'Очистить историю IP?')}
          >
            Только историю IP
          </Button>
          <Button
            variant="outline"
            size="sm"
            disabled={busy || orphans === 0}
            onClick={() => reset('orphans', 'Убрать данные удалённых пользователей?')}
          >
            Удалённых пользователей{orphans > 0 ? ` (${orphans})` : ''}
          </Button>
        </div>

        <div className="flex flex-col sm:flex-row gap-2">
          <Input
            value={label}
            onChange={(e) => setLabel(e.target.value)}
            placeholder="Метка пользователя"
            className="sm:max-w-xs"
          />
          <Button
            variant="outline"
            size="sm"
            disabled={busy || label.trim() === ''}
            onClick={() => reset('user', `Сбросить статистику ${label.trim()}?`, label.trim())}
          >
            Сбросить по одному
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}
