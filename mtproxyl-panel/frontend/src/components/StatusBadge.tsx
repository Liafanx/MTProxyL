import { StatePill } from '@/components/ui/state-pill';

interface StatusBadgeProps {
  status: boolean;
  labelOn?: string;
  labelOff?: string;
}

export function StatusBadge({ status, labelOn = 'ON', labelOff = 'OFF' }: StatusBadgeProps) {
  return <StatePill state={status ? 'ok' : 'error'}>{status ? labelOn : labelOff}</StatePill>;
}
