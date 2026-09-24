import type { HistoryPoint, HistorySeries } from '@/lib/api';

/** Разрыв больше этого — серия прерывалась, шаги через него не считаем. */
export const OBSERVATION_GAP = 120;

export interface CounterStep {
  from: number;
  to: number;
  delta: number;
  seconds: number;
}

/** Шаги накопительного счётчика между соседними точками. */
export function counterSteps(points: HistoryPoint[]): CounterStep[] {
  const steps: CounterStep[] = [];
  for (let i = 1; i < points.length; i += 1) {
    const prev = points[i - 1];
    const next = points[i];
    const seconds = next.ts - prev.ts;
    const delta = next.v - prev.v;
    if (seconds <= 0 || seconds > OBSERVATION_GAP || delta < 0) continue;
    steps.push({ from: prev.ts, to: next.ts, delta, seconds });
  }
  return steps;
}

/** Скорость по шагам последнего непрерывного участка, заканчивающегося в последней точке. */
export function rateValues(series?: HistorySeries): number[] {
  if (!series || series.points.length < 2) return [];
  const steps = counterSteps(series.points);
  if (steps.length === 0) return [];
  const last = series.points[series.points.length - 1].ts;
  let start = steps.length - 1;
  if (steps[start].to !== last) return [];
  while (start > 0 && steps[start - 1].to === steps[start].from) start -= 1;
  return steps.slice(start).map((s) => s.delta / s.seconds);
}

/** Прирост счётчика за последние secs секунд, отсчитанные от последней точки. */
export function windowDelta(series?: HistorySeries, secs = 900): number | null {
  if (!series || series.points.length < 2) return null;
  const end = series.points[series.points.length - 1].ts;
  const from = end - secs;
  let total = 0;
  let counted = false;
  for (const step of counterSteps(series.points)) {
    if (step.to <= from) continue;
    total += step.delta;
    counted = true;
  }
  return counted ? total : null;
}

export function gaugeValues(series?: HistorySeries): number[] {
  return series?.points.map((p) => p.v) ?? [];
}

export function lastValue(series?: HistorySeries): number | null {
  const points = series?.points ?? [];
  return points.length ? points[points.length - 1].v : null;
}

export function peakValue(series?: HistorySeries): number | null {
  const points = series?.points ?? [];
  return points.length ? Math.max(...points.map((p) => p.v)) : null;
}

/** Шкала оси Y: «красивый» шаг 1/2/5·10ⁿ и деления от максимума к нулю. */
export function niceScaleTicks(value: number): number[] {
  if (!Number.isFinite(value) || value <= 0) return [1, 0];
  const rawStep = value / 5;
  const mag = 10 ** Math.floor(Math.log10(rawStep));
  const f = rawStep / mag;
  const snapped = f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10;
  const step = snapped * mag;
  const max = Math.ceil(value / step) * step;
  const ticks: number[] = [];
  for (let v = max; v > step / 2; v -= step) ticks.push(Number(v.toFixed(10)));
  ticks.push(0);
  return ticks;
}
