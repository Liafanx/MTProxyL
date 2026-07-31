import { MetricCard } from '@/components/MetricCard';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { formatNumber, formatBytes } from '@/lib/utils';
import type { ConnectionsData } from '@/types/runtime';

interface ConnectionsSectionProps {
  data: ConnectionsData | null;
}

export function ConnectionsSection({ data }: ConnectionsSectionProps) {
  if (!data?.totals) return null;

  return (
    <CollapsibleSection title="Connections">
      <div className="space-y-4">
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-2">
          <MetricCard label="Total Connections" value={formatNumber(data.totals.current_connections)} />
          <MetricCard label="ME Connections" value={formatNumber(data.totals.current_connections_me)} />
          <MetricCard label="Direct Connections" value={formatNumber(data.totals.current_connections_direct)} />
          <MetricCard label="Active Users" value={formatNumber(data.totals.active_users)} />
        </div>
        {data.top && (data.top.by_connections.length > 0 || data.top.by_throughput.length > 0) && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {data.top.by_connections.length > 0 && (
              <div>
                <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Top by Connections</h4>
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="border-b border-border">
                        <th className="text-left py-2 px-2 text-text-secondary font-medium">User</th>
                        <th className="text-right py-2 px-2 text-text-secondary font-medium">Connections</th>
                        <th className="text-right py-2 px-2 text-text-secondary font-medium">Traffic</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.top.by_connections.map((user, i) => (
                        <tr key={i} className="border-b border-border/50">
                          <td className="py-2 px-2 text-text-primary font-medium">{user.username}</td>
                          <td className="py-2 px-2 text-right text-text-primary">{formatNumber(user.current_connections)}</td>
                          <td className="py-2 px-2 text-right text-text-primary">{formatBytes(user.total_octets)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}
            {data.top.by_throughput.length > 0 && (
              <div>
                <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Top by Throughput</h4>
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="border-b border-border">
                        <th className="text-left py-2 px-2 text-text-secondary font-medium">User</th>
                        <th className="text-right py-2 px-2 text-text-secondary font-medium">Connections</th>
                        <th className="text-right py-2 px-2 text-text-secondary font-medium">Traffic</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.top.by_throughput.map((user, i) => (
                        <tr key={i} className="border-b border-border/50">
                          <td className="py-2 px-2 text-text-primary font-medium">{user.username}</td>
                          <td className="py-2 px-2 text-right text-text-primary">{formatNumber(user.current_connections)}</td>
                          <td className="py-2 px-2 text-right text-text-primary">{formatBytes(user.total_octets)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}
          </div>
        )}
      </div>
    </CollapsibleSection>
  );
}
