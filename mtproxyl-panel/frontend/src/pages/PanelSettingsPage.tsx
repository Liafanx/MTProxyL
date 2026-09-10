import { useEffect, useMemo, useRef, useState } from 'react';
import { Image, RotateCcw, Save, Trash2, Upload } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { ErrorAlert } from '@/components/ErrorAlert';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useBranding } from '@/hooks/useBranding';
import { brandingApi, DEFAULT_PANEL_BRANDING } from '@/lib/api';

const MAX_BACKGROUND_BYTES = 8 * 1024 * 1024;
const IMAGE_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);

interface TextSettings {
  panel_name: string;
  login_title: string;
  login_subtitle: string;
}

export function PanelSettingsPage() {
  const { branding, apply } = useBranding();
  const [form, setForm] = useState<TextSettings>({
    panel_name: branding.panel_name,
    login_title: branding.login_title,
    login_subtitle: branding.login_subtitle,
  });
  const [saving, setSaving] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    setForm({
      panel_name: branding.panel_name,
      login_title: branding.login_title,
      login_subtitle: branding.login_subtitle,
    });
  }, [branding.panel_name, branding.login_title, branding.login_subtitle]);

  const dirty = useMemo(
    () => form.panel_name.trim() !== branding.panel_name
      || form.login_title.trim() !== branding.login_title
      || form.login_subtitle.trim() !== branding.login_subtitle,
    [form, branding],
  );
  const backgroundURL = branding.has_background
    ? brandingApi.backgroundURL(branding.background_revision)
    : '';

  const set = (key: keyof TextSettings) => (event: React.ChangeEvent<HTMLInputElement>) => {
    setNotice('');
    setForm((previous) => ({ ...previous, [key]: event.target.value }));
  };

  const save = async () => {
    setSaving(true);
    setError('');
    setNotice('');
    try {
      const updated = await brandingApi.update({
        panel_name: form.panel_name.trim(),
        login_title: form.login_title.trim(),
        login_subtitle: form.login_subtitle.trim(),
      });
      apply(updated);
      setNotice('Настройки панели сохранены');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Не удалось сохранить настройки');
    } finally {
      setSaving(false);
    }
  };

  const upload = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    setError('');
    setNotice('');
    if (file.type && !IMAGE_TYPES.has(file.type)) {
      setError('Поддерживаются только PNG, JPEG и WebP');
      return;
    }
    if (file.size > MAX_BACKGROUND_BYTES) {
      setError('Изображение больше 8 МБ');
      return;
    }
    setUploading(true);
    try {
      const updated = await brandingApi.uploadBackground(file);
      apply(updated);
      setNotice('Фон страницы входа загружен');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Не удалось загрузить фон');
    } finally {
      setUploading(false);
    }
  };

  const removeBackground = async () => {
    setRemoving(true);
    setError('');
    setNotice('');
    try {
      const updated = await brandingApi.deleteBackground();
      apply(updated);
      setNotice('Фон страницы входа удалён');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Не удалось удалить фон');
    } finally {
      setRemoving(false);
    }
  };

  const restoreDefaults = () => {
    setForm({
      panel_name: DEFAULT_PANEL_BRANDING.panel_name,
      login_title: DEFAULT_PANEL_BRANDING.login_title,
      login_subtitle: DEFAULT_PANEL_BRANDING.login_subtitle,
    });
    setNotice('');
  };

  return (
    <div className="min-h-screen">
      <Header title="Настройки панели" />

      <div className="p-4 lg:p-6 space-y-4 max-w-4xl">
        {error && <ErrorAlert message={error} />}
        {notice && (
          <div className="bg-success/10 border border-success/30 rounded-lg p-3 text-sm text-text-primary">
            {notice}
          </div>
        )}

        <Card>
          <CardHeader>
            <CardTitle>Название и страница входа</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-1.5">
              <Label htmlFor="panel-name">Название панели</Label>
              <Input
                id="panel-name"
                value={form.panel_name}
                onChange={set('panel_name')}
                maxLength={80}
                required
              />
              <p className="text-xs text-text-secondary">
                Показывается в боковом меню, мобильной шапке и названии вкладки браузера.
              </p>
            </div>

            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-1.5">
                <Label htmlFor="login-title">Заголовок страницы входа</Label>
                <Input
                  id="login-title"
                  value={form.login_title}
                  onChange={set('login_title')}
                  maxLength={80}
                  required
                />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="login-subtitle">Подзаголовок страницы входа</Label>
                <Input
                  id="login-subtitle"
                  value={form.login_subtitle}
                  onChange={set('login_subtitle')}
                  maxLength={160}
                  placeholder="Можно оставить пустым"
                />
              </div>
            </div>

            <div className="flex flex-wrap gap-2 pt-2">
              <Button onClick={save} disabled={saving || !dirty || !form.panel_name.trim() || !form.login_title.trim()}>
                <Save size={16} className="mr-1.5" />
                {saving ? 'Сохранение…' : 'Сохранить'}
              </Button>
              <Button type="button" variant="outline" onClick={restoreDefaults} disabled={saving}>
                <RotateCcw size={16} className="mr-1.5" />
                Вернуть стандартный текст
              </Button>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Фон страницы входа</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <p className="text-sm text-text-secondary">
              PNG, JPEG или WebP, не больше 8 МБ. Изображение заполняет весь экран;
              панель добавляет затемнение, чтобы форма оставалась читаемой.
            </p>

            <div
              className="relative min-h-52 overflow-hidden rounded-lg border border-border bg-background bg-cover bg-center flex items-center justify-center"
              style={backgroundURL ? {
                backgroundImage: `linear-gradient(rgba(8, 11, 18, 0.62), rgba(8, 11, 18, 0.74)), url("${backgroundURL}")`,
              } : undefined}
            >
              <div className="text-center px-4">
                {backgroundURL ? (
                  <>
                    <div className="text-xl font-bold text-white drop-shadow">{form.login_title || branding.login_title}</div>
                    {form.login_subtitle && (
                      <div className="text-sm text-white/80 mt-1 drop-shadow">
                        {form.login_subtitle}
                      </div>
                    )}
                  </>
                ) : (
                  <div className="text-text-secondary flex flex-col items-center gap-2">
                    <Image size={32} />
                    Фон не загружен
                  </div>
                )}
              </div>
            </div>

            <input
              ref={inputRef}
              type="file"
              accept="image/png,image/jpeg,image/webp"
              onChange={upload}
              className="hidden"
            />
            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                variant="outline"
                onClick={() => inputRef.current?.click()}
                disabled={uploading || removing}
              >
                <Upload size={16} className="mr-1.5" />
                {uploading ? 'Загрузка…' : branding.has_background ? 'Заменить фон' : 'Загрузить фон'}
              </Button>
              {branding.has_background && (
                <Button
                  type="button"
                  variant="outline"
                  onClick={removeBackground}
                  disabled={uploading || removing}
                  className="text-danger hover:text-danger"
                >
                  <Trash2 size={16} className="mr-1.5" />
                  {removing ? 'Удаление…' : 'Удалить фон'}
                </Button>
              )}
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
