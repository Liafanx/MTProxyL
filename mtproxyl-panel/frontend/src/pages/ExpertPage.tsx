import { useCallback, useEffect, useMemo, useState } from 'react';
import { RotateCcw, Search, Zap } from 'lucide-react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { ParamField } from '@/components/ParamField';
import { ManagerOnlyNotice } from '@/components/ManagerOnlyNotice';
import { useManagerOnly } from '@/hooks/useMtproxyl';
import { mtproxylExpertApi, type ExpertParam } from '@/lib/api';

/** Совпадает ли параметр со строкой поиска. */
function matches(p: ExpertParam, q: string): boolean {
  if (!q) return true;
  const needle = q.toLowerCase();
  return (
    p.key.toLowerCase().includes(needle) ||
    p.section.toLowerCase().includes(needle) ||
    p.description.toLowerCase().includes(needle)
  );
}

export function ExpertPage() {
  const [params, setParams] = useState<ExpertParam[]>([]);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [search, setSearch] = useState('');
  const [onlyOverridden, setOnlyOverridden] = useState(false);

  const { allowed, loading: modeLoading } = useManagerOnly();

  const load = useCallback(async () => {
    // Экспертные параметры правят собственный конфиг движка, которого в
    // реаниматоре нет — MTProxyL такую команду отклонит.
    if (!allowed) {
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      setParams(await mtproxylExpertApi.catalog());
      setEdits({});
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось загрузить каталог');
    } finally {
      setLoading(false);
    }
  }, [allowed]);

  useEffect(() => {
    void load();
  }, [load]);

  const idOf = (p: ExpertParam) => `${p.section}.${p.key}`;

  // Эффективное значение: правка → override → значение по умолчанию.
  const valueOf = (p: ExpertParam) => edits[idOf(p)] ?? (p.has_override ? p.override : p.default);

  const dirty = useMemo(
    () =>
      params.filter((p) => {
        const e = edits[idOf(p)];
        if (e === undefined) return false;
        return e !== (p.has_override ? p.override : p.default);
      }),
    [edits, params],
  );

  const visible = useMemo(
    () => params.filter((p) => matches(p, search) && (!onlyOverridden || p.has_override)),
    [params, search, onlyOverridden],
  );

  const sections = useMemo(() => {
    const out = new Map<string, ExpertParam[]>();
    for (const p of visible) {
      out.set(p.section, [...(out.get(p.section) ?? []), p]);
    }
    return [...out.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [visible]);

  const overriddenCount = params.filter((p) => p.has_override).length;

  const save = async () => {
    if (dirty.length === 0) return;
    setSaving(true);
    setNotice(null);
    try {
      // Последовательно: каждая запись переписывает файл override целиком.
      for (const p of dirty) {
        await mtproxylExpertApi.set(p.section, p.key, edits[idOf(p)]);
      }
      const needsRestart = dirty.some((p) => !p.hot_reload);
      setNotice(
        `Сохранено параметров: ${dirty.length}.` +
          (needsRestart
            ? ' Часть из них применяется только после перезапуска прокси.'
            : ' Все применяются на лету.'),
      );
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить параметры');
    } finally {
      setSaving(false);
    }
  };

  const clearOne = async (p: ExpertParam) => {
    try {
      await mtproxylExpertApi.clear(p.section, p.key);
      setNotice(`Значение [${p.section}] ${p.key} возвращено к сгенерированному`);
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сбросить параметр');
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Экспертные параметры</h1>
        <p className="text-sm text-text-secondary mt-1">
          Точечная правка конфигурации движка telemt. Значения накладываются поверх
          сгенерированного конфига, поэтому переустановка и смена настроек их не затирают.
        </p>
      </div>

      {!modeLoading && !allowed && <ManagerOnlyNotice feature="Экспертные параметры" />}

      {allowed && (
        <>
          {error && <ErrorAlert message={error} onRetry={load} />}
          {notice && (
            <div className="bg-accent/10 border border-accent/30 rounded-lg p-3 text-sm text-text-primary">
              {notice}
            </div>
          )}

          <Card>
            <CardContent className="pt-4 flex flex-wrap items-center gap-3">
              <div className="relative flex-1 min-w-[220px]">
                <Search
                  size={16}
                  className="absolute left-3 top-1/2 -translate-y-1/2 text-text-secondary"
                />
                <Input
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="Поиск по ключу, секции или описанию…"
                  className="pl-9"
                />
              </div>
              <label className="flex items-center gap-2 text-sm text-text-secondary cursor-pointer">
                <input
                  type="checkbox"
                  checked={onlyOverridden}
                  onChange={(e) => setOnlyOverridden(e.target.checked)}
                  className="accent-[var(--color-accent,#3b82f6)]"
                />
                Только изменённые ({overriddenCount})
              </label>
              <span className="text-xs text-text-secondary">
                Показано: {visible.length} из {params.length}
              </span>
            </CardContent>
          </Card>

          {loading && params.length === 0 ? (
            <div className="text-sm text-text-secondary">Загрузка…</div>
          ) : sections.length === 0 ? (
            <div className="text-sm text-text-secondary">Ничего не найдено</div>
          ) : (
            <div className="space-y-3">
              {sections.map(([section, list]) => (
                <CollapsibleSection
                  key={section}
                  title={section}
                  badge={String(list.length)}
                  defaultOpen={Boolean(search) || onlyOverridden}
                >
                  <div className="space-y-4">
                    {list.map((p) => (
                      <div key={idOf(p)} className="flex flex-col lg:flex-row lg:items-start gap-2 lg:gap-4">
                        <div className="lg:w-1/2 min-w-0">
                          <div className="flex items-center gap-2 flex-wrap">
                            <span className="text-sm font-mono text-text-primary">{p.key}</span>
                            {p.hot_reload && (
                              <span
                                title="Применяется без перезапуска"
                                className="inline-flex items-center gap-1 text-xs text-success bg-success/15 px-1.5 py-0.5 rounded"
                              >
                                <Zap size={10} />
                                на лету
                              </span>
                            )}
                            {p.has_override && (
                              <span className="text-xs text-accent bg-accent/15 px-1.5 py-0.5 rounded">
                                изменён
                              </span>
                            )}
                          </div>
                          <div className="text-xs text-text-secondary mt-0.5">{p.description}</div>
                          {p.hint && (
                            <div className="text-xs text-text-secondary/70 mt-0.5">{p.hint}</div>
                          )}
                          <div className="text-xs text-text-secondary/70 mt-0.5 font-mono">
                            по умолчанию: {p.default || '—'}
                          </div>
                        </div>
                        <div className="flex items-start gap-2">
                          <ParamField
                            param={p}
                            value={valueOf(p)}
                            onChange={(v) => setEdits((prev) => ({ ...prev, [idOf(p)]: v }))}
                          />
                          {p.has_override && (
                            <Button
                              size="sm"
                              variant="outline"
                              title="Вернуть сгенерированное значение"
                              onClick={() => clearOne(p)}
                            >
                              <RotateCcw size={14} />
                            </Button>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                </CollapsibleSection>
              ))}
            </div>
          )}

          {dirty.length > 0 && (
            <div className="sticky bottom-4 bg-surface border border-accent/40 rounded-lg p-3 flex items-center gap-3 flex-wrap shadow-lg">
              <span className="text-sm text-text-primary flex-1">
                Изменено параметров: {dirty.length}
              </span>
              <Button variant="outline" onClick={() => setEdits({})} disabled={saving}>
                Отменить
              </Button>
              <Button onClick={save} disabled={saving}>
                {saving ? 'Сохранение…' : 'Сохранить'}
              </Button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
