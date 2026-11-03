import { useRef, useState } from 'react';
import { Download, Upload } from 'lucide-react';
import { appearanceApi } from '@/lib/api';
import { useTheme } from '@/hooks/useTheme';
import { useBranding } from '@/hooks/useBranding';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';

export function AppearanceArchiveCard() {
  const { flush, acceptSettings, syncStatus } = useTheme();
  const { apply } = useBranding();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const input = useRef<HTMLInputElement>(null);
  const run = async (work: () => Promise<void>) => {
    setBusy(true); setError(''); setNotice('');
    try { await work(); }
    catch (err) { setError(err instanceof Error ? err.message : 'Не удалось перенести оформление'); }
    finally { setBusy(false); }
  };
  return <Card>
    <CardHeader><CardTitle>Архив оформления</CardTitle></CardHeader>
    <CardContent className="space-y-3">
      <p className="text-meta text-text-muted">Тема и цвета, название панели, тексты входа, оба фона и ICO в одном ZIP. Архив можно перенести на другой сервер или передать другому пользователю. Паролей, токенов и настроек прокси в нём нет. Сначала сохраните изменения текста и дождитесь окончания загрузки изображений.</p>
      <div className="flex flex-wrap gap-2">
        <Button variant="outline" disabled={busy || syncStatus === 'loading'} onClick={() => { void run(async () => {
          await flush();
          const blob = await appearanceApi.export();
          const url = URL.createObjectURL(blob);
          const link = document.createElement('a'); link.href = url; link.download = 'mtproxyl-panel-appearance.zip';
          document.body.appendChild(link); link.click(); link.remove();
          window.setTimeout(() => URL.revokeObjectURL(url), 1000);
          setNotice('Архив оформления сохранён');
        }); }}><Download size={15} />Скачать оформление</Button>
        <Button variant="outline" disabled={busy || syncStatus === 'loading'} onClick={() => input.current?.click()}><Upload size={15} />Загрузить оформление</Button>
        <input ref={input} className="hidden" type="file" accept=".zip,application/zip" aria-label="Архив оформления ZIP" onChange={(event) => {
          const file = event.target.files?.[0]; event.target.value = '';
          if (!file) return;
          if (file.size > 25 * 1024 * 1024) { setError('Архив больше 25 МБ'); return; }
          if (!window.confirm('Заменить тему, название, тексты входа, фоны и иконку оформлением из архива? Отсутствующие в архиве изображения будут удалены.')) return;
          void run(async () => {
            await flush();
            const result = await appearanceApi.import(file);
            acceptSettings(result.theme); apply(result.branding);
            setNotice('Оформление загружено и сохранено на сервере');
          });
        }} />
      </div>
      {busy && <p role="status" className="text-meta text-text-muted">Обработка оформления…</p>}
      {error && <p role="alert" className="text-meta text-error">{error}</p>}
      {notice && <p role="status" className="text-meta text-ok">{notice}</p>}
    </CardContent>
  </Card>;
}
