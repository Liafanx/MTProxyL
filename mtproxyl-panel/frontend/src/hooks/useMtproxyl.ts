import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { mtproxylApi, type MtproxylMode, type MtproxylOperation } from '@/lib/api';

/**
 * Tracks whether the MTProxyL bridge is available.
 *
 * The panel also runs against a plain telemt install, where these features are
 * absent — the nav hides them rather than showing pages that only error.
 */
export function useMtproxylAvailability() {
  const [enabled, setEnabled] = useState(false);
  const [mode, setMode] = useState<MtproxylMode | ''>('');
  const [apiMismatch, setApiMismatch] = useState<string>('');
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const s = await mtproxylApi.status();
      setEnabled(s.enabled);
      setMode(s.mode);
      setApiMismatch(s.api_mismatch ?? '');
    } catch {
      setEnabled(false);
      setMode('');
      setApiMismatch('');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return { enabled, mode, apiMismatch, loading, refresh };
}

interface MtproxylState {
  enabled: boolean;
  mode: MtproxylMode | '';
  /** Сообщение о том, что панель смотрит на движок другого режима. */
  apiMismatch?: string;
  loading: boolean;
  refresh?: () => Promise<void>;
}

export const MtproxylContext = createContext<MtproxylState>({
  enabled: false,
  mode: '',
  apiMismatch: '',
  loading: true,
});

export const useMtproxyl = () => useContext(MtproxylContext);

/**
 * Часть возможностей MTProxyL существует только в режиме manager: бэкапы и
 * исходящие маршруты завязаны на владение конфигом, и в реаниматоре сам
 * MTProxyL их отклоняет. Прятать их надёжнее, чем показывать заведомо
 * падающие кнопки.
 */
export const useManagerOnly = () => {
  const { mode, loading } = useMtproxyl();
  return { allowed: mode === 'manager', mode, loading };
};

/**
 * Относится ли операция к текущей странице.
 *
 * Имя операции строится как "область:действие" (mode:manager, selfmask:setup,
 * backup:restore, nft:apply). Страница без указанной области принимает любые.
 */
function belongsHere(op: MtproxylOperation, scope?: string[]): boolean {
  if (!scope || scope.length === 0) return true;
  if (!op.name) return op.phase === 'idle';
  return scope.some((prefix) => op.name!.startsWith(prefix));
}

const POLL_INTERVAL_MS = 2000;

/**
 * Polls the shared operation slot while a long-running command is in flight.
 *
 * Mode switches, selfmask setup and restores run in the background on the
 * server, so the UI has to poll rather than await a response.
 */
export function useMtproxylOperation(onFinished?: () => void, scope?: string[]) {
  const [operation, setOperation] = useState<MtproxylOperation | null>(null);
  const timer = useRef<number | null>(null);
  // Kept in a ref so restarting the poll loop does not depend on a changing
  // callback identity.
  const finishedRef = useRef(onFinished);
  finishedRef.current = onFinished;
  const scopeRef = useRef(scope);
  scopeRef.current = scope;

  const stop = useCallback(() => {
    if (timer.current !== null) {
      window.clearInterval(timer.current);
      timer.current = null;
    }
  }, []);

  const poll = useCallback(async () => {
    try {
      const status = await mtproxylApi.status();
      // Без этой проверки отсутствующее поле operation роняет обработчик в
      // catch ниже — и спиннер остаётся крутиться навсегда, хотя операция
      // давно завершилась.
      const op = status?.operation;
      if (!op || typeof op.phase !== 'string') {
        stop();
        finishedRef.current?.();
        return;
      }
      setOperation(op);
      if (op.phase !== 'running') {
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
  //
  // The operation slot is shared server-side, so a page only adopts one that
  // belongs to it — otherwise the backups page would display the output of a
  // selfmask setup that finished minutes ago.
  useEffect(() => {
    let cancelled = false;
    mtproxylApi
      .status()
      .then((s) => {
        const op = s?.operation;
        if (cancelled || !op || typeof op.phase !== 'string') return;
        if (!belongsHere(op, scopeRef.current)) return;
        setOperation(op);
        if (op.phase === 'running') {
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
