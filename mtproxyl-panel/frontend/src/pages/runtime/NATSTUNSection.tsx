import { CollapsibleSection } from '@/components/CollapsibleSection';
import { GatedNotice } from '@/components/GatedNotice';
import { KV, Panel } from '@/components/KeyValue';
import { StatePill } from '@/components/ui/state-pill';
import { gatedData, formatAge, formatMs } from '@/lib/gated';
import type { NatStunData } from '@/types/runtime';

interface NATSTUNSectionProps {
  data: NatStunData | null;
}

export function NATSTUNSection({ data }: NATSTUNSectionProps) {
  if (!data) return null;
  const payload = gatedData(data);
  if (!payload) return <GatedNotice title="NAT / STUN" reason={data.reason} />;
  const { flags, servers, reflection } = payload;
  const probing = flags.nat_probe_enabled && !flags.nat_probe_disabled_runtime;

  return (
    <CollapsibleSection
      title="NAT / STUN"
      description="Как сервер выглядит снаружи: какой у него внешний адрес и порт, и не подменяет ли их NAT."
      badge={<StatePill state={probing ? 'ok' : 'muted'}>{probing ? 'проверка включена' : flags.nat_probe_disabled_runtime ? 'отключена на ходу' : 'проверка выключена'}</StatePill>}
    >
      <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
        <Panel title="Серверы STUN">
          <KV label="Настроено" value={servers.configured.length} mono />
          <KV label="Живых" value={`${servers.live_total} из ${servers.configured.length}`} mono />
          <KV label="Попыток на зонд" value={flags.nat_probe_attempts} mono />
          {payload.stun_backoff_remaining_ms != null && payload.stun_backoff_remaining_ms > 0 && (
            <KV label="Пауза до повтора" value={formatMs(payload.stun_backoff_remaining_ms, 0)} mono />
          )}
          <div className="mt-2 flex flex-wrap gap-1">
            {servers.configured.map((server) => (
              <span
                key={server}
                className={servers.live.includes(server) ? 'rounded bg-ok/12 px-2 py-0.5 font-mono text-[11px] text-ok' : 'rounded bg-surface-2 px-2 py-0.5 font-mono text-[11px] text-text-muted'}
              >
                {server}
              </span>
            ))}
          </div>
        </Panel>
        <Panel title="Внешний IPv4">
          {reflection?.v4 ? (
            <>
              <KV label="Адрес" value={reflection.v4.addr} mono />
              <KV label="Определён" value={`${formatAge(reflection.v4.age_secs)} назад`} />
            </>
          ) : (
            <p className="text-meta text-text-muted">Не определён</p>
          )}
        </Panel>
        <Panel title="Внешний IPv6">
          {reflection?.v6 ? (
            <>
              <KV label="Адрес" value={reflection.v6.addr} mono />
              <KV label="Определён" value={`${formatAge(reflection.v6.age_secs)} назад`} />
            </>
          ) : (
            <p className="text-meta text-text-muted">Не определён</p>
          )}
        </Panel>
      </div>
    </CollapsibleSection>
  );
}
