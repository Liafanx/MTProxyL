import { useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { StatusBadge } from '@/components/StatusBadge';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import {
  mtproxylApi,
  type MtproxylOperation,
  type SelfmaskStatus,
} from '@/lib/api';

interface Props {
  status: SelfmaskStatus;
  running: boolean;
  onStart: (operation: MtproxylOperation) => void;
  onError: (message: string) => void;
}

export function NginxCustomConfigCard({ status, running, onStart, onError }: Props) {
  const [content, setContent] = useState('');
  const [savedContent, setSavedContent] = useState('');
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(false);
  const [output, setOutput] = useState<string | null>(null);
  const [confirmToggle, setConfirmToggle] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (!status.nginx_custom_file_exists) {
      setContent('');
      setSavedContent('');
      return;
    }
    mtproxylApi
      .selfmaskNginxConfig()
      .then((res) => {
        if (cancelled) return;
        setContent(res.content);
        setSavedContent(res.content);
      })
      .catch((e) => {
        if (!cancelled) {
          onError(e instanceof Error ? e.message : 'Не удалось загрузить конфиг nginx');
        }
      });
    return () => {
      cancelled = true;
    };
  }, [status.nginx_custom_file, status.nginx_custom_file_exists, onError]);

  const toggle = async () => {
    const enabled = confirmToggle;
    setConfirmToggle(null);
    if (enabled === null) return;
    setOutput(null);
    try {
      onStart(await mtproxylApi.toggleSelfmaskNginxConfig(enabled));
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Не удалось переключить конфиг nginx');
    }
  };

  const save = async () => {
    setSaving(true);
    setOutput(null);
    try {
      const res = await mtproxylApi.writeSelfmaskNginxConfig(content);
      setSavedContent(content);
      setOutput(res.output || 'Конфиг сохранён и проверен');
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Не удалось сохранить конфиг nginx');
    } finally {
      setSaving(false);
    }
  };

  const test = async () => {
    setTesting(true);
    setOutput(null);
    try {
      const res = await mtproxylApi.testSelfmaskNginxConfig();
      setOutput(res.output || 'Конфиг корректен');
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Проверка nginx завершилась ошибкой');
    } finally {
      setTesting(false);
    }
  };

  return (
    <>
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-3">
            Пользовательский конфиг nginx
            <StatusBadge
              status={status.nginx_custom_active}
              labelOn="ВКЛЮЧЁН"
              labelOff="ВЫКЛЮЧЕН"
            />
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <p className="text-sm text-text-secondary">
            При включении текущий рабочий конфиг копируется один раз. После этого MTProxyL не
            перезаписывает его: домены, порты и дополнительные маршруты вы поддерживаете вручную.
          </p>
          <div className="flex items-start justify-between gap-4">
            <span className="shrink-0 text-sm text-text-secondary">Файл</span>
            <span className="break-all text-right font-mono text-xs text-text-primary">
              {status.nginx_custom_file || '/opt/mtproxyl/nginx-custom.conf'}
            </span>
          </div>
          {status.nginx_custom_enabled && !status.nginx_custom_active && (
            <div className="rounded-md border border-danger/40 bg-danger/10 p-3 text-sm text-text-primary">
              Режим отмечен как включённый, но файл не найден. Выключите его и включите заново,
              чтобы создать конфиг.
            </div>
          )}
          <div className="flex flex-wrap gap-2">
            <Button
              variant={status.nginx_custom_enabled ? 'outline' : 'default'}
              onClick={() => setConfirmToggle(!status.nginx_custom_enabled)}
              disabled={running || saving}
            >
              {status.nginx_custom_enabled ? 'Вернуть стандартный конфиг' : 'Включить свой конфиг'}
            </Button>
            {status.nginx_custom_file_exists && (
              <Button
                variant="outline"
                onClick={test}
                disabled={running || saving || testing}
              >
                {testing ? 'Проверка…' : 'Проверить nginx -t'}
              </Button>
            )}
          </div>
          {status.nginx_custom_file_exists && (
            <>
              <textarea
                value={content}
                onChange={(e) => setContent(e.target.value)}
                spellCheck={false}
                autoCapitalize="off"
                autoCorrect="off"
                className="min-h-[28rem] w-full resize-y rounded border border-border bg-background p-3 font-mono text-xs text-text-primary focus:outline-none focus:ring-2 focus:ring-accent/50"
              />
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  onClick={save}
                  disabled={running || saving || content === savedContent || content.length === 0}
                >
                  {saving ? 'Проверка и сохранение…' : 'Сохранить конфиг'}
                </Button>
                {content !== savedContent && (
                  <span className="text-xs text-text-secondary">Есть несохранённые изменения</span>
                )}
              </div>
            </>
          )}
          {output && (
            <pre className="max-h-48 overflow-y-auto whitespace-pre-wrap break-words rounded-md border border-border bg-background p-3 font-mono text-xs text-text-secondary">
              {output}
            </pre>
          )}
        </CardContent>
      </Card>

      <ConfirmDialog
        open={confirmToggle !== null}
        onClose={() => setConfirmToggle(null)}
        onConfirm={toggle}
        title={
          confirmToggle
            ? 'Включить пользовательский nginx.conf'
            : 'Вернуть стандартный nginx.conf'
        }
        message={
          confirmToggle
            ? 'Текущий рабочий конфиг будет скопирован один раз. После этого изменения Selfmask и WEB Proxy нужно переносить в него вручную.'
            : 'MTProxyL снова начнёт генерировать nginx.conf из своих настроек. Пользовательский файл сохранится, но дополнительные маршруты из него перестанут применяться.'
        }
        confirmLabel={confirmToggle ? 'Включить' : 'Вернуть стандартный'}
      />
    </>
  );
}
