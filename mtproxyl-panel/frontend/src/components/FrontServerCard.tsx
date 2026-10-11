import { useCallback, useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { mtproxylFrontApi, type FrontServer, type FrontStatus, type MtproxylOperation } from '@/lib/api';

const CHOICES: { id: FrontServer; title: string; hint: string }[] = [
  { id: 'nginx', title: 'nginx', hint: 'OpenSSL 3.5.7, вариант по умолчанию' },
  { id: 'caddy', title: 'Caddy', hint: 'с модулем layer4 для общего :443' },
  { id: 'haproxy', title: 'HAProxy', hint: 'OpenSSL 3.5.7, сайт отдаёт mtproxyl-static' },
];

/**
 * Держатель заглушки: сайт Selfmask, публичный TLS WEB Proxy и порт 80 для
 * сертификата. Все трое с постквантовым X25519MLKEM768; перенос ставит
 * сборку, если её нет, и переписывает конфиг с теми же портами.
 */
export function FrontServerCard({ running, onStart, onError, refreshKey }: {
  running: boolean;
  onStart: (op: MtproxylOperation) => void;
  onError: (msg: string) => void;
  /** Меняется после завершения операции — карточка перечитывает состояние. */
  refreshKey?: unknown;
}) {
  const [status, setStatus] = useState<FrontStatus | null>(null);
  const [supported, setSupported] = useState(true);
  const [pending, setPending] = useState<FrontServer | null>(null);

  const load = useCallback(() => {
    mtproxylFrontApi.get()
      .then((r) => {
        setSupported(r.supported);
        setStatus(r.status ?? null);
      })
      .catch(() => setSupported(false));
  }, []);

  useEffect(() => { load(); }, [load, refreshKey]);

  if (!supported || !status) return null;

  const confirm = async () => {
    const target = pending;
    setPending(null);
    if (!target) return;
    try {
      onStart(await mtproxylFrontApi.set(target));
    } catch (e) {
      onError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Держатель заглушки</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        <p className="text-text-secondary">
          Сейчас: <span className="font-medium text-text-primary">{status.title}</span>
          {' — '}{status.source}
          {status.active ? '' : ' (служба не запущена)'}
        </p>
        <div className="flex flex-wrap gap-2">
          {CHOICES.map((c) => (
            <Button
              key={c.id}
              variant={status.server === c.id ? 'default' : 'outline'}
              disabled={running || status.server === c.id}
              onClick={() => setPending(c.id)}
              title={c.hint}
            >
              {c.title}
            </Button>
          ))}
        </div>
        <p className="text-xs text-text-secondary">
          Держит сайт Selfmask, публичный TLS WEB Proxy и порт 80 для сертификата. Раскладка
          портов, заголовки и страница 404 одинаковые у всех трёх.
          {status.custom && ' Свой конфиг к другому держателю не подходит — после переноса включится сгенерированный.'}
        </p>
      </CardContent>
      <ConfirmDialog
        open={pending !== null}
        title="Перенести заглушку?"
        message={`Заглушку и TLS будет держать ${CHOICES.find((c) => c.id === pending)?.title ?? ''}. Сайт и WEB на несколько секунд станут недоступны.`}
        confirmLabel="Перенести"
        loadingLabel="Перенос…"
        confirmVariant="default"
        onConfirm={() => void confirm()}
        onClose={() => setPending(null)}
      />
    </Card>
  );
}
