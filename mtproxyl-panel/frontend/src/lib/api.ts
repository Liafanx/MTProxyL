const BASE = (window as any).__BASE_PATH__ || '';
const TELEMT_BASE = `${BASE}/api/telemt`;
const AUTH_BASE = `${BASE}/api/auth`;

export class ApiError extends Error {
  constructor(public code: string, message: string) {
    super(message);
    this.name = 'ApiError';
  }
}

async function request<T>(base: string, path: string, options?: RequestInit): Promise<T> {
  const url = `${base}${path}`;
  const res = await fetch(url, {
    ...options,
    credentials: 'same-origin',
    headers: {
      'Content-Type': 'application/json',
      ...options?.headers,
    },
  });

  if (res.status === 401 && base === TELEMT_BASE) {
    window.location.href = `${BASE}/login`;
    throw new ApiError('unauthorized', 'Сессия истекла');
  }

  const json = await res.json();
  if (!json.ok) {
    const message = json.error?.message || 'Неизвестная ошибка';
    throw new ApiError(json.error?.code || 'unknown', `${message} (${options?.method || 'GET'} ${path})`);
  }

  return json.data;
}

export const telemt = {
  get: <T>(path: string) => request<T>(TELEMT_BASE, path),
  post: <T>(path: string, body: unknown) =>
    request<T>(TELEMT_BASE, path, { method: 'POST', body: JSON.stringify(body) }),
  patch: <T>(path: string, body: unknown) =>
    request<T>(TELEMT_BASE, path, { method: 'PATCH', body: JSON.stringify(body) }),
  delete: <T>(path: string) =>
    request<T>(TELEMT_BASE, path, { method: 'DELETE' }),
};

const PANEL_BASE = `${BASE}/api`;


export const panelApi = {
  get: <T>(path: string) => request<T>(PANEL_BASE, path),
  post: <T>(path: string, body?: unknown) =>
    request<T>(PANEL_BASE, path, { method: 'POST', body: body ? JSON.stringify(body) : undefined }),
  put: <T>(path: string, body?: unknown) =>
    request<T>(PANEL_BASE, path, { method: 'PUT', body: body ? JSON.stringify(body) : undefined }),
};

export const authApi = {
  login: (username: string, password: string) =>
    request<{ username: string }>(AUTH_BASE, '/login', {
      method: 'POST',
      body: JSON.stringify({ username, password }),
    }),
  logout: () =>
    request<null>(AUTH_BASE, '/logout', { method: 'POST' }),
  me: () =>
    request<{ username: string }>(AUTH_BASE, '/me'),
};

// ── MTProxyL integration ────────────────────────────────────────────────────
// Host-level features backed by the MTProxyL CLI rather than telemt's API.

export type MtproxylMode = 'manager' | 'reanimator';

export interface MtproxylModeStatus {
  mode: MtproxylMode;
  detected_mode: string;
  detected_config: string;
  port: number;
}

export interface SelfmaskStatus {
  enabled: boolean;
  domain: string;
  site_source: string;
  site_dir: string;
  backend_port: number;
  cert_mode: string;
  auto_renew: boolean;
  nginx_conf: string;
  nginx_conf_exists: boolean;
  cert_found: boolean;
  pq_nginx_active: boolean;
}

export interface SelfmaskParam {
  key: string;
  validator: string;
  description: string;
  value: string;
}

export interface MtproxylBackup {
  name: string;
  size: number;
  mtime: number;
}

export type OperationPhase = 'idle' | 'running' | 'done' | 'failed';

export interface MtproxylOperation {
  phase: OperationPhase;
  name?: string;
  output?: string;
  error?: string;
  started_at?: string;
  ended_at?: string;
  /** Вывод команды на текущий момент — чтобы было видно, на каком она шаге. */
  progress?: string;
  /** Сколько операция уже идёт, по часам сервера. */
  elapsed_seconds?: number;
}

export interface MtproxylAvailability {
  enabled: boolean;
  /** Пусто, если режим не удалось прочитать. */
  mode: MtproxylMode | '';
  operation: MtproxylOperation;
}

const MTPROXYL_BASE = `${BASE}/api/mtproxyl`;

export const mtproxylApi = {
  status: () => request<MtproxylAvailability>(MTPROXYL_BASE, '/status'),

  getMode: () => request<MtproxylModeStatus>(MTPROXYL_BASE, '/mode'),
  switchMode: (mode: MtproxylMode) =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/mode', {
      method: 'POST',
      body: JSON.stringify({ mode }),
    }),

  selfmask: () => request<SelfmaskStatus>(MTPROXYL_BASE, '/selfmask'),
  selfmaskParams: () => request<SelfmaskParam[]>(MTPROXYL_BASE, '/selfmask/params'),
  setSelfmaskParam: (key: string, value: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/selfmask/params', {
      method: 'POST',
      body: JSON.stringify({ key, value }),
    }),
  selfmaskApply: () =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/selfmask/apply', { method: 'POST' }),
  selfmaskVerify: () =>
    request<{ output: string }>(MTPROXYL_BASE, '/selfmask/verify', { method: 'POST' }),
  selfmaskDisable: () =>
    request<{ output: string }>(MTPROXYL_BASE, '/selfmask/disable', { method: 'POST' }),

  backups: () => request<MtproxylBackup[]>(MTPROXYL_BASE, '/backups'),
  createBackup: () =>
    request<{ name: string }>(MTPROXYL_BASE, '/backups', { method: 'POST' }),
  restoreBackup: (name: string) =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/backups/restore', {
      method: 'POST',
      body: JSON.stringify({ name }),
    }),
  // Plain link rather than fetch: the browser handles the file download.
  downloadUrl: (name: string) =>
    `${MTPROXYL_BASE}/backups/${encodeURIComponent(name)}/download`,
};

// ── MTProxyL: лимитер, Zapret2, geoblock, маршруты ──────────────────────────

export interface NftParam {
  key: string;
  validator: string;
  description: string;
  value: string;
}

export interface NftStatus {
  nft: { enabled: boolean; mode: string; service_active: boolean };
  ios_fix_v1: { enabled: boolean };
  ios_fix_v2: { enabled: boolean };
  zapret2: { applied: boolean; service_active: boolean };
  meko_opt: { applied: boolean };
  params: NftParam[];
}

export type NftAction =
  | 'apply' | 'remove' | 'service' | 'smart'
  | 'ios1' | 'ios1-off' | 'ios2' | 'ios2-off'
  | 'zapret2' | 'zapret2-start' | 'zapret2-stop' | 'zapret2-rm' | 'zapret2-wscale'
  | 'drop';

export interface Upstream {
  name: string;
  type: string;
  address: string;
  user: string;
  has_password: boolean;
  weight: number;
  iface: string;
  enabled: boolean;
}

export interface UpstreamSpec {
  name: string;
  type: string;
  address: string;
  user: string;
  password: string;
  weight: number;
  iface: string;
}

export const mtproxylNetApi = {
  nft: () => request<NftStatus>(MTPROXYL_BASE, '/nft'),
  setNftParam: (key: string, value: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/nft/params', {
      method: 'POST',
      body: JSON.stringify({ key, value }),
    }),
  nftAction: (action: NftAction) =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/nft/action', {
      method: 'POST',
      body: JSON.stringify({ action }),
    }),
  nftPreset: (preset: 'classic' | 'smart') =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/nft/preset', {
      method: 'POST',
      body: JSON.stringify({ preset }),
    }),

  geoblock: () => request<{ countries: string[] }>(MTPROXYL_BASE, '/geoblock'),
  geoblockAdd: (country: string) =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/geoblock', {
      method: 'POST',
      body: JSON.stringify({ country }),
    }),
  geoblockRemove: (country: string) =>
    request<{ output: string }>(MTPROXYL_BASE, `/geoblock/${encodeURIComponent(country)}`, {
      method: 'DELETE',
    }),

  upstreams: () => request<Upstream[]>(MTPROXYL_BASE, '/upstreams'),
  upstreamAdd: (spec: UpstreamSpec) =>
    request<{ output: string }>(MTPROXYL_BASE, '/upstreams', {
      method: 'POST',
      body: JSON.stringify(spec),
    }),
  upstreamRemove: (name: string) =>
    request<{ output: string }>(MTPROXYL_BASE, `/upstreams/${encodeURIComponent(name)}`, {
      method: 'DELETE',
    }),
  upstreamToggle: (name: string, enabled: boolean) =>
    request<{ output: string }>(MTPROXYL_BASE, `/upstreams/${encodeURIComponent(name)}/toggle`, {
      method: 'POST',
      body: JSON.stringify({ enabled }),
    }),
  upstreamTest: (name: string) =>
    request<{ output: string }>(MTPROXYL_BASE, `/upstreams/${encodeURIComponent(name)}/test`, {
      method: 'POST',
    }),
};

// ── MTProxyL: экспертный режим ──────────────────────────────────────────────

export interface ExpertParam {
  section: string;
  key: string;
  type: string;
  default: string;
  hot_reload: boolean;
  validator: string;
  hint: string;
  description: string;
  override: string;
  has_override: boolean;
}

export interface SuperExpertStatus {
  enabled: boolean;
  active: boolean;
  file: string;
  file_exists: boolean;
  size: number;
  mtime: number;
}

export const mtproxylExpertApi = {
  catalog: () => request<ExpertParam[]>(MTPROXYL_BASE, '/expert'),
  set: (section: string, key: string, value: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/expert', {
      method: 'POST',
      body: JSON.stringify({ section, key, value }),
    }),
  clear: (section: string, key: string) =>
    request<{ output: string }>(
      MTPROXYL_BASE,
      `/expert/${encodeURIComponent(section)}/${encodeURIComponent(key)}`,
      { method: 'DELETE' },
    ),
  // Правки сохраняются без пересборки конфига, применение — одним вызовом
  // на всю пачку.
  apply: () => request<{ output: string }>(MTPROXYL_BASE, '/expert/apply', { method: 'POST' }),

  superExpert: () => request<SuperExpertStatus>(MTPROXYL_BASE, '/superexpert'),
  superExpertConfig: () => request<{ content: string }>(MTPROXYL_BASE, '/superexpert/config'),
  saveSuperExpertConfig: (content: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/superexpert/config', {
      method: 'PUT',
      body: JSON.stringify({ content }),
    }),
  toggleSuperExpert: (enabled: boolean) =>
    request<{ output: string }>(MTPROXYL_BASE, '/superexpert/toggle', {
      method: 'POST',
      body: JSON.stringify({ enabled }),
    }),
};

/**
 * PQ-проверка домена. Пустой домен означает текущий SNI.
 *
 * censorcheck из меню MTProxyL сюда намеренно не перенесён: он запускает
 * сторонний скрипт, скачанный из сети, и делать это по нажатию кнопки в
 * вебе не стоит — команда остаётся в CLI.
 */
export const mtproxylAddonsApi = {
  pqCheck: (domain: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/pq-check', {
      method: 'POST',
      body: JSON.stringify({ domain }),
    }),
};
