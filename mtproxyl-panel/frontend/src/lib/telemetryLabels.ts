/**
 * Русские подписи и пояснения для полей телеметрии движка.
 *
 * Движок отдаёт телеметрию плоскими словарями с машинными именами ключей, и
 * разделы просто выводили их как есть, заменив подчёркивания пробелами. Список
 * получался нечитаемым: по названию невозможно понять, что это за число и
 * хорошо ли оно.
 *
 * Здесь только то, что действительно известно. Незнакомый ключ показывается
 * как есть — выдумывать перевод хуже, чем честно показать машинное имя.
 */
export interface FieldMeta {
  label: string;
  /** Короткое пояснение: что это и на что влияет. */
  hint?: string;
}

const FIELDS: Record<string, FieldMeta> = {
  // ── Общее ───────────────────────────────────────────────────────────────
  active_users: { label: 'Активных пользователей' },
  current_connections: { label: 'Текущих соединений' },
  current_connections_me: {
    label: 'Соединений через ME',
    hint: 'Middle-proxy Endpoint — путь через промежуточные серверы Telegram',
  },
  current_connections_direct: {
    label: 'Прямых соединений',
    hint: 'Напрямую в дата-центр, без промежуточного сервера',
  },
  total_octets: { label: 'Всего трафика' },
  errors_total: { label: 'Всего ошибок' },
  event_type: { label: 'Событие' },
  ts_epoch_secs: { label: 'Время' },
  age_secs: { label: 'Возраст' },
  last_seen_age_secs: { label: 'Последний раз виден' },
  last_check_age_secs: { label: 'Последняя проверка' },

  // ── Задержки и качество ─────────────────────────────────────────────────
  dc_rtt: { label: 'RTT до дата-центра', hint: 'Время round-trip до ДЦ Telegram' },
  rtt_ema_ms: { label: 'RTT (сглаженный), мс', hint: 'Скользящее среднее — реагирует плавно' },
  latency_ema_ms: { label: 'Задержка (сглаженная), мс' },
  effective_latency_ms: {
    label: 'Эффективная задержка, мс',
    hint: 'С учётом штрафов за ошибки — по ней выбирается маршрут',
  },
  ewma_errors_per_min: { label: 'Ошибок в минуту (сглаженно)' },
  threshold_errors_per_min: {
    label: 'Порог ошибок в минуту',
    hint: 'Превышение выводит апстрим из ротации',
  },
  samples_15m: { label: 'Замеров за 15 минут' },
  coverage_pct: { label: 'Покрытие, %', hint: 'Доля запросов, попавших в замеры' },

  // ── Апстримы и маршруты ─────────────────────────────────────────────────
  upstream_id: { label: 'Апстрим' },
  upstream_quality: { label: 'Качество апстримов' },
  route_kind: { label: 'Тип маршрута' },
  route_drops: { label: 'Отброшено маршрутом' },
  by_dc: { label: 'По дата-центрам' },
  by_connections: { label: 'По соединениям' },
  by_throughput: { label: 'По пропускной способности' },
  inflight_dc_total: { label: 'Запросов в полёте к ДЦ' },
  inflight_endpoints_total: { label: 'Запросов в полёте к точкам' },
  ip_preference: { label: 'Предпочтение IP', hint: 'IPv4 или IPv6 при выборе маршрута' },

  // ── Пул ME ──────────────────────────────────────────────────────────────
  me_pool_state: { label: 'Состояние пула ME' },
  me_quality: { label: 'Качество ME' },
  me_runtime: { label: 'Работа ME' },
  active_generation: { label: 'Активное поколение', hint: 'Номер набора адресов ME в работе' },
  warm_generation: { label: 'Прогретое поколение', hint: 'Подготовленный набор для смены без разрыва' },
  pending_hardswap_generation: {
    label: 'Ждёт жёсткой смены',
    hint: 'Поколение, которое заменит активное с разрывом соединений',
  },
  alive_writers: { label: 'Живых писателей' },
  required_writers: { label: 'Нужно писателей', hint: 'Меньше нормы — пул считается неполным' },

  // ── Сеть, NAT, время ────────────────────────────────────────────────────
  nat_stun: { label: 'NAT и STUN' },
  network_path: { label: 'Сетевой путь' },
  addr_state: { label: 'Состояние адреса' },
  port_state: { label: 'Состояние порта' },
  last_addr: { label: 'Последний адрес' },
  last_source: { label: 'Источник' },
  last_skew_secs: {
    label: 'Расхождение часов, с',
    hint: 'Разница с эталонным временем — большое значение ломает handshake',
  },
  max_skew_secs_15m: { label: 'Макс. расхождение за 15 мин, с' },

  // ── Попытки подключения к апстримам ─────────────────────────────────────
  connect_attempt_total: { label: 'Попыток подключения' },
  connect_success_total: { label: 'Успешных подключений' },
  connect_fail_total: { label: 'Неудачных подключений' },
  connect_failfast_hard_error_total: {
    label: 'Отказов без повтора',
    hint: 'Ошибки, при которых повторять бессмысленно — движок сдаётся сразу',
  },

  // ── Пул ME: писатели и пороги ───────────────────────────────────────────
  active_writers: { label: 'Активных писателей' },
  fresh_alive_writers: {
    label: 'Живых писателей (свежих)',
    hint: 'Те, что подтвердили жизнеспособность недавно',
  },
  fresh_coverage_pct: { label: 'Свежее покрытие, %' },
  floor_target: { label: 'Целевое число писателей', hint: 'Сколько движок старается держать' },
  floor_min: { label: 'Минимум писателей' },
  floor_max: { label: 'Максимум писателей' },
  floor_capped: {
    label: 'Упёрлись в потолок',
    hint: 'Пул хотел бы больше писателей, но достиг максимума',
  },
  configured_dc_groups: { label: 'Групп дата-центров' },
  configured_endpoints: { label: 'Точек подключения в конфиге' },
  available_endpoints: { label: 'Доступных точек' },
  available_pct: { label: 'Доступность точек, %' },
  endpoint: { label: 'Точка подключения' },
  endpoints: { label: 'Точки подключения' },
  endpoint_writers: { label: 'Писатели по точкам' },
  load: { label: 'Загрузка', hint: 'Сколько запросов сейчас обслуживает' },
  rtt_ms: { label: 'Задержка (RTT), мс' },

  // ── Маршруты и здоровье ─────────────────────────────────────────────────
  dc: {
    label: 'Дата-центр',
    hint: 'Номер ДЦ Telegram; отрицательный — тестовая инфраструктура',
  },
  healthy: { label: 'Исправен' },
  fails: { label: 'Отказов' },
  scopes: {
    label: 'Область применения',
    hint: 'Теги маршрута: запрос со scope идёт только через маршруты с этим тегом, запрос без scope — только через маршруты с пустой областью',
  },
  weight: {
    label: 'Вес',
    hint: 'Приоритет при случайном выборе апстрима: чем больше, тем чаще выбирается',
  },

  // ── Handshake ───────────────────────────────────────────────────────────
  handshake_error_codes: { label: 'Коды ошибок handshake' },

  // ── Состояние безопасности ──────────────────────────────────────────────
  api_read_only: {
    label: 'API только на чтение',
    hint: 'Через API нельзя менять настройки — только читать',
  },
  api_whitelist_enabled: {
    label: 'Белый список API',
    hint: 'API отвечает только адресам из списка; выключен — отвечает всем, кто дотянулся до порта',
  },
  api_whitelist_entries: { label: 'Записей в белом списке API' },
  api_auth_header_enabled: {
    label: 'Заголовок авторизации API',
    hint: 'Запросы без нужного заголовка отклоняются',
  },
  proxy_protocol_enabled: {
    label: 'PROXY protocol',
    hint: 'Реальный IP клиента берётся из заголовка балансировщика, а не из соединения',
  },
  log_level: { label: 'Уровень логирования' },
  telemetry_core_enabled: { label: 'Телеметрия: ядро' },
  telemetry_user_enabled: {
    label: 'Телеметрия: пользователи',
    hint: 'Разбивка метрик по пользователям',
  },
  telemetry_me_level: { label: 'Телеметрия: уровень ME' },
  entries_total: { label: 'Всего записей' },
  generated_at_epoch_secs: { label: 'Собрано' },

  // ── Лимиты ──────────────────────────────────────────────────────────────
  up_bps: { label: 'Отдача', hint: 'Ограничение скорости от клиента, бит/с' },
  down_bps: { label: 'Загрузка', hint: 'Ограничение скорости к клиенту, бит/с' },
  user_rate_limits: { label: 'Лимиты скорости по пользователям' },
  cidr_rate_limits: {
    label: 'Лимиты скорости по подсетям',
    hint: 'Применяются поверх пользовательских; точный CIDR важнее шаблона',
  },
  user_max_tcp_conns: { label: 'Лимит TCP-соединений на пользователя' },
  user_max_tcp_conns_global_each: {
    label: 'Лимит TCP-соединений по умолчанию',
    hint: 'Для всех, у кого нет персонального значения; 0 — без лимита',
  },
  user_max_unique_ips: { label: 'Лимит уникальных IP на пользователя' },
  user_max_unique_ips_global_each: {
    label: 'Лимит уникальных IP по умолчанию',
    hint: 'Для всех, у кого нет персонального значения; 0 — без лимита',
  },
  user_max_unique_ips_mode: {
    label: 'Как считаются уникальные IP',
    hint: 'active_window — по активным сейчас, time_window — за окно времени, combined — оба',
  },
  user_max_unique_ips_window_secs: { label: 'Окно подсчёта уникальных IP' },
  user_data_quota: { label: 'Квота трафика на пользователя' },
  user_expirations: { label: 'Сроки действия пользователей' },
  replay_check_len: {
    label: 'Размер защиты от повторов',
    hint: 'Сколько недавних handshake движок помнит, чтобы отклонить повторный',
  },
  replay_window_secs: { label: 'Окно защиты от повторов' },
  ignore_time_skew: {
    label: 'Игнорировать расхождение часов',
    hint: 'Включено — handshake принимается даже при разъехавшемся времени',
  },
};

/**
 * Имена-шаблоны, которых в словаре нет и быть не должно.
 *
 * Гистограммы движок отдаёт десятками ключей вида
 * connect_duration_success_bucket_101_500ms — перечислять каждый значило бы
 * держать список, который устареет с первой же новой корзиной. Разбираем
 * структуру имени.
 */
function patternMeta(key: string): FieldMeta | null {
  // <что>_bucket_<диапазон>
  const bucket = key.match(/^(.*)_bucket_(.+)$/);
  if (bucket) {
    const [, what, range] = bucket;
    const base = BUCKET_SUBJECTS[what] ?? what.replace(/_/g, ' ');
    return { label: `${base}: ${humanRange(range)}`, hint: 'Столбец гистограммы' };
  }
  // "<известное>_total" — счётчик того же. Только когда основа известна, иначе
  // вышел бы полуперевод вида «unknown field, всего».
  if (key.endsWith('_total')) {
    const base = key.slice(0, -'_total'.length);
    if (base in FIELDS) {
      const inner = FIELDS[base];
      return { label: `${inner.label}, всего`, hint: inner.hint };
    }
  }
  // Лимиты приходят вложенными таблицами и разворачиваются в точечные ключи.
  // Осмысленное имя стоит то в конце пути, то в начале.
  const known = semanticKey(key);
  if (known !== key) {
    const inner = FIELDS[known];
    const context = key.startsWith(known + '.')
      ? key.slice(known.length + 1)
      : key.slice(0, key.length - known.length - 1);
    return { label: `${context} · ${inner.label}`, hint: inner.hint };
  }
  return null;
}

/**
 * Сегмент точечного ключа, который несёт смысл.
 *
 * Нужен и подписи, и форматированию: "user_data_quota.bob" кончается на имя
 * пользователя, поэтому проверка суффикса по полному ключу не сработала бы и
 * квота осталась бы голым числом байт.
 */
function semanticKey(key: string): string {
  if (!key.includes('.')) return key;
  const tail = key.slice(key.lastIndexOf('.') + 1);
  if (tail in FIELDS) return tail;
  const head = key.slice(0, key.indexOf('.'));
  if (head in FIELDS) return head;
  return key;
}

const BUCKET_SUBJECTS: Record<string, string> = {
  connect_attempts: 'Подключений с попытки',
  connect_duration_success: 'Время успешного подключения',
  connect_duration_fail: 'Время неудачного подключения',
};

/** "101_500ms" → "101–500 мс", "gt_4" → "больше 4", "le_100ms" → "до 100 мс". */
function humanRange(raw: string): string {
  const unit = raw.endsWith('ms') ? ' мс' : '';
  const r = raw.replace(/ms$/, '');
  let m = r.match(/^gt_(.+)$/);
  if (m) return `больше ${m[1]}${unit}`;
  m = r.match(/^(?:le|lt)_(.+)$/);
  if (m) return `до ${m[1]}${unit}`;
  m = r.match(/^(\d+)_(\d+)$/);
  if (m) return `${m[1]}–${m[2]}${unit}`;
  return r.replace(/_/g, '–') + unit;
}

/** Возвращает подпись и пояснение, либо машинное имя, если поле незнакомо. */
export function fieldMeta(key: string): FieldMeta {
  const known = FIELDS[key];
  if (known) return known;
  const byPattern = patternMeta(key);
  if (byPattern) return byPattern;
  // Единственная безопасная обработка незнакомого ключа — сделать его
  // читаемым, не притворяясь, что мы знаем его смысл.
  return { label: key.replace(/_/g, ' ') };
}

/** Есть ли у поля перевод — разделам полезно знать, что показывать сырым. */
export function isKnownField(key: string): boolean {
  return key in FIELDS || patternMeta(key) !== null;
}

const SECONDS_SUFFIXES = ['_secs', '_seconds'];

/**
 * Форматирует значение по имени поля.
 *
 * Секунды и миллисекунды движок отдаёт числом — «3600» на экране ничего не
 * говорит, а «1 ч» говорит.
 */
export function formatFieldValue(key: string, value: unknown): string {
  if (value === null || value === undefined || value === '') return '—';
  if (typeof value !== 'number') return String(value);

  // По суффиксу смотрим осмысленный сегмент, а не весь путь: у ключа
  // "user_data_quota.bob" на конце имя пользователя, а не единица измерения.
  const k = semanticKey(key);

  if (k === 'ts_epoch_secs' && value > 1_000_000_000) {
    return new Date(value * 1000).toLocaleString('ru-RU');
  }
  if (SECONDS_SUFFIXES.some((s) => k.endsWith(s))) {
    return humanSeconds(value);
  }
  if (k.endsWith('_pct')) return `${value.toFixed(1)} %`;
  if (k.endsWith('_ms')) return `${value.toFixed(value < 10 ? 1 : 0)} мс`;
  // Лимиты скорости движок отдаёт в битах в секунду. 0 у него означает «без
  // ограничения», а не «запрещено», — иначе строка читается ровно наоборот.
  if (k.endsWith('_bps')) return value === 0 ? 'без лимита' : humanBps(value);
  if (k.endsWith('_quota') || k.endsWith('_bytes')) {
    return value === 0 ? 'без лимита' : humanBytes(value);
  }
  if (Number.isInteger(value)) return value.toLocaleString('ru-RU');
  return value.toFixed(2);
}

function humanBps(bps: number): string {
  if (bps >= 1_000_000_000) return `${(bps / 1_000_000_000).toFixed(1)} Гбит/с`;
  if (bps >= 1_000_000) return `${(bps / 1_000_000).toFixed(1)} Мбит/с`;
  if (bps >= 1_000) return `${(bps / 1_000).toFixed(1)} кбит/с`;
  return `${bps} бит/с`;
}

function humanBytes(bytes: number): string {
  const units = ['Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ'];
  let v = bytes;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${i === 0 ? v : v.toFixed(1)} ${units[i]}`;
}

function humanSeconds(total: number): string {
  const s = Math.abs(Math.round(total));
  if (s < 60) return `${s} с`;
  if (s < 3600) return `${Math.floor(s / 60)} мин ${s % 60} с`;
  if (s < 86400) return `${Math.floor(s / 3600)} ч ${Math.floor((s % 3600) / 60)} мин`;
  return `${Math.floor(s / 86400)} д ${Math.floor((s % 86400) / 3600)} ч`;
}
