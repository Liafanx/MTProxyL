import { useCallback, useEffect, useState } from 'react';
import { Download, RotateCcw } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { mtproxylApi, type MtproxylBackup } from '@/lib/api';
import { useManagerOnly, useMtproxylOperation } from '@/hooks/useMtproxyl';
import { formatBytes } from '@/lib/utils';
import { ManagerOnlyNotice } from '@/components/ManagerOnlyNotice';

function formatDate(unixSeconds: number): string {
  if (!unixSeconds) return '—';
  return new Date(unixSeconds * 1000).toLocaleString('ru-RU');
}

export function BackupsPage() {
  const [backups, setBackups] = useState<MtproxylBackup[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);
  const [restoreTarget, setRestoreTarget] = useState<MtproxylBackup | null>(null);

  const { allowed, loading: modeLoading } = useManagerOnly();

  const load = useCallback(async () => {
    // В реаниматоре MTProxyL отклонит команду — не дёргаем её вовсе.
    if (!allowed) {
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      setBackups(await mtproxylApi.backups());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить список бэкапов');
    } finally {
      setLoading(false);
    }
  }, [allowed]);

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['backup:']);

  useEffect(() => {
    void load();
  }, [load]);

  const createBackup = async () => {
    setCreating(true);
    try {
      await mtproxylApi.createBackup();
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось создать бэкап');
    } finally {
      setCreating(false);
    }
  };

  const confirmRestore = async () => {
    if (!restoreTarget) return;
    const name = restoreTarget.name;
    setRestoreTarget(null);
    try {
      start(await mtproxylApi.restoreBackup(name));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить восстановление');
    }
  };

  return (
    <div className="p-4 lg:p-6 space-y-4">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h1 className="text-xl font-semibold text-text-primary">Бэкапы</h1>
          <p className="text-sm text-text-secondary mt-1">
            Настройки MTProxyL: секреты, апстримы, правила NFT и экспертные параметры.
            Конфиг движка в архив не входит — он генерируется заново при восстановлении.
          </p>
        </div>
        {allowed && (
          <Button onClick={createBackup} disabled={creating || running}>
            {creating ? 'Создание…' : 'Создать бэкап'}
          </Button>
        )}
      </div>

      {!modeLoading && !allowed && <ManagerOnlyNotice feature="Бэкапы" />}

      {allowed && (
        <>
      {error && <ErrorAlert message={error} onRetry={load} />}
      <OperationProgress operation={operation} onDismiss={dismiss} />

      <Card>
        <CardHeader>
          <CardTitle>Доступные бэкапы</CardTitle>
        </CardHeader>
        <CardContent>
          {loading && backups.length === 0 ? (
            <div className="text-sm text-text-secondary">Загрузка…</div>
          ) : backups.length === 0 ? (
            <div className="text-sm text-text-secondary">Бэкапов пока нет</div>
          ) : (
            <div className="overflow-x-auto -mx-4 px-4">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-text-secondary border-b border-border">
                    <th className="py-2 pr-4 font-medium">Файл</th>
                    <th className="py-2 pr-4 font-medium whitespace-nowrap">Дата</th>
                    <th className="py-2 pr-4 font-medium whitespace-nowrap">Размер</th>
                    <th className="py-2 font-medium text-right">Действия</th>
                  </tr>
                </thead>
                <tbody>
                  {backups.map((b) => (
                    <tr key={b.name} className="border-b border-border last:border-0">
                      <td className="py-2 pr-4 font-mono text-xs break-all">{b.name}</td>
                      <td className="py-2 pr-4 whitespace-nowrap text-text-secondary">
                        {formatDate(b.mtime)}
                      </td>
                      <td className="py-2 pr-4 whitespace-nowrap text-text-secondary">
                        {formatBytes(b.size)}
                      </td>
                      <td className="py-2">
                        <div className="flex items-center justify-end gap-2">
                          <a
                            href={mtproxylApi.downloadUrl(b.name)}
                            className="inline-flex items-center gap-1.5 px-3 h-8 text-xs rounded-md border border-border text-text-primary hover:bg-surface-hover transition-colors"
                          >
                            <Download size={14} />
                            Скачать
                          </a>
                          <Button
                            size="sm"
                            variant="outline"
                            disabled={running}
                            onClick={() => setRestoreTarget(b)}
                          >
                            <RotateCcw size={14} className="mr-1.5" />
                            Восстановить
                          </Button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
        </>
      )}

      <Dialog open={restoreTarget !== null} onClose={() => setRestoreTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Восстановление из бэкапа</DialogTitle>
          </DialogHeader>
          <div className="py-4 space-y-3 text-sm text-text-secondary">
            <p>
              Текущая конфигурация будет перезаписана содержимым архива{' '}
              <span className="font-mono text-text-primary break-all">{restoreTarget?.name}</span>.
            </p>
            <p>
              Перед восстановлением MTProxyL автоматически сохранит текущее состояние отдельным
              бэкапом, поэтому откат останется возможен.
            </p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setRestoreTarget(null)}>
              Отмена
            </Button>
            <Button variant="danger" onClick={confirmRestore}>
              Восстановить
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
