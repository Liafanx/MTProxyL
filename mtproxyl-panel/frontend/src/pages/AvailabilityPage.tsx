import { useCallback, useEffect, useRef, useState } from 'react';
import { Loader2, RefreshCw } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { ErrorAlert } from '@/components/ErrorAlert';
import { StatusDot } from '@/components/StatusDot';
import { mtproxylAddonsApi, type AvailabilityReport } from '@/lib/api';

const POLL_INTERVAL_MS = 2000;

/** «RU» → флаг: узлы приходят с кодом страны, а флаг читается быстрее кода. */
function flag(code: string): string {
  if (!/^[A-Za-z]{2}$/.test(code)) return '';
  return String.fromCodePoint(
    ...code
      .toUpperCase()
      .split('')
      .map((c) => 0x1f1e6 + c.charCodeAt(0) - 65),
  );
}

function verdict(report: AvailabilityReport): { tone: 'ok' | 'warn' | 'error'; text: string } {
  if (!report.local_checked) {
    return { tone: 'warn', text: 'Проверка не выполнялась' };
  }
  if (!report.local_ok) {
    return {
      tone: 'error',
      text: 'Порт не отвечает даже на самом сервере — прокси не запущен или слушает другой порт',
    };
  }
  if (report.total === 0) {
    return { tone: 'warn', text: 'Ни один зонд не ответил — повторите проверку позже' };
  }
  if (report.reachable === 0) {
    return {
      tone: 'error',
      text: 'Снаружи сервер недоступен ниоткуда: порт закрыт фаерволом хостера или адрес заблокирован',
    };
  }
  if (report.reachable < report.total) {
    return {
      tone: 'warn',
      text: 'Доступен не отовсюду — из части стран порт не открывается',
    };
  }
  return { tone: 'ok', text: 'Сервер доступен со всех зондов' };
}

export function AvailabilityPage() {
  const [report, setReport] = useState<AvailabilityReport | null>(null);
  const [host, setHost] = useState('');
  const [port, setPort] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [starting, setStarting] = useState(false);
  const timer = useRef<number | null>(null);

  const stop = useCallback(() => {
    if (timer.current !== null) {
      window.clearInterval(timer.current);
      timer.current = null;
    }
  }, []);

  const poll = useCallback(async () => {
    try {
      const r = await mtproxylAddonsApi.availability();
      setReport(r);
      if (r.phase !== 'running') stop();
    } catch {
      // Одна неудачная попытка не повод бросать: проверка идёт на сервере.
    }
  }, [stop]);

  // Подхватываем проверку, запущенную раньше или в другой вкладке: она общая.
  useEffect(() => {
    let cancelled = false;
    mtproxylAddonsApi
      .availability()
      .then((r) => {
        if (cancelled) return;
        setReport(r);
        if (r.host) setHost(r.host);
        if (r.port) setPort(String(r.port));
        if (r.phase === 'running') {
          timer.current = window.setInterval(poll, POLL_INTERVAL_MS);
        }
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
      stop();
    };
  }, [poll, stop]);

  const start = async () => {
    setStarting(true);
    setError(null);
    try {
      const r = await mtproxylAddonsApi.availabilityCheck(
        host.trim() || undefined,
        port.trim() ? Number(port.trim()) : undefined,
      );
      setReport(r);
      if (r.host) setHost(r.host);
      if (r.port) setPort(String(r.port));
      stop();
      timer.current = window.setInterval(poll, POLL_INTERVAL_MS);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить проверку');
    } finally {
      setStarting(false);
    }
  };

  const running = report?.phase === 'running';
  const v = report && report.phase !== 'idle' ? verdict(report) : null;

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Доступность снаружи</h1>
        <p className="text-sm text-text-secondary mt-1">
          Проверка порта прокси зондами в разных странах и у разных провайдеров.
        </p>
      </div>

      {error && <ErrorAlert message={error} />}

      <Card>
        <CardHeader>
          <CardTitle>Что проверяем</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <p className="text-sm text-text-secondary">
            Сервер не может сам увидеть, доходят ли до него пакеты пользователей: порт слушается,
            а трафик может резаться фаерволом хостера или фильтрацией по пути. Зонды подключаются
            к порту снаружи и показывают, откуда сервер виден, а откуда нет. Проверка идёт через
            публичный сервис check-host.net — обычными исходящими запросами, без прав root и без
            установки чего-либо на сервер.
          </p>

          <form
            className="flex flex-wrap items-end gap-3"
            onSubmit={(e) => {
              e.preventDefault();
              void start();
            }}
          >
            <div className="space-y-1">
              <Label htmlFor="probe-host">Адрес сервера</Label>
              <Input
                id="probe-host"
                value={host}
                onChange={(e) => setHost(e.target.value)}
                placeholder="Пусто — определить самим"
                className="w-[260px]"
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="probe-port">Порт</Label>
              <Input
                id="probe-port"
                value={port}
                onChange={(e) => setPort(e.target.value)}
                placeholder="Текущий"
                className="w-[110px]"
              />
            </div>
            <Button type="submit" disabled={running || starting}>
              {running ? (
                <>
                  <Loader2 size={16} className="animate-spin" /> Проверяем…
                </>
              ) : (
                <>
                  <RefreshCw size={16} /> Проверить
                </>
              )}
            </Button>
          </form>
          <p className="text-xs text-text-secondary">
            Проверка занимает около 10–20 секунд: зонды отвечают вразнобой.
          </p>
        </CardContent>
      </Card>

      {report && report.phase !== 'idle' && (
        <Card>
          <CardHeader>
            <CardTitle>
              Результат{report.host ? ` — ${report.host}:${report.port}` : ''}
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {report.phase === 'failed' ? (
              <ErrorAlert message={report.error || 'Проверка не удалась'} />
            ) : (
              <>
                {v && (
                  <div className="flex items-start gap-2">
                    <StatusDot status={v.tone} size="md" className="mt-1" />
                    <div>
                      <div className="text-sm text-text-primary">{v.text}</div>
                      {report.total > 0 && (
                        <div className="text-xs text-text-secondary mt-0.5">
                          Доступен с {report.reachable} из {report.total} зондов
                        </div>
                      )}
                    </div>
                  </div>
                )}

                {report.local_checked && (
                  <div className="text-xs text-text-secondary">
                    На самом сервере порт{' '}
                    {report.local_ok ? (
                      <span className="text-success">отвечает</span>
                    ) : (
                      <span className="text-danger">не отвечает{report.local_error ? ` (${report.local_error})` : ''}</span>
                    )}
                  </div>
                )}

                {report.nodes.length > 0 && (
                  <div className="border border-border rounded-md divide-y divide-border">
                    {report.nodes.map((n) => (
                      <div key={n.node} className="flex items-center gap-3 px-3 py-2 text-sm">
                        <StatusDot status={n.pending ? 'warn' : n.ok ? 'ok' : 'error'} />
                        <span className="w-8 shrink-0">{flag(n.country_code)}</span>
                        <span className="text-text-primary min-w-0 flex-1 truncate">
                          {n.country || n.country_code}
                          {n.city ? `, ${n.city}` : ''}
                        </span>
                        <span className="text-xs text-text-secondary text-right min-w-0 truncate">
                          {n.ok ? `${n.time_ms} мс` : n.error || 'нет соединения'}
                        </span>
                      </div>
                    ))}
                  </div>
                )}

                {running && (
                  <div className="text-xs text-text-secondary flex items-center gap-2">
                    <Loader2 size={14} className="animate-spin" /> Ждём ответа зондов…
                  </div>
                )}

                {report.permanent_link && (
                  <a
                    href={report.permanent_link}
                    target="_blank"
                    rel="noreferrer noopener"
                    className="text-xs text-accent hover:underline inline-block"
                  >
                    Та же проверка на check-host.net
                  </a>
                )}
              </>
            )}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
