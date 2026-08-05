import { useState, useEffect, useCallback, useRef } from 'react';

interface UsePollingResult<T> {
  data: T | null;
  error: Error | null;
  loading: boolean;
  refresh: () => void;
}

export function usePolling<T>(
  fetcher: () => Promise<T>,
  intervalMs: number = 5000
): UsePollingResult<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [loading, setLoading] = useState(true);
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  const doFetch = useCallback(async () => {
    try {
      const result = await fetcherRef.current();
      setData(result);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e : new Error(String(e)));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    // setTimeout, а не setInterval: следующий опрос планируется только после
    // того, как предыдущий завершился. Опрашиваемые команды идут через CLI
    // (sudo + запуск bash-скрипта), и под нагрузкой один вызов может занять
    // больше intervalMs — setInterval в этом случае копил бы запросы один
    // на другой без предела, а не отставал на шаг.
    let cancelled = false;
    let timeoutId: ReturnType<typeof setTimeout> | undefined;

    const tick = async () => {
      await doFetch();
      if (!cancelled) {
        timeoutId = setTimeout(tick, intervalMs);
      }
    };

    void tick();

    return () => {
      cancelled = true;
      if (timeoutId) clearTimeout(timeoutId);
    };
  }, [doFetch, intervalMs]);

  return { data, error, loading, refresh: doFetch };
}
