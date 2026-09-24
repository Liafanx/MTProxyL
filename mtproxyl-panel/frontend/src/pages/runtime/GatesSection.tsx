import { KV, Panel } from '@/components/KeyValue';
import { StatePill, type PillState } from '@/components/ui/state-pill';
import { formatEpoch } from '@/lib/gated';

interface GatesSectionProps {
  gates: Record<string, unknown> | null;
}

const ROUTE_MODE: Record<string, { pill: PillState; label: string }> = {
  middle: { pill: 'ok', label: 'через ME' },
  me: { pill: 'ok', label: 'через ME' },
  direct: { pill: 'warn', label: 'напрямую в DC' },
  fallback: { pill: 'warn', label: 'аварийно напрямую' },
};

function bool(v: unknown): boolean | null {
  return typeof v === 'boolean' ? v : null;
}

/** Флаги движка: принимает ли клиентов и каким маршрутом ведёт трафик. */
export function GatesSection({ gates }: GatesSectionProps) {
  if (!gates) return null;
  const accepting = bool(gates.accepting_new_connections);
  const meReady = bool(gates.me_runtime_ready);
  const useMiddle = bool(gates.use_middle_proxy);
  const reroute = bool(gates.reroute_active);
  const routeRaw = typeof gates.route_mode === 'string' ? gates.route_mode : '';
  const route = reroute ? ROUTE_MODE.fallback : ROUTE_MODE[routeRaw] ?? (useMiddle === false ? ROUTE_MODE.direct : undefined);

  return (
    <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
      <Panel title="Приём клиентов">
        <KV label="Новые соединения" value={accepting == null ? '—' : <StatePill state={accepting ? 'ok' : 'error'}>{accepting ? 'принимаются' : 'закрыт'}</StatePill>} />
        <KV label="Условный каст" value={bool(gates.conditional_cast_enabled) ? 'включён' : 'выключен'} />
      </Panel>
      <Panel title="Маршрут в Telegram">
        <KV label="Режим" value={route ? <StatePill state={route.pill}>{route.label}</StatePill> : routeRaw || '—'} />
        <KV label="ME готов" value={meReady == null ? '—' : <StatePill state={meReady ? 'ok' : 'warn'}>{meReady ? 'да' : 'нет'}</StatePill>} />
        {reroute && (
          <KV
            label="Переведён напрямую"
            value={typeof gates.reroute_to_direct_at_epoch_secs === 'number' ? formatEpoch(gates.reroute_to_direct_at_epoch_secs) : 'да'}
            hint={typeof gates.reroute_reason === 'string' ? gates.reroute_reason : undefined}
          />
        )}
      </Panel>
      <Panel title="Аварийные пути">
        <KV label="ME → DC fallback" value={bool(gates.me2dc_fallback_enabled) ? 'включён' : 'выключен'} />
        <KV label="ME → DC fast" value={bool(gates.me2dc_fast_enabled) ? 'включён' : 'выключен'} />
        <KV label="Middle proxy" value={useMiddle == null ? '—' : useMiddle ? 'используется' : 'выключен'} />
      </Panel>
    </div>
  );
}
