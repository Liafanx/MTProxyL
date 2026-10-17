import { createContext, useContext, useEffect, useRef, useState, useCallback } from 'react';

interface ServerMessage {
  type: 'data' | 'error';
  endpoint: string;
  data?: unknown;
  error?: string;
  timestamp: number;
}

type DataMap = Record<string, unknown>;
type ErrorMap = Record<string, string>;
type Subscriber = { endpoints: string[]; interval: number };

interface WsContextValue {
  data: DataMap;
  errors: ErrorMap;
  connected: boolean;
  subscribe: (id: string, endpoints: string[], interval?: number) => void;
  unsubscribe: (id: string) => void;
  refresh: () => void;
}

export const WsContext = createContext<WsContextValue>({
  data: {},
  errors: {},
  connected: false,
  subscribe: () => {},
  unsubscribe: () => {},
  refresh: () => {},
});

export function useWsProvider(): WsContextValue {
  const [data, setData] = useState<DataMap>({});
  const [errors, setErrors] = useState<ErrorMap>({});
  const [connected, setConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const reconnectTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const subscribers = useRef<Map<string, Subscriber>>(new Map());
  const active = useRef(false);
  const connectionStarted = useRef(0);
  const responses = useRef<Map<string, number>>(new Map());

  const getAggregated = useCallback(() => {
    const endpointIntervals = new Map<string, number>();
    for (const sub of subscribers.current.values()) {
      for (const ep of sub.endpoints) {
        const existing = endpointIntervals.get(ep);
        if (!existing || sub.interval < existing) {
          endpointIntervals.set(ep, sub.interval);
        }
      }
    }
    return endpointIntervals;
  }, []);

  const sendSubscriptions = useCallback(() => {
    const ws = wsRef.current;
    if (ws?.readyState !== WebSocket.OPEN) return;

    const agg = getAggregated();
    // Пустая подписка тоже отправляется: сервер должен остановить старые опросы.
    const allEndpoints = [...agg.keys()];
    const minInterval = agg.size ? Math.min(...agg.values()) : 5;
    responses.current = new Map(allEndpoints.map(endpoint => [endpoint, Date.now()]));

    ws.send(JSON.stringify({
      type: 'subscribe',
      endpoints: allEndpoints,
      interval: minInterval,
    }));
  }, [getAggregated]);

  const connect = useCallback(() => {
    if (!active.current || document.hidden) return;
    if (wsRef.current?.readyState === WebSocket.OPEN || wsRef.current?.readyState === WebSocket.CONNECTING) return;
    clearTimeout(reconnectTimer.current);

    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const base = (window as any).__BASE_PATH__ || '';
    const ws = new WebSocket(`${proto}//${window.location.host}${base}/api/ws`);
    wsRef.current = ws;
    connectionStarted.current = Date.now();

    ws.onopen = () => {
      if (!active.current || wsRef.current !== ws) return;
      setConnected(true);
      sendSubscriptions();
    };

    ws.onmessage = (event) => {
      if (!active.current || wsRef.current !== ws) return;
      let msg: ServerMessage;
      try { msg = JSON.parse(event.data); } catch { return; }
      if (!msg || typeof msg.endpoint !== 'string' || (msg.type !== 'data' && msg.type !== 'error')) return;
      if (responses.current.has(msg.endpoint)) responses.current.set(msg.endpoint, Date.now());
      if (msg.type === 'data') {
        setData(prev => ({ ...prev, [msg.endpoint]: msg.data }));
        setErrors(prev => {
          if (!prev[msg.endpoint]) return prev;
          const next = { ...prev };
          delete next[msg.endpoint];
          return next;
        });
      } else if (msg.type === 'error') {
        setErrors(prev => ({ ...prev, [msg.endpoint]: msg.error || 'unknown error' }));
      }
    };

    ws.onclose = () => {
      if (!active.current || wsRef.current !== ws) return;
      setConnected(false);
      wsRef.current = null;
      if (!document.hidden) reconnectTimer.current = setTimeout(connect, 3000);
    };

    ws.onerror = () => { if (wsRef.current === ws) ws.close(); };
  }, [sendSubscriptions]);

  const restart = useCallback(() => {
    clearTimeout(reconnectTimer.current);
    const previous = wsRef.current;
    wsRef.current = null;
    previous?.close();
    setConnected(false);
    connect();
  }, [connect]);

  useEffect(() => {
    active.current = true;
    connect();
    const onVisible = () => { if (!document.hidden) restart(); };
    const onPageShow = (event: PageTransitionEvent) => { if (event.persisted) onVisible(); };
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('pageshow', onPageShow);
    window.addEventListener('online', onVisible);
    // Мобильный браузер может оставить зависший сокет в состоянии OPEN.
    const watchdog = setInterval(() => {
      if (document.hidden) return;
      const ws = wsRef.current;
      if (!ws) { connect(); return; }
      const now = Date.now();
      const agg = getAggregated();
      const timeout = Math.max(30000, (agg.size ? Math.min(...agg.values()) : 5) * 1000 + 15000);
      if (ws.readyState === WebSocket.CONNECTING && now - connectionStarted.current > 30000
        || ws.readyState === WebSocket.OPEN && [...responses.current.values()].some(time => now - time > timeout)) {
        restart();
      }
    }, 5000);
    return () => {
      active.current = false;
      clearInterval(watchdog);
      clearTimeout(reconnectTimer.current);
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('pageshow', onPageShow);
      window.removeEventListener('online', onVisible);
      const previous = wsRef.current;
      wsRef.current = null;
      previous?.close();
    };
  }, [connect, restart, getAggregated]);

  const subscribe = useCallback((id: string, endpoints: string[], interval = 5) => {
    subscribers.current.set(id, { endpoints, interval });
    sendSubscriptions();
  }, [sendSubscriptions]);

  const unsubscribe = useCallback((id: string) => {
    subscribers.current.delete(id);
    sendSubscriptions();
  }, [sendSubscriptions]);

  return { data, errors, connected, subscribe, unsubscribe, refresh: restart };
}

// Hook for pages to subscribe to specific endpoints
export function useWsSubscription(id: string, endpoints: string[], interval = 5) {
  const ctx = useContext(WsContext);
  const endpointsKey = endpoints.join(',');

  useEffect(() => {
    ctx.subscribe(id, endpoints, interval);
    return () => ctx.unsubscribe(id);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, endpointsKey, interval]);

  return {
    data: Object.fromEntries(endpoints.filter(endpoint => endpoint in ctx.data).map(endpoint => [endpoint, ctx.data[endpoint]])),
    errors: Object.fromEntries(endpoints.filter(endpoint => endpoint in ctx.errors).map(endpoint => [endpoint, ctx.errors[endpoint]])),
    loading: endpoints.some(endpoint => !(endpoint in ctx.data) && !(endpoint in ctx.errors)),
    connected: ctx.connected,
    refresh: ctx.refresh,
  };
}

// Helper to get typed data from the map
export function useEndpoint<T>(dataMap: DataMap, endpoint: string): T | null {
  return (dataMap[endpoint] as T) ?? null;
}
