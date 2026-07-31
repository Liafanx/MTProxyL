import { StatusBadge } from '@/components/StatusBadge';
import { MetricCard } from '@/components/MetricCard';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { formatNumber } from '@/lib/utils';
import type { UpstreamQualityData } from '@/types/runtime';

interface UpstreamQualitySectionProps {
  data: UpstreamQualityData | null;
}

export function UpstreamQualitySection({ data }: UpstreamQualitySectionProps) {
  if (!data) return null;

  return (
    <CollapsibleSection title="Upstream Quality">
      <div className="space-y-3">
        {data.summary && (
          <div className="grid grid-cols-2 md:grid-cols-5 gap-2">
            {Object.entries(data.summary).map(([key, value]) => (
              <MetricCard
                key={key}
                label={key.replace(/_total$/, '').replace(/_/g, ' ')}
                value={formatNumber(value)}
              />
            ))}
          </div>
        )}
        <div className="grid grid-cols-1 gap-2">
          {data.upstreams?.map((upstream) => (
            <div key={upstream.upstream_id} className="bg-background rounded p-3 border border-border/50">
              <div className="grid grid-cols-2 md:grid-cols-4 gap-x-4 gap-y-2 text-xs">
                <div>
                  <span className="text-text-secondary">Address: </span>
                  <span className="text-text-primary font-medium">{upstream.address}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Route: </span>
                  <span className="text-text-primary font-medium">{upstream.route_kind}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Health: </span>
                  <StatusBadge status={upstream.healthy} />
                </div>
                <div>
                  <span className="text-text-secondary">Latency: </span>
                  <span className="text-text-primary font-medium">
                    {upstream.effective_latency_ms != null ? `${upstream.effective_latency_ms.toFixed(1)}ms` : '-'}
                  </span>
                </div>
                <div>
                  <span className="text-text-secondary">Weight: </span>
                  <span className="text-text-primary font-medium">{upstream.weight}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Fails: </span>
                  <span className="text-text-primary font-medium">{upstream.fails}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Scopes: </span>
                  <span className="text-text-primary font-medium">{upstream.scopes}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Last Check: </span>
                  <span className="text-text-primary font-medium">{upstream.last_check_age_secs}s ago</span>
                </div>
              </div>
              {upstream.dc.length > 0 && (
                <div className="flex flex-wrap gap-1 mt-2">
                  {upstream.dc.map((dc, i) => (
                    <span key={i} className="bg-surface px-2 py-0.5 rounded text-[10px] border border-border/30">
                      <span className="text-text-secondary">DC {dc.dc}:</span>{' '}
                      <span className="text-text-primary">{dc.latency_ema_ms != null ? `${dc.latency_ema_ms.toFixed(1)}ms` : '-'}</span>
                      <span className="text-text-secondary ml-1">({dc.ip_preference})</span>
                    </span>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
      </div>
    </CollapsibleSection>
  );
}
