import { cn } from '@/lib/utils';

interface StatusBadgeProps {
  status: boolean;
  labelOn?: string;
  labelOff?: string;
}

export function StatusBadge({ status, labelOn = 'ON', labelOff = 'OFF' }: StatusBadgeProps) {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 text-xs font-medium px-2.5 py-1 rounded-full',
        status
          ? 'bg-success/15 text-success'
          : 'bg-danger/15 text-danger'
      )}
    >
      <span
        className={cn(
          'w-1.5 h-1.5 rounded-full',
          status ? 'bg-success' : 'bg-danger'
        )}
      />
      {status ? labelOn : labelOff}
    </span>
  );
}
