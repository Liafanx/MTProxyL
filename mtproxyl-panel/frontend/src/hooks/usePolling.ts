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
    // setTimeout, а не setInterval: следующий опрос планируется после ответа.
    // Вызовы идут через CLI и под нагрузкой длятся дольше intervalMs —
    // setInterval копил бы запросы один на другой.
    let cancelled = false;
    let timeoutId: ReturnType<typeof setTimeout> | undefined;

    // В скрытой вкладке не опрашиваем: панель висит открытой сутками, а каждый
    // опрос — это запуск CLI на сервере.
    const hidden = () => typeof document !== 'undefined' && document.hidden;

    const tick = async () => {
      if (!hidden()) {
        await doFetch();
      }
      if (!cancelled) {
        timeoutId = setTimeout(tick, intervalMs);
      }
    };

    const onVisible = () => {
      if (!cancelled && !hidden()) void doFetch();
    };
    document.addEventListener('visibilitychange', onVisible);

    void tick();

    return () => {
      cancelled = true;
      document.removeEventListener('visibilitychange', onVisible);
      if (timeoutId) clearTimeout(timeoutId);
    };
  }, [doFetch, intervalMs]);

  return { data, error, loading, refresh: doFetch };
}
