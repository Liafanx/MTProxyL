import { ArrowDown, ArrowUp } from 'lucide-react';
import { Toggle } from '@/components/ui/toggle';

const CARRIERS = ['websocket', 'websocket-lanes', 'https-lanes', 'https'];

interface Props {
  /** Перебор через запятую, по порядку. */
  value: string;
  /** Основной carrier: движок сам ставит его последним, в списке его нет. */
  main: string;
  onChange: (next: string) => void;
  disabled?: boolean;
}

// Включённые идут сверху в порядке перебора, выключенные — под ними.
export function CarrierOrderPicker({ value, main, onChange, disabled }: Props) {
  const order = value.split(',').map((c) => c.trim()).filter((c) => CARRIERS.includes(c) && c !== main);
  const off = CARRIERS.filter((c) => c !== main && !order.includes(c));
  // Пустое значение CLI принимает словом none.
  const emit = (next: string[]) => onChange(next.join(',') || 'none');
  const move = (i: number, d: number) => {
    const next = [...order];
    [next[i], next[i + d]] = [next[i + d], next[i]];
    emit(next);
  };

  return (
    <div className="space-y-1.5 w-full sm:w-80">
      {order.map((c, i) => (
        <div key={c} className="flex items-center gap-2">
          <Toggle checked onChange={() => emit(order.filter((x) => x !== c))} disabled={disabled} aria-label={`Убрать ${c} из перебора`} />
          <span className="font-mono text-xs text-text-primary flex-1">{i + 1}. {c}</span>
          <button type="button" className="p-1 text-text-secondary hover:text-text-primary disabled:opacity-30" disabled={disabled || i === 0} onClick={() => move(i, -1)} aria-label="Выше">
            <ArrowUp size={14} />
          </button>
          <button type="button" className="p-1 text-text-secondary hover:text-text-primary disabled:opacity-30" disabled={disabled || i === order.length - 1} onClick={() => move(i, 1)} aria-label="Ниже">
            <ArrowDown size={14} />
          </button>
        </div>
      ))}
      {off.map((c) => (
        <div key={c} className="flex items-center gap-2">
          <Toggle checked={false} onChange={() => emit([...order, c])} disabled={disabled} aria-label={`Добавить ${c} в перебор`} />
          <span className="font-mono text-xs text-text-secondary flex-1">{c}</span>
        </div>
      ))}
      <div className="flex items-center gap-2 text-xs text-text-secondary">
        <span className="w-[42px] shrink-0 text-center">—</span>
        <span className="font-mono whitespace-nowrap">{order.length + 1}. {main}</span>
        <span className="whitespace-nowrap">— основной</span>
      </div>
    </div>
  );
}
