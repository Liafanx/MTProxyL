import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { mtproxylApi, type MtddSuspect, type MtddSuspectsAction, type MtddSuspectsStatus } from '@/lib/api';

/** Буквы признаков — как в `mtproxyl suspects` и `mtdd-ctl suspects`. */
const SIGNALS: Record<string, [string, string]> = {
  probe_session: ['A', 'сессия-зонд'],
  secret_text: ['B', 'секрет текстом'],
  raw_obfuscated2: ['C', 'obfuscated2 без FakeTLS'],
  multi_mode: ['D', 'FakeTLS и obfuscated2'],
  wrong_secret: ['E', 'наш домен, неверный секрет'],
  port_check: ['F', 'connect без данных'],
  repeat_visits: ['G', 'повторные короткие визиты'],
  junk: ['H', 'мусор, чужой SNI, replay'],
  canary: ['K', 'ловушка (canary)'],
};

const SYN_OS: Record<string, string> = { linux: 'Linux', windows: 'Windows', apple: 'Apple' };

function marks(sig: MtddSuspect['signals']): { text: string; title: string } {
  const entries = Object.entries(sig ?? {}).sort(([a], [b]) => (SIGNALS[a]?.[0] ?? 'Z').localeCompare(SIGNALS[b]?.[0] ?? 'Z'));
  return {
    text: entries.map(([n, c]) => (SIGNALS[n]?.[0] ?? '?') + (c === 1 ? '' : String(Math.min(c, 99)))).join(''),
    title: entries.map(([n, c]) => `${SIGNALS[n]?.[1] ?? n}: ${c}`).join('\n'),
  };
}

function ago(iso: string): string {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return iso || '—';
  const sec = Math.max(0, Math.round((Date.now() - t) / 1000));
  for (const [div, unit] of [[86400, 'д'], [3600, 'ч'], [60, 'мин']] as const) {
    if (sec >= div) return `${Math.floor(sec / div)} ${unit}`;
  }
  return `${sec} с`;
}

/**
 * Подозрительные адреса mtdd: таблица детектора, учёт, теневой бан и жёсткий
 * блок. Блок — записи в общей «Блокировке IP» MTProxyL с пометкой: один список,
 * все порты, переживает перезагрузку; «Снять» убирает только эти записи.
 */
export function MtddSuspectsPage() {
  const [data, setData] = useState<MtddSuspectsStatus | null>(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const [blockScore, setBlockScore] = useState('60');
  const [banScore, setBanScore] = useState('');
  const [confirmBlock, setConfirmBlock] = useState(false);

  const load = useCallback(async () => {
    try {
      const d = await mtproxylApi.getMtddSuspects();
      setData(d);
      setBanScore(String(d.ban_score ?? 0));
      setError('');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);

  const run = async (a: MtddSuspectsAction, done: string) => {
    setBusy(true);
    setNotice('');
    try {
      const res = await mtproxylApi.mtddSuspects(a);
      setNotice(res.output?.trim() || done);
      setError('');
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const scoreOk = (v: string, min: number) => /^\d+$/.test(v) && Number(v) >= min && Number(v) <= 100;
  const toBlock = data ? data.suspects.filter((s) => s.score >= Number(blockScore)).length : 0;

  return (
    <div className="p-4 lg:p-6 space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Подозрительные адреса (mtdd)</h1>
        <p className="text-sm text-text-secondary mt-1">
          Детектор mtdd копит адреса с признаками сканера или зонда и считает им score. Мягкая мера —
          теневой бан: такие соединения mtdd отдаёт маскировке. Жёсткая — добавить адреса в «Блокировку IP»:
          блок на все порты, переживает перезагрузку, снимается здесь же.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={() => void load()} />}
      {notice && (
        <div className="bg-accent/10 border border-accent/30 rounded-lg p-3 text-sm text-text-primary whitespace-pre-line">
          {notice}
        </div>
      )}

      {data && (
        <Card>
          <CardHeader>
            <CardTitle>Учёт и меры</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="flex flex-wrap items-center gap-3">
              <span className="text-sm text-text-primary">
                Учёт: <b>{data.enabled ? 'включён' : 'выключен'}</b>
                {data.enabled && !data.fingerprint && (
                  <span className="text-text-secondary"> · отпечаток SYN/TLS выключен (ключ fingerprint в «Экспертных параметрах»)</span>
                )}
              </span>
              <Button
                variant="outline"
                size="sm"
                disabled={busy}
                onClick={() => void run({ action: data.enabled ? 'off' : 'on' }, data.enabled ? 'Учёт выключен' : 'Учёт включён')}
              >
                {data.enabled ? 'Выключить' : 'Включить'}
              </Button>
              <span className="text-xs text-text-secondary">Применяется перезапуском mtdd.</span>
            </div>

            <div className="flex flex-wrap items-end gap-3">
              <div className="space-y-1.5">
                <Label htmlFor="ban_score">Теневой бан с score</Label>
                <Input id="ban_score" type="number" min={0} max={100} value={banScore} onChange={(e) => setBanScore(e.target.value)} className="w-28" />
              </div>
              <Button
                variant="outline"
                disabled={busy || !scoreOk(banScore, 0) || Number(banScore) === data.ban_score}
                onClick={() => void run({ action: 'ban', score: Number(banScore) }, 'Порог теневого бана сохранён')}
              >
                Сохранить
              </Button>
              <span className="text-xs text-text-secondary pb-2">0 — выключен. Применяется перезапуском mtdd.</span>
            </div>

            <div className="flex flex-wrap items-end gap-3">
              <div className="space-y-1.5">
                <Label htmlFor="block_score">В «Блокировку IP» с score</Label>
                <Input id="block_score" type="number" min={1} max={100} value={blockScore} onChange={(e) => setBlockScore(e.target.value)} className="w-28" />
              </div>
              <Button disabled={busy || !scoreOk(blockScore, 1) || !data.available} onClick={() => setConfirmBlock(true)}>
                Заблокировать
              </Button>
              <Button variant="outline" disabled={busy || data.blocked === 0} onClick={() => void run({ action: 'unblock' }, 'Записи сняты')}>
                Снять ({data.blocked})
              </Button>
            </div>
            <div className="text-xs text-text-secondary space-y-1">
              <p>Уже в «Блокировке IP» от этой страницы: {data.blocked}. Не блокируются адрес вашей SSH-сессии и подсети, в которые он попадает. Адрес, с которого вы зайдёте позже, это не защищает.</p>
              {!data.ipblock_enabled && (
                <p className="text-warning">«Блокировка IP» выключена: адреса попадут в список, но блокироваться не будут, пока её не включить.</p>
              )}
              {data.proxy_protocol && (
                <p className="text-warning">Включён PROXY protocol: клиенты приходят через фронт, блок по адресу источника их не остановит — блокируйте на фронте.</p>
              )}
            </div>
          </CardContent>
        </Card>
      )}

      {data && (
        <Card>
          <CardHeader>
            <CardTitle>Адреса</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {!data.available ? (
              <p className="text-sm text-text-secondary">
                Таблица недоступна{data.error ? `: ${data.error}` : ''}. Нужна сборка mtdd с полным API (1.0.0+).
              </p>
            ) : (
              <>
                <p className="text-sm text-text-secondary">
                  Всего: {data.total} · под наблюдением: {data.watched} · теневой бан: {data.shadow_banned}
                  {Object.keys(data.by_matches).length > 0 && (
                    <> · по совпадениям: {Object.entries(data.by_matches).sort(([a], [b]) => Number(b) - Number(a)).map(([k, v]) => `${k}×${v}`).join(', ')}</>
                  )}
                </p>
                {data.suspects.length === 0 ? (
                  <p className="text-sm text-text-secondary">
                    {data.enabled ? 'Подозрительных адресов нет.' : 'Учёт выключен — включите его выше.'}
                  </p>
                ) : (
                  <div className="overflow-x-auto -mx-4 px-4">
                    <table className="w-full text-sm">
                      <thead>
                        <tr className="text-left text-text-secondary border-b border-border">
                          <th className="py-2 pr-3 font-medium">Score</th>
                          <th className="py-2 pr-3 font-medium">Сов.</th>
                          <th className="py-2 pr-3 font-medium">IP</th>
                          <th className="py-2 pr-3 font-medium">Признаки</th>
                          <th className="py-2 pr-3 font-medium">Хиты</th>
                          <th className="py-2 pr-3 font-medium">Был</th>
                          <th className="py-2 pr-3 font-medium">Платф.</th>
                          <th className="py-2 pr-3 font-medium">ОС (SYN)</th>
                          <th className="py-2 font-medium">Пользователь</th>
                        </tr>
                      </thead>
                      <tbody>
                        {data.suspects.map((s) => {
                          const m = marks(s.signals);
                          return (
                            <tr key={s.ip} className="border-b border-border/50">
                              <td className="py-1.5 pr-3 tabular-nums">{Math.round(s.score)}</td>
                              <td className="py-1.5 pr-3 tabular-nums">{s.matches}</td>
                              <td className="py-1.5 pr-3 font-mono text-xs">
                                {s.ip}
                                {s.shadow_banned && <span className="ml-1 text-danger">бан</span>}
                                {s.watched && <span className="ml-1 text-text-secondary">лог</span>}
                                {s.real_client && <span className="ml-1 text-success">клиент</span>}
                              </td>
                              <td className="py-1.5 pr-3 font-mono text-xs" title={m.title}>{m.text}</td>
                              <td className="py-1.5 pr-3 tabular-nums">{s.hits}</td>
                              <td className="py-1.5 pr-3">{ago(s.last_seen)}</td>
                              <td className="py-1.5 pr-3">{s.platform || '—'}</td>
                              <td className="py-1.5 pr-3">{SYN_OS[s.syn?.layout ?? ''] ?? '—'}</td>
                              <td className="py-1.5">{s.user || '—'}</td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                )}
                <p className="text-xs text-text-secondary">
                  {Object.values(SIGNALS).map(([c, t]) => `${c} — ${t}`).join(' · ')}. Цифра — число повторов.
                  «клиент» — с адреса были и настоящие сессии: такой адрес блокировать осторожно.
                </p>
              </>
            )}
            <Button variant="outline" disabled={busy} onClick={() => void load()}>
              Обновить
            </Button>
          </CardContent>
        </Card>
      )}

      <ConfirmDialog
        open={confirmBlock}
        onClose={() => setConfirmBlock(false)}
        onConfirm={() => {
          setConfirmBlock(false);
          void run({ action: 'block', score: Number(blockScore) }, 'Адреса добавлены');
        }}
        title="Заблокировать адреса?"
        message={`Адреса со score ≥ ${blockScore} (в таблице сейчас ${toBlock}) попадут в «Блокировку IP»: блок на все порты сервера, переживает перезагрузку. Снять — кнопкой «Снять».`}
        confirmLabel="Заблокировать"
        loadingLabel="Блокирую…"
        loading={busy}
      />
    </div>
  );
}
