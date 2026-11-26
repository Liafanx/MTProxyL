import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { usePolling } from '@/hooks/usePolling';
import { vlessApi, type VlessLink, type VlessTest } from '@/lib/api';

const typeLabel = (l: VlessLink) =>
  `${l.security || '?'}/${l.transport || '?'}${l.encryption && l.encryption !== 'none' ? ' +enc' : ''}`;

/**
 * VLESS: локальный Xray поднимает SOCKS5, и весь трафик движка идёт через
 * выбранную ссылку (или подписку). Middle proxy с VLESS не работает: socks5
 * не сохраняет адрес и порт, поэтому ME выключается с согласия администратора.
 */
export function VlessPage() {
  const { data, error, loading, refresh } = usePolling(() => vlessApi.status(), 10000);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState('');
  const [notice, setNotice] = useState('');
  const [uri, setUri] = useState('');
  const [name, setName] = useState('');
  const [subURL, setSubURL] = useState('');
  const [removeIDs, setRemoveIDs] = useState<string[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [confirmSubOff, setConfirmSubOff] = useState(false);
  const [test, setTest] = useState<VlessTest | null>(null);
  const [conflict, setConflict] = useState('');
  const [allowME, setAllowME] = useState(false);
  const [ua, setUA] = useState('');

  // Сетевой сбой мог оборвать ответ, хотя действие уже применилось: как только
  // статус снова получен, старый «Failed to fetch» больше не актуален.
  useEffect(() => {
    if (!data) return;
    setActionError((prev) => (/^(Failed to fetch|NetworkError|Load failed)/i.test(prev) ? '' : prev));
  }, [data]);

  const run = useCallback(async (fn: () => Promise<{ output?: string } | void>, ok = '') => {
    setBusy(true);
    setActionError('');
    setNotice('');
    setConflict('');
    try {
      const res = await fn();
      if (ok || (res && 'output' in res && res.output)) setNotice(ok || String(res && 'output' in res ? res.output : ''));
      refresh();
      return true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setActionError(msg);
      if (/другой выход|Уже включён/i.test(msg)) setConflict(msg);
      return false;
    } finally {
      setBusy(false);
    }
  }, [refresh]);

  const doTest = async () => {
    setBusy(true);
    setActionError('');
    try {
      setTest(await vlessApi.test());
    } catch (e) {
      setActionError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const addLink = async () => {
    if (!uri.trim()) return;
    if (await run(() => vlessApi.addLink(uri.trim(), name.trim()), 'Ссылка добавлена')) {
      setUri('');
      setName('');
    }
  };

  const active = data?.active ?? null;
  const links = data?.links ?? [];
  const selectedLinks = links.filter((l) => selected.includes(l.id));
  const allSelected = links.length > 0 && selectedLinks.length === links.length;
  const removeLinks = links.filter((l) => removeIDs.includes(l.id));

  const toggleSelected = (id: string) => {
    setSelected((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  };

  const toggleAll = () => {
    setSelected(allSelected ? [] : links.map((l) => l.id));
  };

  const deleteLinks = async (ids: string[]) => {
    // Активную ссылку удаляем последней: иначе каждая следующая смена
    // перезапускает Xray, а он нужен для ответа панели.
    const ordered = [
      ...ids.filter((id) => !links.find((l) => l.id === id)?.active),
      ...ids.filter((id) => links.find((l) => l.id === id)?.active),
    ];
    const ok = await run(async () => {
      for (const id of ordered) await vlessApi.removeLink(id);
    }, ids.length === 1 ? 'Ссылка удалена' : `Удалено ссылок: ${ids.length}`);
    if (ok) {
      setRemoveIDs([]);
      setSelected((prev) => prev.filter((id) => !ids.includes(id)));
    }
  };

  // Результат проверки относится к конкретной активной ссылке: после смены
  // локации старый IP вводит в заблуждение, пока не нажата «Проверить».
  useEffect(() => {
    setTest(null);
  }, [active?.id, data?.enabled]);

  const meLabel = data?.me_state === 'direct'
    ? 'mtdd: весь DC-трафик через Direct (рекламный тег не действует)'
    : data?.me_state === 'disabled'
      ? 'выключен'
      : 'включён';

  const subUAChanged = !!data && ua.trim() !== (data.sub_ua || '');

  return (
    <div className="p-4 lg:p-6 space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Telegram через VLESS</h1>
        <p className="text-sm text-text-secondary mt-1">
          Локальный Xray принимает SOCKS5 от движка и отправляет трафик на ваш сервер
          VLESS (Reality, TLS, VLESS Encryption, XHTTP). Хост и другие службы не затрагиваются,
          Middle proxy с таким выходом не работает: MTProxyL выключит его с вашего согласия.
        </p>
      </div>

      {(error || actionError) && (
        <ErrorAlert message={actionError || error?.message || ''} onRetry={refresh} />
      )}
      {conflict && (
        <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm space-y-2">
          <div>Включён другой выход (WARP, донор или свой AWG). Одновременно работает только один.</div>
          <Button
            variant="outline"
            disabled={busy}
            onClick={() => void run(() => vlessApi.on(true, allowME), 'Прежний выход выключен, VLESS включён')}
          >
            Выключить другие и включить VLESS
          </Button>
        </div>
      )}
      {notice && <div className="rounded-lg border border-success/40 bg-success/10 p-3 text-sm">{notice}</div>}
      {loading && !data && <div className="text-sm text-text-secondary">Загрузка…</div>}

      {data && (
        <>
          <Card>
            <CardHeader><CardTitle>Маршрут</CardTitle></CardHeader>
            <CardContent className="space-y-3">
              <div className="text-sm space-y-1">
                <div>
                  Состояние:{' '}
                  <b className={data.enabled ? 'text-success' : 'text-text-secondary'}>
                    {data.enabled ? 'включён' : 'выключен'}
                  </b>
                  {' '}· служба: {data.service} · Xray: {data.core_version}
                </div>
                <div>Локальный SOCKS5: <span className="font-mono">127.0.0.1:{data.socks_port}</span></div>
                <div>
                  Активная ссылка: {active
                    ? <><b>{active.name || active.id}</b> — <span className="font-mono">{active.host}:{active.port}</span> ({typeLabel(active)})</>
                    : 'не выбрана'}
                </div>
                <div>
                  Middle proxy: <b className={data.me_state === 'enabled' ? 'text-success' : 'text-warning'}>{meLabel}</b>
                </div>
              </div>
              {!data.enabled && (
                <label className="flex items-center gap-2 text-sm text-text-secondary cursor-pointer">
                  <input
                    type="checkbox"
                    checked={allowME}
                    onChange={(e) => setAllowME(e.target.checked)}
                    className="accent-[var(--color-accent,#3b82f6)]"
                  />
                  Выключить middle proxy (иначе VLESS не поднимется; рекламный тег перестанет действовать)
                </label>
              )}
              <div className="flex flex-wrap gap-2">
                <Button disabled={busy || data.enabled || !data.links.length} onClick={() => void run(() => vlessApi.on(false, allowME), 'VLESS включён')}>
                  Включить
                </Button>
                <Button variant="outline" disabled={busy || !data.enabled} onClick={() => void run(() => vlessApi.off(), 'VLESS выключен')}>
                  Выключить
                </Button>
                <Button variant="outline" disabled={busy || !data.enabled} onClick={() => void run(() => vlessApi.recover(), 'Маршрут переприменён')}>
                  Перезапустить
                </Button>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Проверка выхода</CardTitle></CardHeader>
            <CardContent className="space-y-3">
              <Button variant="outline" disabled={busy || !data.enabled} onClick={() => void doTest()}>
                Проверить
              </Button>
              <p className="text-xs text-text-secondary">
                Проверка идёт через активную ссылку. После смены локации нажмите «Проверить»:
                выходной IP зависит от сервера и у разных локаций может совпадать.
              </p>
              {test && (
                <div className="text-sm space-y-1">
                  <div>{test.ok ? 'Туннель работает' : 'Проверка не прошла'}</div>
                  <div>Выходной IP: <span className="font-mono">{test.exit_ip || 'не определён'}</span></div>
                  <div>api.telegram.org: {test.telegram} · TCP до DC: {test.dc}</div>
                </div>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>HWID и клиент подписки</CardTitle></CardHeader>
            <CardContent className="space-y-3">
              <p className="text-sm text-text-secondary">
                Провайдеры Happ и INCY считают устройства по заголовку <span className="font-mono">x-hwid</span>
                {' '}и могут отдавать ссылки только знакомому клиенту. Идентификатор стабилен для этой установки.
              </p>
              {data.sub_notice && (
                <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm break-words">
                  Подписка вернула подсказку вместо ссылки: {data.sub_notice}
                </div>
              )}
              <div className="flex flex-wrap items-center gap-3 text-sm">
                <span className="text-text-secondary">HWID:</span>
                <span className="font-mono break-all min-w-0 flex-1 sm:flex-none">{data.hwid || 'не создан'}</span>
                <label className="flex items-center gap-2 text-text-secondary cursor-pointer">
                  <input
                    type="checkbox"
                    checked={data.hwid_enabled}
                    disabled={busy}
                    onChange={(e) => void run(() => vlessApi.hwid(e.target.checked ? 'on' : 'off'), e.target.checked ? 'HWID отправляется' : 'HWID не отправляется')}
                    className="accent-[var(--color-accent,#3b82f6)]"
                  />
                  Передавать в подписке
                </label>
                <Button
                  variant="outline"
                  size="sm"
                  disabled={busy}
                  onClick={() => void run(() => vlessApi.hwid('regen'), 'HWID обновлён')}
                >
                  Новый HWID
                </Button>
              </div>
              <div className="flex flex-wrap items-end gap-2">
                <div className="flex-1 min-w-[260px]">
                  <Label htmlFor="vless-ua" className="text-xs">User-Agent подписки</Label>
                  <Input
                    id="vless-ua"
                    value={ua || data.sub_ua}
                    onChange={(e) => setUA(e.target.value)}
                    placeholder="Happ/3.23.0"
                    className="font-mono"
                  />
                </div>
                <Button
                  variant="outline"
                  disabled={busy || !subUAChanged}
                  onClick={() => void run(() => vlessApi.subUA(ua), 'User-Agent сохранён')}
                >
                  Сохранить
                </Button>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Ссылки</CardTitle></CardHeader>
            <CardContent className="space-y-3">
              {data.links.length === 0 && <p className="text-sm text-text-secondary">Ссылок нет.</p>}
              {data.links.length > 0 && (
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm text-text-secondary">Выбрано: {selectedLinks.length}</span>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy || selectedLinks.length === 0}
                    onClick={() => setRemoveIDs(selectedLinks.map((l) => l.id))}
                  >
                    Удалить выбранные
                  </Button>
                  {selectedLinks.length > 0 && (
                    <Button size="sm" variant="ghost" disabled={busy} onClick={() => setSelected([])}>
                      Снять выбор
                    </Button>
                  )}
                </div>
              )}
              {data.links.length > 0 && (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="text-left text-text-secondary">
                        <th className="pb-2 pr-4 font-normal">
                          <input
                            type="checkbox"
                            aria-label="Выбрать все ссылки"
                            checked={allSelected}
                            onChange={toggleAll}
                            className="accent-[var(--color-accent,#3b82f6)]"
                          />
                        </th>
                        <th className="pb-2 pr-4 font-normal">ID</th>
                        <th className="pb-2 pr-4 font-normal">Имя</th>
                        <th className="pb-2 pr-4 font-normal">Тип</th>
                        <th className="pb-2 pr-4 font-normal">Адрес</th>
                        <th className="pb-2 font-normal">Действия</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.links.map((l) => (
                        <tr key={l.id} className="border-t border-border">
                          <td className="py-2 pr-4">
                            <input
                              type="checkbox"
                              aria-label={`Выбрать ${l.name || l.id}`}
                              checked={selected.includes(l.id)}
                              onChange={() => toggleSelected(l.id)}
                              className="accent-[var(--color-accent,#3b82f6)]"
                            />
                          </td>
                          <td className="py-2 pr-4 font-mono">{l.id}</td>
                          <td className="py-2 pr-4">{l.name || '—'}{l.active && <span className="text-success"> · активная</span>}</td>
                          <td className="py-2 pr-4">{typeLabel(l)}</td>
                          <td className="py-2 pr-4 font-mono">{l.host}:{l.port}</td>
                          <td className="py-2">
                            <div className="flex flex-wrap gap-2">
                              <Button size="sm" variant="outline" disabled={busy || l.active} onClick={() => void run(() => vlessApi.useLink(l.id), 'Активная ссылка изменена')}>
                                Использовать
                              </Button>
                              <Button size="sm" variant="ghost" disabled={busy} onClick={() => setRemoveIDs([l.id])}>
                                Удалить
                              </Button>
                            </div>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              <div className="grid gap-2 sm:grid-cols-[1fr_220px_auto]">
                <div className="space-y-1">
                  <Label htmlFor="vless-uri">Ссылка vless://</Label>
                  <Input id="vless-uri" value={uri} onChange={(e) => setUri(e.target.value)} placeholder="vless://…" className="font-mono" />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="vless-name">Имя</Label>
                  <Input id="vless-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="необязательно" maxLength={64} />
                </div>
                <div className="flex items-end">
                  <Button disabled={busy || !uri.trim()} onClick={() => void addLink()}>Добавить</Button>
                </div>
              </div>
              <p className="text-xs text-text-secondary">
                Ссылка содержит секрет и показывается только при вставке. В списке видны адрес и тип.
              </p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Подписка</CardTitle></CardHeader>
            <CardContent className="space-y-3">
              <div className="grid gap-2 sm:grid-cols-[1fr_auto_auto]">
                <Input value={subURL} onChange={(e) => setSubURL(e.target.value)} placeholder="https://… (base64 или список ссылок)" />
                <Button disabled={busy || !subURL.trim()} onClick={() => void run(() => vlessApi.subSet(subURL.trim()), 'Подписка обновлена')}>
                  Задать и обновить
                </Button>
                <Button variant="outline" disabled={busy || !data.subscription} onClick={() => void run(() => vlessApi.subRefresh(), 'Подписка обновлена')}>
                  Обновить
                </Button>
              </div>
              <div className="flex items-center gap-3 text-sm text-text-secondary">
                <span>Подписка: {data.subscription ? 'задана' : 'не задана'}</span>
                {data.subscription && (
                  <Button size="sm" variant="ghost" disabled={busy} onClick={() => setConfirmSubOff(true)}>
                    Отключить и удалить ссылки
                  </Button>
                )}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Ядро Xray</CardTitle></CardHeader>
            <CardContent className="space-y-3">
              <div className="text-sm">Установлено: <span className="font-mono">{data.core_version}</span></div>
              <div className="flex flex-wrap gap-2">
                <Button variant="outline" disabled={busy} onClick={() => void run(() => vlessApi.update(), 'Xray обновлён')}>Обновить</Button>
                <Button variant="ghost" disabled={busy} onClick={() => void run(() => vlessApi.rollback(), 'Выполнен откат Xray')}>Откатить</Button>
              </div>
            </CardContent>
          </Card>
        </>
      )}

      <ConfirmDialog
        open={removeIDs.length > 0}
        onClose={() => setRemoveIDs([])}
        onConfirm={() => void deleteLinks(removeIDs)}
        title={removeIDs.length === 1 ? 'Удалить ссылку' : 'Удалить выбранные ссылки'}
        message={removeIDs.length === 1
          ? (removeLinks[0] ? `Удалить ${removeLinks[0].id} (${removeLinks[0].host}:${removeLinks[0].port})?` : '')
          : `Удалить выбранные ссылки (${removeIDs.length})? Если среди них активная, будет выбрана первая оставшаяся или VLESS выключится.`}
        loading={busy}
      />
      <ConfirmDialog
        open={confirmSubOff}
        onClose={() => setConfirmSubOff(false)}
        onConfirm={() => {
          void run(() => vlessApi.subOff(), 'Подписка отключена, ссылки подписки удалены').then((ok) => {
            setConfirmSubOff(false);
            if (ok) setSelected([]);
          });
        }}
        title="Отключить подписку"
        message="Удалить подписку и все ссылки, полученные из неё? Ручные ссылки останутся. Если активная ссылка была из подписки, будет выбрана первая оставшаяся или VLESS выключится."
        confirmLabel="Отключить и удалить"
        loading={busy}
      />
    </div>
  );
}
