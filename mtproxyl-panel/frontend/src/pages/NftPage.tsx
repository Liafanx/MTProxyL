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

// Параметры сгруппированы, чтобы форма не читалась плоским списком из 25 ключей.
// Порядок групп повторяет порядок разделов страницы.
const GROUPS: { title: string; prefixes: string[]; legacy?: boolean }[] = [
  { title: 'Zapret2', prefixes: ['ZAPRET2_'] },
  {
    title: 'Smart-режим (By-MEKO)',
    prefixes: [
      'NFT_IOS_RATE', 'NFT_IOS_BURST', 'NFT_IOS_LIMIT_ENABLED', 'NFT_IOS_DETECT',
      'NFT_OTHER_RATE', 'NFT_OTHER_BURST', 'NFT_OTHER_LIMIT_ENABLED',
      'NFT_OTHER_ACTION', 'NFT_REJECT_MODE',
    ],
  },
  { title: 'Classic-режим', prefixes: ['NFT_RATE', 'NFT_BURST', 'NFT_METER_TIMEOUT'], legacy: true },
  { title: 'iOS Fix v1 (keepalive)', prefixes: ['IOS_KA_'], legacy: true },
  { title: 'iOS Fix v2 (MSS + редирект)', prefixes: ['IOS2_'], legacy: true },
];

function groupOf(key: string): string {
  for (const g of GROUPS) {
    if (g.prefixes.some((p) => key === p || key.startsWith(p))) return g.title;
  }
  return 'Прочее';
}

/**
 * Какой способ защиты работает прямо сейчас.
 *
 * Zapret2 и лимитер обрабатывают один и тот же трафик и друг другу мешают,
 * поэтому MTProxyL включает их взаимоисключающе: установка Zapret2 снимает
 * лимитер, а включение Smart останавливает Zapret2. Страница показывает это
 * как выбор одного из двух, а не как два независимых переключателя.
 */
type Defense = 'zapret2' | 'smart' | 'classic' | 'none';

function activeDefense(status: NftStatus): Defense {
  if (status.zapret2.service_active) return 'zapret2';
  if (status.nft.service_active || status.nft.enabled) {
    return status.nft.mode === 'smart' ? 'smart' : 'classic';
  }
  return 'none';
}

const DEFENSE_LABEL: Record<Defense, string> = {
  zapret2: 'Zapret2',
  smart: 'Smart-режим (By-MEKO)',
  classic: 'Classic-лимитер',
  none: 'ничего',
};

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

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['nft:']);

  useEffect(() => {
    void load();
  }, [load]);

  const dirty = useMemo(
    () => Object.keys(edits).filter((k) => edits[k] !== status?.params.find((p) => p.key === k)?.value),
    [edits, status],
  );

  /**
   * Что переприменять после сохранения — решают изменённые ключи.
   *
   * Раньше действие выбиралось по сохранённому NFT_MODE, и правка параметров
   * zapret2 при NFT_MODE=smart запускала лимитер, а тот по своей же
   * взаимоисключающей логике останавливал zapret2. Возвращает null, когда
   * применять нечего: подсистема не установлена или сейчас не работает.
   */
  const applyActionFor = (keys: string[]): NftAction | null => {
    const zapret = keys.some((k) => k.startsWith('ZAPRET2_'));
    const limiter = keys.some((k) => !k.startsWith('ZAPRET2_'));
    const limiterAction: NftAction = status?.nft.mode === 'smart' ? 'smart' : 'apply';
    if (zapret && !limiter) return status?.zapret2.applied ? 'zapret2-start' : null;
    if (limiter && !zapret) return limiterAction;
    // Задели обе стороны — переприменяем ту, что защищает сейчас: включать
    // выключенную защиту молча, за компанию с сохранением, нельзя.
    switch (status ? activeDefense(status) : 'none') {
      case 'zapret2': return 'zapret2-start';
      case 'smart':   return 'smart';
      case 'classic': return 'apply';
      default:        return null;
    }
  };

  // saveChanged пишет параметры и, если попросили, переприменяет правила.
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

      const action = thenApply ? applyActionFor(dirty) : null;
      if (action) {
        start(await mtproxylNetApi.nftAction(action));
      } else if (thenApply) {
        setNotice(
          `Сохранено параметров: ${dirty.length}. Применять пока нечего: ` +
          'подсистема этих параметров не установлена или остановлена.',
        );
        await load();
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

  const active = status ? activeDefense(status) : 'none';

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Лимитер и защита</h1>
        <p className="text-sm text-text-secondary mt-1">
          Два основных способа: Zapret2 обходит DPI, Smart-режим ограничивает SYN-флуд.
          Они обрабатывают один и тот же трафик и мешают друг другу, поэтому работает
          что-то одно — включение любого из них снимает второй. Изменённые параметры
          можно сохранить и сразу применить одной кнопкой либо применить правила позже.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={load} />}
      {notice && (
        <div className="bg-accent/10 border border-accent/30 rounded-lg p-3 text-sm text-text-primary">
          {notice}
        </div>
      )}
      <OperationProgress operation={operation} onDismiss={dismiss} />

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
                <div className="pb-2 mb-1 border-b border-border">
                  <span className="text-text-secondary">Сейчас защищает: </span>
                  <span className="text-text-primary font-medium">{DEFENSE_LABEL[active]}</span>
                  {active === 'none' && (
                    <p className="text-xs text-warning mt-1">
                      Ни один способ не активен — сервер работает без защиты от SYN-флуда и DPI.
                    </p>
                  )}
                  {active === 'classic' && (
                    <p className="text-xs text-text-secondary mt-1">
                      Classic отнесён к устаревшим методам — Smart-режим делает то же самое,
                      не роняя iOS-клиентов.
                    </p>
                  )}
                </div>
                <StateRow
                  label="Zapret2"
                  on={status.zapret2.applied}
                  extra={status.zapret2.service_active ? 'служба активна' : 'служба не запущена'}
                />
                <StateRow
                  label={`Лимитер (${status.nft.mode})`}
                  on={status.nft.enabled}
                  extra={status.nft.service_active ? 'служба активна' : 'служба не запущена'}
                />
                <StateRow label="Оптимизация By-MEKO" on={status.meko_opt.applied} />
                <StateRow label="iOS Fix v1 (устар.)" on={status.ios_fix_v1.enabled} />
                <StateRow label="iOS Fix v2 (устар.)" on={status.ios_fix_v2.enabled} />
              </CardContent>
            </Card>

            <DefenseCard
              title="Zapret2"
              subtitle="Серверный обход DPI: disorder + badsum + управление TCP-окном. Клиенту ставить ничего не нужно."
              active={active === 'zapret2'}
              activeLabel="Работает"
              installed={status.zapret2.applied}
              running={running}
              onActivate={() =>
                status.zapret2.applied ? runAction('zapret2-start') : runAction('zapret2')
              }
              activateLabel={status.zapret2.applied ? 'Активировать Zapret2' : 'Установить и активировать Zapret2'}
              note={
                active === 'smart' || active === 'classic'
                  ? 'Сейчас работает лимитер — при активации Zapret2 он будет снят.'
                  : undefined
              }
              extra={
                <>
                  {status.zapret2.applied && (
                    <Button variant="outline" disabled={running} onClick={() => runAction('zapret2-stop')}>
                      Остановить
                    </Button>
                  )}
                  <Button variant="outline" disabled={running} onClick={() => runAction('zapret2-wscale')}>
                    Проверить wscale
                  </Button>
                  {status.zapret2.applied && (
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
                  )}
                </>
              }
            />

            <DefenseCard
              title="Smart-режим (By-MEKO)"
              subtitle="SYN-лимитер, который сам различает iOS и остальных по TTL и отвечает RST вместо молчания — клиент переподключается за секунды. Отдельный порт и iOS Fix v2 не нужны."
              active={active === 'smart'}
              activeLabel="Работает"
              installed
              running={running}
              onActivate={() => runAction('smart')}
              activateLabel="Активировать Smart-режим"
              note={
                active === 'zapret2'
                  ? 'Сейчас работает Zapret2 — при активации Smart он будет остановлен.'
                  : undefined
              }
              extra={
                (status.nft.enabled || status.nft.service_active) && (
                  <Button
                    variant="danger"
                    disabled={running}
                    onClick={() =>
                      setConfirmAction({
                        action: 'remove',
                        title: 'Снять правила лимитера',
                        message:
                          'Правила nftables будут сняты, ограничение SYN перестанет действовать. Продолжить?',
                      })
                    }
                  >
                    Снять правила лимитера
                  </Button>
                )
              }
            />

            <div className="space-y-3">
              {GROUPS.filter((g) => !g.legacy).map(({ title }) => (
                <ParamSection
                  key={title}
                  title={`Настройки: ${title}`}
                  params={grouped.get(title)}
                  edits={edits}
                  setEdits={setEdits}
                />
              ))}
            </div>

            <div className="pt-2">
              <div className="flex items-center gap-3 mb-2">
                <div className="h-px flex-1 bg-border" />
                <h2 className="text-sm font-medium text-text-secondary">Устаревшие методы</h2>
                <div className="h-px flex-1 bg-border" />
              </div>
              <p className="text-xs text-text-secondary/70 mb-3">
                Оставлены для совместимости и особых случаев. Smart-режим покрывает то же самое:
                classic ограничивает всех одинаково и роняет iOS-клиентов, iOS Fix v2 требует
                отдельного порта, а iOS Fix v1 правит sysctl всей системы. Если работает Smart или
                Zapret2, включать что-то отсюда не нужно.
              </p>

              <div className="space-y-3">
                <CollapsibleSection title="Classic-лимитер" defaultOpen={false}>
                  <div className="space-y-3">
                    <p className="text-xs text-text-secondary">
                      Один лимит на всех: 1 SYN в секунду с адреса. Работает, но iOS после выхода из
                      фона переподключается по 10-20 секунд.
                    </p>
                    <div className="flex flex-wrap gap-2">
                      <Button
                        variant={active === 'classic' ? 'default' : 'outline'}
                        disabled={running}
                        onClick={() => runPreset('classic')}
                      >
                        Переключить на classic
                      </Button>
                      <Button variant="outline" disabled={running} onClick={() => runAction('apply')}>
                        Применить правила
                      </Button>
                      <Button variant="outline" disabled={running} onClick={() => runAction('service')}>
                        Установить службу
                      </Button>
                    </div>
                    <ParamRows
                      params={grouped.get('Classic-режим')}
                      edits={edits}
                      setEdits={setEdits}
                    />
                  </div>
                </CollapsibleSection>

                <CollapsibleSection
                  title={`iOS Fix v1 — keepalive${status.ios_fix_v1.enabled ? ' · включён' : ''}`}
                  defaultOpen={false}
                >
                  <div className="space-y-3">
                    <p className="text-xs text-text-secondary">
                      Меняет sysctl TCP keepalive для всей системы, чтобы мёртвые сокеты
                      обнаруживались быстрее.
                    </p>
                    <div className="flex flex-wrap gap-2">
                      <Button variant="outline" disabled={running} onClick={() => runAction('ios1')}>
                        Включить
                      </Button>
                      <Button variant="outline" disabled={running} onClick={() => runAction('ios1-off')}>
                        Откатить
                      </Button>
                    </div>
                    <ParamRows
                      params={grouped.get('iOS Fix v1 (keepalive)')}
                      edits={edits}
                      setEdits={setEdits}
                    />
                  </div>
                </CollapsibleSection>

                <CollapsibleSection
                  title={`iOS Fix v2 — MSS и редирект${status.ios_fix_v2.enabled ? ' · включён' : ''}`}
                  defaultOpen={false}
                >
                  <div className="space-y-3">
                    <p className="text-xs text-text-secondary">
                      Отдельный порт для iOS с урезанным MSS и редиректом на основной. Smart-режим
                      заменяет его и при включении отключает.
                    </p>
                    <div className="flex flex-wrap gap-2">
                      <Button variant="outline" disabled={running} onClick={() => runAction('ios2')}>
                        Включить
                      </Button>
                      <Button variant="outline" disabled={running} onClick={() => runAction('ios2-off')}>
                        Откатить
                      </Button>
                    </div>
                    <ParamRows
                      params={grouped.get('iOS Fix v2 (MSS + редирект)')}
                      edits={edits}
                      setEdits={setEdits}
                    />
                  </div>
                </CollapsibleSection>

                {grouped.get('Прочее') && (
                  <ParamSection
                    title="Прочее"
                    params={grouped.get('Прочее')}
                    edits={edits}
                    setEdits={setEdits}
                  />
                )}
              </div>
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

interface DefenseCardProps {
  title: string;
  subtitle: string;
  active: boolean;
  activeLabel: string;
  installed: boolean;
  running: boolean;
  onActivate: () => void;
  activateLabel: string;
  /** Что произойдёт со вторым способом защиты при активации этого. */
  note?: string;
  extra?: React.ReactNode;
}

/**
 * Один способ защиты: что это, работает ли сейчас и кнопка активации.
 *
 * Главная кнопка одна и названа действием — раньше страница показывала
 * «Установить / Запустить / Остановить» рядом и требовала знать, в каком
 * состоянии находится каждый способ, чтобы выбрать нужную.
 */
function DefenseCard({
  title,
  subtitle,
  active,
  activeLabel,
  installed,
  running,
  onActivate,
  activateLabel,
  note,
  extra,
}: DefenseCardProps) {
  return (
    <Card className={active ? 'border-success/40' : undefined}>
      <CardHeader>
        <div className="flex items-start justify-between gap-4 flex-wrap">
          <CardTitle>{title}</CardTitle>
          {active ? (
            <span className="text-xs px-2 py-1 rounded bg-success/15 text-success shrink-0">
              {activeLabel}
            </span>
          ) : (
            <span className="text-xs px-2 py-1 rounded bg-surface-hover text-text-secondary shrink-0">
              {installed ? 'Не активен' : 'Не установлен'}
            </span>
          )}
        </div>
      </CardHeader>
      <CardContent className="space-y-3">
        <p className="text-sm text-text-secondary">{subtitle}</p>
        {note && !active && <p className="text-xs text-warning">{note}</p>}
        <div className="flex flex-wrap gap-2">
          <Button disabled={running || active} onClick={onActivate}>
            {active ? 'Уже активен' : activateLabel}
          </Button>
          {extra}
        </div>
      </CardContent>
    </Card>
  );
}

interface ParamRowsProps {
  params: NftParam[] | undefined;
  edits: Record<string, string>;
  setEdits: React.Dispatch<React.SetStateAction<Record<string, string>>>;
}

function ParamRows({ params, edits, setEdits }: ParamRowsProps) {
  if (!params || params.length === 0) return null;
  return (
    <div className="space-y-3">
      {params.map((p) => (
        <div key={p.key} className="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-4">
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
  );
}

function ParamSection({ title, params, edits, setEdits }: ParamRowsProps & { title: string }) {
  if (!params || params.length === 0) return null;
  return (
    <CollapsibleSection title={title} defaultOpen={false}>
      <ParamRows params={params} edits={edits} setEdits={setEdits} />
    </CollapsibleSection>
  );
}
