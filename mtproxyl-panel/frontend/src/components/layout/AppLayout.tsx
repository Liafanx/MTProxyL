import { useState } from 'react';
import { Outlet, Navigate } from 'react-router-dom';
import { Sidebar, BottomNav } from './Sidebar';
import { Shell } from './Shell';
import { useNavLayout } from '@/hooks/useNavLayout';
import { useAuth } from '@/hooks/useAuth';
import { useMtproxyl } from '@/hooks/useMtproxyl';
import { Menu, AlertTriangle } from 'lucide-react';
import { useBranding } from '@/hooks/useBranding';
import { activePanelBackgroundURL } from '@/lib/api';

export function AppLayout() {
  const { username, loading } = useAuth();
  const [sidebarOpen, setSidebarOpen] = useState(false);
  // Показываем на всех страницах, а не только на дашборде: несоответствие
  // адреса API одинаково искажает и пользователей, и телеметрию, и статус.
  const { apiMismatch } = useMtproxyl();
  const { branding } = useBranding();
  const { layout } = useNavLayout();
  const backgroundURL = activePanelBackgroundURL(branding);

  if (loading) {
    return (
      <div className="h-screen flex items-center justify-center bg-background">
        <div className="w-6 h-6 border-2 border-accent border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  if (!username) {
    return <Navigate to="/login" replace />;
  }

  const mismatch = apiMismatch && (
    <div className="m-4 rounded-lg border border-error/40 bg-error/10 p-4 flex items-start gap-3">
      <AlertTriangle size={18} className="text-error shrink-0 mt-0.5" />
      <div className="min-w-0 space-y-1">
        <p className="text-sm text-text">Данные могут быть от другого движка</p>
        <p className="text-sm text-text-muted break-words">{apiMismatch}</p>
      </div>
    </div>
  );
  const backgroundClass = `bg-bg bg-cover bg-center bg-fixed ${backgroundURL ? 'panel-background' : ''}`;
  const backgroundStyle = backgroundURL
    ? { backgroundImage: `linear-gradient(rgb(var(--bg) / 0.72), rgb(var(--bg) / 0.84)), url("${backgroundURL}")` }
    : undefined;

  if (layout === 'modern') {
    return (
      <div className={`min-h-dvh ${backgroundClass}`} style={backgroundStyle}>
        <Shell>
          {mismatch}
          <Outlet />
        </Shell>
      </div>
    );
  }

  return (
    <div className={`flex min-h-screen ${backgroundClass}`} style={backgroundStyle}>
      <Sidebar isOpen={sidebarOpen} onClose={() => setSidebarOpen(false)} />

      <main className="flex-1 min-w-0 overflow-x-hidden lg:ml-60 pb-16 lg:pb-0">
        <div className="lg:hidden sticky top-0 z-20 bg-surface border-b border-border px-4 py-2 flex items-center gap-2 pt-safe">
          <button
            onClick={() => setSidebarOpen(true)}
            className="tap-target -ml-2 flex items-center justify-center rounded-lg text-text-muted hover:bg-surface-2 hover:text-text"
            aria-label="Открыть меню"
          >
            <Menu size={20} />
          </button>
          <h1 className="text-[15px] font-bold text-text truncate" title={branding.panel_name}>
            {branding.panel_name}
          </h1>
        </div>

        {mismatch}

        <Outlet />
      </main>

      <BottomNav />
    </div>
  );
}
