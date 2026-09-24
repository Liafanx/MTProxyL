import { formatBytes } from '@/lib/utils';
import type { TrafficHistoryPoint } from '@/lib/api';

interface TimeBarsProps {
  points: TrafficHistoryPoint[];
  from: number;
  to: number;
  emptyLabel?: string;
  height?: number;
}

const TIER_SECS = { '15m': 900, '1h': 3600, '1d': 86400 } as const;

/** Столбцы по времени: ширина столбца — размер корзины, высота — байты. */
export function TimeBars({ points, from, to, emptyLabel = 'Данных пока нет', height = 112 }: TimeBarsProps) {
  const width = 720;
  const max = Math.max(0, ...points.map((p) => p.v));
  const span = Math.max(1, to - from);
  if (points.length === 0 || max === 0) {
    return <div className="flex h-28 items-center justify-center rounded-lg bg-bg text-meta text-text-muted">{emptyLabel}</div>;
  }
  return (
    <div className="relative overflow-hidden rounded-lg bg-bg">
      <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" className="w-full" style={{ height }} role="img" aria-label="Трафик по времени">
        <defs>
          <linearGradient id="time-bars-fill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0" stopColor="rgb(var(--accent))" stopOpacity="0.85" />
            <stop offset="1" stopColor="rgb(var(--accent))" stopOpacity="0.18" />
          </linearGradient>
        </defs>
        {[0.25, 0.5, 0.75].map((ratio) => (
          <line key={ratio} x1="0" x2={width} y1={height * ratio} y2={height * ratio} stroke="rgb(var(--border))" strokeWidth="1" vectorEffect="non-scaling-stroke" />
        ))}
        {points.map((p) => {
          if (p.v <= 0) return null;
          const secs = TIER_SECS[p.tier] ?? 900;
          const barWidth = Math.max(1, Math.min(22, (secs / span) * width * 0.72));
          const x = Math.max(0, Math.min(width - barWidth, ((p.ts - from) / span) * width));
          const barHeight = Math.max(1, (p.v / max) * (height - 8));
          return <rect key={`${p.tier}:${p.ts}`} x={x} y={height - barHeight} width={barWidth} height={barHeight} rx={Math.min(2, barWidth / 2)} fill="url(#time-bars-fill)" />;
        })}
      </svg>
      <span className="pointer-events-none absolute right-2 top-1.5 rounded bg-bg/80 px-1 font-mono text-[10px] tabular-nums text-text-muted">{formatBytes(max)}</span>
      <span className="pointer-events-none absolute bottom-1.5 right-2 text-[9px] text-text-faint">UTC</span>
    </div>
  );
}
