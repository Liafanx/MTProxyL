import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { mtproxylAddonsApi, mtproxylApi, type GeoIPStatus, type SelfmaskStatus } from '@/lib/api';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';

export function AddonsPage() {
  const [domain, setDomain] = useState('');
  const [output, setOutput] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Чем проверять домен: системным OpenSSL 3.5.0+, нашей сборкой, или нечем —
  // тогда предлагаем поставить её прямо отсюда, а не отправляем в CLI.
  const [pq, setPq] = useState<Pick<SelfmaskStatus, 'pq_source' | 'pq_available' | 'pq_system'> | null>(null);
  const [geoip, setGeoip] = useState<GeoIPStatus | null>(null);

  const loadPq = useCallback(async () => {
    try {
      const st = await mtproxylApi.selfmask();
      setPq({ pq_source: st.pq_source, pq_available: st.pq_available, pq_system: st.pq_system });
    } catch {
      setPq(null);
    }
  }, []);

  const loadGeoip = useCallback(async () => {
    try {
      setGeoip(await mtproxylAddonsApi.geoipStatus());
    } catch {
      setGeoip(null);
    }
  }, []);

  useEffect(() => {
    void loadPq();
    void loadGeoip();
  }, [loadPq, loadGeoip]);

  const { operation, start, dismiss, running } = useMtproxylOperation(loadPq, ['selfmask:pq-install']);
  const {
    operation: geoipOperation,
    start: startGeoip,
    dismiss: dismissGeoip,
    running: geoipRunning,
  } = useMtproxylOperation(loadGeoip, ['geoip:install']);

  const installPq = async () => {
    try {
      start(await mtproxylAddonsApi.pqInstall());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить установку');
    }
  };

  const installGeoip = async () => {
    try {
      startGeoip(await mtproxylAddonsApi.geoipInstall());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить установку');
    }
  };

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
    <div className="p-4 lg:p-6 space-y-4">
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
            <Button type="submit" disabled={checking || pq?.pq_available === false}>
              {checking ? 'Проверка…' : 'Проверить'}
            </Button>
          </form>

          <OperationProgress operation={operation} onDismiss={dismiss} />

          {pq?.pq_available === false ? (
            <div className="bg-warning/10 border border-warning/30 rounded-lg p-3 space-y-2">
              <p className="text-sm text-text-primary">
                Проверять нечем: нужен OpenSSL с постквантовым обменом ключами.
              </p>
              <p className="text-xs text-text-secondary">
                Системный OpenSSL 3.5.0 и новее умеет это сам — тогда ничего ставить не надо.
                Здесь он старее, поэтому можно поставить сборку из состава MTProxyL: она
                встанет отдельно и не тронет системный пакет.
              </p>
              <Button onClick={installPq} disabled={running}>
                {running ? 'Установка…' : 'Установить PQ OpenSSL'}
              </Button>
            </div>
          ) : (
            pq?.pq_source && (
              <p className="text-xs text-text-secondary">
                Проверка идёт через: {pq.pq_source}
                {pq.pq_system && ' — своя сборка не нужна'}
              </p>
            )
          )}

          <p className="text-xs text-text-secondary">
            Можно указать порт: <span className="font-mono">example.com:8443</span>.
          </p>
          {output && (
            <pre className="text-xs text-text-secondary bg-background border border-border rounded-md p-3 whitespace-pre-wrap break-words font-mono max-h-80 overflow-y-auto">
              {output}
            </pre>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>База GeoIP</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <p className="text-sm text-text-secondary">
            Страна, город и провайдер для IP-адресов пользователей (страница «Пользователи» и
            история подключений). Без базы адреса показываются как есть, без геоданных. Работает
            одинаково в режиме менеджера и реаниматора — база не привязана к конфигу цели.
          </p>

          <OperationProgress operation={geoipOperation} onDismiss={dismissGeoip} />

          {geoip?.city_installed ? (
            <p className="text-sm text-text-primary">
              <span className="text-success">Установлена</span> в {geoip.dir}
              {!geoip.asn_installed && ' — без базы ASN (провайдер не определится)'}
              <Button
                variant="outline"
                size="sm"
                className="ml-3"
                onClick={installGeoip}
                disabled={geoipRunning}
              >
                {geoipRunning ? 'Установка…' : 'Переустановить'}
              </Button>
            </p>
          ) : (
            <div className="space-y-2">
              <p className="text-sm text-text-secondary">
                Не установлена. Базы GeoLite2 (MaxMind) скачиваются с зеркала{' '}
                <span className="font-mono">github.com/P3TERX/GeoLite.mmdb</span>.
              </p>
              <Button onClick={installGeoip} disabled={geoipRunning}>
                {geoipRunning ? 'Установка…' : 'Установить базу GeoIP'}
              </Button>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
