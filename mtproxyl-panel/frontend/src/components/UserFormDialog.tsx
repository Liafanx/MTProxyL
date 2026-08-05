import { useState, useEffect, FormEvent } from 'react';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

interface UserFormData {
  username: string;
  secret?: string;
  user_ad_tag?: string;
  max_tcp_conns?: number | '';
  expiration_rfc3339?: string;
  data_quota_bytes?: number | '';
  max_unique_ips?: number | '';
}

interface UserFormDialogProps {
  open: boolean;
  onClose: () => void;
  onSubmit: (data: Record<string, unknown>) => Promise<void>;
  initialData?: Partial<UserFormData>;
  mode: 'create' | 'edit';
  /**
   * Действующий секрет пользователя.
   *
   * Список пользователей его не отдаёт — он есть только внутри ссылок
   * tg://, поэтому вызывающий достаёт его оттуда. Поле ввода остаётся
   * пустым (пустое = «оставить как есть»), а текущее значение показывается
   * рядом, только для чтения: иначе форма выглядит так, будто секрет
   * потерялся.
   */
  currentSecret?: string;
  /**
   * В режиме Manager пользователями владеет MTProxyL, а он умеет только
   * перевыпустить секрет — задать произвольный при правке нельзя. Поле ввода
   * в этом случае заменяется на явный флажок: иначе форма обещает то, чего
   * не сделает.
   */
  secretRotateOnly?: boolean;
}

/** Байты трудно читать глазами — показываем, сколько это на самом деле. */
function quotaHint(value: number | '' | undefined): string {
  const n = Number(value);
  if (!value || !Number.isFinite(n) || n <= 0) return 'Пустое поле или 0 — без ограничения.';
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `Это ${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}.`;
}

const emptyForm: UserFormData = {
  username: '',
  secret: '',
  user_ad_tag: '',
  max_tcp_conns: '',
  expiration_rfc3339: '',
  data_quota_bytes: '',
  max_unique_ips: '',
};

export function UserFormDialog({
  open,
  onClose,
  onSubmit,
  initialData,
  mode,
  currentSecret,
  secretRotateOnly,
}: UserFormDialogProps) {
  const [form, setForm] = useState<UserFormData>(emptyForm);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [secretShown, setSecretShown] = useState(false);

  useEffect(() => {
    if (open) {
      const init = { ...emptyForm, ...initialData };
      // Treat 0 as "not set" for numeric limit fields so the form shows empty
      // and PATCH will not send 0 (which telemt interprets as "block user")
      if (init.max_tcp_conns === 0) init.max_tcp_conns = '';
      if (init.data_quota_bytes === 0) init.data_quota_bytes = '';
      if (init.max_unique_ips === 0) init.max_unique_ips = '';
      setForm(init);
      setError('');
      setSecretShown(false);
    }
  }, [open, initialData]);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError('');

    try {
      const payload: Record<string, unknown> = {};

      if (mode === 'create') {
        payload.username = form.username;
      }
      if (form.secret) payload.secret = form.secret;
      if (form.user_ad_tag) payload.user_ad_tag = form.user_ad_tag;
      if (form.max_tcp_conns !== '' && form.max_tcp_conns !== undefined && Number(form.max_tcp_conns) > 0) {
        payload.max_tcp_conns = Number(form.max_tcp_conns);
      }
      if (form.expiration_rfc3339) payload.expiration_rfc3339 = form.expiration_rfc3339;
      if (form.data_quota_bytes !== '' && form.data_quota_bytes !== undefined && Number(form.data_quota_bytes) > 0) {
        payload.data_quota_bytes = Number(form.data_quota_bytes);
      }
      if (form.max_unique_ips !== '' && form.max_unique_ips !== undefined && Number(form.max_unique_ips) > 0) {
        payload.max_unique_ips = Number(form.max_unique_ips);
      }

      await onSubmit(payload);
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Ошибка');
    } finally {
      setLoading(false);
    }
  };

  const set = (key: keyof UserFormData) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((prev) => ({ ...prev, [key]: e.target.value }));

  return (
    <Dialog open={open} onClose={onClose}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{mode === 'create' ? 'Создание пользователя' : 'Редактирование пользователя'}</DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="space-y-4 py-4">
          {mode === 'create' && (
            <div className="space-y-1.5">
              <Label htmlFor="username">Имя пользователя *</Label>
              <Input
                id="username"
                value={form.username}
                onChange={set('username')}
                placeholder="user1"
                required
                pattern="[A-Za-z0-9_.\-]+"
              />
              <p className="text-xs text-text-secondary">
                Латиница, цифры, точка, дефис и подчёркивание.
              </p>
            </div>
          )}

          <div className="space-y-1.5">
            <Label htmlFor="secret">Секрет</Label>
            {mode === 'edit' && currentSecret && (
              <div className="flex items-center gap-2">
                <code className="flex-1 min-w-0 truncate rounded border border-border bg-background px-2 py-1.5 text-xs font-mono text-text-secondary">
                  {secretShown ? currentSecret : '•'.repeat(32)}
                </code>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  onClick={() => setSecretShown((v) => !v)}
                >
                  {secretShown ? 'Скрыть' : 'Показать'}
                </Button>
              </div>
            )}
            {mode === 'edit' && secretRotateOnly ? (
              <>
                <label className="flex items-center gap-2 text-sm text-text-primary cursor-pointer">
                  <input
                    type="checkbox"
                    checked={Boolean(form.secret)}
                    onChange={(e) =>
                      setForm((prev) => ({ ...prev, secret: e.target.checked ? 'rotate' : '' }))
                    }
                    className="accent-[var(--color-accent,#3b82f6)]"
                  />
                  Перевыпустить секрет
                </label>
                <p className="text-xs text-text-secondary">
                  MTProxyL сгенерирует новый секрет сам — задать свой при правке нельзя.
                  После перевыпуска старые ссылки перестанут работать.
                </p>
              </>
            ) : (
              <>
                <Input
                  id="secret"
                  value={form.secret}
                  onChange={set('secret')}
                  placeholder={mode === 'edit' ? 'оставьте пустым — секрет не изменится' : 'создастся автоматически'}
                  pattern="[0-9a-fA-F]{32}"
                />
                <p className="text-xs text-text-secondary">
                  {mode === 'edit'
                    ? 'Новый секрет — 32 шестнадцатеричных символа. После смены старые ссылки перестанут работать.'
                    : '32 шестнадцатеричных символа. Пустое поле — секрет сгенерируется сам.'}
                </p>
              </>
            )}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="ad_tag">Рекламная метка</Label>
            <Input
              id="ad_tag"
              value={form.user_ad_tag}
              onChange={set('user_ad_tag')}
              placeholder="необязательно"
              pattern="[0-9a-fA-F]{32}"
            />
            <p className="text-xs text-text-secondary">
              32 шестнадцатеричных символа от @MTProxybot — только для этого пользователя.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="max_tcp">Макс. TCP-соединений</Label>
              <Input
                id="max_tcp"
                type="number"
                value={form.max_tcp_conns}
                onChange={set('max_tcp_conns')}
                min={0}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="max_ips">Макс. уникальных IP</Label>
              <Input
                id="max_ips"
                type="number"
                value={form.max_unique_ips}
                onChange={set('max_unique_ips')}
                min={0}
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="quota">Квота трафика, байт</Label>
            <Input
              id="quota"
              type="number"
              value={form.data_quota_bytes}
              onChange={set('data_quota_bytes')}
              min={0}
              placeholder="без ограничения"
            />
            <p className="text-xs text-text-secondary">
              {quotaHint(form.data_quota_bytes)}
            </p>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="expiration">Действует до</Label>
            <Input
              id="expiration"
              value={form.expiration_rfc3339}
              onChange={set('expiration_rfc3339')}
              placeholder="2026-12-31T23:59:59Z"
            />
            <p className="text-xs text-text-secondary">
              Формат RFC3339: ГГГГ-ММ-ДДTЧЧ:ММ:ССZ. Пустое поле — бессрочно.
            </p>
          </div>

          {error && <p className="text-sm text-danger">{error}</p>}

          <DialogFooter>
            <Button variant="outline" type="button" onClick={onClose} disabled={loading}>
              Отмена
            </Button>
            <Button type="submit" disabled={loading}>
              {loading ? 'Сохранение…' : mode === 'create' ? 'Создать' : 'Сохранить'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
