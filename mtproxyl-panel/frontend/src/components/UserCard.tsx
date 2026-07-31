import { Pencil, Trash2, RotateCcw } from 'lucide-react';
import { Link } from 'react-router-dom';
import { cn } from '@/lib/utils';
import { QuotaBar } from '@/components/QuotaBar';
import { ProxyLinkButtons, type ProxyLinkGroup } from '@/components/ProxyLinkButtons';

export interface UserCardProps {
  username: string;
  detailHref: string;
  connections: number;
  activeUniqueIps: number;
  totalTraffic: number;
  online: boolean;
  expiration?: string;
  links?: ProxyLinkGroup[];
  quotaUsed?: number;
  quotaLimit?: number;
  onEdit: () => void;
  onDelete: () => void;
  onResetQuota?: () => void;
  className?: string;
}

const palette = [
  'bg-accent/20 text-accent',
  'bg-status-ok/20 text-status-ok',
  'bg-status-warn/20 text-status-warn',
  'bg-purple-500/20 text-purple-400',
  'bg-pink-500/20 text-pink-400',
  'bg-teal-500/20 text-teal-400',
];

function colorFromName(name: string): string {
  let hash = 0;
  for (let i = 0; i < name.length; i++) hash = name.charCodeAt(i) + ((hash << 5) - hash);
  return palette[Math.abs(hash) % palette.length];
}

function initials(name: string): string {
  return name.split(/[\s_-]+/).slice(0, 2).map((w) => w[0]?.toUpperCase() ?? '').join('');
}

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  return `${(bytes / Math.pow(1024, i)).toFixed(i > 0 ? 1 : 0)} ${units[i]}`;
}

export function UserCard({
  username,
  detailHref,
  connections,
  activeUniqueIps,
  totalTraffic,
  online,
  links,
  quotaUsed,
  quotaLimit,
  onEdit,
  onDelete,
  onResetQuota,
  className,
}: UserCardProps) {
  return (
    <div
      className={cn(
        'bg-surface border border-border rounded-lg p-3 flex items-start gap-3',
        'hover:border-border-hi hover:bg-surface-hover transition-colors',
        className,
      )}
    >
      {/* Avatar */}
      <div className="relative shrink-0">
        <span
          className={cn(
            'inline-flex items-center justify-center rounded-full h-9 w-9 text-xs font-mono font-semibold',
            colorFromName(username),
          )}
        >
          {initials(username)}
        </span>
        <span
          className={cn(
            'absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full border-2 border-surface',
            online ? 'bg-status-ok' : 'bg-text-secondary/40',
          )}
        />
      </div>

      {/* Content */}
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 mb-1">
          <Link to={detailHref} className="text-sm font-medium text-accent hover:underline truncate">
            {username}
          </Link>
          <span
            className={cn(
              'inline-flex items-center gap-1 rounded-full px-1.5 py-0.5 text-[10px] font-mono leading-none shrink-0',
              online
                ? 'bg-status-ok/10 text-status-ok'
                : 'bg-surface-hover text-text-secondary',
            )}
          >
            <span className={cn('h-1.5 w-1.5 rounded-full', online ? 'bg-status-ok' : 'bg-text-secondary/40')} />
            {connections}
          </span>
        </div>

        <div className="flex items-center gap-3 text-[11px] text-text-secondary">
          <span>{formatBytes(totalTraffic)}</span>
          {activeUniqueIps > 0 && <span>{activeUniqueIps} IP</span>}
        </div>

        {links && links.length > 0 && (
          <div className="mt-2">
            <ProxyLinkButtons links={links} />
          </div>
        )}

        {quotaLimit !== undefined && quotaLimit > 0 && quotaUsed !== undefined && (
          <div className="mt-2">
            <QuotaBar used={quotaUsed} limit={quotaLimit} />
          </div>
        )}
      </div>

      {/* Actions */}
      <div className="flex items-center gap-1 shrink-0">
        {onResetQuota && (
          <button
            onClick={onResetQuota}
            className="p-2.5 text-text-secondary hover:text-accent hover:bg-surface-hover rounded-lg transition-colors min-w-[44px] min-h-[44px] flex items-center justify-center"
            title="Reset quota"
          >
            <RotateCcw size={14} />
          </button>
        )}
        <button
          onClick={onEdit}
          className="p-2.5 text-text-secondary hover:text-text-primary hover:bg-surface-hover rounded-lg transition-colors min-w-[44px] min-h-[44px] flex items-center justify-center"
          title="Edit"
        >
          <Pencil size={14} />
        </button>
        <button
          onClick={onDelete}
          className="p-2.5 text-text-secondary hover:text-danger hover:bg-danger/10 rounded-lg transition-colors min-w-[44px] min-h-[44px] flex items-center justify-center"
          title="Delete"
        >
          <Trash2 size={14} />
        </button>
      </div>
    </div>
  );
}
