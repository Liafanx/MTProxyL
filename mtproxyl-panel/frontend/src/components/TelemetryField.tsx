import { StatusBadge } from '@/components/StatusBadge';
import { fieldMeta, formatFieldValue, isKnownField } from '@/lib/telemetryLabels';

interface TelemetryFieldProps {
  fieldKey: string;
  value: unknown;
  /** Плитка с рамкой (сетки состояний) или строка списка. */
  variant?: 'tile' | 'row';
}

/**
 * Одно поле телеметрии: русская подпись, форматированное значение и пояснение.
 *
 * Разделы выводили сырые ключи движка, поэтому по экрану было непонятно, что
 * означает число и хорошо ли оно. Незнакомые поля показываются машинным
 * именем — молча выдумывать перевод хуже.
 */
export function TelemetryField({ fieldKey, value, variant = 'tile' }: TelemetryFieldProps) {
  const meta = fieldMeta(fieldKey);
  const unknown = !isKnownField(fieldKey);

  const rendered =
    typeof value === 'boolean' ? (
      <StatusBadge status={value} />
    ) : (
      <span className="text-sm text-text-primary font-medium">
        {formatFieldValue(fieldKey, value)}
      </span>
    );

  if (variant === 'row') {
    return (
      <div className="flex items-start justify-between gap-4 py-1">
        <div className="min-w-0">
          <span className={unknown ? 'text-sm text-text-secondary font-mono' : 'text-sm text-text-secondary'}>
            {meta.label}
          </span>
          {meta.hint && <div className="text-xs text-text-secondary/70">{meta.hint}</div>}
        </div>
        <div className="text-right shrink-0">{rendered}</div>
      </div>
    );
  }

  return (
    <div
      className="bg-surface border border-border rounded-lg p-3 min-h-[44px] flex flex-col items-center justify-center gap-1.5"
      title={meta.hint ?? fieldKey}
    >
      <span
        className={
          unknown
            ? 'text-xs text-text-secondary text-center leading-tight font-mono'
            : 'text-xs text-text-secondary text-center leading-tight'
        }
      >
        {meta.label}
      </span>
      {rendered}
    </div>
  );
}
