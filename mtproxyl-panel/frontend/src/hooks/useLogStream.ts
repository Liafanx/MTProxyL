import { useState, useRef, useCallback, useEffect } from 'react';

interface LogLine {
  id: number;
  text: string;
}

interface ServerMsg {
  type: 'line' | 'history' | 'status' | 'error';
  data?: string;
  lines?: string[];
  count?: number;
  streaming?: boolean;
  message?: string;
  timestamp: number;
}

interface LogStreamState {
  lines: LogLine[];
  streaming: boolean;
  connected: boolean;
  error: string | null;
  paused: boolean;
}

const MAX_BUFFER = 10_000;

export function useLogStream() {
  const [state, setState] = useState<LogStreamState>({
    lines: [],
    streaming: false,
    connected: false,
    error: null,
    paused: false,
  });

  const wsRef = useRef<WebSocket | null>(null);
  const idCounter = useRef(0);
  const pauseBuffer = useRef<LogLine[]>([]);
  const pausedRef = useRef(false);
  const [bufferedCount, setBufferedCount] = useState(0);

  const addLines = useCallback((newLines: string[]) => {
    const entries: LogLine[] = newLines.map((text) => ({
      id: idCounter.current++,
      text,
    }));

    if (pausedRef.current) {
      pauseBuffer.current.push(...entries);
      setBufferedCount(pauseBuffer.current.length);
      return;
    }

    setState((prev) => {
      const combined = [...prev.lines, ...entries];
      const trimmed = combined.length > MAX_BUFFER
        ? combined.slice(combined.length - MAX_BUFFER)
        : combined;
      return { ...prev, lines: trimmed };
    });
  }, []);

  const connect = useCallback(() => {
    if (wsRef.current?.readyState === WebSocket.OPEN) return;

    const base = (window as any).__BASE_PATH__ || '';
    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${proto}//${window.location.host}${base}/api/ws/logs`);

    ws.onopen = () => {
      setState((prev) => ({ ...prev, connected: true, error: null }));
    };

    ws.onmessage = (e) => {
      const msg: ServerMsg = JSON.parse(e.data);
      switch (msg.type) {
        case 'history':
          if (msg.lines) addLines(msg.lines);
          break;
        case 'line':
          if (msg.data) addLines([msg.data]);
          break;
        case 'status':
          setState((prev) => ({
            ...prev,
            streaming: msg.streaming ?? prev.streaming,
          }));
          break;
        case 'error':
          setState((prev) => ({ ...prev, error: msg.message ?? 'Unknown error' }));
          break;
      }
    };

    ws.onclose = () => {
      setState((prev) => ({ ...prev, connected: false, streaming: false }));
    };

    wsRef.current = ws;
  }, [addLines]);

  const disconnect = useCallback(() => {
    wsRef.current?.close();
    wsRef.current = null;
  }, []);

  const start = useCallback((lines: number = 200, since: string = '1h') => {
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) {
      connect();
      // Wait for connection, then start
      const check = setInterval(() => {
        if (wsRef.current?.readyState === WebSocket.OPEN) {
          clearInterval(check);
          wsRef.current!.send(JSON.stringify({ action: 'start', lines, since }));
        }
      }, 100);
      setTimeout(() => clearInterval(check), 5000);
      return;
    }
    setState((prev) => ({ ...prev, lines: [], error: null }));
    idCounter.current = 0;
    wsRef.current.send(JSON.stringify({ action: 'start', lines, since }));
  }, [connect]);

  const stop = useCallback(() => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({ action: 'stop' }));
    }
    setState((prev) => ({ ...prev, streaming: false, paused: false }));
    pausedRef.current = false;
    pauseBuffer.current = [];
    setBufferedCount(0);
  }, []);

  const pause = useCallback(() => {
    pausedRef.current = true;
    pauseBuffer.current = [];
    setBufferedCount(0);
    setState((prev) => ({ ...prev, paused: true }));
  }, []);

  const resume = useCallback(() => {
    pausedRef.current = false;
    const buffered = pauseBuffer.current;
    pauseBuffer.current = [];
    setBufferedCount(0);
    setState((prev) => {
      const combined = [...prev.lines, ...buffered];
      const trimmed = combined.length > MAX_BUFFER
        ? combined.slice(combined.length - MAX_BUFFER)
        : combined;
      return { ...prev, lines: trimmed, paused: false };
    });
  }, []);

  const clear = useCallback(() => {
    setState((prev) => ({ ...prev, lines: [] }));
    idCounter.current = 0;
  }, []);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      wsRef.current?.close();
    };
  }, []);

  return {
    ...state,
    bufferedCount,
    start,
    stop,
    pause,
    resume,
    clear,
    disconnect,
  };
}
