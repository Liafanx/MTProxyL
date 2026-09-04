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
  proxy_mode?: 'mtproto' | 'web' | 'combined';
  /** Чем менеджер держит движок: docker (контейнер) или binary (служба). */
  engine?: string;
  detected_mode: string;
  detected_config: string;
  /** Конфиг движка текущего режима. */
  engine_config?: string;
  port: number;
  /** Состояние своего контейнера MTProxyL: running, exited, absent и т.п. */
  own_container?: string;
  /** Запущен ли движок текущего режима. */
  running?: boolean;
}

/** Что сделать со своим контейнером при уходе из режима менеджера. */
export type ContainerDisposition = 'remove' | 'stop' | 'keep';

export type ProxyAction = 'start' | 'stop' | 'restart';

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
  nginx_custom_enabled: boolean;
  nginx_custom_active: boolean;
  nginx_custom_file: string;
  nginx_custom_file_exists: boolean;
  cert_found: boolean;
  pq_nginx_active: boolean;
  /** Чем проверять домен на PQ: описание источника, пусто — нечем. */
  pq_source: string;
  pq_available: boolean;
  /** true — хватает системного OpenSSL, своя сборка не нужна. */
  pq_system: boolean;
  /** Есть ли снимок настроек до включения Selfmask — его вернёт отключение. */
  prev_saved?: boolean;
  /** Fake SNI, который стоял до Selfmask; пусто, если его не было. */
  prev_domain?: string;
}

export interface WebStatus {
  enabled: boolean;
  proxy_mode: string;
  mtproto_enabled?: boolean;
  frontend: string;
  haproxy_ready: boolean;
  haproxy_cert: string;
  /** shared — один публичный порт на двоих, split — у WEB свой. */
  layout: string;
  public_port: number;
  proxy_port: number;
  domain: string;
  carrier: string;
  secret_mode: string;
  public_addr: string;
  listen_port: number;
  tls_port: number;
  mtproxy_port: number;
  decoy_mode: string;
  decoy_source: string;
  decoy_dir: string;
  debug: boolean;
  /** Что мешает включению, через точку с запятой. Пусто — можно включать. */
  problems: string;
}

export interface WebParam {
  key: string;
  validator: string;
  desc: string;
  value: string;
}

export interface GeoblockStatus {
  mode: 'blacklist' | 'whitelist';
  rules_active: boolean;
  ports_match: boolean;
  service_enabled: boolean;
  countries: string[];
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
  /**
   * Заполнено, когда панель опрашивает не тот движок, которым владеет текущий
   * режим. Готовое сообщение на русском — его и показываем.
   */
  api_mismatch?: string;
  api_expected_port?: number;
  api_enabled?: boolean;
  operation: MtproxylOperation;
}

export interface IpBlockStatus {
  enabled: boolean;
  action: string;
  rules_active: boolean;
  count: number;
  hits_total: number;
  entries: string[];
}

export interface IpBlockHit {
  entry: string;
  packets: number;
  bytes: number;
  first: string;
  last: string;
}

const MTPROXYL_BASE = `${BASE}/api/mtproxyl`;

/** Ответ `mtproxyl update --check`: что стоит и что опубликовано. */
export interface MtproxylUpdateInfo {
  current: string;
  latest: string;
  update_available: boolean;
  /** Ветка, из которой приходят обновления: main у релизной установки. */
  branch?: string;
  release_url?: string;
  /** Проверка не удалась (github недоступен) — версия при этом известна. */
  error?: string;
  checked_at?: string;
}

/** Ответ `mtproxyl engine versions`: чем движок носится и что доступно. */
export interface MtproxylEngineRelease {
  tag: string;
  name: string;
  date: string;
}

export interface MtproxylEngineVersions {
  /** docker или binary. */
  backend: string;
  current: string;
  binary: boolean;
  /** Версии на диске — к ним откатываются без сети. */
  local: string[];
  releases: MtproxylEngineRelease[];
}

/** Ответ `mtproxyl stats --json`: что накоплено на диске. */
export interface MtproxylStats {
  mode: string;
  traffic: { users: number; orphans: number; in_bytes: number; out_bytes: number };
  ips: { records: number; orphans: number };
}

export type MtproxylStatsScope = 'all' | 'traffic' | 'ips' | 'orphans' | 'user';

export const mtproxylApi = {
  status: () => request<MtproxylAvailability>(MTPROXYL_BASE, '/status'),

  // Проверка ходит на github и запускает скрипт под sudo, поэтому ответ
  // кэшируется на сервере; refresh — это кнопка «Проверить».
  update: (refresh = false) =>
    request<MtproxylUpdateInfo>(MTPROXYL_BASE, `/update${refresh ? '?refresh=1' : ''}`),
  applyUpdate: () =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/update/apply', { method: 'POST' }),

  engineVersions: () =>
    request<MtproxylEngineVersions>(MTPROXYL_BASE, '/engine/versions'),
  engineUpdate: (tag: string) =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/engine/update', {
      method: 'POST',
      body: JSON.stringify({ tag }),
    }),
  // Пустой tag — «на предыдущую»: у бинарного движка другой формы нет.
  engineRollback: (tag = '') =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/engine/rollback', {
      method: 'POST',
      body: JSON.stringify({ tag }),
    }),

  stats: () => request<MtproxylStats>(MTPROXYL_BASE, '/stats'),
  statsReset: (scope: MtproxylStatsScope, label = '') =>
    request<{ output: string }>(MTPROXYL_BASE, '/stats/reset', {
      method: 'POST',
      body: JSON.stringify({ scope, label }),
    }),

  // Слот операции общий и переживает перезагрузку страницы, поэтому закрытие
  // окна с логом приходится подтверждать на сервере — иначе тот же лог
  // возвращается при следующем открытии панели.
  dismissOperation: () =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/operation/dismiss', { method: 'POST' }),

  getMode: () => request<MtproxylModeStatus>(MTPROXYL_BASE, '/mode'),
  // container обязателен при переходе в реаниматор: без него CLI выберет
  // умолчание и удалит контейнер, а это решение пользователя.
  switchMode: (mode: MtproxylMode, container?: ContainerDisposition) =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/mode', {
      method: 'POST',
      body: JSON.stringify({ mode, container }),
    }),

  proxyAction: (action: ProxyAction) =>
    request<MtproxylOperation>(MTPROXYL_BASE, `/proxy/${action}`, { method: 'POST' }),

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
  selfmaskNginxConfig: () =>
    request<{ content: string }>(MTPROXYL_BASE, '/selfmask/nginx-config'),
  writeSelfmaskNginxConfig: (content: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/selfmask/nginx-config', {
      method: 'PUT',
      body: JSON.stringify({ content }),
    }),
  toggleSelfmaskNginxConfig: (enabled: boolean) =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/selfmask/nginx-config/toggle', {
      method: 'POST',
      body: JSON.stringify({ enabled }),
    }),
  testSelfmaskNginxConfig: () =>
    request<{ output: string }>(MTPROXYL_BASE, '/selfmask/nginx-config/test', { method: 'POST' }),

  web: () => request<WebStatus>(MTPROXYL_BASE, '/web'),
  webParams: () => request<WebParam[]>(MTPROXYL_BASE, '/web/params'),
  setWebParam: (key: string, value: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/web/params', {
      method: 'POST',
      body: JSON.stringify({ key, value }),
    }),
  webEnable: () =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/web/enable', { method: 'POST' }),
  webDisable: () =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/web/disable', { method: 'POST' }),
  webMode: (mode: 'web' | 'combined') =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/web/mode', {
      method: 'POST',
      body: JSON.stringify({ mode }),
    }),
  webLinks: () => request<{ output: string }>(MTPROXYL_BASE, '/web/links'),
  webHAProxyConfig: () => request<{ output: string }>(MTPROXYL_BASE, '/web/haproxy-config'),
  // Профиль WEB движок сам не заводит: пользователь, созданный через его
  // /v1/users, попадает только в [access.users] и остаётся без WEB-ссылки.
  webSync: () =>
    request<{ output: string }>(MTPROXYL_BASE, '/web/sync', { method: 'POST' }),

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

// ── MTProxyL: собственные настройки прокси ──────────────────────────────────
// Живут в settings.conf, а не в конфиге движка: в Manager тот примонтирован
// только для чтения.

export interface MtproxylSetting {
  key: string;
  validator: string;
  description: string;
  value: string;
}

export const mtproxylSettingsApi = {
  list: () => request<MtproxylSetting[]>(MTPROXYL_BASE, '/settings'),
  set: (key: string, value: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/settings', {
      method: 'POST',
      body: JSON.stringify({ key, value }),
    }),
};

// ── MTProxyL: пользователи (секреты) ────────────────────────────────────────
// В Manager движок не может записать пользователя («Device or resource busy»),
// поэтому правим через CLI; API движка остаётся для чтения статистики.

export interface MtproxylUserIP {
  ip: string;
  first_seen: number;
  last_seen: number;
}

export interface MtproxylUser {
  label: string;
  secret: string;
  created: number;
  enabled: boolean;
  max_conns: number;
  max_ips: number;
  quota_bytes: number;
  /** "0" — бессрочно, иначе RFC3339. */
  expires: string;
  notes: string;
  /** 0, если источник не разделяет направления — тогда актуален total_bytes. */
  total_in: number;
  total_out: number;
  /** Накопленное с первого опроса, переживает перезапуск цели/движка. */
  total_bytes: number;
  /** История IP: копится, пока «активные»/«недавние» списки движка живут только сессию. */
  ip_history: MtproxylUserIP[];
}

export interface MtproxylUserLimits {
  max_conns?: number;
  max_ips?: number;
  quota_bytes?: number;
  /** "0" | "never" | "ГГГГ-ММ-ДД"; поле не передано — не менять. */
  expires?: string;
}

export const mtproxylUsersApi = {
  list: () => request<MtproxylUser[]>(MTPROXYL_BASE, '/users'),
  create: (label: string, secret?: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/users', {
      method: 'POST',
      body: JSON.stringify({ label, secret: secret ?? '' }),
    }),
  remove: (label: string) =>
    request<{ output: string }>(MTPROXYL_BASE, `/users/${encodeURIComponent(label)}`, {
      method: 'DELETE',
    }),
  setLimits: (label: string, limits: MtproxylUserLimits) =>
    request<{ output: string }>(MTPROXYL_BASE, `/users/${encodeURIComponent(label)}/limits`, {
      method: 'POST',
      body: JSON.stringify(limits),
    }),
  setAdTag: (label: string, adTag: string) =>
    request<{ output: string }>(MTPROXYL_BASE, `/users/${encodeURIComponent(label)}/adtag`, {
      method: 'POST',
      body: JSON.stringify({ ad_tag: adTag }),
    }),
  toggle: (label: string, enabled: boolean) =>
    request<{ output: string }>(MTPROXYL_BASE, `/users/${encodeURIComponent(label)}/toggle`, {
      method: 'POST',
      body: JSON.stringify({ enabled }),
    }),
  rotate: (label: string) =>
    request<{ output: string }>(MTPROXYL_BASE, `/users/${encodeURIComponent(label)}/rotate`, {
      method: 'POST',
    }),
  rename: (label: string, to: string) =>
    request<{ output: string }>(MTPROXYL_BASE, `/users/${encodeURIComponent(label)}/rename`, {
      method: 'POST',
      body: JSON.stringify({ to }),
    }),
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
  /** Теги маршрута через запятую; пусто — маршрут для запросов без scope. */
  scopes: string;
  enabled: boolean;
}

export interface UpstreamSpec {
  name: string;
  type: string;
  /** host:port для socks4/socks5, ss://-URL для shadowsocks. */
  address: string;
  user: string;
  password: string;
  weight: number;
  iface: string;
  scopes: string;
}

export interface TrafficUser {
  user: string;
  /** Осмысленны только при directional; иначе весь объём лежит в total. */
  in: number;
  out: number;
  total: number;
  session_in: number;
  session_out: number;
  connections: number;
  unique_ips: number;
  enabled: boolean;
  /** Сводная строка по пользователям, которых больше нет. */
  deleted?: boolean;
}

export interface TrafficReport {
  mode: 'manager' | 'reanimator';
  /** db — своя база менеджера, metrics/api — счётчики цели, none — нет данных. */
  source: 'db' | 'metrics' | 'api' | 'none';
  /** Разделён ли трафик на входящий и исходящий. */
  directional: boolean;
  /** Переживают ли числа перезапуск движка. */
  persistent: boolean;
  error?: string;
  totals: {
    in: number;
    out: number;
    total: number;
    session_in: number;
    session_out: number;
    connections: number;
    unique_ips: number;
  };
  users: TrafficUser[];
}

export const mtproxylNetApi = {
  traffic: () => request<TrafficReport>(MTPROXYL_BASE, '/traffic'),
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

  ipblock: () => request<IpBlockStatus>(MTPROXYL_BASE, '/ipblock'),
  ipblockHits: () => request<{ hits: IpBlockHit[] }>(MTPROXYL_BASE, '/ipblock/hits'),
  ipblockAdd: (entry: string, comment: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/ipblock', {
      method: 'POST',
      body: JSON.stringify({ entry, comment }),
    }),
  ipblockRemove: (entry: string) =>
    request<{ output: string }>(MTPROXYL_BASE, `/ipblock/${encodeURIComponent(entry)}`, {
      method: 'DELETE',
    }),
  ipblockState: (body: { enabled?: boolean; action?: string }) =>
    request<{ output: string }>(MTPROXYL_BASE, '/ipblock/state', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  ipblockImport: (body: string, mode: 'replace' | 'append') =>
    request<{ output: string }>(MTPROXYL_BASE, '/ipblock/import', {
      method: 'POST',
      body: JSON.stringify({ body, mode }),
    }),
  ipblockExportUrl: () => `${MTPROXYL_BASE}/ipblock/export`,

  geoblock: () => request<GeoblockStatus>(MTPROXYL_BASE, '/geoblock'),
  geoblockAdd: (country: string) =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/geoblock', {
      method: 'POST',
      body: JSON.stringify({ country }),
    }),
  geoblockRemove: (country: string) =>
    request<{ output: string }>(MTPROXYL_BASE, `/geoblock/${encodeURIComponent(country)}`, {
      method: 'DELETE',
    }),
  geoblockMode: (mode: 'blacklist' | 'whitelist') =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/geoblock/mode', {
      method: 'PUT',
      body: JSON.stringify({ mode }),
    }),
  geoblockReapply: () =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/geoblock/reapply', {
      method: 'POST',
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
export interface GeoIPStatus {
  city_installed: boolean;
  asn_installed: boolean;
  dir: string;
}

export const mtproxylAddonsApi = {
  pqCheck: (domain: string) =>
    request<{ output: string }>(MTPROXYL_BASE, '/pq-check', {
      method: 'POST',
      body: JSON.stringify({ domain }),
    }),
  /** Поставить PQ OpenSSL, когда системного не хватает. Долгая — операция. */
  pqInstall: () =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/pq-install', { method: 'POST' }),
  /**
   * Не зависит от режима manager/reanimator: база GeoIP живёт в
   * общесистемном каталоге, а не в конфиге цели или менеджера.
   */
  geoipStatus: () => request<GeoIPStatus>(MTPROXYL_BASE, '/geoip-status'),
  /** Скачивает GeoLite2-City/-ASN с зеркала P3TERX. Долгая — операция. */
  geoipInstall: () =>
    request<MtproxylOperation>(MTPROXYL_BASE, '/geoip-install', { method: 'POST' }),
};

// ── Доступность из России ───────────────────────────────────────────────────
// Проверка снаружи, с зондов на домашних сетях: фильтрация применяется к
// абонентскому трафику. HTTPS HEAD на порт прокси с fake SNI, успех —
// полученный TLS-сертификат.

export type AvailabilityLevel = 'green' | 'yellow' | 'red';

export interface AvailabilityTLSInfo {
  authorized: boolean;
  createdAt: string;
  expiresAt: string;
  issuer: { C: string; O: string; CN: string };
  subject: { CN: string; alt: string };
}

export interface AvailabilityProbe {
  city: string;
  country: string;
  region: string;
  continent: string;
  asn: number;
  network: string;
  tags: string[];
  status: string;
  /** Зонд получил TLS-сертификат — прокси для него доступен. */
  tls_success: boolean;
  tls_info?: AvailabilityTLSInfo | null;
  http_status_code?: number;
  raw_output: string;
  error?: string;
}

export interface AvailabilityResult {
  percentage: number;
  level: AvailabilityLevel;
  total_probes: number;
  success_probes: number;
  /** Что именно проверяли: адрес, порт и SNI. */
  target: string;
  measurement_id: string;
  checked_at: string;
  probes?: AvailabilityProbe[];
  error?: string;
}

/** Часовая квота Globalping: один зонд — один кредит. */
export interface AvailabilityQuota {
  budget: number;
  spent: number;
  remaining: number;
  reset_in_seconds: number;
  has_token: boolean;
}

/** Расписание проверок — то, что оператор задал в MTProxyL. */
export interface AvailabilitySchedule {
  /** Идут ли проверки по расписанию. Кнопка «Проверить сейчас» работает всегда. */
  auto_check?: boolean;
  /** Живёт ли systemd-таймер: автопроверка включена, а таймер мог не встать. */
  timer_active?: boolean;
  /** Период автопроверки, минут. */
  interval?: number;
  /** Сколько зондов опрашивается за проверку (кредит за зонд). */
  probes?: number;
  /** Порог доступности для уведомления в телеграм-боте, %. */
  threshold?: number;
  /** Время следующей проверки, RFC3339. Пусто, если таймер не запущен. */
  next_run?: string;
}

export interface AvailabilityStatusResponse extends AvailabilitySchedule {
  enabled: boolean;
  status?: AvailabilityResult | null;
  quota?: AvailabilityQuota;
  message?: string;
}

export interface AvailabilityDetailsResponse extends AvailabilitySchedule {
  enabled: boolean;
  result?: AvailabilityResult | null;
  quota?: AvailabilityQuota;
  message?: string;
}

/** Что проверять. Пустое поле означает «определить автоматически». */
export interface AvailabilityOverride {
  host?: string;
  port?: number;
  sni?: string;
}

export interface AvailabilityTargetResponse {
  override: AvailabilityOverride;
  /** Что подставится на самом деле — переопределение плюс автоопределение. */
  resolved: { host: string; port: number; sni: string; error?: string };
}

const AVAILABILITY_BASE = `${BASE}/api/availability`;

export const availabilityApi = {
  /** Короткая сводка — для индикатора на дашборде. */
  status: () => request<AvailabilityStatusResponse>(AVAILABILITY_BASE, '/status'),
  /** Полный результат со списком зондов. */
  details: () => request<AvailabilityDetailsResponse>(AVAILABILITY_BASE, '/details'),
  /** Проверить прямо сейчас. Сервер может отказать: каждый зонд стоит квоты. */
  check: () =>
    request<AvailabilityDetailsResponse>(AVAILABILITY_BASE, '/check', { method: 'POST' }),
  /** Текущая цель проверки и то, что определилось само. */
  target: () => request<AvailabilityTargetResponse>(AVAILABILITY_BASE, '/target'),
  /** Задать цель. Пустые поля возвращают автоопределение. */
  saveTarget: (o: AvailabilityOverride) =>
    request<AvailabilityTargetResponse>(AVAILABILITY_BASE, '/target', {
      method: 'PUT',
      body: JSON.stringify(o),
    }),
  /** Сохранить токен Globalping. Пустая строка — убрать. */
  setToken: (token: string) =>
    request<{ has_token: boolean }>(AVAILABILITY_BASE, '/token', {
      method: 'PUT',
      body: JSON.stringify({ token }),
    }),
  /** Включить или выключить проверку по расписанию. */
  setAutoCheck: (enabled: boolean) =>
    request<{ auto_check: boolean }>(AVAILABILITY_BASE, '/autocheck', {
      method: 'PUT',
      body: JSON.stringify({ enabled }),
    }),
};

// ── Телеграм-бот ─────────────────────────────────────────────────────────────

export interface TgbotConfig {
  admins: number[];
  notify: Record<string, boolean>;
  intervals: Record<string, number>;
  autobackup: { enabled: boolean; time: string; send_file: boolean };
  /** Локальный SOCKS5 для похода в Telegram; пусто — напрямую. */
  proxy?: string;
  has_token: boolean;
}

export interface TgbotStatus {
  installed: boolean;
  configured: boolean;
  /** Служба запущена сейчас. */
  active: boolean;
  /** Включён автозапуск при загрузке сервера. */
  enabled: boolean;
  dir: string;
  service: string;
  config: TgbotConfig;
}

export interface TgbotStatusResponse {
  /** false — установленный MTProxyL старше бота. */
  supported: boolean;
  message?: string;
  status?: TgbotStatus;
  /** Подсказка про @BotFather — приходит с сервера, чтобы не расходилась с CLI. */
  hint?: string;
  operation?: MtproxylOperation;
}

const TGBOT_BASE = `${BASE}/api/tgbot`;

export const tgbotApi = {
  status: () => request<TgbotStatusResponse>(TGBOT_BASE, '/status'),
  logs: (lines = 100) =>
    request<{ lines: string }>(TGBOT_BASE, `/logs?lines=${lines}`),
  /** Пустой токен — переустановка поверх настроенного бота, без смены токена. */
  install: (token: string, admin: number) =>
    request<MtproxylOperation>(TGBOT_BASE, '/install', {
      method: 'POST',
      body: JSON.stringify({ token, admin }),
    }),
  service: (action: 'start' | 'stop' | 'restart' | 'update') =>
    request<{ output: string }>(TGBOT_BASE, '/service', {
      method: 'POST',
      body: JSON.stringify({ action }),
    }),
  uninstall: () =>
    request<{ output: string }>(TGBOT_BASE, '/uninstall', { method: 'POST' }),
  admin: (id: number, remove = false) =>
    request<TgbotStatusResponse>(TGBOT_BASE, '/admins', {
      method: 'POST',
      body: JSON.stringify({ id, remove }),
    }),
  set: (key: string, value: string) =>
    request<TgbotStatusResponse>(TGBOT_BASE, '/settings', {
      method: 'PUT',
      body: JSON.stringify({ key, value }),
    }),
};

// ── Маршрут до Telegram через WARP ──────────────────────────────────────────
// Правила ставит MTProxyL, включение идёт фоновой операцией: разведка минуты.

const WARP_BASE = `${BASE}/api/warp`;

/** Куда выходим по версии самого Cloudflare. */
export interface WarpExit {
  ip: string;
  loc: string;
  colo: string;
  /** false — туннель не ответил: служба может работать, а маршрута нет. */
  confirmed: boolean;
}

export interface WarpStatus {
  enabled: boolean;
  /** socks — A, iface — B, upstream — C. */
  mode: 'socks' | 'iface' | 'upstream';
  proto: string;
  endpoint: string;
  location: string;
  installed: boolean;
  version: string;
  socks_active: boolean;
  redirect_active: boolean;
  iface_active: boolean;
  nft_applied: boolean;
  cidr_count: number;
  socks_port: number;
  redirect_port: number;
  /** Счётчик nft: сколько пакетов до Telegram ушло в туннель. */
  matched_packets: number;
  exit: WarpExit;
}

export interface WarpStatusResponse {
  /** false — установленный MTProxyL старше этой возможности. */
  supported: boolean;
  message?: string;
  status?: WarpStatus;
}

export interface WarpScanNode {
  node: string;
  endpoint: string;
  ping: string;
  region: string;
  location: string;
}

export interface WarpScanResult {
  scanned_at: number;
  proto?: string;
  filter?: string;
  nodes: WarpScanNode[];
}

export interface WarpScanResponse {
  supported: boolean;
  scan?: WarpScanResult;
}

export interface WarpSettingsPatch {
  location?: string;
  endpoint?: string;
  proto?: string;
}

export const warpApi = {
  status: () => request<WarpStatusResponse>(WARP_BASE, '/status'),
  enable: (mode: 'socks' | 'iface' | 'upstream') =>
    request<MtproxylOperation>(WARP_BASE, '/enable', {
      method: 'POST',
      body: JSON.stringify({ mode }),
    }),
  disable: () => request<MtproxylOperation>(WARP_BASE, '/disable', { method: 'POST' }),
  scan: () => request<MtproxylOperation>(WARP_BASE, '/scan', { method: 'POST' }),
  lastScan: () => request<WarpScanResponse>(WARP_BASE, '/scan'),
  reapply: () => request<MtproxylOperation>(WARP_BASE, '/reapply', { method: 'POST' }),
  save: (patch: WarpSettingsPatch) =>
    request<WarpStatusResponse>(WARP_BASE, '/settings', {
      method: 'PUT',
      body: JSON.stringify(patch),
    }),
};
