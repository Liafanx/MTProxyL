import { MetricCard } from '@/components/MetricCard';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { formatNumber, cn } from '@/lib/utils';
import type { MeQualityData } from '@/types/runtime';

interface MEQualitySectionProps {
  data: MeQualityData | null;
}

export function MEQualitySection({ data }: MEQualitySectionProps) {
  if (!data?.data) return null;

  return (
    <CollapsibleSection title="ME Quality">
      <div className="space-y-4">
        {/* DC RTT Table */}
        {data.data.dc_rtt.length > 0 && (
          <div>
            <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Datacenter Status</h4>
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="border-b border-border">
                    <th className="text-left py-2 px-2 text-text-secondary font-medium">DC</th>
                    <th className="text-right py-2 px-2 text-text-secondary font-medium">RTT</th>
                    <th className="text-right py-2 px-2 text-text-secondary font-medium">Writers</th>
                    <th className="text-right py-2 px-2 text-text-secondary font-medium">Coverage</th>
                  </tr>
                </thead>
                <tbody>
                  {data.data.dc_rtt.map((dc) => (
                    <tr key={dc.dc} className="border-b border-border/50">
                      <td className="py-2 px-2 text-text-primary font-medium">DC {dc.dc}</td>
                      <td className="py-2 px-2 text-right text-text-primary">
                        {dc.rtt_ema_ms != null ? `${dc.rtt_ema_ms.toFixed(1)}ms` : '-'}
                      </td>
                      <td className="py-2 px-2 text-right text-text-primary">
                        {dc.alive_writers} / {dc.required_writers}
                      </td>
                      <td className="py-2 px-2 text-right">
                        <span className={cn(
                          'font-medium',
                          dc.coverage_pct >= 90 ? 'text-success' : dc.coverage_pct >= 50 ? 'text-warning' : 'text-danger'
                        )}>
                          {dc.coverage_pct.toFixed(1)}%
                        </span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {/* Counters & Route Drops */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {data.data.counters && (
            <div className="bg-background rounded p-3 border border-border/50">
              <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Counters</h4>
              <div className="grid grid-cols-2 gap-2">
                {Object.entries(data.data.counters).map(([key, value]) => (
                  <MetricCard
                    key={key}
                    label={key.replace(/_total$/, '').replace(/_/g, ' ')}
                    value={formatNumber(value)}
                  />
                ))}
              </div>
            </div>
          )}
          {data.data.route_drops && (
            <div className="bg-background rounded p-3 border border-border/50">
              <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Route Drops</h4>
              <div className="grid grid-cols-2 gap-2">
                {Object.entries(data.data.route_drops).map(([key, value]) => (
                  <MetricCard
                    key={key}
                    label={key.replace(/_total$/, '').replace(/_/g, ' ')}
                    value={formatNumber(value)}
                  />
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </CollapsibleSection>
  );
}
