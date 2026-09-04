import { useCallback, useEffect, useMemo, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ParamField } from '@/components/ParamField';
import { useManagerOnly } from '@/hooks/useMtproxyl';
import { mtproxylSettingsApi, type MtproxylSetting } from '@/lib/api';

/**
 * Настройки самого MTProxyL: в конфиг движка не попадают, поэтому им не место
 * в «Настройках прокси», которые в реаниматоре скрыты целиком.
 */
export const MAINTENANCE_KEYS = [
  'BACKUP_RETENTION_DAYS',
  'IP_HISTORY_LIMIT',
  'IP_HISTORY_INTERVAL',
];

/** Бэкапы — только у менеджера, у чужой цели их делать нечем. */
const MANAGER_ONLY_KEYS = new Set(['BACKUP_RETENTION_DAYS']);

export function MaintenancePage() {
  const [params, setParams] = useState<MtproxylSetting[]>([]);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const { allowed: isManager } = useManagerOnly();

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setParams(await mtproxylSettingsApi.list());
      setEdits({});
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось загрузить настройки');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const shown = useMemo(
    () =>
      MAINTENANCE_KEYS.filter((k) => isManager || !MANAGER_ONLY_KEYS.has(k))
        .map((k) => params.find((p) => p.key === k))
        .filter(Boolean) as MtproxylSetting[],
    [params, isManager],
  );
  const byKey = useMemo(() => new Map(params.map((p) => [p.key, p])), [params]);
  const valueOf = (key: string) => edits[key] ?? byKey.get(key)?.value ?? '';

  const dirty = useMemo(
    () => Object.keys(edits).filter((k) => edits[k] !== byKey.get(k)?.value),
    [edits, byKey],
  );

  const save = async () => {
    if (dirty.length === 0) return;
    setSaving(true);
    setNotice(null);
    try {
      for (const key of dirty) {
        await mtproxylSettingsApi.set(key, edits[key]);
      }
      setNotice(`Сохранено настроек: ${dirty.length}`);
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить настройки');
      await load();
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="p-4 lg:p-6 space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Обслуживание</h1>
        <p className="text-sm text-text-secondary mt-1">
          Настройки самого MTProxyL: в конфиг движка они не попадают. Глубина истории IP
          работает в обоих режимах, хранение бэкапов — только в Manager, потому что
          бэкапить чужую цель нечем.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={load} />}
      {notice && <div className="text-sm text-success">{notice}</div>}

      {loading && params.length === 0 ? (
        <div className="text-sm text-text-secondary">Загрузка…</div>
      ) : shown.length === 0 ? (
        <Card>
          <CardContent className="p-4 text-sm text-text-secondary">
            MTProxyL не отдал ни одной из этих настроек — возможно, он старее панели.
          </CardContent>
        </Card>
      ) : (
        <Card>
          <CardHeader>
            <CardTitle>Настройки MTProxyL</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {shown.map((p) => (
              <div key={p.key} className="flex flex-col sm:flex-row sm:items-start gap-2 sm:gap-4">
                <div className="sm:w-1/2 min-w-0">
                  <div className="text-sm text-text-primary">{p.description}</div>
                  <div className="text-xs text-text-secondary font-mono truncate">{p.key}</div>
                </div>
                <ParamField
                  param={p}
                  value={valueOf(p.key)}
                  onChange={(v) => setEdits((prev) => ({ ...prev, [p.key]: v }))}
                />
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      {dirty.length > 0 && (
        <div className="sticky bottom-4 bg-surface border border-accent/40 rounded-lg p-3 shadow-lg">
          <div className="flex items-center gap-3 flex-wrap">
            <span className="text-sm text-text-primary flex-1">
              Изменено настроек: {dirty.length}
            </span>
            <Button variant="outline" onClick={() => setEdits({})} disabled={saving}>
              Отменить
            </Button>
            <Button onClick={save} disabled={saving}>
              {saving ? 'Сохраняем…' : 'Сохранить'}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
