import { cn } from '@/lib/utils';
import { formatBytes } from '@/lib/utils';

interface QuotaBarProps {
  used: number;
  limit: number;
  className?: string;
}

export function QuotaBar({ used, limit, className }: QuotaBarProps) {
  const pct = limit > 0 ? (used / limit) * 100 : 0;
  const clamped = Math.min(100, Math.max(0, pct));
  const barColor = pct >= 100 ? 'bg-bar-fill-full' : pct >= 80 ? 'bg-bar-fill-warn' : 'bg-bar-fill';

  return (
    <div className={cn('flex flex-col gap-1 min-w-[110px]', className)}>
      <span className="text-xs whitespace-nowrap tabular-nums">
        {formatBytes(used)} / {formatBytes(limit)}
      </span>
      <div className="flex items-center gap-1.5">
        <div className="h-1.5 flex-1 rounded-full bg-bar-track overflow-hidden">
          <div className={cn('h-full rounded-full', barColor)} style={{ width: `${clamped}%` }} />
        </div>
        <span className="text-[10px] text-text-muted tabular-nums w-9 text-right">
          {Math.round(pct)}%
        </span>
      </div>
    </div>
  );
}
