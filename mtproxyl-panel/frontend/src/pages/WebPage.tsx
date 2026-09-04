import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { OperationProgress } from '@/components/OperationProgress';
import { ParamField } from '@/components/ParamField';
import { NginxCustomConfigCard } from '@/components/NginxCustomConfigCard';
import { SiteSourcePicker, siteSourceLabel } from '@/components/SiteSourcePicker';
import { CopyButton } from '@/components/CopyButton';
import { mtproxylApi, type SelfmaskStatus, type WebParam, type WebStatus } from '@/lib/api';
import { useManagerOnly, useMtproxylOperation } from '@/hooks/useMtproxyl';

const LAYOUT_LABELS: Record<string, string> = {
  web: 'WEB-only — без обычного MTProto',
  shared: 'shared — один порт с обычным прокси, разбор по SNI',
  split: 'split — у WEB свой порт',
};

const FRONTEND_LABELS: Record<string, string> = {
  nginx: 'nginx MTProxyL',
  haproxy: 'Внешний HAProxy',
  'haproxy-nginx': 'HAProxy → nginx MTProxyL',
};

const CARRIER_LABELS: Record<string, string> = {
  websocket: 'websocket — по умолчанию, стабильный один сокет',
  'websocket-lanes': 'websocket-lanes — сокет на каждый поток',
  'https-lanes': 'https-lanes — потоки не блокируют друг друга, нужен HTTP/2',
  https: 'https — максимальная совместимость',
};

export function WebPage() {
  const [status, setStatus] = useState<WebStatus | null>(null);
  const [nginxStatus, setNginxStatus] = useState<SelfmaskStatus | null>(null);
  const [params, setParams] = useState<WebParam[]>([]);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [links, setLinks] = useState<string | null>(null);
  const [haproxyConfig, setHAProxyConfig] = useState<string | null>(null);
  const [confirmDisable, setConfirmDisable] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [st, ps, nginx] = await Promise.all([
        mtproxylApi.web(),
        mtproxylApi.webParams(),
        mtproxylApi.selfmask(),
      ]);
      setStatus(st);
      setNginxStatus(nginx);
      setParams(ps);
      setEdits({});
      setHAProxyConfig(null);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить статус WEB Proxy');
    } finally {
      setLoading(false);
    }
  }, []);

  const { operation, start, dismiss, running } = useMtproxylOperation(load, [
    'web:',
    'selfmask:nginx-custom-',
  ]);
  // В реаниматоре WEB поднимает хозяин цели: включать и настраивать нам нечего,
  // MTProxyL там только читает её конфиг и собирает ссылки.
  const { allowed: isManager, loading: modeLoading } = useManagerOnly();

  useEffect(() => {
    void load();
  }, [load]);

  const valueOf = (key: string) => edits[key] ?? params.find((p) => p.key === key)?.value ?? '';
  const dirty = Object.keys(edits).filter(
    (k) => edits[k] !== params.find((p) => p.key === k)?.value,
  );

  // В shared публичный порт задаёт сам прокси, поэтому поле не показываем.
  const layout = valueOf('WEB_LAYOUT') || 'shared';
  const frontend = valueOf('WEB_FRONTEND') || 'nginx';
  const decoyMode = valueOf('WEB_DECOY_MODE') || 'static_directory';
  const visibleParams = params.filter((p) => {
    if (status?.proxy_mode === 'web' && ['WEB_LAYOUT', 'WEB_TLS_PORT', 'WEB_MTPROXY_PORT'].includes(p.key)) return false;
    if (layout === 'split' && ['WEB_TLS_PORT', 'WEB_MTPROXY_PORT'].includes(p.key)) return false;
    if (frontend.startsWith('haproxy') && p.key === 'WEB_PUBLIC_PORT') return false;
    if (frontend !== 'haproxy' && p.key === 'WEB_HAPROXY_CERT') return false;
    if (decoyMode === 'empty') {
      if (['WEB_DECOY_SOURCE', 'WEB_DECOY_DIR', 'WEB_DECOY_UPSTREAM'].includes(p.key)) return false;
    } else if (decoyMode === 'http_upstream') {
      if (['WEB_DECOY_SOURCE', 'WEB_DECOY_DIR'].includes(p.key)) return false;
    } else if (p.key === 'WEB_DECOY_UPSTREAM') {
      return false;
    }
    return layout === 'split' || status?.proxy_mode === 'web' || p.key !== 'WEB_PUBLIC_PORT';
  });

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

  const changeMode = async (mode: 'web' | 'combined') => {
    setNotice(null);
    if (dirty.length > 0 && !(await saveParams())) return;
    try {
      start(await mtproxylApi.webMode(mode));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переключить режим');
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

  const showHAProxyConfig = async () => {
    if (dirty.length > 0 && !(await saveParams())) return;
    try {
      const r = await mtproxylApi.webHAProxyConfig();
      setHAProxyConfig(r.output);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить конфигурацию HAProxy');
    }
  };

  // Предполётные причины приходят одной строкой через точку с запятой.
  const problems = (status?.problems ?? '').split(';').map((p) => p.trim()).filter(Boolean);
  const proxyMode = status?.proxy_mode || (status?.enabled ? 'combined' : 'mtproto');

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">WEB Proxy</h1>
        <p className="text-sm text-text-secondary mt-1">
          Тип прокси WEB: MTProto внутри обычного HTTPS. TLS терминирует
          nginx MTProxyL либо внешний HAProxy; движок получает простой HTTP
          на приватном порту.
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
                <Row
                  label="Режим"
                  value={proxyMode === 'web' ? 'Только WEB' : proxyMode === 'combined' ? 'MTProto + WEB' : 'Только MTProto'}
                />
                {/* У цели раскладку и порты задаёт её хозяин, и MTProxyL их не знает:
                    показывать нули и пустые поля честнее не показывать вовсе. */}
                {status.layout !== 'target' && (
                  <>
                    <Row label="Раскладка" value={LAYOUT_LABELS[status.layout] ?? status.layout} />
                    <Row label="Frontend" value={FRONTEND_LABELS[status.frontend] ?? status.frontend} />
                    <Row label="Транспорт" value={CARRIER_LABELS[status.carrier] ?? status.carrier} />
                    <Row label="Секрет в ссылке" value={status.secret_mode} />
                    <Row label="public_addr" value={status.public_addr || 'не определён'} mono />
                    <Row
                      label="Порты"
                      value={
                        status.frontend === 'haproxy-nginx'
                          ? `HAProxy :443 → nginx :${status.tls_port} → WEB :${status.listen_port}${status.layout === 'shared' ? `; MTProto :${status.mtproxy_port}` : status.layout === 'split' ? `, MTProto HAProxy :${status.proxy_port}` : ''}`
                          : status.frontend === 'haproxy'
                          ? status.layout === 'shared'
                            ? `HAProxy :443 → MTProto :${status.mtproxy_port}, TLS :${status.tls_port} → WEB :${status.listen_port}`
                            : `HAProxy :443 → WEB :${status.listen_port}${status.layout === 'split' ? `, MTProto :${status.proxy_port}` : ''}`
                          : status.layout === 'split'
                            ? `nginx :${status.public_port} → WEB :${status.listen_port}`
                            : status.layout === 'web'
                              ? `nginx :${status.public_port} → WEB :${status.listen_port}`
                              : `nginx :${status.public_port} → движок :${status.mtproxy_port}, WEB :${status.listen_port}`
                      }
                      mono
                    />
                    {status.frontend.startsWith('haproxy') && (
                      <>
                        <Row label="HAProxy" value={status.haproxy_ready ? 'слушает ожидаемые порты' : 'нужно применить конфигурацию'} />
                        {status.frontend === 'haproxy' && <Row label="PEM" value={status.haproxy_cert} mono />}
                      </>
                    )}
                    {status.decoy_mode === 'empty' ? (
                      <Row label="Сайт-заглушка" value="Выключен — пустой ответ" />
                    ) : status.decoy_mode === 'static_directory' ? (
                      <>
                        <Row label="Шаблон заглушки" value={siteSourceLabel(status.decoy_source || 'stub')} />
                        <Row label="Сайт-заглушка" value={status.decoy_dir} mono />
                      </>
                    ) : (
                      <Row label="Сайт-заглушка" value="HTTP upstream" />
                    )}
                  </>
                )}
                {status.layout === 'target' && (
                  <>
                    <Row label="Секрет в ссылке" value={status.secret_mode || '—'} />
                    <Row label="Порт цели" value={String(status.public_port)} mono />
                  </>
                )}
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

            {!modeLoading && !isManager && (
              <Card>
                <CardContent className="pt-4 space-y-2 text-sm text-text-secondary">
                  <p>
                    Конфигом владеет цель, поэтому WEB Proxy включает и настраивает её
                    хозяин. MTProxyL показывает состояние и собирает ссылки.
                  </p>
                  <Button variant="outline" onClick={showLinks} disabled={running}>
                    Ссылки
                  </Button>
                </CardContent>
              </Card>
            )}

            {isManager && (
              <Card>
                <CardHeader>
                  <CardTitle>Режим транспорта</CardTitle>
                </CardHeader>
                <CardContent className="flex flex-wrap gap-2">
                  <Button
                    variant={proxyMode === 'web' ? 'default' : 'outline'}
                    onClick={() => void changeMode('web')}
                    disabled={running || saving}
                  >
                    Только WEB
                  </Button>
                  <Button
                    variant={proxyMode === 'combined' ? 'default' : 'outline'}
                    onClick={() => void changeMode('combined')}
                    disabled={running || saving}
                  >
                    MTProto + WEB
                  </Button>
                </CardContent>
              </Card>
            )}

            {isManager && (
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
                      {p.key === 'WEB_DECOY_SOURCE' ? (
                        <SiteSourcePicker
                          value={valueOf(p.key)}
                          onChange={(v) => setEdits((e) => ({ ...e, [p.key]: v }))}
                          disabled={saving || running}
                        />
                      ) : (
                        <ParamField
                          param={p}
                          value={valueOf(p.key)}
                          onChange={(v) => setEdits((e) => ({ ...e, [p.key]: v }))}
                          disabled={saving || running}
                        />
                      )}
                    </div>
                  ))}
                </CardContent>
              </Card>
            )}

            {isManager && (
              <div className="flex flex-wrap gap-2">
                {/* Кнопку не блокируем списком причин: он собран при загрузке
                    страницы и после неудачного включения оставался бы вечным.
                    Предполёт всё равно повторяет CLI и назовёт свежую причину. */}
                <Button onClick={enable} disabled={saving || running}>
                  {status.enabled ? 'Применить заново' : 'Включить'}
                </Button>
                <Button variant="outline" onClick={() => void load()} disabled={loading || running}>
                  Проверить снова
                </Button>
                {status.enabled && (
                  <>
                    <Button variant="outline" onClick={showLinks} disabled={running}>
                      Ссылки
                    </Button>
                    {proxyMode !== 'web' && !(status.frontend.startsWith('haproxy') && status.layout === 'shared') && <Button
                      variant="danger"
                      onClick={() => setConfirmDisable(true)}
                      disabled={running}
                    >
                      Выключить
                    </Button>}
                  </>
                )}
              </div>
            )}

            {isManager && frontend === 'nginx' && nginxStatus && (
              <NginxCustomConfigCard
                status={nginxStatus}
                running={running}
                onStart={start}
                onError={setError}
              />
            )}

            {isManager && frontend.startsWith('haproxy') && (
              <Card>
                <CardHeader>
                  <CardTitle>Конфигурация HAProxy</CardTitle>
                </CardHeader>
                <CardContent className="space-y-3">
                  <p className="text-sm text-text-secondary">
                    MTProxyL не изменяет и не перезапускает HAProxy. Добавьте этот
                    фрагмент в существующую конфигурацию и примените её самостоятельно.
                    {frontend === 'haproxy-nginx' && ' Сертификат остаётся у nginx MTProxyL — PEM для HAProxy не нужен.'}
                  </p>
                  <Button variant="outline" onClick={() => void showHAProxyConfig()} disabled={running}>
                    Показать конфигурацию
                  </Button>
                  {haproxyConfig && (
                    <div className="space-y-2">
                      <CopyButton text={haproxyConfig} label="Копировать" />
                      <pre className="font-mono text-xs text-text-primary whitespace-pre-wrap break-all bg-background rounded-lg p-3 border border-border">
                        {haproxyConfig}
                      </pre>
                    </div>
                  )}
                </CardContent>
              </Card>
            )}

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
        message={status?.frontend === 'haproxy'
          ? 'WEB-listener будет выключен, но конфигурация HAProxy останется без изменений. Удалите его WEB-маршрут самостоятельно.'
          : 'Публичный порт вернётся движку, ссылки tg://webproxy перестанут работать.'}
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
