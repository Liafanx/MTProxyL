import { Header } from '@/components/layout/Header';
import { StatusBadge } from '@/components/StatusBadge';
import { ErrorAlert } from '@/components/ErrorAlert';
import { MetricCard } from '@/components/MetricCard';
import { useWsSubscription, useEndpoint } from '@/hooks/useWebSocket';
import { fieldMeta, formatFieldValue } from '@/lib/telemetryLabels';

interface UpstreamStatus {
  address?: string;
  type?: string;
  enabled?: boolean;
  weight?: number;
  [key: string]: unknown;
}

interface UpstreamsData {
  enabled: boolean;
  reason?: string;
  zero?: Record<string, unknown>;
  summary?: Record<string, unknown>;
  upstreams?: UpstreamStatus[];
}

interface DcStatus {
  dc_id: number;
  [key: string]: unknown;
}

interface DcStatusData {
  middle_proxy_enabled: boolean;
  reason?: string;
  dcs: DcStatus[];
}

interface MeWritersData {
  enabled?: boolean;
  reason?: string;
  summary?: Record<string, unknown>;
  [key: string]: unknown;
}

function formatValue(value: unknown): string {
  if (value == null) return '-';
  if (typeof value === 'boolean') return value ? 'Yes' : 'No';
  if (typeof value === 'number') return Number.isInteger(value) ? String(value) : value.toFixed(1);
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(formatValue).join(', ');
  if (typeof value === 'object') {
    return Object.entries(value as Record<string, unknown>)
      .map(([k, v]) => `${k}: ${formatValue(v)}`)
      .join(', ');
  }
  return String(value);
}

const ENDPOINTS = ['/v1/stats/upstreams', '/v1/stats/dcs', '/v1/stats/me-writers'];

export function UpstreamsPage() {
  const { data: wsData, errors, connected, refresh } = useWsSubscription('upstreams', ENDPOINTS, 5);

  const upstreams = useEndpoint<UpstreamsData>(wsData, '/v1/stats/upstreams');
  const dcs = useEndpoint<DcStatusData>(wsData, '/v1/stats/dcs');
  const meWriters = useEndpoint<MeWritersData>(wsData, '/v1/stats/me-writers');

  const firstError = Object.values(errors)[0];

  return (
    <div>
      <Header title="Апстримы и DC" refreshing={!connected} onRefresh={refresh} />

      <div className="p-6 space-y-6">
        {firstError && <ErrorAlert message={firstError} onRetry={refresh} />}

        {upstreams && (
          <div className="space-y-4">
            <div>
              <h3 className="text-sm font-medium text-text-secondary">Серверы-апстримы</h3>
              <p className="text-xs text-text-secondary/70 mt-0.5">
                Промежуточные серверы Telegram, через которые движок отдаёт трафик. Для каждого
                видно задержку и долю ошибок — по ним выбирается маршрут.
              </p>
            </div>

            {!upstreams.enabled && (
              <div className="bg-warning/10 border border-warning/30 rounded-lg p-3 text-sm text-warning">
                Данные по апстримам недоступны: {upstreams.reason || 'функция выключена в конфиге движка'}
              </div>
            )}

            {upstreams.zero && (
              <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
                {Object.entries(upstreams.zero).map(([key, value]) => (
                  <MetricCard key={key} label={fieldMeta(key).label} value={formatFieldValue(key, value)} />
                ))}
              </div>
            )}

            {upstreams.upstreams && upstreams.upstreams.length > 0 && (
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                {upstreams.upstreams.map((u, i) => (
                  <div key={i} className="bg-surface border border-border rounded-lg p-4 space-y-2">
                    <div className="flex items-center justify-between">
                      <code className="text-sm font-mono text-text-primary">{u.address || `upstream-${i}`}</code>
                      {u.enabled !== undefined && (
                        <StatusBadge status={u.enabled} labelOn="Active" labelOff="Disabled" />
                      )}
                    </div>
                    <div className="grid grid-cols-2 gap-2 text-xs">
                      {Object.entries(u)
                        .filter(([k]) => !['address', 'enabled'].includes(k))
                        .map(([key, value]) => (
                          <div key={key}>
                            <span className="text-text-secondary">{fieldMeta(key).label}: </span>
                            <span className="text-text-primary">
                              {typeof value === 'boolean' ? (value ? 'Yes' : 'No') : formatValue(value)}
                            </span>
                          </div>
                        ))}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}

        {dcs?.dcs && (
          <div className="space-y-4">
            <div>
              <h3 className="text-sm font-medium text-text-secondary">Состояние DC</h3>
              <p className="text-xs text-text-secondary/70 mt-0.5">
                Дата-центры Telegram (DC 1–5) и связь с каждым из них. Клиент сам выбирает свой
                DC, поэтому недоступность одного задевает только часть пользователей.
              </p>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              {dcs.dcs.map((dc) => (
                <div key={dc.dc_id} className="bg-surface border border-border rounded-lg p-4">
                  <div className="flex items-center justify-between mb-3">
                    <span className="font-medium text-text-primary">DC {dc.dc_id}</span>
                  </div>
                  <div className="grid grid-cols-2 gap-2 text-xs">
                    {Object.entries(dc)
                      .filter(([k]) => k !== 'dc_id')
                      .map(([key, value]) => (
                        <div key={key} className={Array.isArray(value) || (typeof value === 'object' && value !== null && typeof value !== 'boolean') ? 'col-span-2' : ''}>
                          <span className="text-text-secondary">{fieldMeta(key).label}: </span>
                          {typeof value === 'boolean' ? (
                            <StatusBadge status={value} />
                          ) : Array.isArray(value) ? (
                            <div className="mt-1 space-y-0.5">
                              {value.map((item, i) => (
                                <div key={i} className="text-text-primary font-mono text-xs break-all">
                                  {formatValue(item)}
                                </div>
                              ))}
                            </div>
                          ) : typeof value === 'object' && value !== null ? (
                            <div className="mt-1 space-y-0.5">
                              {Object.entries(value as Record<string, unknown>).map(([k, v]) => (
                                <div key={k} className="text-text-primary text-xs break-all">
                                  <span className="text-text-secondary">{k}: </span>{formatValue(v)}
                                </div>
                              ))}
                            </div>
                          ) : (
                            <span className="text-text-primary">{formatValue(value)}</span>
                          )}
                        </div>
                      ))}
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {meWriters && (
          <div className="space-y-4">
            <div>
              <h3 className="text-sm font-medium text-text-secondary">Писатели ME</h3>
              <p className="text-xs text-text-secondary/70 mt-0.5">
                Соединения, через которые движок пишет в промежуточные серверы. Если живых
                меньше, чем требуется, пул считается неполным и трафик идёт хуже.
              </p>
            </div>

            {meWriters.enabled === false && (
              <div className="bg-warning/10 border border-warning/30 rounded-lg p-3 text-sm text-warning">
                Данные по писателям ME недоступны: {meWriters.reason || 'функция выключена в конфиге движка'}
              </div>
            )}

            {meWriters.summary && (
              <div className="bg-surface border border-border rounded-lg p-4">
                <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
                  {Object.entries(meWriters.summary).map(([key, value]) => (
                    <div key={key}>
                      <div className="text-xs text-text-secondary">{fieldMeta(key).label}</div>
                      <div className="text-sm text-text-primary font-medium">
                        {typeof value === 'number' && key.includes('pct')
                          ? `${(value as number).toFixed(1)}%`
                          : String(value ?? '-')}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
