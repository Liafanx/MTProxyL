import type { HistoryPoint } from '@/lib/api';
import { formatNumber } from '@/lib/utils';
import { niceScaleTicks } from '@/lib/history';

const W = 760;
const H = 230;
const PAD = 18;

interface LoadChartProps {
  connections: HistoryPoint[];
  activeUsers: HistoryPoint[];
  windowSecs?: number;
  label: string;
  emptyLabel: string;
}

function pathOf(points: Array<{ x: number; y: number }>): string {
  return points.map((p, i) => `${i === 0 ? 'M' : 'L'}${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ');
}

/** Две линии за окно: текущие соединения (заливка) и активные пользователи. */
export function LoadChart({ connections, activeUsers, windowSecs = 1800, label, emptyLabel }: LoadChartProps) {
  const latestTs = Math.max(
    0,
    connections.length ? connections[connections.length - 1].ts : 0,
    activeUsers.length ? activeUsers[activeUsers.length - 1].ts : 0,
  );
  const startTs = latestTs - windowSecs;
  const maxValue = Math.max(1, ...connections.map((p) => p.v), ...activeUsers.map((p) => p.v));
  const ticks = niceScaleTicks(maxValue);
  const maximum = ticks[0];
  const empty = connections.length < 2 && activeUsers.length < 2;

  const project = (points: HistoryPoint[]) =>
    points
      .filter((p) => p.ts >= startTs)
      .map((p) => ({
        x: Math.max(0, Math.min(W, ((p.ts - startTs) / windowSecs) * W)),
        y: PAD + (1 - p.v / Math.max(1, maximum)) * (H - PAD * 2),
      }));

  const connPts = project(connections);
  const userPts = project(activeUsers);
  const baseline = H - PAD;
  const connPath = pathOf(connPts);

  return (
    <div className="relative">
      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        className="h-[190px] w-full md:h-[230px]"
        role="img"
        aria-label={`${label}. 0–${formatNumber(maximum)}`}
      >
        <defs>
          <linearGradient id="load-chart-area" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0" stopColor="rgb(var(--accent))" stopOpacity="0.22" />
            <stop offset="1" stopColor="rgb(var(--accent))" stopOpacity="0.02" />
          </linearGradient>
        </defs>
        {ticks.map((tick, i) => {
          const y = PAD + (i / Math.max(1, ticks.length - 1)) * (H - PAD * 2);
          return (
            <line
              key={tick}
              x1={0}
              x2={W}
              y1={y}
              y2={y}
              stroke="rgb(var(--border))"
              strokeWidth={1}
              strokeDasharray={i === ticks.length - 1 ? undefined : '3 5'}
              vectorEffect="non-scaling-stroke"
            />
          );
        })}
        {connPts.length > 1 && (
          <path
            d={`${connPath} L${connPts[connPts.length - 1].x.toFixed(1)},${baseline} L${connPts[0].x.toFixed(1)},${baseline} Z`}
            fill="url(#load-chart-area)"
          />
        )}
        {connPts.length > 1 && (
          <path
            d={connPath}
            fill="none"
            stroke="rgb(var(--accent))"
            strokeWidth={2.25}
            strokeLinejoin="round"
            strokeLinecap="round"
            vectorEffect="non-scaling-stroke"
          />
        )}
        {userPts.length > 1 && (
          <path
            d={pathOf(userPts)}
            fill="none"
            stroke="rgb(var(--ok))"
            strokeWidth={1.75}
            strokeOpacity={0.78}
            strokeLinejoin="round"
            strokeLinecap="round"
            vectorEffect="non-scaling-stroke"
          />
        )}
      </svg>
      {connPts.length > 1 && <EndDot point={connPts[connPts.length - 1]} tone="accent" size={7} />}
      {userPts.length > 1 && <EndDot point={userPts[userPts.length - 1]} tone="ok" size={6} />}
      {!empty && <div className="pointer-events-none absolute inset-y-[7.8%] left-0 flex flex-col justify-between" aria-hidden="true">
        {ticks.map((tick) => (
          <span key={tick} className="rounded bg-surface/80 px-1 font-mono text-[10px] leading-none tabular-nums text-text-faint">
            {formatNumber(tick)}
          </span>
        ))}
      </div>}
      {empty && (
        <div className="absolute inset-0 flex items-center justify-center text-meta text-text-muted">{emptyLabel}</div>
      )}
    </div>
  );
}

function EndDot({ point, tone, size }: { point: { x: number; y: number }; tone: 'accent' | 'ok'; size: number }) {
  return (
    <span
      aria-hidden="true"
      className={tone === 'accent' ? 'absolute rounded-full bg-accent' : 'absolute rounded-full bg-ok'}
      style={{
        width: size,
        height: size,
        left: `calc(${(point.x / W) * 100}% - ${size / 2}px)`,
        top: `calc(${(point.y / H) * 100}% - ${size / 2}px)`,
        boxShadow: '0 0 0 2px rgb(var(--surface))',
      }}
    />
  );
}
