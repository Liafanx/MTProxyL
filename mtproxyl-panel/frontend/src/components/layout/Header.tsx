import { RefreshCw } from 'lucide-react';
import { cn } from '@/lib/utils';

interface HeaderProps {
  title: string;
  refreshing?: boolean;
  onRefresh?: () => void;
}

export function Header({ title, refreshing, onRefresh }: HeaderProps) {
  return (
    <header className="h-14 border-b border-border flex items-center justify-between px-4 lg:px-6 bg-surface lg:bg-transparent">
      <h2 className="text-base lg:text-lg font-semibold text-text-primary">{title}</h2>
      {onRefresh && (
        <button
          onClick={onRefresh}
          className="p-2 rounded-md text-text-secondary hover:text-text-primary hover:bg-surface-hover transition-colors"
          title="Refresh"
        >
          <RefreshCw size={16} className={cn(refreshing && 'animate-spin')} />
        </button>
      )}
    </header>
  );
}
