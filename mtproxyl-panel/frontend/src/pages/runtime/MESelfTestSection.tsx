import { CollapsibleSection } from '@/components/CollapsibleSection';
import { formatNumber, cn } from '@/lib/utils';
import type { MeSelftestData } from '@/types/runtime';

interface MESelfTestSectionProps {
  data: MeSelftestData | null;
}

export function MESelfTestSection({ data }: MESelfTestSectionProps) {
  if (!data?.data) return null;

  const { kdf, timeskew, bnd, ip, pid, upstreams } = data.data;

  return (
    <CollapsibleSection title="ME Self-Test">
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
        {/* KDF */}
        {kdf && (
          <div className="bg-background rounded p-3 border border-border/50">
            <div className="flex items-center justify-between mb-2">
              <h4 className="text-xs font-semibold text-accent uppercase tracking-wide">KDF</h4>
              <span className={cn(
                'text-xs font-medium px-2 py-0.5 rounded',
                kdf.state === 'ok'
                  ? 'bg-success/10 text-success'
                  : 'bg-danger/10 text-danger'
              )}>
                {kdf.state}
              </span>
            </div>
            <div className="space-y-1 text-xs">
              <div className="flex justify-between">
                <span className="text-text-secondary">EWMA errors/min</span>
                <span className="text-text-primary font-medium">{kdf.ewma_errors_per_min.toFixed(2)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-secondary">Threshold</span>
                <span className="text-text-primary font-medium">{kdf.threshold_errors_per_min.toFixed(2)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-secondary">Total errors</span>
                <span className="text-text-primary font-medium">{formatNumber(kdf.errors_total)}</span>
              </div>
            </div>
          </div>
        )}

        {/* Timeskew */}
        {timeskew && (
          <div className="bg-background rounded p-3 border border-border/50">
            <div className="flex items-center justify-between mb-2">
              <h4 className="text-xs font-semibold text-accent uppercase tracking-wide">Time Skew</h4>
              <span className={cn(
                'text-xs font-medium px-2 py-0.5 rounded',
                timeskew.state === 'ok'
                  ? 'bg-success/10 text-success'
                  : 'bg-danger/10 text-danger'
              )}>
                {timeskew.state}
              </span>
            </div>
            <div className="space-y-1 text-xs">
              <div className="flex justify-between">
                <span className="text-text-secondary">Max skew (15m)</span>
                <span className="text-text-primary font-medium">
                  {timeskew.max_skew_secs_15m != null ? `${timeskew.max_skew_secs_15m}s` : '-'}
                </span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-secondary">Samples (15m)</span>
                <span className="text-text-primary font-medium">{timeskew.samples_15m}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-secondary">Last skew</span>
                <span className="text-text-primary font-medium">
                  {timeskew.last_skew_secs != null ? `${timeskew.last_skew_secs}s` : '-'}
                </span>
              </div>
              {timeskew.last_source && (
                <div className="flex justify-between">
                  <span className="text-text-secondary">Source</span>
                  <span className="text-text-primary font-medium">{timeskew.last_source}</span>
                </div>
              )}
            </div>
          </div>
        )}

        {/* BND */}
        {bnd && (
          <div className="bg-background rounded p-3 border border-border/50">
            <div className="flex items-center justify-between mb-2">
              <h4 className="text-xs font-semibold text-accent uppercase tracking-wide">BND</h4>
              <div className="flex gap-1">
                <span className={cn(
                  'text-xs font-medium px-2 py-0.5 rounded',
                  bnd.addr_state === 'ok'
                    ? 'bg-success/10 text-success'
                    : 'bg-danger/10 text-danger'
                )}>
                  addr: {bnd.addr_state}
                </span>
                <span className={cn(
                  'text-xs font-medium px-2 py-0.5 rounded',
                  bnd.port_state === 'ok'
                    ? 'bg-success/10 text-success'
                    : 'bg-danger/10 text-danger'
                )}>
                  port: {bnd.port_state}
                </span>
              </div>
            </div>
            <div className="space-y-1 text-xs">
              <div className="flex justify-between">
                <span className="text-text-secondary">Last addr</span>
                <span className="text-text-primary font-medium font-mono">
                  {bnd.last_addr ?? '-'}
                </span>
              </div>
              {bnd.last_seen_age_secs != null && (
                <div className="flex justify-between">
                  <span className="text-text-secondary">Last seen</span>
                  <span className="text-text-primary font-medium">{bnd.last_seen_age_secs}s ago</span>
                </div>
              )}
            </div>
          </div>
        )}

        {/* IP */}
        {ip && (
          <div className="bg-background rounded p-3 border border-border/50">
            <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">IP Interfaces</h4>
            <div className="space-y-2 text-xs">
              {ip.v4 && (
                <div className="flex justify-between items-center">
                  <div>
                    <span className="text-text-secondary">IPv4: </span>
                    <span className="text-text-primary font-mono">{ip.v4.addr}</span>
                  </div>
                  <span className={cn(
                    'text-xs font-medium px-2 py-0.5 rounded',
                    ip.v4.state === 'good'
                      ? 'bg-success/10 text-success'
                      : 'bg-danger/10 text-danger'
                  )}>
                    {ip.v4.state}
                  </span>
                </div>
              )}
              {ip.v6 && (
                <div className="flex justify-between items-center">
                  <div>
                    <span className="text-text-secondary">IPv6: </span>
                    <span className="text-text-primary font-mono">{ip.v6.addr}</span>
                  </div>
                  <span className={cn(
                    'text-xs font-medium px-2 py-0.5 rounded',
                    ip.v6.state === 'good'
                      ? 'bg-success/10 text-success'
                      : 'bg-danger/10 text-danger'
                  )}>
                    {ip.v6.state}
                  </span>
                </div>
              )}
              {!ip.v4 && !ip.v6 && (
                <span className="text-text-secondary">No interface data</span>
              )}
            </div>
          </div>
        )}

        {/* PID */}
        {pid && (
          <div className="bg-background rounded p-3 border border-border/50">
            <div className="flex items-center justify-between mb-2">
              <h4 className="text-xs font-semibold text-accent uppercase tracking-wide">PID</h4>
              <span className={cn(
                'text-xs font-medium px-2 py-0.5 rounded',
                pid.state === 'non-one'
                  ? 'bg-success/10 text-success'
                  : 'bg-warning/10 text-warning'
              )}>
                {pid.state}
              </span>
            </div>
            <div className="text-xs flex justify-between">
              <span className="text-text-secondary">PID</span>
              <span className="text-text-primary font-medium font-mono">{pid.pid}</span>
            </div>
          </div>
        )}
      </div>

      {/* Upstream Self-Test */}
      {upstreams && upstreams.length > 0 && (
        <div className="mt-4">
          <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Upstreams</h4>
          <div className="grid grid-cols-1 gap-2">
            {upstreams.map((u) => (
              <div key={u.upstream_id} className="bg-background rounded p-3 border border-border/50">
                <div className="grid grid-cols-2 md:grid-cols-4 gap-x-4 gap-y-2 text-xs">
                  <div>
                    <span className="text-text-secondary">ID: </span>
                    <span className="text-text-primary font-medium">{u.upstream_id}</span>
                  </div>
                  <div>
                    <span className="text-text-secondary">Address: </span>
                    <span className="text-text-primary font-medium font-mono">{u.address}</span>
                  </div>
                  <div>
                    <span className="text-text-secondary">Route: </span>
                    <span className="text-text-primary font-medium">{u.route_kind}</span>
                  </div>
                  {u.ip && (
                    <div>
                      <span className="text-text-secondary">IP: </span>
                      <span className="text-text-primary font-medium font-mono">{u.ip}</span>
                    </div>
                  )}
                </div>
                {u.bnd && (
                  <div className="flex flex-wrap gap-2 mt-2">
                    <span className={cn(
                      'text-[10px] font-medium px-2 py-0.5 rounded',
                      u.bnd.addr_state === 'ok' ? 'bg-success/10 text-success' : 'bg-danger/10 text-danger'
                    )}>
                      addr: {u.bnd.addr_state}
                    </span>
                    <span className={cn(
                      'text-[10px] font-medium px-2 py-0.5 rounded',
                      u.bnd.port_state === 'ok' ? 'bg-success/10 text-success' : 'bg-danger/10 text-danger'
                    )}>
                      port: {u.bnd.port_state}
                    </span>
                    {u.bnd.last_addr && (
                      <span className="text-[10px] text-text-secondary px-2 py-0.5">
                        last: <span className="text-text-primary font-mono">{u.bnd.last_addr}</span>
                      </span>
                    )}
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      )}
    </CollapsibleSection>
  );
}
