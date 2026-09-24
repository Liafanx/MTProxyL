import type { ReactNode } from 'react';
import { RefreshCw } from 'lucide-react';
import { cn } from '@/lib/utils';

interface HeaderProps {
  title: string;
  description?: ReactNode;
  actions?: ReactNode;
  refreshing?: boolean;
  onRefresh?: () => void;
}

export function Header({ title, description, actions, refreshing, onRefresh }: HeaderProps) {
  return (
    <header className="flex items-start justify-between gap-3 px-4 pt-4 lg:px-6 lg:pt-6">
      <div className="min-w-0">
        <h2 className="text-[22px] font-extrabold leading-tight tracking-[-0.02em] text-text md:text-title">{title}</h2>
        {description && <p className="mt-1 max-w-[80ch] text-[13px] leading-relaxed text-text-muted">{description}</p>}
      </div>
      {(actions || onRefresh) && (
        <div className="flex shrink-0 items-center gap-2">
          {actions}
          {onRefresh && (
            <button
              onClick={onRefresh}
              className="tap-target flex items-center justify-center rounded-lg text-text-muted transition-colors hover:bg-surface-2 hover:text-text"
              title="Обновить"
              aria-label="Обновить"
            >
              <RefreshCw size={16} className={cn(refreshing && 'animate-spin')} />
            </button>
          )}
        </div>
      )}
    </header>
  );
}
