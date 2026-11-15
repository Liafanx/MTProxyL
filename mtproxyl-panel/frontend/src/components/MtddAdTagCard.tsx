import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { mtddApi } from '@/lib/api';

/**
 * Временная подмена общего рекламного тега mtdd (/v1/ad-tag).
 *
 * Действует без перезапуска и не пишется в конфиг: после перезапуска движка
 * снова работает тег из настроек. Секрет не нужен, тег виден в ссылках только
 * у новых подключений — старые переподключать не требуется.
 */
export function MtddAdTagCard() {
  const [override, setOverride] = useState<{ override: boolean; ad_tag: string | null } | null>(null);
  const [tag, setTag] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const load = useCallback(async () => {
    try {
      setOverride(await mtddApi.adTag());
      setError('');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);
  useEffect(() => { void load(); }, [load]);

  const submit = async () => {
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const res = await mtddApi.setAdTag(tag.trim());
      setNotice(res.output || 'Тег подменён');
      setTag('');
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const reset = async () => {
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const res = await mtddApi.resetAdTag();
      setNotice(res.output || 'Подмена снята');
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Временный рекламный тег</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <p className="text-sm text-text-secondary">
          Подмена общего тега на лету: клиенты не переподключаются, в конфиг ничего не пишется.
          После перезапуска движка снова действует тег из настроек.
        </p>
        <div className="text-sm">
          {override?.override && override.ad_tag
            ? <>Сейчас действует подмена: <span className="font-mono break-all">{override.ad_tag}</span></>
            : <span className="text-text-secondary">Подмены нет — действует тег из настроек.</span>}
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="mtdd-ad-tag">Новый тег (32 hex)</Label>
          <Input
            id="mtdd-ad-tag"
            value={tag}
            onChange={(e) => setTag(e.target.value)}
            placeholder="не из одних нулей"
            maxLength={32}
            className="font-mono"
          />
        </div>
        {error && <p className="text-sm text-error">{error}</p>}
        {notice && <p className="text-sm text-success">{notice}</p>}
        <div className="flex flex-wrap gap-2">
          <Button disabled={busy || tag.trim().length !== 32} onClick={submit}>Подменить</Button>
          <Button variant="outline" disabled={busy || !override?.override} onClick={reset}>Вернуть тег из настроек</Button>
        </div>
      </CardContent>
    </Card>
  );
}
