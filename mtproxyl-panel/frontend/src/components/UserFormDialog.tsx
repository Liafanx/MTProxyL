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
  /** Скорость в форме — Мбит/с; в API уходит в бит/с. */
  rate_up_mbps?: number | '';
  rate_down_mbps?: number | '';
  notes?: string;
  /** Лимит устройств mtdd. */
  max_devices?: number | '';
  /** Персональный FakeTLS-домен mtdd; пусто — общий. */
  tls_domain?: string;
  /** Пользователь-ловушка mtdd. */
  canary?: boolean;
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
  /** Переименование выполняет MTProxyL: API самого telemt его не поддерживает. */
  usernameEditable?: boolean;
  /** Текущая скорость в бит/с — для правки. */
  initialRate?: { up: number; down: number };
  /** Заметки хранит MTProxyL в режиме Manager; у движка такого поля нет. */
  notesEditable?: boolean;
  /** false — движок не поддерживает метку на пользователя (mtdd): поле скрыто. */
  adTagEditable?: boolean;
  /** Движок: у mtdd свои пределы полей и лимит устройств. */
  engine?: string;
  /** Текущий лимит устройств mtdd (0 — без лимита). */
  initialDevices?: number;
  /** Текущий персональный домен mtdd (пусто — общий). */
  initialDomain?: string;
  /** Текущая ловушка mtdd. */
  initialCanary?: boolean;
}

// Пределы API mtdd 1.0.0 (src/config.cpp, users API).
const MTDD_MIN_RATE_BPS = 8192;
const MTDD_MAX_COUNT = 1_000_000;
const MTDD_NOTE_BYTES = 256;
const MTDD_MAX_QUOTA = 2 ** 60;

function utf8Bytes(s: string): number {
  return new TextEncoder().encode(s).length;
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
  rate_up_mbps: '',
  rate_down_mbps: '',
  notes: '',
  max_devices: '',
};

const MBIT = 1_000_000;

/** «Без ограничения» или пусто → 0, иначе Мбит/с → бит/с. */
function mbpsToBps(v: number | '' | undefined): number {
  const n = Number(v);
  return v === '' || v === undefined || !Number.isFinite(n) || n <= 0 ? 0 : Math.round(n * MBIT);
}

export function UserFormDialog({
  open,
  onClose,
  onSubmit,
  initialData,
  mode,
  currentSecret,
  secretRotateOnly,
  usernameEditable = true,
  initialRate,
  notesEditable,
  adTagEditable = true,
  engine = 'telemt',
  initialDevices,
  initialDomain,
  initialCanary,
}: UserFormDialogProps) {
  const isMtdd = engine === 'mtdd';
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
      init.rate_up_mbps = initialRate?.up ? initialRate.up / MBIT : '';
      init.rate_down_mbps = initialRate?.down ? initialRate.down / MBIT : '';
      init.max_devices = initialDevices ? initialDevices : '';
      init.tls_domain = initialDomain ?? '';
      init.canary = Boolean(initialCanary);
      setForm(init);
      setError('');
      setSecretShown(false);
    }
  }, [open, initialData, initialRate, initialDevices, initialDomain, initialCanary]);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError('');

    try {
      const payload: Record<string, unknown> = {};

      // У mtdd пределы уже, чем у telemt: проверяем до отправки, чтобы не
      // получить отказ API на полпути (лимиты, затем скорость, затем заметка).
      if (isMtdd) {
        for (const [v, name] of [[form.max_tcp_conns, 'Соединений'], [form.max_unique_ips, 'Уникальных IP'], [form.max_devices, 'Устройств']] as const) {
          if (v !== '' && v !== undefined && Number(v) > MTDD_MAX_COUNT) throw new Error(`${name}: у mtdd не больше 1 000 000`);
        }
        if (Number(form.data_quota_bytes) > MTDD_MAX_QUOTA) throw new Error('Квота: у mtdd не больше 2^60 байт');
        for (const [v, name] of [[form.rate_down_mbps, 'к клиенту'], [form.rate_up_mbps, 'от клиента']] as const) {
          const bps = mbpsToBps(v);
          if (bps > 0 && bps < MTDD_MIN_RATE_BPS) throw new Error(`Скорость ${name}: у mtdd не меньше 8192 бит/с (0.0082 Мбит/с)`);
        }
        const dom = String(form.tls_domain ?? '').trim().toLowerCase();
        if (dom && (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/.test(dom) || dom.length > 253 || !dom.includes('.'))) {
          throw new Error('Домен: DNS-имя в нижнем регистре, например example.org');
        }
        if (notesEditable && utf8Bytes(String(form.notes ?? '').trim()) > MTDD_NOTE_BYTES) {
          throw new Error('Заметка: у mtdd не длиннее 256 байт (≈128 букв кириллицы)');
        }
      }

      const username = form.username.trim();
      if (mode === 'create' || username !== String(initialData?.username ?? '')) {
        payload.username = username;
      }
      if (form.secret) payload.secret = form.secret;
      // Пустое поле у telemt — ошибка «must be exactly 32 hex characters»,
      // снимает метку только null. Ключ шлём, лишь когда он реально изменился:
      // отсутствие ключа означает «оставить как есть».
      const adTag = String(form.user_ad_tag ?? '').trim();
      if (!adTagEditable) {
        // поле скрыто — метку не трогаем
      } else if (adTag) payload.user_ad_tag = adTag;
      else if (initialData?.user_ad_tag) payload.user_ad_tag = null;
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

      // Скорость шлём, только если её задали или сняли: так её не трогают
      // движки старше 3.4.1, где этих полей нет.
      const up = mbpsToBps(form.rate_up_mbps);
      const down = mbpsToBps(form.rate_down_mbps);
      const prevUp = initialRate?.up ?? 0;
      const prevDown = initialRate?.down ?? 0;
      if (up !== prevUp || down !== prevDown) {
        payload.rate_limit_up_bps = up > 0 ? up : null;
        payload.rate_limit_down_bps = down > 0 ? down : null;
      }

      if (notesEditable) {
        const notes = String(form.notes ?? '').trim();
        if (notes !== String(initialData?.notes ?? '')) payload.notes = notes;
      }

      if (isMtdd) {
        const dev = form.max_devices === '' || form.max_devices === undefined ? 0 : Math.max(0, Math.floor(Number(form.max_devices)));
        if (dev !== (initialDevices ?? 0)) payload.max_devices = dev;
        const dom = String(form.tls_domain ?? '').trim().toLowerCase();
        if (dom !== String(initialDomain ?? '')) payload.tls_domain = dom;
        if (Boolean(form.canary) !== Boolean(initialCanary)) payload.canary = Boolean(form.canary);
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
          <div className="space-y-1.5">
            <Label htmlFor="username">Имя пользователя *</Label>
            <Input
              id="username"
              value={form.username}
              onChange={set('username')}
              placeholder="user1"
              required
              maxLength={64}
              pattern="[A-Za-z0-9_.\-]+"
              disabled={mode === 'edit' && !usernameEditable}
            />
            <p className="text-xs text-text-secondary">
              {mode === 'edit' && !usernameEditable
                ? 'Переименование доступно при включённой интеграции с MTProxyL.'
                : 'Латиница, цифры, точка, дефис и подчёркивание.'}
            </p>
          </div>

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

          {adTagEditable && <div className="space-y-1.5">
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
          </div>}

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="max_tcp">Макс. TCP-соединений</Label>
              <Input
                id="max_tcp"
                type="number"
                value={form.max_tcp_conns}
                onChange={set('max_tcp_conns')}
                min={0}
                max={isMtdd ? MTDD_MAX_COUNT : undefined}
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
                max={isMtdd ? MTDD_MAX_COUNT : undefined}
              />
            </div>
          </div>

          {isMtdd && (
            <div className="space-y-1.5">
              <Label htmlFor="max_devices">Лимит устройств</Label>
              <Input
                id="max_devices"
                type="number"
                value={form.max_devices}
                onChange={set('max_devices')}
                min={0}
                max={MTDD_MAX_COUNT}
                placeholder="без ограничения"
              />
              <p className="text-xs text-text-secondary">
                Сколько разных устройств может работать по ссылке (1–1 000 000). Пусто или 0 — без ограничения.
              </p>
            </div>
          )}

          {isMtdd && (
            <div className="space-y-1.5">
              <Label htmlFor="tls_domain">Свой домен FakeTLS</Label>
              <Input
                id="tls_domain"
                value={form.tls_domain ?? ''}
                onChange={set('tls_domain')}
                placeholder="example.org"
                maxLength={253}
              />
              <p className="text-xs text-text-secondary">
                Пусто — общий домен сервера. С домена идёт ссылка и маскировка пользователя.
              </p>
            </div>
          )}

          {isMtdd && (
            <label className="flex items-center gap-2 text-sm text-text-primary cursor-pointer">
              <input
                type="checkbox"
                checked={Boolean(form.canary)}
                onChange={(e) => setForm((prev) => ({ ...prev, canary: e.target.checked }))}
                className="accent-[var(--color-accent,#3b82f6)]"
              />
              Пользователь-ловушка (каждое подключение помечается как canary)
            </label>
          )}

          <div className="space-y-1.5">
            <Label htmlFor="quota">Квота трафика, байт</Label>
            <Input
              id="quota"
              type="number"
              value={form.data_quota_bytes}
              onChange={set('data_quota_bytes')}
              min={0}
              max={isMtdd ? MTDD_MAX_QUOTA : undefined}
              placeholder="без ограничения"
            />
            <p className="text-xs text-text-secondary">
              {quotaHint(form.data_quota_bytes)}
            </p>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="rate_down">Скорость к клиенту, Мбит/с</Label>
              <Input
                id="rate_down"
                type="number"
                step="0.1"
                value={form.rate_down_mbps}
                onChange={set('rate_down_mbps')}
                min={0}
                placeholder="без ограничения"
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="rate_up">Скорость от клиента, Мбит/с</Label>
              <Input
                id="rate_up"
                type="number"
                step="0.1"
                value={form.rate_up_mbps}
                onChange={set('rate_up_mbps')}
                min={0}
                placeholder="без ограничения"
              />
            </div>
          </div>
          <p className="-mt-2 text-xs text-text-secondary">
            {isMtdd
              ? 'Пусто или 0 — без ограничения. У mtdd не меньше 8192 бит/с (0.0082 Мбит/с).'
              : 'Нужен telemt 3.4.1+. Пусто или 0 — без ограничения.'}
          </p>

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

          {notesEditable && (
            <div className="space-y-1.5">
              <Label htmlFor="notes">Заметка</Label>
              <Input
                id="notes"
                value={form.notes}
                onChange={set('notes')}
                placeholder="кому выдан, оплата — видно только вам"
                maxLength={200}
              />
              {isMtdd && (
                <p className="text-xs text-text-secondary">
                  У mtdd до 256 байт (≈128 букв кириллицы): {utf8Bytes(String(form.notes ?? '').trim())} / 256.
                </p>
              )}
            </div>
          )}

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
