import { useCallback, useEffect, useState } from 'react';
import Editor from '@monaco-editor/react';
import { AlertTriangle } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { ManagerOnlyNotice } from '@/components/ManagerOnlyNotice';
import { useManagerOnly } from '@/hooks/useMtproxyl';
import { useTheme } from '@/hooks/useTheme';
import { mtproxylExpertApi, type SuperExpertStatus } from '@/lib/api';
import { formatBytes } from '@/lib/utils';

const STARTER_CONFIG = `# Конфигурация движка telemt целиком под вашим контролем.
# Пока режим включён, MTProxyL не генерирует конфиг и не перезаписывает этот файл.

[general]
port = 443

[censorship]
tls_domain = "www.google.com"
`;

export function SuperExpertPage() {
  const [status, setStatus] = useState<SuperExpertStatus | null>(null);
  const [content, setContent] = useState('');
  const [savedContent, setSavedContent] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [toggling, setToggling] = useState(false);
  const [confirmToggle, setConfirmToggle] = useState<boolean | null>(null);

  const { theme } = useTheme();
  const { allowed, loading: modeLoading } = useManagerOnly();

  const load = useCallback(async () => {
    // Свой конфиг движка есть только в режиме manager.
    if (!allowed) {
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      const st = await mtproxylExpertApi.superExpert();
      setStatus(st);
      if (st.file_exists) {
        const cfg = await mtproxylExpertApi.superExpertConfig();
        setContent(cfg.content);
        setSavedContent(cfg.content);
      } else {
        // Файла ещё нет — показываем заготовку, чтобы не начинать с пустого
        // экрана, но считаем её несохранённой.
        setContent(STARTER_CONFIG);
        setSavedContent('');
      }
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось загрузить конфиг');
    } finally {
      setLoading(false);
    }
  }, [allowed]);

  useEffect(() => {
    void load();
  }, [load]);

  const dirty = content !== savedContent;

  const save = async () => {
    setSaving(true);
    setNotice(null);
    try {
      await mtproxylExpertApi.saveSuperExpertConfig(content);
      setSavedContent(content);
      setNotice('Конфиг сохранён. Перезапустите прокси, чтобы он вступил в силу.');
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить конфиг');
    } finally {
      setSaving(false);
    }
  };

  const toggle = async () => {
    const enabled = confirmToggle;
    setConfirmToggle(null);
    if (enabled === null) return;
    setToggling(true);
    try {
      await mtproxylExpertApi.toggleSuperExpert(enabled);
      setNotice(
        enabled
          ? 'Режим включён: конфигом движка теперь управляете вы.'
          : 'Режим выключен: MTProxyL снова генерирует конфиг. Файл сохранён.',
      );
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переключить режим');
    } finally {
      setToggling(false);
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Супер эксперт</h1>
        <p className="text-sm text-text-secondary mt-1">
          Конфигурация движка целиком под вашим контролем: MTProxyL перестаёт её генерировать и
          подставляет ваш файл при каждом запуске.
        </p>
      </div>

      {!modeLoading && !allowed && <ManagerOnlyNotice feature="Режим супер эксперта" />}

      {allowed && (
        <>
          <div className="bg-warning/10 border border-warning/30 rounded-lg p-4 flex items-start gap-3">
            <AlertTriangle size={18} className="text-warning shrink-0 mt-0.5" />
            <div className="text-sm text-text-secondary space-y-1">
              <p className="text-text-primary">Пока режим включён, часть настроек панели не действует.</p>
              <p>
                Секреты, порт, домен, экспертные параметры и быстрый тюнинг перестают влиять на
                движок — всё это задаётся в вашем файле. Ошибка в нём приведёт к тому, что прокси
                не поднимется.
              </p>
            </div>
          </div>

          {error && <ErrorAlert message={error} onRetry={load} />}
          {notice && (
            <div className="bg-accent/10 border border-accent/30 rounded-lg p-3 text-sm text-text-primary">
              {notice}
            </div>
          )}

          {loading && !status ? (
            <div className="text-sm text-text-secondary">Загрузка…</div>
          ) : (
            status && (
              <>
                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-3">
                      Состояние
                      <StatusBadge status={status.active} labelOn="ВКЛЮЧЁН" labelOff="ВЫКЛЮЧЕН" />
                    </CardTitle>
                  </CardHeader>
                  <CardContent className="space-y-2 text-sm">
                    <Row label="Файл" value={status.file} mono />
                    <Row label="Файл существует" value={status.file_exists ? 'да' : 'нет'} />
                    {status.file_exists && <Row label="Размер" value={formatBytes(status.size)} />}
                    {status.enabled && !status.active && (
                      <p className="text-sm text-danger">
                        Режим включён, но файла нет — движок не получит конфиг. Сохраните файл
                        ниже или выключите режим.
                      </p>
                    )}
                    <div className="pt-2">
                      <Button
                        variant={status.enabled ? 'danger' : 'default'}
                        disabled={toggling}
                        onClick={() => setConfirmToggle(!status.enabled)}
                      >
                        {status.enabled ? 'Выключить режим' : 'Включить режим'}
                      </Button>
                    </div>
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center justify-between gap-3">
                      <span>Конфигурация движка</span>
                      {dirty && (
                        <span className="text-xs font-normal text-warning">не сохранено</span>
                      )}
                    </CardTitle>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    <div className="border border-border rounded-md overflow-hidden">
                      <Editor
                        height="55vh"
                        language="ini"
                        value={content}
                        onChange={(v) => setContent(v ?? '')}
                        theme={theme === 'dark' ? 'vs-dark' : 'light'}
                        options={{
                          minimap: { enabled: false },
                          fontSize: 13,
                          scrollBeyondLastLine: false,
                          wordWrap: 'on',
                        }}
                      />
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      <Button onClick={save} disabled={saving || !dirty}>
                        {saving ? 'Сохранение…' : 'Сохранить'}
                      </Button>
                      {dirty && (
                        <Button
                          variant="outline"
                          onClick={() => setContent(savedContent || STARTER_CONFIG)}
                          disabled={saving}
                        >
                          Отменить изменения
                        </Button>
                      )}
                      <span className="text-xs text-text-secondary">
                        После сохранения перезапустите прокси, чтобы конфиг вступил в силу.
                      </span>
                    </div>
                  </CardContent>
                </Card>
              </>
            )
          )}
        </>
      )}

      <ConfirmDialog
        open={confirmToggle !== null}
        onClose={() => setConfirmToggle(null)}
        onConfirm={toggle}
        title={confirmToggle ? 'Включить режим супер эксперта' : 'Выключить режим супер эксперта'}
        message={
          confirmToggle
            ? 'MTProxyL перестанет генерировать конфиг движка и будет подставлять ваш файл. Настройки секретов, порта и домена перестанут на него влиять.'
            : 'MTProxyL снова начнёт генерировать конфиг движка. Ваш файл сохранится, но применяться перестанет.'
        }
        confirmLabel={confirmToggle ? 'Включить' : 'Выключить'}
        loadingLabel="Переключение…"
        confirmVariant={confirmToggle ? 'default' : 'danger'}
        loading={toggling}
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
