import { useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import { mtproxylAddonsApi } from '@/lib/api';

export function AddonsPage() {
  const [domain, setDomain] = useState('');
  const [output, setOutput] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const check = async () => {
    setChecking(true);
    setOutput(null);
    try {
      const res = await mtproxylAddonsApi.pqCheck(domain.trim());
      setOutput(res.output || 'Проверка завершена без вывода');
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Проверка не удалась');
    } finally {
      setChecking(false);
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Дополнения</h1>
        <p className="text-sm text-text-secondary mt-1">
          Вспомогательные проверки MTProxyL.
        </p>
      </div>

      {error && <ErrorAlert message={error} />}

      <Card>
        <CardHeader>
          <CardTitle>Проверка домена на постквантовый обмен ключами</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <p className="text-sm text-text-secondary">
            Если для FakeTLS используется чужой домен без поддержки PQ (X25519MLKEM768),
            клиенты на iOS могут бесконечно висеть на «Соединение…». Заглушка Selfmask
            поднимается своим nginx с гарантированной поддержкой, и её проверять не нужно.
          </p>
          <form
            className="flex flex-wrap items-center gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              void check();
            }}
          >
            <Input
              value={domain}
              onChange={(e) => setDomain(e.target.value)}
              placeholder="Пусто — текущий SNI-домен"
              className="max-w-[320px]"
            />
            <Button type="submit" disabled={checking}>
              {checking ? 'Проверка…' : 'Проверить'}
            </Button>
          </form>
          <p className="text-xs text-text-secondary">
            Можно указать порт: <span className="font-mono">example.com:8443</span>. Проверка
            требует установленного PQ OpenSSL — он ставится вместе с Selfmask.
          </p>
          {output && (
            <pre className="text-xs text-text-secondary bg-background border border-border rounded-md p-3 whitespace-pre-wrap break-words font-mono max-h-80 overflow-y-auto">
              {output}
            </pre>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
