import { useCallback, useEffect, useState } from 'react';
import { X, Download, Upload, Shield } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import { mtproxylNetApi, type IpBlockStatus, type IpBlockHit } from '@/lib/api';

/** Адрес или подсеть: IPv4 с маской 0-32, IPv6 с маской 0-128. */
export function validateEntry(raw: string): string | null {
  const e = raw.trim();
  if (!e) return 'Введите адрес или подсеть';
  if (e.length > 64) return 'Слишком длинная запись';
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\/(\d{1,2}))?$/.exec(e);
  if (v4) {
    for (let i = 1; i <= 4; i++) {
      if (Number(v4[i]) > 255) return 'Октет больше 255';
    }
    if (v4[5] !== undefined && Number(v4[5]) > 32) return 'Маска IPv4 не больше 32';
    return null;
  }
  if (e.includes(':') && /^[0-9a-fA-F:]+(?:\/\d{1,3})?$/.test(e) && !e.includes(':::')) {
    const slash = e.indexOf('/');
    if (slash >= 0 && Number(e.slice(slash + 1)) > 128) return 'Маска IPv6 не больше 128';
    return null;
  }
  return 'Не похоже на адрес или подсеть';
}

function human(n: number): string {
  if (n < 1024) return `${n} Б`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} КБ`;
  return `${(n / 1024 / 1024).toFixed(1)} МБ`;
}

export function IpBlockPage() {
  const [status, setStatus] = useState<IpBlockStatus | null>(null);
  const [hits, setHits] = useState<IpBlockHit[]>([]);
  const [entry, setEntry] = useState('');
  const [comment, setComment] = useState('');
  const [importText, setImportText] = useState('');
  const [showImport, setShowImport] = useState(false);
  const [busy, setBusy] = useState(false);
  const [removing, setRemoving] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const st = await mtproxylNetApi.ipblock();
      setStatus(st);
      try {
        const h = await mtproxylNetApi.ipblockHits();
        setHits(h.hits ?? []);
      } catch {
        setHits([]);
      }
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить состояние');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const wrap = async (fn: () => Promise<unknown>, fallback: string) => {
    setBusy(true);
    try {
      await fn();
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : fallback);
    } finally {
      setBusy(false);
    }
  };

  const add = async () => {
    const problem = validateEntry(entry);
    if (problem) {
      setError(problem);
      return;
    }
    if (comment.includes('#')) {
      setError('Комментарий не должен содержать #');
      return;
    }
    await wrap(async () => {
      await mtproxylNetApi.ipblockAdd(entry.trim(), comment.trim());
      setEntry('');
      setComment('');
    }, 'Не удалось добавить');
  };

  const remove = async (e: string) => {
    setRemoving(e);
    await wrap(() => mtproxylNetApi.ipblockRemove(e), 'Не удалось удалить');
    setRemoving(null);
  };

  const doImport = async (mode: 'replace' | 'append') => {
    if (!importText.trim()) {
      setError('Пустой список');
      return;
    }
    await wrap(async () => {
      await mtproxylNetApi.ipblockImport(importText, mode);
      setImportText('');
      setShowImport(false);
    }, 'Не удалось загрузить список');
  };

  const hitFor = (e: string) => hits.find((h) => h.entry === e || h.entry === e.replace(/\/32$/, ''));

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Блокировка IP адресов</h1>
        <p className="text-sm text-text-secondary mt-1">
          Адреса и подсети из списка не доходят до сервера — правила живут в nftables.
          Список хранится файлом, его можно выгрузить и перенести на другой сервер.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={load} />}

      <Card>
        <CardHeader>
          <CardTitle>Состояние</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex flex-wrap items-center gap-3">
            <Button
              onClick={() => void wrap(() => mtproxylNetApi.ipblockState({ enabled: !status?.enabled }), 'Не удалось переключить')}
              disabled={busy || loading}
              variant={status?.enabled ? 'outline' : 'default'}
            >
              <Shield size={16} className="mr-2" />
              {status?.enabled ? 'Выключить' : 'Включить'}
            </Button>

            <div className="flex items-center gap-2">
              <span className="text-sm text-text-secondary">Действие:</span>
              {(['drop', 'reject'] as const).map((a) => (
                <Button
                  key={a}
                  size="sm"
                  variant={status?.action === a ? 'default' : 'outline'}
                  disabled={busy || loading}
                  onClick={() => void wrap(() => mtproxylNetApi.ipblockState({ action: a }), 'Не удалось изменить действие')}
                >
                  {a}
                </Button>
              ))}
            </div>

            <span className="text-sm text-text-secondary">
              В списке: <span className="text-text-primary">{status?.count ?? 0}</span>
            </span>
            <span className="text-sm text-text-secondary">
              Отбито пакетов: <span className="text-text-primary">{status?.hits_total ?? 0}</span>
            </span>
            {status && !status.rules_active && status.enabled && (
              <span className="text-sm text-warning">правила не применены</span>
            )}
          </div>
          <p className="text-xs text-text-secondary mt-3">
            drop — молча отбрасывать пакеты. reject — отвечать отказом ICMP.
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Добавить адрес или подсеть</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="flex flex-wrap items-end gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              void add();
            }}
          >
            <div>
              <label className="block text-xs text-text-secondary mb-1">Адрес</label>
              <Input
                value={entry}
                onChange={(e) => setEntry(e.target.value)}
                placeholder="203.0.113.0/24"
                className="max-w-[220px]"
              />
            </div>
            <div className="flex-1 min-w-[200px]">
              <label className="block text-xs text-text-secondary mb-1">Комментарий</label>
              <Input
                value={comment}
                onChange={(e) => setComment(e.target.value)}
                placeholder="необязательно"
              />
            </div>
            <Button type="submit" disabled={busy}>
              Заблокировать
            </Button>
          </form>
          <p className="text-xs text-text-secondary mt-2">
            Примеры: 203.0.113.7, 203.0.113.0/24, 2001:db8::/32
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Список</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex flex-wrap gap-2 mb-4">
            <a href={mtproxylNetApi.ipblockExportUrl()} download>
              <Button variant="outline" size="sm">
                <Download size={14} className="mr-2" />
                Выгрузить файл
              </Button>
            </a>
            <Button variant="outline" size="sm" onClick={() => setShowImport((v) => !v)}>
              <Upload size={14} className="mr-2" />
              Загрузить список
            </Button>
          </div>

          {showImport && (
            <div className="mb-4 space-y-2">
              <textarea
                value={importText}
                onChange={(e) => setImportText(e.target.value)}
                rows={8}
                spellCheck={false}
                placeholder={'#сканеры\n1.1.1.1/32\n2.2.2.0/24\n#клиент\n3.3.3.3'}
                className="w-full font-mono text-sm bg-surface border border-border rounded-md p-2 text-text-primary"
              />
              <div className="flex gap-2">
                <Button size="sm" disabled={busy} onClick={() => void doImport('replace')}>
                  Заменить список
                </Button>
                <Button size="sm" variant="outline" disabled={busy} onClick={() => void doImport('append')}>
                  Добавить к текущему
                </Button>
              </div>
              <p className="text-xs text-text-secondary">
                Строки с # — комментарии, они сохраняются. Некорректные записи пропускаются.
              </p>
            </div>
          )}

          {loading && !status ? (
            <div className="text-sm text-text-secondary">Загрузка…</div>
          ) : !status || status.entries.length === 0 ? (
            <div className="text-sm text-text-secondary">Список пуст</div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-text-secondary border-b border-border">
                    <th className="py-2 pr-4 font-normal">Адрес</th>
                    <th className="py-2 pr-4 font-normal text-right">Пакетов</th>
                    <th className="py-2 pr-4 font-normal text-right">Трафик</th>
                    <th className="py-2 pr-4 font-normal">Последнее срабатывание</th>
                    <th className="py-2 w-8" />
                  </tr>
                </thead>
                <tbody>
                  {status.entries.map((e) => {
                    const h = hitFor(e);
                    return (
                      <tr key={e} className="border-b border-border/50">
                        <td className="py-2 pr-4 font-mono text-text-primary">{e}</td>
                        <td className="py-2 pr-4 text-right text-text-primary">{h?.packets ?? 0}</td>
                        <td className="py-2 pr-4 text-right text-text-secondary">
                          {human(h?.bytes ?? 0)}
                        </td>
                        <td className="py-2 pr-4 text-text-secondary">
                          {h && h.last !== '-' ? h.last.replace('T', ' ').replace('Z', '') : '—'}
                        </td>
                        <td className="py-2">
                          <button
                            onClick={() => void remove(e)}
                            disabled={removing === e || busy}
                            title="Разблокировать"
                            className="p-1 rounded-full hover:bg-danger/15 hover:text-danger disabled:opacity-40"
                          >
                            <X size={14} />
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
