import { Link } from 'react-router-dom';
import { ArrowUpCircle } from 'lucide-react';
import { panelVersionLabel, usePanelUpdate } from '@/hooks/usePanelUpdate';

export function PanelUpdateBanner() {
  const { info, error } = usePanelUpdate();
  if (error || !info?.update_available) return null;
  return (
    <Link to="/update" className="flex items-center gap-3 rounded-lg border border-accent/30 bg-accent/10 p-3 text-sm text-accent">
      <ArrowUpCircle size={20} className="shrink-0" />
      <span>Доступна новая версия панели: <strong>{panelVersionLabel(info.latest_version)}</strong>. Перейти к обновлению</span>
    </Link>
  );
}
