import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { OperationProgress } from '@/components/OperationProgress';
import { mtproxylApi, type SelfmaskStatus } from '@/lib/api';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';

const SITE_SOURCE_LABELS: Record<string, string> = {
  stub: 'Заглушка «сайт недоступен»',
  filemanager: 'Файловый менеджер',
  catrunner: 'Мини-игра Cat Runner',
  mekorunner: 'Мини-игра MEKO Runner',
  custom: 'Свой сайт',
};

const CERT_MODE_LABELS: Record<string, string> = {
  letsencrypt: "Let's Encrypt",
  selfsigned: 'Самоподписанный',
};

export function SelfmaskPage() {
  const [status, setStatus] = useState<SelfmaskStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [verifyOutput, setVerifyOutput] = useState<string | null>(null);
  const [verifying, setVerifying] = useState(false);
  const [disabling, setDisabling] = useState(false);
  const [confirmDisable, setConfirmDisable] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setStatus(await mtproxylApi.selfmask());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить статус Selfmask');
    } finally {
      setLoading(false);
    }
  }, []);

  const { operation, start, running } = useMtproxylOperation(load);

  useEffect(() => {
    void load();
  }, [load]);

  const runSetup = async () => {
    try {
      start(await mtproxylApi.selfmaskSetup());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить настройку');
    }
  };

  const runVerify = async () => {
    setVerifying(true);
    setVerifyOutput(null);
    try {
      const res = await mtproxylApi.selfmaskVerify();
      setVerifyOutput(res.output || 'Проверка завершена без вывода');
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Проверка не удалась');
    } finally {
      setVerifying(false);
    }
  };

  const runDisable = async () => {
    setDisabling(true);
    try {
      await mtproxylApi.selfmaskDisable();
      setConfirmDisable(false);
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось отключить Selfmask');
      setConfirmDisable(false);
    } finally {
      setDisabling(false);
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Selfmask</h1>
        <p className="text-sm text-text-secondary mt-1">
          Свой HTTPS-сайт-заглушка на том же порту: при проверке домена извне отдаётся настоящий
          сайт, а клиенты Telegram продолжают получать MTProto.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={load} />}
      <OperationProgress operation={operation} />

      {loading && !status ? (
        <div className="text-sm text-text-secondary">Загрузка…</div>
      ) : (
        status && (
          <>
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-3">
                  Состояние
                  <StatusBadge status={status.enabled} labelOn="ВКЛЮЧЁН" labelOff="ВЫКЛЮЧЕН" />
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-2 text-sm">
                <Row label="Домен" value={status.domain || 'не задан'} />
                <Row
                  label="Источник сайта"
                  value={SITE_SOURCE_LABELS[status.site_source] ?? status.site_source}
                />
                <Row label="Каталог сайта" value={status.site_dir} mono />
                <Row label="Backend" value={`127.0.0.1:${status.backend_port}`} mono />
                <Row
                  label="Тип сертификата"
                  value={CERT_MODE_LABELS[status.cert_mode] ?? status.cert_mode}
                />
                {status.cert_mode === 'letsencrypt' && (
                  <Row label="Автопродление" value={status.auto_renew ? 'включено' : 'выключено'} />
                )}
                <Row
                  label="Конфиг nginx"
                  value={status.nginx_conf_exists ? status.nginx_conf : 'не найден'}
                  mono
                />
                <Row label="Сертификат" value={status.cert_found ? 'найден' : 'не найден'} />
                <Row label="PQ nginx" value={status.pq_nginx_active ? 'активен' : 'не запущен'} />
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Действия</CardTitle>
              </CardHeader>
              <CardContent className="space-y-3">
                <p className="text-sm text-text-secondary">
                  Настройка выполняется мастером MTProxyL и принимает значения по умолчанию:
                  домен и шаблон сайта задаются в самом MTProxyL. Установка занимает несколько минут.
                </p>
                <div className="flex flex-wrap gap-2">
                  <Button onClick={runSetup} disabled={running}>
                    {status.enabled ? 'Переустановить' : 'Настроить'}
                  </Button>
                  <Button variant="outline" onClick={runVerify} disabled={verifying || running}>
                    {verifying ? 'Проверка…' : 'Проверить'}
                  </Button>
                  {status.enabled && (
                    <Button
                      variant="danger"
                      onClick={() => setConfirmDisable(true)}
                      disabled={running}
                    >
                      Отключить
                    </Button>
                  )}
                </div>
                {verifyOutput && (
                  <pre className="text-xs text-text-secondary bg-background border border-border rounded-md p-3 whitespace-pre-wrap break-words font-mono max-h-64 overflow-y-auto">
                    {verifyOutput}
                  </pre>
                )}
              </CardContent>
            </Card>
          </>
        )
      )}

      <ConfirmDialog
        open={confirmDisable}
        onClose={() => setConfirmDisable(false)}
        onConfirm={runDisable}
        title="Отключить Selfmask"
        message="Сайт-заглушка будет отключён, а FakeTLS вернётся к прежней настройке. Продолжить?"
        confirmLabel="Отключить"
        loadingLabel="Отключение…"
        loading={disabling}
      />
    </div>
  );
}

function Row({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex items-start justify-between gap-4">
      <span className="text-text-secondary shrink-0">{label}</span>
      <span
        className={
          mono
            ? 'font-mono text-xs text-text-primary break-all text-right'
            : 'text-text-primary text-right'
        }
      >
        {value}
      </span>
    </div>
  );
}
