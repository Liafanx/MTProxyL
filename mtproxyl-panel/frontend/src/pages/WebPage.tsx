import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { OperationProgress } from '@/components/OperationProgress';
import { ParamField } from '@/components/ParamField';
import { mtproxylApi, type WebParam, type WebStatus } from '@/lib/api';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';

const LAYOUT_LABELS: Record<string, string> = {
  shared: 'shared — один порт с обычным прокси, разбор по SNI',
  split: 'split — у WEB свой порт',
};

const CARRIER_LABELS: Record<string, string> = {
  'https-lanes': 'https-lanes — потоки не блокируют друг друга',
  https: 'https — максимальная совместимость',
  websocket: 'websocket — один сокет на все потоки',
  'websocket-lanes': 'websocket-lanes — сокет на каждый поток',
};

export function WebPage() {
  const [status, setStatus] = useState<WebStatus | null>(null);
  const [params, setParams] = useState<WebParam[]>([]);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [links, setLinks] = useState<string | null>(null);
  const [confirmDisable, setConfirmDisable] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [st, ps] = await Promise.all([mtproxylApi.web(), mtproxylApi.webParams()]);
      setStatus(st);
      setParams(ps);
      setEdits({});
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить статус WEB Proxy');
    } finally {
      setLoading(false);
    }
  }, []);

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['web:']);

  useEffect(() => {
    void load();
  }, [load]);

  const valueOf = (key: string) => edits[key] ?? params.find((p) => p.key === key)?.value ?? '';
  const dirty = Object.keys(edits).filter(
    (k) => edits[k] !== params.find((p) => p.key === k)?.value,
  );

  // В shared публичный порт задаёт сам прокси, поэтому поле не показываем.
  const layout = valueOf('WEB_LAYOUT') || 'shared';
  const visibleParams = params.filter(
    (p) => layout === 'split' || p.key !== 'WEB_PUBLIC_PORT',
  );

  const saveParams = async (): Promise<boolean> => {
    if (dirty.length === 0) return true;
    setSaving(true);
    try {
      // Последовательно: каждая запись переписывает файл настроек целиком.
      for (const key of dirty) {
        await mtproxylApi.setWebParam(key, edits[key]);
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

  const enable = async () => {
    setNotice(null);
    if (dirty.length > 0 && !(await saveParams())) return;
    try {
      start(await mtproxylApi.webEnable());
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить включение');
    }
  };

  const runDisable = async () => {
    setConfirmDisable(false);
    try {
      start(await mtproxylApi.webDisable());
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось отключить WEB Proxy');
    }
  };

  const showLinks = async () => {
    try {
      const r = await mtproxylApi.webLinks();
      setLinks(r.output);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить ссылки');
    }
  };

  // Предполётные причины приходят одной строкой через точку с запятой.
  const problems = (status?.problems ?? '').split(';').map((p) => p.trim()).filter(Boolean);

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">WEB Proxy</h1>
        <p className="text-sm text-text-secondary mt-1">
          Тип прокси WEB из Telegram Desktop: MTProto внутри обычного HTTPS. TLS терминирует
          nginx, движок получает простой HTTP на приватном порту.
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
                <CardTitle className="flex items-center gap-3">
                  Состояние
                  <StatusBadge status={status.enabled} labelOn="ВКЛЮЧЁН" labelOff="ВЫКЛЮЧЕН" />
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-2 text-sm">
                <Row label="Домен" value={status.domain || 'не задан'} mono />
                <Row label="Раскладка" value={LAYOUT_LABELS[status.layout] ?? status.layout} />
                <Row label="Транспорт" value={CARRIER_LABELS[status.carrier] ?? status.carrier} />
                <Row label="Секрет в ссылке" value={status.secret_mode} />
                <Row label="public_addr" value={status.public_addr || 'не определён'} mono />
                <Row
                  label="Порты"
                  value={
                    status.layout === 'split'
                      ? `nginx :${status.public_port} → WEB :${status.listen_port}`
                      : `nginx :${status.public_port} → движок :${status.mtproxy_port}, WEB :${status.listen_port}`
                  }
                  mono
                />
                <Row label="Сайт-заглушка" value={status.decoy_dir} mono />
              </CardContent>
            </Card>

            {problems.length > 0 && (
              <Card>
                <CardHeader>
                  <CardTitle>Мешает включению</CardTitle>
                </CardHeader>
                <CardContent>
                  <ul className="space-y-1 text-sm text-text-primary list-disc pl-5">
                    {problems.map((p) => (
                      <li key={p}>{p}</li>
                    ))}
                  </ul>
                </CardContent>
              </Card>
            )}

            <Card>
              <CardHeader>
                <CardTitle>Параметры</CardTitle>
              </CardHeader>
              <CardContent className="space-y-3">
                {visibleParams.map((p) => (
                  <div key={p.key} className="flex items-start justify-between gap-4">
                    <div className="min-w-0">
                      <div className="text-sm text-text-primary">{p.desc}</div>
                      <div className="font-mono text-xs text-text-secondary">{p.key}</div>
                    </div>
                    <ParamField
                      param={p}
                      value={valueOf(p.key)}
                      onChange={(v) => setEdits((e) => ({ ...e, [p.key]: v }))}
                      disabled={saving || running}
                    />
                  </div>
                ))}
              </CardContent>
            </Card>

            <div className="flex flex-wrap gap-2">
              <Button
                onClick={enable}
                disabled={saving || running || (!status.enabled && problems.length > 0)}
              >
                {status.enabled ? 'Применить заново' : 'Включить'}
              </Button>
              {status.enabled && (
                <>
                  <Button variant="outline" onClick={showLinks} disabled={running}>
                    Ссылки
                  </Button>
                  <Button
                    variant="danger"
                    onClick={() => setConfirmDisable(true)}
                    disabled={running}
                  >
                    Выключить
                  </Button>
                </>
              )}
            </div>

            {links && (
              <Card>
                <CardHeader>
                  <CardTitle>Ссылки tg://webproxy</CardTitle>
                </CardHeader>
                <CardContent>
                  <pre className="font-mono text-xs text-text-primary whitespace-pre-wrap break-all">
                    {links}
                  </pre>
                </CardContent>
              </Card>
            )}
          </>
        )
      )}

      <ConfirmDialog
        open={confirmDisable}
        title="Выключить WEB Proxy?"
        message="Публичный порт вернётся движку, ссылки tg://webproxy перестанут работать."
        confirmLabel="Выключить"
        confirmVariant="danger"
        onConfirm={runDisable}
        onClose={() => setConfirmDisable(false)}
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
