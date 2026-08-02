import { useState, useEffect } from 'react';
import { Settings, Save, RotateCw, X, Info, AlertTriangle } from 'lucide-react';
import { Link } from 'react-router-dom';
import { panelApi } from '@/lib/api';
import { QuickSettingsTab } from '@/components/config/QuickSettingsTab';
import { AdvancedEditorTab } from '@/components/config/AdvancedEditorTab';
import { useMtproxyl } from '@/hooks/useMtproxyl';

type Tab = 'quick' | 'advanced';

interface ConfigData {
  content: string;
  path: string;
  hash: string;
  mode: 'api' | 'file';
}

export function ConfigPage() {
  const [activeTab, setActiveTab] = useState<Tab>('quick');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [originalContent, setOriginalContent] = useState('');
  const [currentContent, setCurrentContent] = useState('');
  const [configPath, setConfigPath] = useState('');
  const [hasChanges, setHasChanges] = useState(false);
  const [mode, setMode] = useState<'api' | 'file'>('api');
  const [configHash, setConfigHash] = useState('');

  // В режиме manager конфигом движка владеет MTProxyL: он пересобирает
  // config.toml из своих настроек и экспертных правок. Правка здесь переживёт
  // только до ближайшей пересборки, поэтому об этом надо сказать прямо.
  const { enabled: mtproxylEnabled, mode: mtproxylMode } = useMtproxyl();
  const configOwnedByMtproxyl = mtproxylEnabled && mtproxylMode === 'manager';

  useEffect(() => {
    loadConfig();
  }, []);

  useEffect(() => {
    const handleBeforeUnload = (e: BeforeUnloadEvent) => {
      if (hasChanges) {
        e.preventDefault();
        e.returnValue = '';
      }
    };

    window.addEventListener('beforeunload', handleBeforeUnload);
    return () => window.removeEventListener('beforeunload', handleBeforeUnload);
  }, [hasChanges]);

  const loadConfig = async () => {
    try {
      setLoading(true);
      setError(null);
      const data = await panelApi.get<ConfigData>('/telemt/config/raw');
      setOriginalContent(data.content);
      setCurrentContent(data.content);
      setConfigPath(data.path);
      setMode(data.mode ?? 'file');
      setConfigHash(data.hash ?? '');
      setHasChanges(false);
    } catch (err: any) {
      setError(err.message || 'Не удалось загрузить конфиг');
    } finally {
      setLoading(false);
    }
  };

  const handleSave = async (restart: boolean) => {
    if (!hasChanges) return;
    if (configOwnedByMtproxyl) {
      // Не отправляем запрос, который заведомо не пройдёт: config.toml
      // примонтирован в контейнер только для чтения, и движок отвечает
      // «Device or resource busy».
      alert(
        'В режиме Manager движок не может записать свой конфиг: файл ' +
          'примонтирован в контейнер только для чтения.\n\n' +
          'Порт, домен и маскировку меняйте в «Настройках прокси», остальное — ' +
          'через «Экспертные параметры» (они переживут пересборку) или возьмите ' +
          'конфиг целиком в «Супер эксперте».',
      );
      return;
    }

    try {
      setSaving(true);
      setError(null);

      const result = await panelApi.post<{ new_hash?: string; restart_required?: boolean }>(
        '/telemt/config/save',
        { content: currentContent, hash: configHash, restart },
      );

      setOriginalContent(currentContent);
      setHasChanges(false);
      if (result?.new_hash) setConfigHash(result.new_hash);

      const restarted = restart || result?.restart_required;
      alert(restarted ? 'Конфиг сохранён, Telemt перезапускается…' : 'Конфиг сохранён');
    } catch (err: any) {
      if (err?.code === 'revision_conflict') {
        setError('Конфиг изменился на сервере, перезагружаем…');
        await loadConfig();
        alert(
          'Конфиг Telemt изменился с тех пор, как вы его открыли. Правки не сохранены — ' +
            'загружена актуальная версия.',
        );
        return;
      }
      setError(err.message || 'Не удалось сохранить конфиг');
      alert('Ошибка: ' + (err.message || 'Не удалось сохранить конфиг'));
    } finally {
      setSaving(false);
    }
  };

  const handleDiscard = () => {
    if (!hasChanges) return;
    if (confirm('Отменить все изменения?')) {
      setCurrentContent(originalContent);
      setHasChanges(false);
    }
  };

  const handleContentChange = (newContent: string) => {
    setCurrentContent(newContent);
    setHasChanges(newContent !== originalContent);
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="text-text-secondary">Загрузка конфигурации…</div>
      </div>
    );
  }

  if (error && !currentContent) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="text-red-500">{error}</div>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full">
      {configOwnedByMtproxyl && (
        <div className="px-4 py-3 bg-warning/10 border-b border-warning/30 text-sm flex items-start gap-2">
          <AlertTriangle className="w-4 h-4 shrink-0 mt-0.5 text-warning" />
          <div className="space-y-1 text-text-secondary">
            <p className="text-text-primary">
              В режиме Manager сохранение отсюда недоступно — только просмотр.
            </p>
            <p>
              Конфиг движка примонтирован в его контейнер только для чтения, поэтому telemt
              физически не может его записать: любая попытка возвращает «Device or resource
              busy». Владелец конфига здесь — MTProxyL, он пересобирает{' '}
              <code>config.toml</code> из своих настроек. Порт, домен и маскировку меняйте в{' '}
              <Link to="/proxy-settings" className="text-accent hover:underline">
                настройках прокси
              </Link>
              , остальное — через{' '}
              <Link to="/expert" className="text-accent hover:underline">
                экспертные параметры
              </Link>{' '}
              или возьмите конфиг под себя целиком в{' '}
              <Link to="/superexpert" className="text-accent hover:underline">
                супер эксперте
              </Link>
              .
            </p>
          </div>
        </div>
      )}
      {mode === 'api' && (
        <div className="px-4 py-3 bg-accent/10 border-b border-accent/20 text-sm flex items-start gap-2">
          <Info className="w-4 h-4 shrink-0 mt-0.5 text-accent" />
          <div className="space-y-1 text-text-secondary">
            <p className="text-text-primary">
              Значения читаются через API движка — показаны все, включая заводские.
            </p>
            <p>
              Поэтому в списке много строк, которых вы не задавали: это действующие значения
              telemt по умолчанию, а не что-то, что записала панель. Но при сохранении они
              будут записаны в конфиг явно и перестанут следовать за обновлениями движка —
              меняйте только то, что нужно. Чтобы работать с файлом как есть, задайте{' '}
              <code>config_edit_mode = "file"</code> в конфиге панели.
            </p>
          </div>
        </div>
      )}
      {/* Header */}
      <div className="flex flex-col gap-3 p-4 border-b border-border sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3 min-w-0">
          <Settings className="w-5 h-5 text-primary shrink-0" />
          <div className="min-w-0">
            <h1 className="text-lg font-semibold text-text-primary">Конфигурация Telemt</h1>
            <p className="text-sm text-text-secondary truncate">{configPath}</p>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2 shrink-0">
          {hasChanges && (
            <button
              onClick={handleDiscard}
              disabled={saving}
              className="px-3 py-1.5 text-sm rounded-lg border border-border hover:bg-surface-hover transition-colors flex items-center gap-2"
            >
              <X className="w-4 h-4" />
              Отменить
            </button>
          )}

          <button
            onClick={() => handleSave(false)}
            disabled={!hasChanges || saving || configOwnedByMtproxyl}
            className="px-3 py-1.5 text-sm rounded-lg bg-primary text-white hover:bg-primary/90 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-2"
          >
            <Save className="w-4 h-4" />
            {saving ? 'Сохранение…' : 'Сохранить'}
          </button>

          <button
            onClick={() => handleSave(true)}
            disabled={!hasChanges || saving || configOwnedByMtproxyl}
            className="px-3 py-1.5 text-sm rounded-lg bg-orange-600 text-white hover:bg-orange-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-2"
          >
            <RotateCw className="w-4 h-4" />
            {saving ? 'Сохранение…' : 'Сохранить и перезапустить'}
          </button>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex border-b border-border">
        <button
          onClick={() => setActiveTab('quick')}
          className={`px-4 py-2 text-sm font-medium transition-colors ${
            activeTab === 'quick'
              ? 'text-primary border-b-2 border-primary'
              : 'text-text-secondary hover:text-text-primary'
          }`}
        >
          Быстрые настройки
        </button>
        <button
          onClick={() => setActiveTab('advanced')}
          className={`px-4 py-2 text-sm font-medium transition-colors ${
            activeTab === 'advanced'
              ? 'text-primary border-b-2 border-primary'
              : 'text-text-secondary hover:text-text-primary'
          }`}
        >
          Редактор конфига
        </button>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-auto">
        {activeTab === 'quick' ? (
          <QuickSettingsTab
            content={currentContent}
            onChange={handleContentChange}
            mode={mode}
          />
        ) : (
          <AdvancedEditorTab
            content={currentContent}
            onChange={handleContentChange}
          />
        )}
      </div>

      {hasChanges && (
        <div className="px-4 py-2 bg-yellow-500/10 border-t border-yellow-500/20 text-sm text-yellow-600">
          Есть несохранённые изменения
        </div>
      )}
    </div>
  );
}
