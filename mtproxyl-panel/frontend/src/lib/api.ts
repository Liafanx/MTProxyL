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
    throw new ApiError('unauthorized', 'Session expired');
  }

  const json = await res.json();
  if (!json.ok) {
    const message = json.error?.message || 'Unknown error';
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
}

export interface MtproxylAvailability {
  enabled: boolean;
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
  selfmaskSetup: () =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/selfmask/setup', { method: 'POST' }),
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
