import { useCallback, useEffect, useMemo, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ParamField } from '@/components/ParamField';
import { ManagerOnlyNotice } from '@/components/ManagerOnlyNotice';
import { useManagerOnly } from '@/hooks/useMtproxyl';
import { mtproxylSettingsApi, type MtproxylSetting } from '@/lib/api';

/**
 * Настройки сгруппированы по смыслу, а не свалены одним списком из 16 полей.
 */
const GROUPS: { title: string; description: string; keys: string[] }[] = [
  {
    title: 'Подключение',
    description: 'Куда подключаются клиенты и какой адрес попадает в ссылки.',
    keys: ['PROXY_PORT', 'CUSTOM_IP', 'PROXY_DOMAIN', 'AD_TAG'],
  },
  {
    title: 'Маскировка',
    description:
      'Что прокси отдаёт тому, кто пришёл не по протоколу MTProto: настоящий сайт вместо ' +
      'разрыва соединения делает сервер похожим на обычный веб-сервер.',
    keys: ['MASKING_ENABLED', 'MASKING_HOST', 'MASKING_PORT', 'UNKNOWN_SNI_ACTION', 'FAKE_CERT_LEN'],
  },
  {
    title: 'Нагрузка и протокол',
    description: 'Ограничения движка и приём заголовка от вышестоящего балансировщика.',
    keys: ['PROXY_CONCURRENCY', 'PROXY_PROTOCOL'],
  },
  {
    title: 'Служебные порты',
    description:
      'Оба слушаются только на localhost. Меняются не на лету — движок открывает сокеты ' +
      'при старте, так что нужен перезапуск.',
    keys: ['PROXY_METRICS_PORT', 'PROXY_API_PORT'],
  },
  {
    title: 'Обслуживание',
    description: 'Настройки самого MTProxyL — в конфиг движка не попадают.',
    keys: ['AUTO_UPDATE_ENABLED', 'BACKUP_RETENTION_DAYS', 'SECRET_AUTO_ROTATE_DAYS'],
  },
];

/** Ключи, смена которых рвёт активные соединения или требует действий от вас. */
const WARNINGS: Record<string, string> = {
  PROXY_PORT: 'Прокси перезапустится, ссылки изменятся, правила гео-блокировки переедут на новый порт.',
  PROXY_DOMAIN: 'Ссылки изменятся — старые перестанут работать.',
  PROXY_API_PORT: 'После перезапуска поправьте адрес в конфиге панели, иначе она потеряет движок.',
  PROXY_METRICS_PORT: 'Применится только после перезапуска прокси.',
};

export function SettingsPage() {
  const [params, setParams] = useState<MtproxylSetting[]>([]);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  const { allowed, loading: modeLoading } = useManagerOnly();

  const load = useCallback(async () => {
    // Настройки принадлежат собственному прокси MTProxyL. В реаниматоре его
    // нет — там конфигом владеет чужая цель, и править её надо в её же файле.
    if (!allowed) {
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      setParams(await mtproxylSettingsApi.list());
      setEdits({});
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось загрузить настройки');
    } finally {
      setLoading(false);
    }
  }, [allowed]);

  useEffect(() => {
    void load();
  }, [load]);

  const byKey = useMemo(() => new Map(params.map((p) => [p.key, p])), [params]);
  const valueOf = (key: string) => edits[key] ?? byKey.get(key)?.value ?? '';

  const dirty = useMemo(
    () => Object.keys(edits).filter((k) => edits[k] !== byKey.get(k)?.value),
    [edits, byKey],
  );

  const save = async () => {
    if (dirty.length === 0) return;
    setSaving(true);
    setNotice(null);
    try {
      // Последовательно: смена порта перезапускает контейнер, и параллельные
      // записи в settings.conf затёрли бы друг друга.
      for (const key of dirty) {
        await mtproxylSettingsApi.set(key, edits[key]);
      }
      setNotice(`Сохранено настроек: ${dirty.length}`);
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить настройки');
      // Часть могла примениться — перечитываем, чтобы форма не врала.
      await load();
    } finally {
      setSaving(false);
    }
  };

  const dirtyWarnings = dirty.map((k) => WARNINGS[k]).filter(Boolean);

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Настройки прокси</h1>
        <p className="text-sm text-text-secondary mt-1">
          Настройки MTProxyL, из которых он собирает конфиг движка. Меняются через его CLI:
          в режиме Manager конфиг примонтирован в контейнер только для чтения, и сам telemt
          изменить их не может.
        </p>
      </div>

      {!modeLoading && !allowed && <ManagerOnlyNotice feature="Настройки прокси" />}

      {allowed && (
        <>
          {error && <ErrorAlert message={error} onRetry={load} />}
          {notice && (
            <div className="bg-accent/10 border border-accent/30 rounded-lg p-3 text-sm text-text-primary">
              {notice}
            </div>
          )}

          {loading && params.length === 0 ? (
            <div className="text-sm text-text-secondary">Загрузка…</div>
          ) : (
            <div className="space-y-4">
              {GROUPS.map((group) => {
                const present = group.keys.filter((k) => byKey.has(k));
                if (present.length === 0) return null;
                return (
                  <Card key={group.title}>
                    <CardHeader>
                      <CardTitle>{group.title}</CardTitle>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <p className="text-sm text-text-secondary">{group.description}</p>
                      <div className="space-y-3">
                        {present.map((key) => {
                          const p = byKey.get(key)!;
                          return (
                            <div
                              key={key}
                              className="flex flex-col sm:flex-row sm:items-start gap-2 sm:gap-4"
                            >
                              <div className="sm:w-1/2 min-w-0">
                                <div className="text-sm text-text-primary">{p.description}</div>
                                <div className="text-xs text-text-secondary font-mono truncate">
                                  {p.key}
                                </div>
                              </div>
                              <ParamField
                                param={p}
                                value={valueOf(key)}
                                onChange={(v) => setEdits((prev) => ({ ...prev, [key]: v }))}
                              />
                            </div>
                          );
                        })}
                      </div>
                    </CardContent>
                  </Card>
                );
              })}
            </div>
          )}

          {dirty.length > 0 && (
            <div className="sticky bottom-4 bg-surface border border-accent/40 rounded-lg p-3 space-y-2 shadow-lg">
              {dirtyWarnings.length > 0 && (
                <ul className="text-xs text-warning space-y-0.5">
                  {dirtyWarnings.map((wtext) => (
                    <li key={wtext}>• {wtext}</li>
                  ))}
                </ul>
              )}
              <div className="flex items-center gap-3 flex-wrap">
                <span className="text-sm text-text-primary flex-1">
                  Изменено настроек: {dirty.length}
                </span>
                <Button variant="outline" onClick={() => setEdits({})} disabled={saving}>
                  Отменить
                </Button>
                <Button onClick={save} disabled={saving}>
                  {saving ? 'Сохранение…' : 'Сохранить'}
                </Button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}
