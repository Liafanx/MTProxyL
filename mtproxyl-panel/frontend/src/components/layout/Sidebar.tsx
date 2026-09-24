import { NavLink } from 'react-router-dom';
import { LayoutDashboard, Users, Activity, Network, LogOut, X, Palette } from 'lucide-react';
import { PANEL_NAV_ITEMS, MTPROXYL_NAV_ITEMS } from './nav';
import { cn } from '@/lib/utils';
import { useAuth } from '@/hooks/useAuth';
import { useTheme, THEMES, THEME_LABELS, isTheme } from '@/hooks/useTheme';
import { useMtproxyl } from '@/hooks/useMtproxyl';
import { useBranding } from '@/hooks/useBranding';

const navItems = PANEL_NAV_ITEMS;
const mtproxylNavItems = MTPROXYL_NAV_ITEMS;

interface SidebarProps {
  isOpen?: boolean;
  onClose?: () => void;
}

export function Sidebar({ isOpen = true, onClose }: SidebarProps) {
  const { logout, username } = useAuth();
  const { theme, setTheme } = useTheme();
  const { enabled: mtproxylEnabled, mode: mtproxylMode } = useMtproxyl();
  const { branding } = useBranding();

  return (
    <>
      {/* Mobile overlay */}
      {isOpen && (
        <div
          className="fixed inset-0 bg-scrim/60 z-40 lg:hidden"
          onClick={onClose}
        />
      )}

      {/* Sidebar */}
      <aside className={cn(
        "w-60 h-dvh bg-surface border-r border-border flex flex-col fixed left-0 top-0 z-50 transition-transform duration-300",
        "lg:translate-x-0",
        isOpen ? "translate-x-0" : "-translate-x-full"
      )}>
        <div className="p-4 border-b border-border flex items-center justify-between">
          <h1
            className="text-[15px] font-extrabold text-text tracking-tight truncate min-w-0 flex-1"
            title={branding.panel_name}
          >
            {branding.panel_name}
          </h1>
          <button
            onClick={onClose}
            className="lg:hidden tap-target flex items-center justify-center rounded-lg text-text-muted hover:bg-surface-2 hover:text-text"
            aria-label="Закрыть меню"
          >
            <X size={20} />
          </button>
        </div>

        {/* pr-4 и стабильный жёлоб: иначе длинные пункты уходили под полосу прокрутки */}
        <nav
          className="flex-1 min-h-0 overflow-y-auto p-3 pr-4 space-y-1"
          style={{ scrollbarGutter: 'stable' }}
        >
          {navItems.map(({ to, icon: Icon, label }) => (
            <NavLink
              key={to}
              to={to}
              end={to === '/'}
              onClick={onClose}
              className={({ isActive }) =>
                cn(
                  'flex min-h-[40px] items-center gap-3 min-w-0 px-3 py-2 rounded-lg text-[13.5px] transition-colors',
                  isActive
                    ? 'bg-accent/14 text-accent font-semibold'
                    : 'text-text-muted hover:text-text hover:bg-surface-2'
                )
              }
            >
              <Icon size={18} className="shrink-0" />
              <span className="truncate">{label}</span>
            </NavLink>
          ))}

          {mtproxylEnabled && (
            <>
              <div className="pt-4 pb-1 px-3 text-micro font-semibold text-text-faint uppercase tracking-[0.06em]">
                MTProxyL
              </div>
              {mtproxylNavItems
                .filter((i) => !i.managerOnly || mtproxylMode === 'manager')
                .map(({ to, icon: Icon, label }) => (
                <NavLink
                  key={to}
                  to={to}
                  onClick={onClose}
                  className={({ isActive }) =>
                    cn(
                      'flex min-h-[40px] items-center gap-3 min-w-0 px-3 py-2 rounded-lg text-[13.5px] transition-colors',
                      isActive
                        ? 'bg-accent/14 text-accent font-semibold'
                        : 'text-text-muted hover:text-text hover:bg-surface-2'
                    )
                  }
                >
                  <Icon size={18} className="shrink-0" />
                  <span className="truncate">{label}</span>
                </NavLink>
              ))}
            </>
          )}
        </nav>

        <div className="p-3 border-t border-border">
          <div className="text-micro text-text-faint mb-1 px-3 truncate">
            {username}
          </div>
          <label className="flex items-center gap-3 px-3 py-1.5 rounded-lg text-[13.5px] text-text-muted hover:text-text hover:bg-surface-2 w-full transition-colors">
            <Palette size={18} className="shrink-0" />
            <span className="sr-only">Тема</span>
            <select
              value={theme}
              onChange={(e) => {
                if (isTheme(e.target.value)) setTheme(e.target.value);
              }}
              className="min-h-[32px] w-full min-w-0 cursor-pointer rounded-md bg-transparent text-[13.5px] text-inherit focus:outline-none"
              aria-label="Тема оформления"
            >
              {THEMES.map((value) => (
                <option key={value} value={value} className="bg-surface text-text">{THEME_LABELS[value]}</option>
              ))}
            </select>
          </label>
          <a
            href="https://github.com/Liafanx/MTProxyL"
            target="_blank"
            rel="noopener noreferrer"
            className="flex min-h-[40px] items-center gap-3 px-3 py-2 rounded-lg text-[13.5px] text-text-muted hover:text-text hover:bg-surface-2 w-full transition-colors"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 2c-.3 1.15-.3 2.35 0 3.5A5.403 5.403 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.39.49-.68 1.05-.85 1.65S8.93 17.38 9 18v4"/><path d="M9 18c-4.51 2-5-2-7-2"/></svg>
            GitHub
          </a>
          <button
            onClick={logout}
            className="flex min-h-[40px] items-center gap-3 px-3 py-2 rounded-lg text-[13.5px] text-text-muted hover:text-error hover:bg-surface-2 w-full transition-colors"
          >
            <LogOut size={18} />
            Выйти
          </button>
        </div>
      </aside>
    </>
  );
}

// Mobile bottom navigation
export function BottomNav() {
  const navItems = [
    { to: '/', icon: LayoutDashboard, label: 'Дашборд' },
    { to: '/users', icon: Users, label: 'Пользователи' },
    { to: '/runtime', icon: Activity, label: 'Телеметрия' },
    { to: '/upstreams', icon: Network, label: 'Ещё' },
  ];

  return (
    <nav className="lg:hidden fixed bottom-0 left-0 right-0 bg-surface border-t border-border z-30 pb-safe" aria-label="Основные разделы">
      <div className="flex min-h-[60px] items-stretch">
        {navItems.map(({ to, icon: Icon, label }) => (
          <NavLink
            key={to}
            to={to}
            end={to === '/'}
            className={({ isActive }) =>
              cn(
                'tap-target flex flex-auto flex-col items-center justify-center gap-0.5 py-1 text-[10px] font-semibold transition-colors min-w-0',
                isActive ? 'text-accent' : 'text-text-faint'
              )
            }
          >
            {({ isActive }) => (
              <>
                <span className={cn('flex h-7 min-w-10 items-center justify-center rounded-lg', isActive && 'bg-accent/14')}>
                  <Icon size={20} />
                </span>
                <span className="truncate max-w-full">{label}</span>
              </>
            )}
          </NavLink>
        ))}
      </div>
    </nav>
  );
}
