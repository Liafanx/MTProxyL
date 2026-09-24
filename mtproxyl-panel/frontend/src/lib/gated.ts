/** Ответ движка с гейтом: данные приходят только при enabled = true. */
export interface Gated<T> {
  enabled: boolean;
  reason?: string;
  generated_at_epoch_secs?: number;
  data?: T | null;
}

const REASONS: Record<string, string> = {
  feature_disabled: 'функция выключена в конфиге движка',
  source_unavailable: 'источник данных сейчас недоступен',
  middle_proxy_disabled: 'middle proxy выключен',
  not_ready: 'движок ещё не готов',
  starting: 'движок запускается',
  telemetry_disabled: 'телеметрия выключена',
};

export function reasonText(reason?: string): string {
  if (!reason) return 'причина не сообщена';
  return REASONS[reason] ?? reason;
}

/** Гейты группы runtime edge требуют server.api.runtime_edge_enabled. */
export function isRuntimeEdgeGate(reason?: string): boolean {
  return !reason || reason === 'feature_disabled';
}

export function gatedData<T>(value: Gated<T> | null | undefined): T | null {
  if (!value || !value.enabled || value.data == null) return null;
  return value.data;
}

export function formatAge(secs: number | null | undefined): string {
  if (secs == null) return '—';
  if (secs < 60) return `${Math.round(secs)} с`;
  if (secs < 3600) return `${Math.floor(secs / 60)} мин`;
  if (secs < 86400) return `${Math.floor(secs / 3600)} ч ${Math.floor((secs % 3600) / 60)} мин`;
  return `${Math.floor(secs / 86400)} д`;
}

export function formatMs(ms: number | null | undefined, digits = 1): string {
  if (ms == null || !Number.isFinite(ms)) return '—';
  return `${ms.toFixed(digits)} мс`;
}

export function formatEpoch(secs: number | null | undefined): string {
  if (!secs) return '—';
  return new Date(secs * 1000).toLocaleString('ru-RU', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
}
