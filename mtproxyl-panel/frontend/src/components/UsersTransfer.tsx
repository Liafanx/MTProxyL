import { useRef, useState } from 'react';
import { Download, Upload } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { ErrorAlert } from '@/components/ErrorAlert';
import { mtproxylUsersApi } from '@/lib/api';

/**
 * Перенос пользователей с лимитами между серверами и режимами: файл, выгруженный
 * в реаниматоре, загружается в менеджер как есть. Существующие имена пропускаются.
 */
export function UsersTransfer({ onImported }: { onImported: () => void }) {
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [result, setResult] = useState('');
  const fileRef = useRef<HTMLInputElement>(null);

  const readFile = (file: File | undefined) => {
    if (!file) return;
    void file.text().then(setText);
  };

  const doImport = async () => {
    if (!text.trim()) {
      setError('Пустой файл');
      return;
    }
    setBusy(true);
    setError('');
    setResult('');
    try {
      const res = await mtproxylUsersApi.importFile(text);
      setResult(importSummary(res.output));
      setText('');
      onImported();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось загрузить пользователей');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-3 rounded-lg border border-border bg-surface p-3 sm:p-4">
      <p className="text-sm text-text-secondary">
        Файл содержит ключи, включённость, лимиты соединений и IP, квоту трафика, срок
        действия и рекламную метку. Его можно загрузить на другом сервере или после смены
        режима — выгрузка из реаниматора подходит для менеджера. Пользователи с уже
        существующими именами пропускаются.
      </p>
      <div className="flex flex-wrap gap-2">
        <a href={mtproxylUsersApi.exportUrl()} download>
          <Button variant="outline" size="sm">
            <Download size={14} className="mr-2" />
            Выгрузить файл
          </Button>
        </a>
        <input
          ref={fileRef}
          type="file"
          accept=".csv,.txt,.conf,text/plain"
          className="hidden"
          onChange={(e) => {
            readFile(e.target.files?.[0]);
            e.target.value = '';
          }}
        />
        <Button variant="outline" size="sm" onClick={() => fileRef.current?.click()}>
          <Upload size={14} className="mr-2" />
          Выбрать файл
        </Button>
      </div>
      <textarea
        value={text}
        onChange={(e) => setText(e.target.value)}
        rows={6}
        spellCheck={false}
        placeholder={'# label|key|enabled|max_conns|max_ips|quota|expires|notes|ad_tag\nalice|0123456789abcdef0123456789abcdef|true|5|0|1073741824|0||'}
        className="w-full font-mono text-xs bg-background border border-border rounded-md p-2 text-text-primary"
      />
      <Button size="sm" disabled={busy || !text.trim()} onClick={() => void doImport()}>
        {busy ? 'Загрузка…' : 'Загрузить пользователей'}
      </Button>
      {error && <ErrorAlert message={error} />}
      {result && <div className="text-sm text-success">{result}</div>}
    </div>
  );
}

/** Из вывода CLI оставляем строку с итогом — остальное служебное. */
export function importSummary(output: string): string {
  const line = output.split('\n').find((l) => l.includes('Импортировано'));
  return (line ?? output).replace(/^\s*\[[^\]]*\]\s*/, '').trim() || 'Готово';
}
