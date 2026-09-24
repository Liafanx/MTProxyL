import { CollapsibleSection } from '@/components/CollapsibleSection';
import { KV } from '@/components/KeyValue';
import type { NetworkPathEntry } from '@/types/runtime';

interface NetworkPathSectionProps {
  data: NetworkPathEntry[] | null;
}

export function NetworkPathSection({ data }: NetworkPathSectionProps) {
  if (!data || data.length === 0) return null;

  return (
    <CollapsibleSection
      title="Сетевой путь"
      defaultOpen={false}
      description="Каким адресом трафик уходит в каждый дата-центр Telegram и что движок предпочёл: IPv4 или IPv6."
    >
      <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {data.map((entry) => (
          <div key={entry.dc} className="rounded-lg bg-bg p-3">
            <div className="mb-1 text-meta font-semibold text-text">DC {entry.dc}</div>
            <KV label="Предпочтение" value={entry.ip_preference || '—'} mono />
            <KV label="IPv4" value={entry.selected_addr_v4 || '—'} mono />
            <KV label="IPv6" value={entry.selected_addr_v6 || '—'} mono />
          </div>
        ))}
      </div>
    </CollapsibleSection>
  );
}
