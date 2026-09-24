import { useMemo, useState } from 'react';
import { CollapsibleSection } from '@/components/CollapsibleSection';
import { GatedNotice } from '@/components/GatedNotice';
import { Chip } from '@/components/ui/chip';
import { Input } from '@/components/ui/input';
import { StatePill } from '@/components/ui/state-pill';
import { gatedData, formatEpoch } from '@/lib/gated';
import { formatNumber } from '@/lib/utils';
import type { EventsData } from '@/types/runtime';

interface RecentEventsSectionProps {
  data: EventsData | null;
}

const FAMILY_LABELS: Record<string, string> = {
  config: 'конфиг',
  me: 'ME',
  upstream: 'апстримы',
  route: 'маршруты',
  pool: 'пул',
  dc: 'DC',
  web: 'WEB',
  nat: 'NAT',
};

function familyOf(eventType: string): string {
  return eventType.split(/[._]/)[0] || 'other';
}

export function RecentEventsSection({ data }: RecentEventsSectionProps) {
  const [family, setFamily] = useState<string>('all');
  const [query, setQuery] = useState('');
  const payload = gatedData(data);
  const events = useMemo(() => payload?.events ?? [], [payload]);
  const families = useMemo(() => {
    const counts = new Map<string, number>();
    for (const e of events) counts.set(familyOf(e.event_type), (counts.get(familyOf(e.event_type)) ?? 0) + 1);
    return [...counts.entries()].sort((a, b) => b[1] - a[1]);
  }, [events]);
  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    return events
      .filter((e) => family === 'all' || familyOf(e.event_type) === family)
      .filter((e) => !q || e.event_type.toLowerCase().includes(q) || (e.context ?? '').toLowerCase().includes(q))
      .slice()
      .sort((a, b) => b.ts_epoch_secs - a.ts_epoch_secs);
  }, [events, family, query]);

  if (!data) return null;
  if (!payload) {
    return <GatedNotice title="Последние события" reason={data.reason} runtimeEdge />;
  }

  return (
    <CollapsibleSection
      title="Последние события"
      description="Лента заметных событий движка: смена поколения пула, потеря апстрима, ошибки маршрутизации."
      badge={payload.dropped_total > 0 ? <StatePill state="warn">потеряно {formatNumber(payload.dropped_total)}</StatePill> : undefined}
    >
      <div className="space-y-3">
        <div className="flex flex-wrap items-center gap-2">
          <Chip active={family === 'all'} onClick={() => setFamily('all')} count={events.length}>Все</Chip>
          {families.map(([f, n]) => (
            <Chip key={f} active={family === f} onClick={() => setFamily(f)} count={n}>{FAMILY_LABELS[f] ?? f}</Chip>
          ))}
          <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Поиск по типу и контексту" className="h-[34px] max-w-xs" />
        </div>
        <div className="max-h-80 space-y-0.5 overflow-y-auto font-mono text-xs">
          {visible.length === 0 ? (
            <p className="py-4 text-center font-sans text-text-muted">Событий пока нет</p>
          ) : (
            visible.map((evt) => (
              <div key={`${evt.seq}-${evt.ts_epoch_secs}`} className="flex gap-3 rounded px-2 py-1 hover:bg-surface-2">
                <span className="shrink-0 tabular-nums text-text-faint">{formatEpoch(evt.ts_epoch_secs)}</span>
                <span className="shrink-0 text-accent">{evt.event_type}</span>
                <span className="break-all text-text">{evt.context}</span>
              </div>
            ))
          )}
        </div>
        <p className="text-micro text-text-faint">
          Кольцевой буфер на {formatNumber(payload.capacity)} событий; показано {visible.length} из {events.length}.
        </p>
      </div>
    </CollapsibleSection>
  );
}
