import { useState } from 'react';
import { ChevronDown } from 'lucide-react';
import { cn } from '@/lib/utils';

interface CollapsibleSectionProps {
  title: string;
  description?: string;
  badge?: React.ReactNode;
  defaultOpen?: boolean;
  children: React.ReactNode;
}

export function CollapsibleSection({ title, description, badge, defaultOpen = true, children }: CollapsibleSectionProps) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="overflow-hidden rounded-xl border border-border bg-surface">
      <button
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        className="flex min-h-[48px] w-full items-center justify-between px-4 py-3 text-left transition-colors hover:bg-surface-2"
      >
        <div className="flex min-w-0 items-center gap-2">
          <h3 className="text-[13px] font-semibold text-text">{title}</h3>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {badge}
          <ChevronDown size={16} className={cn('shrink-0 text-text-muted transition-transform', open && 'rotate-180')} />
        </div>
      </button>
      {open && (
        <div className="px-4 pb-4">
          {description && (
            <p className="mb-3 text-meta text-text-muted">{description}</p>
          )}
          {children}
        </div>
      )}
    </div>
  );
}
