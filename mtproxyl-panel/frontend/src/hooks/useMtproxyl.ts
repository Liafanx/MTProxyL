import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { mtproxylApi, type MtproxylOperation } from '@/lib/api';

/**
 * Tracks whether the MTProxyL bridge is available.
 *
 * The panel also runs against a plain telemt install, where these features are
 * absent — the nav hides them rather than showing pages that only error.
 */
export function useMtproxylAvailability() {
  const [enabled, setEnabled] = useState(false);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    mtproxylApi
      .status()
      .then((s) => {
        if (!cancelled) setEnabled(s.enabled);
      })
      .catch(() => {
        if (!cancelled) setEnabled(false);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return { enabled, loading };
}

export const MtproxylContext = createContext<{ enabled: boolean; loading: boolean }>({
  enabled: false,
  loading: true,
});

export const useMtproxyl = () => useContext(MtproxylContext);

const POLL_INTERVAL_MS = 2000;

/**
 * Polls the shared operation slot while a long-running command is in flight.
 *
 * Mode switches, selfmask setup and restores run in the background on the
 * server, so the UI has to poll rather than await a response.
 */
export function useMtproxylOperation(onFinished?: () => void) {
  const [operation, setOperation] = useState<MtproxylOperation | null>(null);
  const timer = useRef<number | null>(null);
  // Kept in a ref so restarting the poll loop does not depend on a changing
  // callback identity.
  const finishedRef = useRef(onFinished);
  finishedRef.current = onFinished;

  const stop = useCallback(() => {
    if (timer.current !== null) {
      window.clearInterval(timer.current);
      timer.current = null;
    }
  }, []);

  const poll = useCallback(async () => {
    try {
      const status = await mtproxylApi.status();
      setOperation(status.operation);
      if (status.operation.phase !== 'running') {
        stop();
        finishedRef.current?.();
      }
    } catch {
      // A failed poll is not fatal: the operation keeps running server-side and
      // the next tick may succeed. Stopping here would strand the UI.
    }
  }, [stop]);

  const start = useCallback(
    (initial: MtproxylOperation) => {
      setOperation(initial);
      stop();
      timer.current = window.setInterval(poll, POLL_INTERVAL_MS);
    },
    [poll, stop],
  );

  // Pick up an operation started elsewhere (another tab, or a page reload
  // mid-run) so the UI does not look idle while the server is busy.
  useEffect(() => {
    let cancelled = false;
    mtproxylApi
      .status()
      .then((s) => {
        if (cancelled) return;
        setOperation(s.operation);
        if (s.operation.phase === 'running') {
          timer.current = window.setInterval(poll, POLL_INTERVAL_MS);
        }
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
      stop();
    };
  }, [poll, stop]);

  return { operation, start, running: operation?.phase === 'running' };
}
