import { MetricCard } from '@/components/MetricCard';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { formatNumber } from '@/lib/utils';
import type { PoolStateData } from '@/types/runtime';

interface MEPoolStateSectionProps {
  data: PoolStateData | null;
}

export function MEPoolStateSection({ data }: MEPoolStateSectionProps) {
  if (!data?.data) return null;

  return (
    <CollapsibleSection title="ME Pool State">
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div className="bg-background rounded p-3 border border-border/50">
          <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Generations</h4>
          <div className="space-y-1 text-xs">
            <div className="flex justify-between">
              <span className="text-text-secondary">Active</span>
              <span className="text-text-primary font-medium">{data.data.generations.active_generation}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-text-secondary">Warm</span>
              <span className="text-text-primary font-medium">{data.data.generations.warm_generation}</span>
            </div>
            {data.data.generations.pending_hardswap_generation != null && (
              <div className="flex justify-between">
                <span className="text-text-secondary">Pending Hardswap</span>
                <span className="text-text-primary font-medium">{data.data.generations.pending_hardswap_generation}</span>
              </div>
            )}
          </div>
        </div>
        <div className="bg-background rounded p-3 border border-border/50">
          <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Contour</h4>
          <div className="space-y-1 text-xs">
            <div className="flex justify-between">
              <span className="text-text-secondary">Active</span>
              <span className="text-text-primary font-medium">{data.data.writers.contour.active}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-text-secondary">Warm</span>
              <span className="text-text-primary font-medium">{data.data.writers.contour.warm}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-text-secondary">Draining</span>
              <span className="text-text-primary font-medium">{data.data.writers.contour.draining}</span>
            </div>
          </div>
        </div>
        <div className="bg-background rounded p-3 border border-border/50">
          <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Writers Health</h4>
          <div className="space-y-1 text-xs">
            <div className="flex justify-between">
              <span className="text-text-secondary">Healthy</span>
              <span className="text-text-primary font-medium">{data.data.writers.health.healthy}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-text-secondary">Degraded</span>
              <span className="text-text-primary font-medium">{data.data.writers.health.degraded}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-text-secondary">Draining</span>
              <span className="text-text-primary font-medium">{data.data.writers.health.draining}</span>
            </div>
          </div>
        </div>
      </div>
      {data.data.refill.inflight_endpoints_total > 0 && (
        <div className="bg-background rounded p-3 border border-border/50 mt-4">
          <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Refill</h4>
          <div className="grid grid-cols-2 gap-2 mb-3">
            <MetricCard label="Inflight Endpoints" value={formatNumber(data.data.refill.inflight_endpoints_total)} />
            <MetricCard label="Inflight DC" value={formatNumber(data.data.refill.inflight_dc_total)} />
          </div>
          {data.data.refill.by_dc.length > 0 && (
            <div className="flex flex-wrap gap-1">
              {data.data.refill.by_dc.map((dc, i) => (
                <span key={i} className="bg-surface px-2 py-0.5 rounded text-[10px] border border-border/30">
                  <span className="text-text-secondary">DC {dc.dc} ({dc.family}):</span>{' '}
                  <span className="text-text-primary">{dc.inflight}</span>
                </span>
              ))}
            </div>
          )}
        </div>
      )}
    </CollapsibleSection>
  );
}
