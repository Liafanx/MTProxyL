import { CollapsibleSection } from '@/components/CollapsibleSection';
import type { EventsData } from '@/types/runtime';

interface RecentEventsSectionProps {
  data: EventsData | null;
}

export function RecentEventsSection({ data }: RecentEventsSectionProps) {
  if (!data?.events) return null;

  return (
    <CollapsibleSection title="Recent Events">
      <div className="max-h-72 overflow-y-auto space-y-0.5 font-mono text-xs">
        {data.events.length === 0 ? (
          <p className="text-text-secondary py-4 text-center font-sans">No recent events</p>
        ) : (
          data.events.map((evt, i) => (
            <div key={i} className="flex gap-3 py-1 px-2 rounded hover:bg-surface-hover">
              <span className="text-text-secondary shrink-0 tabular-nums">
                {new Date(evt.ts_epoch_secs * 1000).toLocaleTimeString()}
              </span>
              <span className="text-accent shrink-0">{evt.event_type}</span>
              <span className="text-text-primary break-all">{evt.context}</span>
            </div>
          ))
        )}
      </div>
    </CollapsibleSection>
  );
}
