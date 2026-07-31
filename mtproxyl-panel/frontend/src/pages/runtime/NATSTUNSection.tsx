import { CollapsibleSection } from '@/components/CollapsibleSection';
import type { NatStunData } from '@/types/runtime';

interface NATSTUNSectionProps {
  data: NatStunData | null;
}

export function NATSTUNSection({ data }: NATSTUNSectionProps) {
  if (!data?.data) return null;

  return (
    <CollapsibleSection title="NAT / STUN">
      <div className="space-y-3">
        <div>
          <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Configured Servers</h4>
          <div className="flex flex-wrap gap-2">
            {data.data.servers.configured.map((server: string, i: number) => (
              <span key={i} className="bg-background px-3 py-1.5 rounded text-sm text-text-primary font-mono border border-border/50">
                {server}
              </span>
            ))}
          </div>
        </div>
        {data.data.reflection && (data.data.reflection.v4 || data.data.reflection.v6) && (
          <div>
            <h4 className="text-xs font-semibold text-accent uppercase tracking-wide mb-2">Detected IPs</h4>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-2 text-xs">
              {data.data.reflection.v4 && (
                <div className="flex justify-between bg-background rounded p-2 border border-border/50">
                  <span className="text-text-secondary">IPv4</span>
                  <div className="text-right">
                    <div className="text-text-primary font-mono">{data.data.reflection.v4.addr}</div>
                    <div className="text-text-secondary text-[10px]">{data.data.reflection.v4.age_secs}s ago</div>
                  </div>
                </div>
              )}
              {data.data.reflection.v6 && (
                <div className="flex justify-between bg-background rounded p-2 border border-border/50">
                  <span className="text-text-secondary">IPv6</span>
                  <div className="text-right">
                    <div className="text-text-primary font-mono">{data.data.reflection.v6.addr}</div>
                    <div className="text-text-secondary text-[10px]">{data.data.reflection.v6.age_secs}s ago</div>
                  </div>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </CollapsibleSection>
  );
}
