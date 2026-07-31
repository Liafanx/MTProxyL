import { formatNumber } from '@/lib/utils';

export interface ClassCount {
  class: string;
  total: number;
}

// Friendly names for the classes telemt currently emits; unknown classes fall
// back to a generic humanizer so new backend classes still render sensibly.
const KNOWN_LABELS: Record<string, string> = {
  timeout: 'Timeout',
  other: 'Other',
  unknown_tls_sni: 'Unknown TLS SNI',
  tls_clienthello_len_out_of_bounds: 'TLS ClientHello length out of bounds',
  tls_clienthello_read_error: 'TLS ClientHello read error',
  tls_clienthello_truncated: 'TLS ClientHello truncated',
  tls_handshake_bad_client: 'TLS handshake — bad client',
  tls_mtproto_bad_client: 'TLS MTProto — bad client',
  eof: 'Early EOF',
};

function humanizeClass(cls: string): string {
  const known = KNOWN_LABELS[cls];
  if (known) return known;
  const spaced = cls.replace(/_/g, ' ');
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

function ErrorSection({ title, items }: { title: string; items: ClassCount[] }) {
  const sorted = items.filter((i) => i.total > 0).sort((a, b) => b.total - a.total);
  if (sorted.length === 0) return null;

  const total = sorted.reduce((sum, i) => sum + i.total, 0);
  const max = sorted[0].total;

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between">
        <span className="text-xs lg:text-sm font-medium text-text-primary">{title}</span>
        <span className="text-xs lg:text-sm font-semibold text-warning tabular-nums">
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
                className="h-full rounded-full bg-warning"
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
  const bad = badByClass ?? [];
  const handshake = handshakeFailuresByClass ?? [];

  const hasData = bad.some((i) => i.total > 0) || handshake.some((i) => i.total > 0);
  if (!hasData) return null;

  return (
    <div className="bg-surface border border-border rounded-lg p-3 lg:p-4 space-y-4">
      <h3 className="text-xs lg:text-sm font-medium text-text-secondary">Connection Errors</h3>
      <ErrorSection title="Bad connections" items={bad} />
      <ErrorSection title="Handshake failures" items={handshake} />
    </div>
  );
}
