import { useCallback, useMemo } from 'react';
import { usePolling } from '@/hooks/usePolling';
import { historyApi, type HistoryMetric, type HistoryRange, type HistorySeries } from '@/lib/api';

type SeriesMap = Partial<Record<HistoryMetric, HistorySeries>>;

/** История метрик с бэкенда панели; опрос ставится на паузу в скрытой вкладке. */
export function useHistorySeries(metrics: HistoryMetric[], range: HistoryRange = '30m', intervalMs = 10_000) {
  const key = metrics.join(',');
  const fetcher = useCallback(
    () => historyApi.get(key.split(',') as HistoryMetric[], range),
    [key, range],
  );
  const { data, error, loading, refresh } = usePolling(fetcher, intervalMs, `${key}:${range}`);
  const series = useMemo(() => {
    const map: SeriesMap = {};
    if (data?.range === range) {
      for (const s of data.series) map[s.metric] = s;
    }
    return map;
  }, [data, range]);
  return { series, error, loading, refresh, disabled: error?.message.includes('history_disabled') ?? false };
}
