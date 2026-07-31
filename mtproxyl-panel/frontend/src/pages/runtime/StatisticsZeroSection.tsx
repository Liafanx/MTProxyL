import { StatusBadge } from '@/components/StatusBadge';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { formatNumber } from '@/lib/utils';

interface StatisticsZeroSectionProps {
  data: Record<string, unknown> | null;
}

export function StatisticsZeroSection({ data }: StatisticsZeroSectionProps) {
  if (!data || Object.keys(data).length === 0) return null;

  return (
    <CollapsibleSection title="Statistics (zero/all)" defaultOpen={false}>
      <div className="space-y-4">
        {Object.entries(data).map(([section, value]) => {
          if (value == null || typeof value !== 'object') return null;
          const entries = Object.entries(value as Record<string, unknown>);
          if (entries.length === 0) return null;
          return (
            <div key={section} className="bg-background rounded p-3 border border-border/50">
              <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">
                {section.replace(/_/g, ' ')}
              </h4>
              <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-2">
                {entries.map(([key, val]) => {
                  if (val == null || typeof val === 'object') return null;
                  const label = key.replace(/_total$/, '').replace(/_/g, ' ');
                  let display = String(val);
                  if (typeof val === 'number') {
                    display = key.includes('seconds') || key.includes('_secs')
                      ? `${(val as number).toFixed(1)}s`
                      : key.includes('pct') || key.includes('ratio')
                        ? `${((val as number) * (val <= 1 ? 100 : 1)).toFixed(1)}%`
                        : formatNumber(val as number);
                  }
                  if (typeof val === 'boolean') {
                    return (
                      <div key={key} className="flex items-center justify-between gap-2 text-xs">
                        <span className="text-text-secondary truncate">{label}</span>
                        <StatusBadge status={val} />
                      </div>
                    );
                  }
                  return (
                    <div key={key} className="text-xs">
                      <div className="text-text-secondary truncate">{label}</div>
                      <div className="text-text-primary font-medium tabular-nums">{display}</div>
                    </div>
                  );
                })}
              </div>
              {/* Render nested arrays (e.g. handshake_error_codes) */}
              {entries.filter(([, v]) => Array.isArray(v) && (v as unknown[]).length > 0).map(([key, val]) => (
                <div key={key} className="mt-2">
                  <span className="text-xs text-text-secondary">{key.replace(/_/g, ' ')}:</span>
                  <div className="flex flex-wrap gap-1 mt-1">
                    {(val as Array<Record<string, unknown>>).map((item, i) => (
                      <span key={i} className="bg-surface px-2 py-0.5 rounded text-[10px] border border-border/30">
                        {Object.entries(item).map(([k, v]) => `${k}: ${v}`).join(', ')}
                      </span>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          );
        })}
      </div>
    </CollapsibleSection>
  );
}
