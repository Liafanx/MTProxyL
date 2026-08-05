import { useCallback, useEffect, useMemo, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { OperationProgress } from '@/components/OperationProgress';
import { ParamField } from '@/components/ParamField';
import { mtproxylApi, type SelfmaskParam, type SelfmaskStatus } from '@/lib/api';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';

const SITE_SOURCE_LABELS: Record<string, string> = {
  stub: 'Заглушка «сайт недоступен»',
  filemanager: 'Файловый менеджер',
  catrunner: 'Мини-игра Cat Runner',
  mekorunner: 'Мини-игра MEKO Runner',
};

const CERT_MODE_LABELS: Record<string, string> = {
  letsencrypt: "Let's Encrypt",
  selfsigned: 'Самоподписанный',
};

function siteSourceLabel(v: string): string {
  return SITE_SOURCE_LABELS[v] ?? (v.startsWith('http') ? `Свой сайт: ${v}` : v);
}

/**
 * Шаблон задаётся строкой: либо имя встроенного, либо ссылка на index.html.
 * Отдельный переключатель нужен, чтобы поле ввода URL появлялось только когда
 * оно осмысленно.
 */
function TemplatePicker({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const isCustom = value.startsWith('http');
  return (
    <div className="space-y-2">
      <select
        value={isCustom ? 'custom' : value || 'stub'}
        onChange={(e) => onChange(e.target.value === 'custom' ? 'https://' : e.target.value)}
        className="rounded border border-border bg-surface px-2 py-1.5 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-accent/50 max-w-[260px]"
      >
        {Object.entries(SITE_SOURCE_LABELS).map(([k, label]) => (
          <option key={k} value={k}>
            {label}
          </option>
        ))}
        <option value="custom">Свой сайт по ссылке</option>
      </select>
      {isCustom && (
        <input
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="https://example.com/index.html"
          className="w-full max-w-[260px] rounded border border-border bg-surface px-2 py-1.5 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-accent/50"
        />
      )}
    </div>
  );
}

export function SelfmaskPage() {
  const [status, setStatus] = useState<SelfmaskStatus | null>(null);
  const [params, setParams] = useState<SelfmaskParam[]>([]);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [verifyOutput, setVerifyOutput] = useState<string | null>(null);
  const [verifying, setVerifying] = useState(false);
  const [disabling, setDisabling] = useState(false);
  const [confirmDisable, setConfirmDisable] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [st, ps] = await Promise.all([mtproxylApi.selfmask(), mtproxylApi.selfmaskParams()]);
      setStatus(st);
      setParams(ps);
      setEdits({});
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить статус Selfmask');
    } finally {
      setLoading(false);
    }
  }, []);

  const { operation, start, running } = useMtproxylOperation(load, ['selfmask:']);

  useEffect(() => {
    void load();
  }, [load]);

  const valueOf = (key: string) => edits[key] ?? params.find((p) => p.key === key)?.value ?? '';

  const dirty = useMemo(
    () => Object.keys(edits).filter((k) => edits[k] !== params.find((p) => p.key === k)?.value),
    [edits, params],
  );

  // certMode decides whether the Let's Encrypt fields are meaningful at all.
  const certMode = valueOf('SELFMASK_CERT_MODE') || 'letsencrypt';

  const visibleParams = params.filter((p) => {
    if (certMode === 'selfsigned') {
      // Самоподписанный сертификат выпускаем сами — почта и автопродление
      // Let's Encrypt к нему отношения не имеют.
      return p.key !== 'SELFMASK_CERT_EMAIL' && p.key !== 'SELFMASK_AUTO_RENEW';
    }
    return true;
  });

  const saveParams = async (): Promise<boolean> => {
    if (dirty.length === 0) return true;
    setSaving(true);
    try {
      // Последовательно: каждая запись переписывает файл настроек целиком.
      for (const key of dirty) {
        await mtproxylApi.setSelfmaskParam(key, edits[key]);
      }
      setError(null);
      return true;
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить параметры');
      return false;
    } finally {
      setSaving(false);
    }
  };

  const saveOnly = async () => {
    setNotice(null);
    if (await saveParams()) {
      setNotice(
        `Сохранено параметров: ${dirty.length}. Нажмите «Применить», чтобы перевыпустить сайт и сертификат.`,
      );
      await load();
    }
  };

  const apply = async () => {
    setNotice(null);
    if (dirty.length > 0 && !(await saveParams())) return;
    try {
      start(await mtproxylApi.selfmaskApply());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить установку');
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
                <CardTitle className="flex items-center gap-3">
                  Состояние
                  <StatusBadge status={status.enabled} labelOn="ВКЛЮЧЁН" labelOff="ВЫКЛЮЧЕН" />
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-2 text-sm">
                <Row label="Домен" value={status.domain || 'не задан'} />
                <Row label="Источник сайта" value={siteSourceLabel(status.site_source)} />
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
                <CardTitle>Параметры</CardTitle>
              </CardHeader>
              <CardContent className="space-y-4">
                <p className="text-sm text-text-secondary">
                  Значения сохраняются отдельно от установки. «Применить» развернёт сайт и выпустит
                  сертификат по этим параметрам — это занимает несколько минут.
                </p>

                <div className="space-y-3">
                  {visibleParams.map((p) => (
                    <div
                      key={p.key}
                      className="flex flex-col sm:flex-row sm:items-start gap-2 sm:gap-4"
                    >
                      <div className="sm:w-1/2 min-w-0">
                        <div className="text-sm text-text-primary">{p.description}</div>
                        <div className="text-xs text-text-secondary font-mono truncate">{p.key}</div>
                      </div>
                      {p.key === 'SELFMASK_SITE_SOURCE' ? (
                        <TemplatePicker
                          value={valueOf(p.key)}
                          onChange={(v) => setEdits((prev) => ({ ...prev, [p.key]: v }))}
                        />
                      ) : (
                        <ParamField
                          param={p}
                          value={valueOf(p.key)}
                          onChange={(v) => setEdits((prev) => ({ ...prev, [p.key]: v }))}
                        />
                      )}
                    </div>
                  ))}
                </div>

                {certMode === 'letsencrypt' && (
                  <p className="text-xs text-text-secondary">
                    Для Let's Encrypt домену нужна A-запись на этот сервер и свободный порт 80.
                    Самоподписанный сертификат работает с любым доменом, даже несуществующим.
                  </p>
                )}
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Действия</CardTitle>
              </CardHeader>
              <CardContent className="space-y-3">
                <div className="flex flex-wrap gap-2">
                  <Button onClick={apply} disabled={running || saving}>
                    {saving ? 'Сохранение…' : dirty.length > 0 ? 'Сохранить и применить' : 'Применить'}
                  </Button>
                  {dirty.length > 0 && (
                    <Button variant="outline" onClick={saveOnly} disabled={running || saving}>
                      Только сохранить
                    </Button>
                  )}
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
                {dirty.length > 0 && (
                  <p className="text-xs text-text-secondary">
                    Изменено параметров: {dirty.length}
                  </p>
                )}
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
