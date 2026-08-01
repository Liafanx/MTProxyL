import { CollapsibleSection } from '@/components/CollapsibleSection';
import { fieldMeta } from '@/lib/telemetryLabels';

interface NetworkPathSectionProps {
  data: Array<Record<string, unknown>> | null;
}

export function NetworkPathSection({ data }: NetworkPathSectionProps) {
  if (!data || data.length === 0) return null;

  return (
    <CollapsibleSection title="Сетевой путь" defaultOpen={false}
      description="Каким маршрутом трафик уходит в Telegram и что движок выбрал: IPv4 или IPv6, прямо или через промежуточный сервер.">
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
        {data.map((entry, i) => (
          <div key={i} className="bg-background rounded p-3 border border-border/50 text-xs">
            {Object.entries(entry).map(([key, value]) => (
              <div key={key} className="flex justify-between py-0.5">
                <span className="text-text-secondary">{fieldMeta(key).label}</span>
                <span className="text-text-primary font-medium font-mono">{value != null ? String(value) : '-'}</span>
              </div>
            ))}
          </div>
        ))}
      </div>
    </CollapsibleSection>
  );
}
