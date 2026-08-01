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

  // ── Handshake ───────────────────────────────────────────────────────────
  handshake_error_codes: { label: 'Коды ошибок handshake' },
};

/** Возвращает подпись и пояснение, либо машинное имя, если поле незнакомо. */
export function fieldMeta(key: string): FieldMeta {
  const known = FIELDS[key];
  if (known) return known;
  // Единственная безопасная обработка незнакомого ключа — сделать его
  // читаемым, не притворяясь, что мы знаем его смысл.
  return { label: key.replace(/_/g, ' ') };
}

/** Есть ли у поля перевод — разделам полезно знать, что показывать сырым. */
export function isKnownField(key: string): boolean {
  return key in FIELDS;
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

  if (key === 'ts_epoch_secs' && value > 1_000_000_000) {
    return new Date(value * 1000).toLocaleString('ru-RU');
  }
  if (SECONDS_SUFFIXES.some((s) => key.endsWith(s))) {
    return humanSeconds(value);
  }
  if (key.endsWith('_pct')) return `${value.toFixed(1)} %`;
  if (key.endsWith('_ms')) return `${value.toFixed(value < 10 ? 1 : 0)} мс`;
  if (Number.isInteger(value)) return value.toLocaleString('ru-RU');
  return value.toFixed(2);
}

function humanSeconds(total: number): string {
  const s = Math.abs(Math.round(total));
  if (s < 60) return `${s} с`;
  if (s < 3600) return `${Math.floor(s / 60)} мин ${s % 60} с`;
  if (s < 86400) return `${Math.floor(s / 3600)} ч ${Math.floor((s % 3600) / 60)} мин`;
  return `${Math.floor(s / 86400)} д ${Math.floor((s % 86400) / 3600)} ч`;
}
