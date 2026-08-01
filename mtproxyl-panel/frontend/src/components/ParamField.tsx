import { Input } from '@/components/ui/input';

/** Параметр MTProxyL с валидатором из его каталога. */
export interface CatalogParam {
  key: string;
  validator: string;
  description: string;
  value: string;
}

/**
 * Подбирает поле ввода по валидатору, пришедшему от MTProxyL.
 *
 * Правила проверки живут в bash-каталоге, поэтому интерфейс их не дублирует,
 * а выводит из строки валидатора — иначе они разъезжались бы при изменении
 * каталога.
 */
export function ParamField({
  param,
  value,
  onChange,
}: {
  param: CatalogParam;
  value: string;
  onChange: (v: string) => void;
}) {
  const selectClass =
    'rounded border border-border bg-surface px-2 py-1.5 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-accent/50';

  if (param.validator === 'bool') {
    return (
      <select value={value} onChange={(e) => onChange(e.target.value)} className={selectClass}>
        <option value="true">включено</option>
        <option value="false">выключено</option>
      </select>
    );
  }

  if (param.validator.startsWith('enum:')) {
    const options = param.validator.slice('enum:'.length).split(',');
    return (
      <select value={value} onChange={(e) => onChange(e.target.value)} className={selectClass}>
        {options.map((o) => (
          <option key={o} value={o}>
            {o}
          </option>
        ))}
      </select>
    );
  }

  const range = param.validator.match(/^range:(\d+):(\d+)$/);
  return (
    <Input
      value={value}
      type={range ? 'number' : 'text'}
      min={range?.[1]}
      max={range?.[2]}
      onChange={(e) => onChange(e.target.value)}
      className="max-w-[260px]"
    />
  );
}
