import { formatNumber, cn } from '@/lib/utils';
import { isProbeClass } from '@/lib/probes';

export interface ClassCount {
  class: string;
  total: number;
}

// Friendly names for the classes telemt currently emits; unknown classes fall
// back to a generic humanizer so new backend classes still render sensibly.
const KNOWN_LABELS: Record<string, string> = {
  timeout: 'Таймаут',
  other: 'Прочее',
  unknown_tls_sni: 'Неизвестный TLS SNI',
  tls_clienthello_len_out_of_bounds: 'Недопустимая длина TLS ClientHello',
  tls_clienthello_read_error: 'Ошибка чтения TLS ClientHello',
  tls_clienthello_truncated: 'Обрезанный TLS ClientHello',
  tls_handshake_bad_client: 'TLS handshake — bad client',
  tls_mtproto_bad_client: 'TLS MTProto — bad client',
  direct_modes_disabled: 'Отключённые режимы MTProto',
  direct_mtproto_bad_client: 'Прямой MTProto — bad client',
  proxy_protocol_header_timeout: 'PROXY protocol — таймаут заголовка',
  proxy_protocol_invalid_header: 'PROXY protocol — неверный заголовок',
  proxy_protocol_untrusted: 'PROXY protocol — недоверенный источник',
  web_mtproto_bad_client: 'WEB MTProto — bad client',
  web_mtproto_first_byte_timeout: 'WEB MTProto — таймаут первого байта',
  web_mtproto_handshake_io: 'WEB MTProto — обрыв рукопожатия',
  web_mtproto_handshake_timeout: 'WEB MTProto — таймаут рукопожатия',
  eof: 'Преждевременный EOF',
};

function humanizeClass(cls: string): string {
  const known = KNOWN_LABELS[cls];
  if (known) return known;
  const spaced = cls.replace(/_/g, ' ');
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

function ErrorSection({ title, items, neutral }: { title: string; items: ClassCount[]; neutral?: boolean }) {
  const sorted = items.filter((i) => i.total > 0).sort((a, b) => b.total - a.total);
  if (sorted.length === 0) return null;

  const total = sorted.reduce((sum, i) => sum + i.total, 0);
  const max = sorted[0].total;

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between">
        <span className="text-xs lg:text-sm font-medium text-text-primary">{title}</span>
        <span className={cn('text-xs lg:text-sm font-semibold tabular-nums', neutral ? 'text-text-secondary' : 'text-warning')}>
          {formatNumber(total)}
        </span>
      </div>
      <div className="space-y-1.5">
        {sorted.map((item) => (
          <div key={item.class} className="flex items-center gap-2">
            <span
              className="text-xs text-text-secondary truncate min-w-0 flex-1"
              title={item.class}
            >
              {humanizeClass(item.class)}
            </span>
            <div className="h-1.5 w-16 sm:w-24 rounded-full bg-border overflow-hidden shrink-0">
              <div
                className={cn('h-full rounded-full', neutral ? 'bg-text-muted' : 'bg-warning')}
                style={{ width: `${(item.total / max) * 100}%` }}
              />
            </div>
            <span className="text-xs text-text-primary tabular-nums w-12 text-right shrink-0">
              {formatNumber(item.total)}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

interface ConnectionErrorsProps {
  badByClass?: ClassCount[];
  handshakeFailuresByClass?: ClassCount[];
}

export function ConnectionErrors({ badByClass, handshakeFailuresByClass }: ConnectionErrorsProps) {
  const bad = (badByClass ?? []).filter((i) => !isProbeClass(i.class));
  const probes = (badByClass ?? []).filter((i) => isProbeClass(i.class));
  const handshake = handshakeFailuresByClass ?? [];

  const hasData = [bad, probes, handshake].some((list) => list.some((i) => i.total > 0));
  if (!hasData) return null;

  return (
    <div className="bg-surface border border-border rounded-lg p-3 lg:p-4 space-y-4">
      <h3 className="text-xs lg:text-sm font-medium text-text-secondary">Ошибки соединений</h3>
      <ErrorSection title="Ошибочные соединения" items={bad} />
      <ErrorSection title="Сбои рукопожатия" items={handshake} />
      <ErrorSection title="Отбито проб — сканеры и чужие клиенты, не ошибки прокси" items={probes} neutral />
    </div>
  );
}
