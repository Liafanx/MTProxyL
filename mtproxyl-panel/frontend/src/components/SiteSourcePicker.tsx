const SITE_SOURCE_LABELS: Record<string, string> = {
  stub: 'Заглушка «сайт недоступен»',
  filemanager: 'Файловый менеджер',
  catrunner: 'Мини-игра Cat Runner',
  mekorunner: 'Мини-игра MEKO Runner',
};

export function siteSourceLabel(value: string = ''): string {
  if (SITE_SOURCE_LABELS[value]) return SITE_SOURCE_LABELS[value];
  if (value.startsWith('http')) return `Свой сайт: ${value}`;
  if (value.startsWith('/')) return `Свой сайт из папки: ${value}`;
  return value;
}

export function SiteSourcePicker({
  value,
  onChange,
  disabled = false,
}: {
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
}) {
  const isUrl = value.startsWith('http');
  const isPath = value.startsWith('/');
  const kind = isUrl ? 'url' : isPath ? 'path' : value || 'stub';

  const pick = (next: string) => {
    if (next === 'url') return onChange('https://');
    if (next === 'path') return onChange('/var/www/');
    onChange(next);
  };

  return (
    <div className="space-y-2">
      <select
        value={kind}
        onChange={(event) => pick(event.target.value)}
        disabled={disabled}
        className="rounded border border-border bg-surface px-2 py-1.5 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-accent/50 max-w-[260px] disabled:opacity-50"
      >
        {Object.entries(SITE_SOURCE_LABELS).map(([key, label]) => (
          <option key={key} value={key}>
            {label}
          </option>
        ))}
        <option value="url">Свой сайт по ссылке</option>
        <option value="path">Свой сайт из папки на сервере</option>
      </select>
      {(isUrl || isPath) && (
        <>
          <input
            value={value}
            onChange={(event) => onChange(event.target.value)}
            disabled={disabled}
            placeholder={isPath ? '/var/www/some.name.ru' : 'https://example.com/index.html'}
            spellCheck={false}
            className="w-full max-w-[260px] rounded border border-border bg-surface px-2 py-1.5 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-accent/50 disabled:opacity-50"
          />
          {isPath && (
            <div className="text-xs text-text-secondary max-w-[260px]">
              Папка с index.html на этом сервере — скопируется целиком.
            </div>
          )}
        </>
      )}
    </div>
  );
}
