import { useCallback, useEffect, useMemo, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { ParamField } from '@/components/ParamField';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { OperationProgress } from '@/components/OperationProgress';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { mtproxylNetApi, type NftAction, type NftParam, type NftStatus } from '@/lib/api';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';

// Parameters are grouped so the form does not read as one flat list of 25 keys.
const GROUPS: { title: string; prefixes: string[] }[] = [
  // Smart идёт первым: это рекомендуемый режим, а classic оставлен для
  // простых случаев и совместимости со старыми настройками.
  {
    title: 'Smart-режим (By-MEKO) — рекомендуемый',
    prefixes: [
      'NFT_IOS_RATE', 'NFT_IOS_BURST', 'NFT_IOS_LIMIT_ENABLED', 'NFT_IOS_DETECT',
      'NFT_OTHER_RATE', 'NFT_OTHER_BURST', 'NFT_OTHER_LIMIT_ENABLED',
      'NFT_OTHER_ACTION', 'NFT_REJECT_MODE',
    ],
  },
  { title: 'Classic-режим', prefixes: ['NFT_RATE', 'NFT_BURST', 'NFT_METER_TIMEOUT'] },
  { title: 'iOS Fix v1 (keepalive)', prefixes: ['IOS_KA_'] },
  { title: 'iOS Fix v2 (MSS + редирект)', prefixes: ['IOS2_'] },
  { title: 'Zapret2', prefixes: ['ZAPRET2_'] },
];

function groupOf(key: string): string {
  for (const g of GROUPS) {
    if (g.prefixes.some((p) => key === p || key.startsWith(p))) return g.title;
  }
  return 'Прочее';
}

export function NftPage() {
  const [status, setStatus] = useState<NftStatus | null>(null);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [confirmAction, setConfirmAction] = useState<{ action: NftAction; title: string; message: string } | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const st = await mtproxylNetApi.nft();
      setStatus(st);
      setEdits({});
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить состояние');
    } finally {
      setLoading(false);
    }
  }, []);

  const { operation, start, running } = useMtproxylOperation(load, ['nft:']);

  useEffect(() => {
    void load();
  }, [load]);

  const dirty = useMemo(
    () => Object.keys(edits).filter((k) => edits[k] !== status?.params.find((p) => p.key === k)?.value),
    [edits, status],
  );

  // saveChanged writes the edited parameters and, when asked, reapplies the
  // rules so the new values take effect in one step.
  //
  // Which action to apply depends on the active preset: the smart limiter is
  // built by its own command, so running plain `apply` there would rebuild the
  // classic ruleset and silently change behaviour.
  const saveChanged = async (thenApply: boolean) => {
    if (dirty.length === 0) return;
    setSaving(true);
    setNotice(null);
    try {
      // Sequential on purpose: each write rewrites the whole settings file, so
      // parallel requests would race and lose values.
      for (const key of dirty) {
        await mtproxylNetApi.setNftParam(key, edits[key]);
      }
      setError(null);

      if (thenApply) {
        const action: NftAction = status?.nft.mode === 'smart' ? 'smart' : 'apply';
        start(await mtproxylNetApi.nftAction(action));
      } else {
        setNotice(
          `Сохранено параметров: ${dirty.length}. Чтобы значения вступили в силу, примените правила заново.`,
        );
        await load();
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить параметры');
    } finally {
      setSaving(false);
    }
  };

  const runAction = async (action: NftAction) => {
    try {
      start(await mtproxylNetApi.nftAction(action));
      setError(null);
      setNotice(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось выполнить действие');
    }
  };

  const runPreset = async (preset: 'classic' | 'smart') => {
    try {
      start(await mtproxylNetApi.nftPreset(preset));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переключить режим');
    }
  };

  const grouped = useMemo(() => {
    const out = new Map<string, NftParam[]>();
    for (const p of status?.params ?? []) {
      const g = groupOf(p.key);
      out.set(g, [...(out.get(g) ?? []), p]);
    }
    return out;
  }, [status]);

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Лимитер и защита</h1>
        <p className="text-sm text-text-secondary mt-1">
          Ограничение SYN-флуда, фиксы для iOS и обход DPI через Zapret2. Изменённые
          параметры можно сохранить и сразу применить одной кнопкой либо сохранить
          отдельно и применить правила позже.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={load} />}
      {notice && (
        <div className="bg-accent/10 border border-accent/30 rounded-lg p-3 text-sm text-text-primary">
          {notice}
        </div>
      )}
      <OperationProgress operation={operation} />

      {loading && !status ? (
        <div className="text-sm text-text-secondary">Загрузка…</div>
      ) : (
        status && (
          <>
            <Card>
              <CardHeader>
                <CardTitle>Состояние</CardTitle>
              </CardHeader>
              <CardContent className="space-y-2 text-sm">
                <StateRow
                  label={`Лимитер (${status.nft.mode})`}
                  on={status.nft.enabled}
                  extra={status.nft.service_active ? 'служба активна' : 'служба не запущена'}
                />
                <StateRow label="iOS Fix v1" on={status.ios_fix_v1.enabled} />
                <StateRow label="iOS Fix v2" on={status.ios_fix_v2.enabled} />
                <StateRow
                  label="Zapret2"
                  on={status.zapret2.applied}
                  extra={status.zapret2.service_active ? 'служба активна' : 'служба не запущена'}
                />
                <StateRow label="Оптимизация By-MEKO" on={status.meko_opt.applied} />
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Действия</CardTitle>
              </CardHeader>
              <CardContent className="space-y-4">
                <div>
                  <div className="text-xs text-text-secondary mb-2">
                    Режим лимитера — рекомендуется Smart
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Button
                      variant={status.nft.mode === 'smart' ? 'default' : 'outline'}
                      disabled={running}
                      onClick={() => runPreset('smart')}
                    >
                      Smart (By-MEKO)
                    </Button>
                    <Button
                      variant={status.nft.mode === 'classic' ? 'default' : 'outline'}
                      disabled={running}
                      onClick={() => runPreset('classic')}
                    >
                      Classic
                    </Button>
                  </div>
                </div>

                <div>
                  <div className="text-xs text-text-secondary mb-2">Правила</div>
                  <div className="flex flex-wrap gap-2">
                    <Button disabled={running} onClick={() => runAction('apply')}>
                      Применить правила
                    </Button>
                    <Button variant="outline" disabled={running} onClick={() => runAction('service')}>
                      Установить службу
                    </Button>
                    <Button
                      variant="danger"
                      disabled={running}
                      onClick={() =>
                        setConfirmAction({
                          action: 'remove',
                          title: 'Удалить правила лимитера',
                          message: 'Правила nftables будут сняты, ограничение SYN перестанет действовать. Продолжить?',
                        })
                      }
                    >
                      Удалить правила
                    </Button>
                  </div>
                </div>

                <div>
                  <div className="text-xs text-text-secondary mb-2">Фиксы для iOS</div>
                  <div className="flex flex-wrap gap-2">
                    <Button variant="outline" disabled={running} onClick={() => runAction('ios1')}>
                      Включить v1
                    </Button>
                    <Button variant="outline" disabled={running} onClick={() => runAction('ios1-off')}>
                      Откатить v1
                    </Button>
                    <Button variant="outline" disabled={running} onClick={() => runAction('ios2')}>
                      Включить v2
                    </Button>
                    <Button variant="outline" disabled={running} onClick={() => runAction('ios2-off')}>
                      Откатить v2
                    </Button>
                  </div>
                </div>

                <div>
                  <div className="text-xs text-text-secondary mb-2">Zapret2</div>
                  <div className="flex flex-wrap gap-2">
                    <Button disabled={running} onClick={() => runAction('zapret2')}>
                      Установить
                    </Button>
                    <Button variant="outline" disabled={running} onClick={() => runAction('zapret2-start')}>
                      Запустить
                    </Button>
                    <Button variant="outline" disabled={running} onClick={() => runAction('zapret2-stop')}>
                      Остановить
                    </Button>
                    <Button variant="outline" disabled={running} onClick={() => runAction('zapret2-wscale')}>
                      Проверить wscale
                    </Button>
                    <Button
                      variant="danger"
                      disabled={running}
                      onClick={() =>
                        setConfirmAction({
                          action: 'zapret2-rm',
                          title: 'Удалить Zapret2',
                          message: 'Служба и правила Zapret2 будут удалены. Продолжить?',
                        })
                      }
                    >
                      Удалить
                    </Button>
                  </div>
                </div>
              </CardContent>
            </Card>

            <div className="space-y-3">
              {GROUPS.map(({ title }) => {
                const params = grouped.get(title);
                if (!params || params.length === 0) return null;
                return (
                  <CollapsibleSection key={title} title={title} defaultOpen={false}>
                    <div className="space-y-3">
                      {params.map((p) => (
                        <div
                          key={p.key}
                          className="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-4"
                        >
                          <div className="sm:w-1/2 min-w-0">
                            <div className="text-sm text-text-primary">{p.description}</div>
                            <div className="text-xs text-text-secondary font-mono truncate">{p.key}</div>
                          </div>
                          <ParamField
                            param={p}
                            value={edits[p.key] ?? p.value}
                            onChange={(v) => setEdits((prev) => ({ ...prev, [p.key]: v }))}
                          />
                        </div>
                      ))}
                    </div>
                  </CollapsibleSection>
                );
              })}
            </div>

            {dirty.length > 0 && (
              <div className="sticky bottom-4 bg-surface border border-accent/40 rounded-lg p-3 flex items-center gap-3 flex-wrap shadow-lg">
                <span className="text-sm text-text-primary flex-1">
                  Изменено параметров: {dirty.length}
                </span>
                <Button variant="outline" onClick={() => setEdits({})} disabled={saving || running}>
                  Сбросить
                </Button>
                <Button variant="outline" onClick={() => saveChanged(false)} disabled={saving || running}>
                  {saving ? 'Сохранение…' : 'Только сохранить'}
                </Button>
                <Button onClick={() => saveChanged(true)} disabled={saving || running}>
                  {saving ? 'Сохранение…' : 'Сохранить и применить'}
                </Button>
              </div>
            )}
          </>
        )
      )}

      <ConfirmDialog
        open={confirmAction !== null}
        onClose={() => setConfirmAction(null)}
        onConfirm={() => {
          const a = confirmAction;
          setConfirmAction(null);
          if (a) void runAction(a.action);
        }}
        title={confirmAction?.title ?? ''}
        message={confirmAction?.message ?? ''}
        confirmLabel="Продолжить"
        loadingLabel="Выполнение…"
      />
    </div>
  );
}

function StateRow({ label, on, extra }: { label: string; on: boolean; extra?: string }) {
  return (
    <div className="flex items-center justify-between gap-4">
      <span className="text-text-secondary">{label}</span>
      <span className="flex items-center gap-2">
        {extra && <span className="text-xs text-text-secondary">{extra}</span>}
        <StatusBadge status={on} labelOn="ВКЛ" labelOff="ВЫКЛ" />
      </span>
    </div>
  );
}
