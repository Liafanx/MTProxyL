import { useState, useEffect, useCallback, useRef } from 'react';

interface UsePollingResult<T> {
  data: T | null;
  error: Error | null;
  loading: boolean;
  refresh: () => void;
}

export function usePolling<T>(
  fetcher: () => Promise<T>,
  intervalMs: number = 5000,
  queryKey?: string,
): UsePollingResult<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [loading, setLoading] = useState(true);
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;
  const requestIdRef = useRef(0);

  const doFetch = useCallback(async () => {
    const requestId = ++requestIdRef.current;
    try {
      const result = await fetcherRef.current();
      if (requestId === requestIdRef.current) {
        setData(result);
        setError(null);
      }
    } catch (e) {
      if (requestId === requestIdRef.current) {
        setError(e instanceof Error ? e : new Error(String(e)));
      }
    } finally {
      if (requestId === requestIdRef.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    // Смена параметров должна сразу запустить новый запрос, а ответ от
    // предыдущего периода не должен попасть в карточку.
    requestIdRef.current++;
    if (queryKey !== undefined) {
      setData(null);
      setError(null);
      setLoading(true);
    }
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
      requestIdRef.current++;
      document.removeEventListener('visibilitychange', onVisible);
      if (timeoutId) clearTimeout(timeoutId);
    };
  }, [doFetch, intervalMs, queryKey]);

  return { data, error, loading, refresh: doFetch };
}
