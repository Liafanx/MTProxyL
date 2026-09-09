import { useEffect, useState } from 'react';
import { Card } from '@/components/ui/card';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ParamField } from '@/components/ParamField';
import { mtproxylSettingsApi, type MtproxylSetting } from '@/lib/api';

export function HttpsHeadersCard({ disabled = false }: { disabled?: boolean }) {
  const [params, setParams] = useState<MtproxylSetting[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const load = async () => {
    const values = await mtproxylSettingsApi.list();
    setParams(values.filter(p => p.key.startsWith('HTTPS_')));
  };
  useEffect(() => { void load().catch(e => setError(String(e))); }, []);
  const save = async (key: string, value: string) => {
    setBusy(true);
    setError('');
    try {
      await mtproxylSettingsApi.set(key, value);
      await load();
    } catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  };
  if (!params.length && !error) return null;
  return (
    <Card className="p-4 space-y-3">
      <div className="font-medium">HTTPS-заголовки Selfmask и WEB</div>
      <p className="text-xs text-text-secondary">
        Общие настройки управляемого nginx. HSTS действует только для текущего домена,
        кроме самоподписанных сертификатов, и переводит HTTP на HTTPS на всех его портах.
        Отключение отправляет max-age=0.
        Permissions-Policy запрещает камеру, микрофон и геолокацию.
        Собственный nginx-конфиг и внешний HAProxy нужно обновить вручную.
      </p>
      {error && <ErrorAlert message={error} />}
      {params.map(p => (
        <label key={p.key} className="flex flex-wrap items-center justify-between gap-2 text-sm">
          {p.description}
          <ParamField param={p} value={p.value} disabled={disabled || busy}
            onChange={value => void save(p.key, value)} />
        </label>
      ))}
    </Card>
  );
}
