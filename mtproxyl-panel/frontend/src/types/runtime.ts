import type { Gated } from '@/lib/gated';

export interface EventEntry {
  seq: number;
  ts_epoch_secs: number;
  event_type: string;
  context: string;
}

export interface EventsPayload {
  capacity: number;
  dropped_total: number;
  events: EventEntry[];
}

export type EventsData = Gated<EventsPayload>;

export interface DcRttEntry {
  dc: number;
  rtt_ema_ms: number | null;
  alive_writers: number;
  required_writers: number;
  coverage_pct: number;
}

export interface MeQualityData {
  enabled: boolean;
  reason?: string;
  generated_at_epoch_secs: number;
  data?: {
    counters: Record<string, number>;
    route_drops: Record<string, number>;
    family_states?: MeFamilyState[];
    drain_gate?: MeDrainGate;
    dc_rtt: DcRttEntry[];
  };
}

export interface MeFamilyState {
  family: string;
  state: string;
  state_since_epoch_secs: number;
  suppressed_until_epoch_secs?: number;
  fail_streak: number;
  recover_success_streak: number;
}

export interface MeDrainGate {
  route_quorum_ok: boolean;
  redundancy_ok: boolean;
  block_reason: string;
  updated_at_epoch_secs: number;
}

export interface UpstreamDc {
  dc: number;
  latency_ema_ms: number | null;
  ip_preference: string;
}

export interface Upstream {
  upstream_id: number;
  route_kind: string;
  address: string;
  weight: number;
  scopes: string;
  healthy: boolean;
  fails: number;
  last_check_age_secs: number;
  effective_latency_ms: number | null;
  dc: UpstreamDc[];
}

export interface ConnectionsTopUser {
  username: string;
  current_connections: number;
  total_octets: number;
}

export interface ConnectionsPayload {
  cache: {
    ttl_ms: number;
    served_from_cache: boolean;
    stale_cache_used: boolean;
  };
  totals: {
    current_connections: number;
    current_connections_me: number;
    current_connections_direct: number;
    active_users: number;
  };
  top: {
    limit: number;
    by_connections: ConnectionsTopUser[];
    by_throughput: ConnectionsTopUser[];
  };
  telemetry: {
    user_enabled: boolean;
    throughput_is_cumulative: boolean;
  };
}

export type ConnectionsData = Gated<ConnectionsPayload>;

export interface UpstreamQualityData {
  enabled: boolean;
  reason?: string;
  generated_at_epoch_secs: number;
  policy?: {
    connect_retry_attempts: number;
    connect_retry_backoff_ms: number;
    connect_budget_ms: number;
    unhealthy_fail_threshold: number;
    connect_failfast_hard_errors: boolean;
  };
  counters?: {
    connect_attempt_total: number;
    connect_success_total: number;
    connect_fail_total: number;
    connect_failfast_hard_error_total: number;
  };
  summary?: Record<string, number>;
  upstreams?: Upstream[];
}

export interface PoolStateData {
  enabled: boolean;
  reason?: string;
  generated_at_epoch_secs: number;
  data?: {
    generations: {
      active_generation: number;
      warm_generation: number;
      pending_hardswap_generation: number | null;
      pending_hardswap_age_secs: number | null;
      draining_generations: number[];
    };
    hardswap: {
      enabled: boolean;
      pending: boolean;
    };
    writers: {
      total: number;
      alive_non_draining: number;
      draining: number;
      degraded: number;
      contour: { active: number; warm: number; draining: number };
      health: { healthy: number; degraded: number; draining: number };
    };
    refill: {
      inflight_endpoints_total: number;
      inflight_dc_total: number;
      by_dc: Array<{ dc: number; family: string; inflight: number }>;
    };
  };
}

export interface MeSelftestKdfData {
  state: string;
  ewma_errors_per_min: number;
  threshold_errors_per_min: number;
  errors_total: number;
}

export interface MeSelftestTimeskewData {
  state: string;
  max_skew_secs_15m: number | null;
  samples_15m: number;
  last_skew_secs: number | null;
  last_source: string | null;
  last_seen_age_secs: number | null;
}

export interface MeSelftestIpFamilyData {
  addr: string;
  state: string;
}

export interface MeSelftestIpData {
  v4?: MeSelftestIpFamilyData;
  v6?: MeSelftestIpFamilyData;
}

export interface MeSelftestPidData {
  pid: number;
  state: string;
}

export interface MeSelftestBndData {
  addr_state: string;
  port_state: string;
  last_addr: string | null;
  last_seen_age_secs: number | null;
}

export interface MeSelftestUpstreamData {
  upstream_id: number;
  route_kind: string;
  address: string;
  bnd?: MeSelftestBndData | null;
  ip?: string | null;
}

export interface MeSelftestData {
  enabled: boolean;
  reason?: string;
  generated_at_epoch_secs: number;
  data?: {
    kdf: MeSelftestKdfData;
    timeskew: MeSelftestTimeskewData;
    ip: MeSelftestIpData;
    pid: MeSelftestPidData;
    bnd: MeSelftestBndData | null;
    upstreams?: MeSelftestUpstreamData[];
  };
}

export interface NatStunData {
  enabled: boolean;
  reason?: string;
  generated_at_epoch_secs: number;
  data?: {
    flags: {
      nat_probe_enabled: boolean;
      nat_probe_disabled_runtime: boolean;
      nat_probe_attempts: number;
    };
    servers: {
      configured: string[];
      live: string[];
      live_total: number;
    };
    reflection?: {
      v4?: { addr: string; age_secs: number };
      v6?: { addr: string; age_secs: number };
    };
    stun_backoff_remaining_ms?: number;
  };
}

export interface MeRuntimeData {
  active_generation?: number;
  warm_generation?: number;
  quarantined_endpoints_total?: number;
  quarantined_endpoints?: Array<{ endpoint: string; remaining_ms: number }>;
  [key: string]: unknown;
}

export interface NetworkPathEntry {
  dc: number;
  ip_preference?: string;
  selected_addr_v4?: string;
  selected_addr_v6?: string;
}

export interface MinimalAllResponse {
  enabled?: boolean;
  reason?: string;
  data?: {
    me_runtime?: MeRuntimeData | null;
    network_path?: NetworkPathEntry[];
  };
}

export interface InitializationComponent {
  id: string;
  title: string;
  status: string;
  started_at_epoch_ms: number | null;
  finished_at_epoch_ms: number | null;
  duration_ms: number | null;
  attempts: number;
  details?: string;
}

export interface InitializationData {
  status: string;
  degraded: boolean;
  current_stage: string;
  progress_pct: number;
  started_at_epoch_secs: number;
  ready_at_epoch_secs?: number;
  total_elapsed_ms: number;
  transport_mode: string;
  me: {
    status: string;
    current_stage: string;
    progress_pct: number;
    init_attempt: number;
    retry_limit: string;
    last_error?: string;
  };
  components: InitializationComponent[];
}
