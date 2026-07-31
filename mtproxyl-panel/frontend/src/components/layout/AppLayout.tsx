import { useState } from 'react';
import { Outlet, Navigate } from 'react-router-dom';
import { Sidebar, BottomNav } from './Sidebar';
import { useAuth } from '@/hooks/useAuth';
import { Menu } from 'lucide-react';

export function AppLayout() {
  const { username, loading } = useAuth();
  const [sidebarOpen, setSidebarOpen] = useState(false);

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

  return (
    <div className="flex min-h-screen bg-background">
      <Sidebar isOpen={sidebarOpen} onClose={() => setSidebarOpen(false)} />

      <main className="flex-1 min-w-0 overflow-x-hidden lg:ml-60 pb-16 lg:pb-0">
        {/* Mobile header with hamburger */}
        <div className="lg:hidden sticky top-0 z-20 bg-surface border-b border-border px-4 py-3 flex items-center gap-3">
          <button
            onClick={() => setSidebarOpen(true)}
            className="p-2 hover:bg-surface-hover rounded-md"
          >
            <Menu size={20} />
          </button>
          <h1 className="text-sm font-semibold text-text-primary">
            MTProxyL-Panel
          </h1>
        </div>

        <Outlet />
      </main>

      <BottomNav />
    </div>
  );
}
