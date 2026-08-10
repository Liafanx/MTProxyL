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

const MTPROXYL_BASE = `${BASE}/api/mtproxyl`;

export const mtproxylApi = {
  status: () => request<MtproxylAvailability>(MTPROXYL_BASE, '/status'),

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

export interface AvailabilityStatusResponse {
  enabled: boolean;
  status?: AvailabilityResult | null;
  quota?: AvailabilityQuota;
  /** Идут ли проверки по расписанию. Кнопка «Проверить сейчас» работает всегда. */
  auto_check?: boolean;
  message?: string;
}

export interface AvailabilityDetailsResponse {
  enabled: boolean;
  result?: AvailabilityResult | null;
  quota?: AvailabilityQuota;
  auto_check?: boolean;
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
  /** Включить или выключить проверку по расписанию. */
  setAutoCheck: (enabled: boolean) =>
    request<{ auto_check: boolean }>(AVAILABILITY_BASE, '/autocheck', {
      method: 'PUT',
      body: JSON.stringify({ enabled }),
    }),
};
