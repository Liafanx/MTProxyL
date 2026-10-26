// Отказы движка, за которыми стоит чужой трафик (пробы, сканеры), а не сбой
// прокси. Список совпадает с панелью (internal/history/probes.go).
export const PROBE_CLASSES = new Set([
  'direct_modes_disabled',
  'tls_clienthello_len_out_of_bounds',
  'tls_clienthello_truncated',
  'tls_clienthello_read_error',
  'tls_handshake_bad_client',
  'unknown_tls_sni',
]);

export function isProbeClass(cls: string): boolean {
  return PROBE_CLASSES.has(cls);
}

export function sumProbes(items: { class: string; total: number }[] | undefined): number {
  return (items ?? []).reduce((sum, i) => (isProbeClass(i.class) ? sum + i.total : sum), 0);
}
