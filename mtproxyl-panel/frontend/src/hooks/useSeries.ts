import { useEffect, useRef, useState } from 'react';

/**
 * Накапливает последние значения метрики за время жизни страницы.
 * Для счётчиков (cumulative) хранит приращения между снимками.
 */
export function useSeries(value: number | undefined, opts: { cumulative?: boolean; max?: number } = {}): number[] {
  const { cumulative = false, max = 60 } = opts;
  const [series, setSeries] = useState<number[]>([]);
  const last = useRef<number | undefined>(undefined);

  useEffect(() => {
    if (value === undefined || !Number.isFinite(value)) return;
    if (cumulative) {
      const prev = last.current;
      last.current = value;
      if (prev === undefined) return;
      const delta = value >= prev ? value - prev : 0;
      setSeries((s) => [...s.slice(-(max - 1)), delta]);
      return;
    }
    if (last.current === value && series.length > 0) {
      setSeries((s) => [...s.slice(-(max - 1)), value]);
      return;
    }
    last.current = value;
    setSeries((s) => [...s.slice(-(max - 1)), value]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value, cumulative, max]);

  return series;
}
