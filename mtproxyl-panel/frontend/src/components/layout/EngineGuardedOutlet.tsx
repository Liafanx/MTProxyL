import { Link, Outlet, useLocation } from 'react-router-dom';
import { useMtproxyl } from '@/hooks/useMtproxyl';
import { isTelemtOnlyPath } from './nav';

/**
 * Outlet с заглушкой: разделы, привязанные к telemt, скрыты из меню при mtdd,
 * но открыться по прямому адресу всё равно могут.
 */
export function EngineGuardedOutlet() {
  const { pathname } = useLocation();
  const { engineKind } = useMtproxyl();
  if (engineKind === 'mtdd' && isTelemtOnlyPath(pathname)) {
    return (
      <div className="p-4 lg:p-6">
        <div className="rounded-xl border border-dashed border-border-strong bg-surface px-4 py-3">
          <p className="text-meta font-semibold text-text">У mtdd этого раздела нет</p>
          <p className="mt-1 text-micro leading-relaxed text-text-muted">
            Раздел относится к движку telemt. <Link to="/" className="text-accent hover:underline">На дашборд</Link>
          </p>
        </div>
      </div>
    );
  }
  return <Outlet />;
}
