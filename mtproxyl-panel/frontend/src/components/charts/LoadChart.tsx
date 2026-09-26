import { useRef, useState } from 'react';
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

function pointTime(ts: number): string {
  return new Date(ts * 1000).toLocaleString('ru-RU', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  });
}

/** Две линии за окно: текущие соединения (заливка) и активные пользователи. */
export function LoadChart({ connections, activeUsers, windowSecs = 1800, label, emptyLabel }: LoadChartProps) {
  const [hoverTs, setHoverTs] = useState<number | null>(null);
  const [pinnedTs, setPinnedTs] = useState<number | null>(null);
  const touchStart = useRef<{ x: number; y: number } | null>(null);
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
  const timestamps = [...new Set([...connections, ...activeUsers]
    .filter((p) => p.ts >= startTs && p.ts <= latestTs)
    .map((p) => p.ts))].sort((a, b) => a - b);
  const selectedTs = (pinnedTs !== null && timestamps.includes(pinnedTs) ? pinnedTs : null)
    ?? (hoverTs !== null && timestamps.includes(hoverTs) ? hoverTs : null);
  const selectedX = selectedTs === null ? null : ((selectedTs - startTs) / windowSecs) * W;
  const selectedConn = selectedTs === null ? null : connections.find((p) => p.ts === selectedTs);
  const selectedUsers = selectedTs === null ? null : activeUsers.find((p) => p.ts === selectedTs);
  const pointY = (value: number) => PAD + (1 - value / Math.max(1, maximum)) * (H - PAD * 2);
  const selectAt = (clientX: number, element: HTMLDivElement, pin: boolean, touch = false) => {
    if (empty || timestamps.length === 0) return;
    const bounds = element.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (clientX - bounds.left) / bounds.width));
    const target = startTs + ratio * windowSecs;
    const nearest = timestamps.reduce((best, ts) => Math.abs(ts - target) < Math.abs(best - target) ? ts : best);
    if (pin) {
      setPinnedTs((previous) => previous === nearest ? null : nearest);
      setHoverTs(touch ? null : nearest);
    } else {
      setHoverTs(nearest);
    }
  };

  return (
    <div
      className={`relative ${empty ? '' : 'cursor-crosshair rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent'}`}
      role={empty ? undefined : 'button'}
      tabIndex={empty ? -1 : 0}
      aria-label={selectedTs === null
        ? `${label}. Наведите курсор или коснитесь графика, чтобы узнать значения; стрелки переключают точки.`
        : `${label}. ${pointTime(selectedTs)}: соединения ${selectedConn ? formatNumber(selectedConn.v) : 'нет данных'}, пользователи ${selectedUsers ? formatNumber(selectedUsers.v) : 'нет данных'}.`}
      onPointerMove={(event) => {
        if ((event.pointerType === 'mouse' || event.pointerType === 'pen') && pinnedTs === null) {
          selectAt(event.clientX, event.currentTarget, false);
        }
      }}
      onPointerLeave={() => setHoverTs(null)}
      onPointerDown={(event) => {
        if (event.pointerType === 'touch') {
          touchStart.current = { x: event.clientX, y: event.clientY };
        } else {
          selectAt(event.clientX, event.currentTarget, true);
        }
      }}
      onPointerUp={(event) => {
        if (event.pointerType !== 'touch' || !touchStart.current) return;
        const start = touchStart.current;
        touchStart.current = null;
        if (Math.abs(event.clientX - start.x) <= 10 && Math.abs(event.clientY - start.y) <= 10) {
          selectAt(event.clientX, event.currentTarget, true, true);
        }
      }}
      onPointerCancel={() => { touchStart.current = null; }}
      onFocus={() => { if (selectedTs === null && timestamps.length) setHoverTs(timestamps[timestamps.length - 1]); }}
      onBlur={() => setHoverTs(null)}
      onKeyDown={(event) => {
        if (empty || timestamps.length === 0) return;
        if (event.key === 'Escape') {
          setPinnedTs(null);
          setHoverTs(null);
        } else if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
          event.preventDefault();
          const index = timestamps.indexOf(selectedTs ?? timestamps[timestamps.length - 1]);
          const next = Math.max(0, Math.min(timestamps.length - 1, index + (event.key === 'ArrowLeft' ? -1 : 1)));
          setPinnedTs(timestamps[next]);
          setHoverTs(null);
        } else if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          setPinnedTs(selectedTs === pinnedTs ? null : (selectedTs ?? timestamps[timestamps.length - 1]));
        }
      }}
    >
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
        {selectedX !== null && (
          <g pointerEvents="none" aria-hidden="true">
            <line x1={selectedX} x2={selectedX} y1={PAD} y2={baseline}
              stroke="rgb(var(--text-muted))" strokeWidth={1} strokeDasharray="4 4" vectorEffect="non-scaling-stroke" />
            {selectedConn && <circle cx={selectedX} cy={pointY(selectedConn.v)} r={5}
              fill="rgb(var(--accent))" stroke="rgb(var(--surface))" strokeWidth={2} vectorEffect="non-scaling-stroke" />}
            {selectedUsers && <circle cx={selectedX} cy={pointY(selectedUsers.v)} r={5}
              fill="rgb(var(--ok))" stroke="rgb(var(--surface))" strokeWidth={2} vectorEffect="non-scaling-stroke" />}
          </g>
        )}
      </svg>
      {selectedTs !== null && (
        <div aria-hidden="true" className={`pointer-events-none absolute top-2 z-10 w-[190px] max-w-[calc(100%-1rem)] rounded-lg border border-border-strong bg-surface px-3 py-2 text-[11px] text-text shadow-lg ${selectedX !== null && selectedX > W / 2 ? 'left-2' : 'right-2'}`}>
          <div className="mb-1 font-mono tabular-nums text-text-muted">{pointTime(selectedTs)}</div>
          <div className="flex items-center justify-between gap-3"><span className="flex items-center gap-1.5"><i className="h-2 w-2 rounded-full bg-accent" />Соединения</span><strong className="font-mono tabular-nums">{selectedConn ? formatNumber(selectedConn.v) : '—'}</strong></div>
          <div className="flex items-center justify-between gap-3"><span className="flex items-center gap-1.5"><i className="h-2 w-2 rounded-full bg-ok" />Пользователи</span><strong className="font-mono tabular-nums">{selectedUsers ? formatNumber(selectedUsers.v) : '—'}</strong></div>
        </div>
      )}
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
