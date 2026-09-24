import { useEffect, useState, type ReactNode } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { LogOut, MoreHorizontal, Palette, X } from 'lucide-react';
import { cn } from '@/lib/utils';
import { useAuth } from '@/hooks/useAuth';
import { useTheme, THEMES, THEME_LABELS, isTheme } from '@/hooks/useTheme';
import { useMtproxyl } from '@/hooks/useMtproxyl';
import { useBranding } from '@/hooks/useBranding';
import { useKeyboardInset } from '@/hooks/useKeyboardInset';
import { Dialog, DialogContent } from '@/components/ui/dialog';
import { PANEL_NAV_ITEMS, isNavItemActive, mtproxylItems, primaryItems, type NavItem } from './nav';

/** Одна навигация в трёх геометриях: табы до 600px, рельса до 1180px, полное меню шире. */
export function Shell({ children }: { children: ReactNode }) {
  const { pathname } = useLocation();
  const { enabled, mode } = useMtproxyl();
  const keyboardInset = useKeyboardInset();
  const [moreOpen, setMoreOpen] = useState(false);
  const [railMoreOpen, setRailMoreOpen] = useState(false);
  const primary = primaryItems(enabled, mode);
  const primaryPaths = new Set(primary.map((i) => i.to));
  const secondaryPanel = PANEL_NAV_ITEMS.filter((i) => !primaryPaths.has(i.to));
  const secondaryMtproxyl = mtproxylItems(enabled, mode).filter((i) => !primaryPaths.has(i.to));
  const secondaryActive = [...secondaryPanel, ...secondaryMtproxyl].some((i) => isNavItemActive(i.to, pathname));

  useEffect(() => {
    setMoreOpen(false);
    setRailMoreOpen(false);
  }, [pathname]);

  useEffect(() => {
    if (!railMoreOpen) return;
    const close = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setRailMoreOpen(false);
    };
    document.addEventListener('keydown', close);
    return () => document.removeEventListener('keydown', close);
  }, [railMoreOpen]);

  return (
    <div className="flex min-h-dvh min-[600px]:flex-row">
      <FullSidebar pathname={pathname} panelItems={PANEL_NAV_ITEMS} mtproxylItems={mtproxylItems(enabled, mode)} />

      <aside className="sticky top-0 z-30 hidden h-dvh w-16 shrink-0 flex-col items-center border-r border-border bg-surface py-3 min-[600px]:flex min-[1180px]:hidden">
        <BrandMark compact />
        <nav className="mt-4 flex flex-col gap-2" aria-label="Основные разделы">
          {primary.map((item) => (
            <RailLink key={item.to} item={item} active={isNavItemActive(item.to, pathname)} />
          ))}
        </nav>
        <button
          type="button"
          className={cn(
            'tap-target mt-auto flex w-11 items-center justify-center rounded-lg text-text-faint transition-colors hover:bg-surface-2 hover:text-text',
            (secondaryActive || railMoreOpen) && 'bg-accent/14 text-accent',
          )}
          aria-label="Ещё разделы"
          aria-haspopup="menu"
          aria-expanded={railMoreOpen}
          onClick={() => setRailMoreOpen((v) => !v)}
        >
          <MoreHorizontal size={20} />
        </button>
        {railMoreOpen && (
          <>
            <button type="button" className="fixed inset-0 z-30 cursor-default" aria-label="Закрыть" onClick={() => setRailMoreOpen(false)} />
            <div className="fixed bottom-3 left-[72px] z-40 max-h-[85dvh] w-72 overflow-y-auto rounded-xl border border-border bg-surface p-2 shadow-2xl">
              <SecondaryLinks panelItems={secondaryPanel} mtproxylItems={secondaryMtproxyl} pathname={pathname} onNavigate={() => setRailMoreOpen(false)} />
            </div>
          </>
        )}
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <div className="sticky top-0 z-20 flex items-center gap-2 border-b border-border bg-surface px-4 py-2 pt-safe min-[600px]:hidden">
          <BrandMark compact />
          <PanelTitle />
        </div>
        <main className="flex-1 pb-[76px] min-[600px]:pb-0">{children}</main>
        <nav
          className="fixed inset-x-0 bottom-0 z-40 flex min-h-[60px] border-t border-border bg-surface pb-safe min-[600px]:hidden"
          style={{ bottom: keyboardInset }}
          aria-label="Основные разделы"
        >
          {primary.map((item) => (
            <BottomLink key={item.to} item={item} active={isNavItemActive(item.to, pathname)} />
          ))}
          <button
            type="button"
            className={cn(
              'tap-target flex flex-auto flex-col items-center justify-center gap-0.5 py-1 text-[10px] font-semibold',
              secondaryActive || moreOpen ? 'text-accent' : 'text-text-faint',
            )}
            aria-label="Ещё разделы"
            aria-haspopup="dialog"
            aria-expanded={moreOpen}
            onClick={() => setMoreOpen(true)}
          >
            <span className={cn('flex h-7 min-w-10 items-center justify-center rounded-lg', (secondaryActive || moreOpen) && 'bg-accent/14')}>
              <MoreHorizontal size={20} />
            </span>
            Ещё
          </button>
        </nav>
      </div>

      <Dialog open={moreOpen} onClose={() => setMoreOpen(false)}>
        <DialogContent className="lg:max-w-md">
          <div className="mb-2 flex items-center justify-between">
            <h2 className="text-[15px] font-bold text-text">Разделы</h2>
            <button type="button" onClick={() => setMoreOpen(false)} className="tap-target -mr-2 flex items-center justify-center rounded-lg text-text-muted hover:bg-surface-2 hover:text-text" aria-label="Закрыть">
              <X size={18} />
            </button>
          </div>
          <SecondaryLinks panelItems={secondaryPanel} mtproxylItems={secondaryMtproxyl} pathname={pathname} onNavigate={() => setMoreOpen(false)} />
        </DialogContent>
      </Dialog>
    </div>
  );
}

function PanelTitle() {
  const { branding } = useBranding();
  return <h1 className="min-w-0 flex-1 truncate text-[15px] font-bold text-text" title={branding.panel_name}>{branding.panel_name}</h1>;
}

function BrandMark({ compact = false }: { compact?: boolean }) {
  const { branding } = useBranding();
  const initial = (branding.panel_name || 'M').trim().charAt(0).toUpperCase();
  return (
    <span
      className={cn('brand-gradient flex shrink-0 items-center justify-center rounded-xl font-extrabold text-brand-text', compact ? 'h-8 w-8 text-sm' : 'h-10 w-10 text-base')}
      aria-hidden="true"
    >
      {initial}
    </span>
  );
}

function FullSidebar({ pathname, panelItems, mtproxylItems: mtItems }: { pathname: string; panelItems: NavItem[]; mtproxylItems: NavItem[] }) {
  const { branding } = useBranding();
  return (
    <aside className="sticky top-0 z-30 hidden h-dvh w-[240px] shrink-0 flex-col border-r border-border bg-surface px-3 py-4 min-[1180px]:flex">
      <div className="flex items-center gap-2.5 px-2.5 pb-4">
        <BrandMark />
        <span title={branding.panel_name} className="min-w-0 flex-1 truncate text-sm font-bold text-text">{branding.panel_name}</span>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto pr-1" style={{ scrollbarGutter: 'stable' }}>
        <SidebarGroup label="Панель" items={panelItems} pathname={pathname} />
        {mtItems.length > 0 && <SidebarGroup label="MTProxyL" items={mtItems} pathname={pathname} className="mt-4" />}
      </div>
      <SidebarFooter />
    </aside>
  );
}

function SidebarGroup({ label, items, pathname, className }: { label: string; items: NavItem[]; pathname: string; className?: string }) {
  return (
    <div className={className}>
      <p className="px-2.5 pb-1.5 text-[10px] font-semibold uppercase tracking-[0.12em] text-text-faint">{label}</p>
      <nav className="flex flex-col gap-0.5" aria-label={label}>
        {items.map(({ to, label: text, icon: Icon }) => {
          const active = isNavItemActive(to, pathname);
          return (
            <Link
              key={to}
              to={to}
              aria-current={active ? 'page' : undefined}
              className={cn(
                'flex min-h-[38px] items-center gap-3 rounded-lg px-2.5 text-[13.5px] font-medium text-text-muted transition-colors hover:bg-surface-2 hover:text-text',
                active && 'bg-accent/14 font-semibold text-accent',
              )}
            >
              <Icon size={18} className="shrink-0" />
              <span className="truncate">{text}</span>
            </Link>
          );
        })}
      </nav>
    </div>
  );
}

function SidebarFooter() {
  const { logout, username } = useAuth();
  const { theme, setTheme } = useTheme();
  return (
    <div className="mt-auto flex flex-col gap-0.5 border-t border-border pt-3">
      <div className="truncate px-2.5 pb-1 text-micro text-text-faint">{username}</div>
      <label className="flex min-h-[38px] items-center gap-3 rounded-lg px-2.5 text-[13.5px] text-text-muted transition-colors hover:bg-surface-2 hover:text-text">
        <Palette size={18} className="shrink-0" />
        <span className="sr-only">Тема</span>
        <select
          value={theme}
          onChange={(e) => {
            if (isTheme(e.target.value)) setTheme(e.target.value);
          }}
          className="min-h-[30px] w-full min-w-0 cursor-pointer rounded-md bg-transparent text-[13.5px] text-inherit focus:outline-none"
          aria-label="Тема оформления"
        >
          {THEMES.map((value) => (
            <option key={value} value={value} className="bg-surface text-text">{THEME_LABELS[value]}</option>
          ))}
        </select>
      </label>
      <button
        onClick={logout}
        className="flex min-h-[38px] w-full items-center gap-3 rounded-lg px-2.5 text-[13.5px] text-text-muted transition-colors hover:bg-surface-2 hover:text-error"
      >
        <LogOut size={18} className="shrink-0" />
        Выйти
      </button>
    </div>
  );
}

function RailLink({ item, active }: { item: NavItem; active: boolean }) {
  const { to, label, icon: Icon } = item;
  return (
    <Link
      to={to}
      title={label}
      aria-label={label}
      aria-current={active ? 'page' : undefined}
      className={cn('tap-target flex w-11 items-center justify-center rounded-lg text-text-faint transition-colors hover:bg-surface-2 hover:text-text', active && 'bg-accent/14 text-accent')}
    >
      <Icon size={20} />
    </Link>
  );
}

function BottomLink({ item, active }: { item: NavItem; active: boolean }) {
  const { to, label, icon: Icon } = item;
  return (
    <Link
      to={to}
      className={cn('tap-target flex flex-auto flex-col items-center justify-center gap-0.5 py-1 text-[10px] font-semibold', active ? 'text-accent' : 'text-text-faint')}
      aria-current={active ? 'page' : undefined}
    >
      <span className={cn('flex h-7 min-w-10 items-center justify-center rounded-lg', active && 'bg-accent/14')}>
        <Icon size={20} />
      </span>
      <span className="max-w-full truncate px-1">{label}</span>
    </Link>
  );
}

function SecondaryLinks({ panelItems, mtproxylItems: mtItems, pathname, onNavigate }: { panelItems: NavItem[]; mtproxylItems: NavItem[]; pathname: string; onNavigate: () => void }) {
  const { logout, username } = useAuth();
  const { theme, setTheme } = useTheme();
  const link = (item: NavItem) => {
    const active = isNavItemActive(item.to, pathname);
    const Icon = item.icon;
    return (
      <Link
        key={item.to}
        to={item.to}
        role="menuitem"
        onClick={onNavigate}
        aria-current={active ? 'page' : undefined}
        className={cn('flex min-h-[42px] items-center gap-3 rounded-lg px-3 text-row font-medium text-text-muted transition-colors hover:bg-surface-2 hover:text-text', active && 'bg-accent/14 font-semibold text-accent')}
      >
        <Icon size={18} className="shrink-0" />
        <span className="truncate">{item.label}</span>
      </Link>
    );
  };
  return (
    <div role="menu" className="flex flex-col gap-0.5">
      <p className="px-3 pb-1 pt-1 text-[10px] font-semibold uppercase tracking-[0.12em] text-text-faint">Панель</p>
      {panelItems.map(link)}
      {mtItems.length > 0 && (
        <>
          <p className="px-3 pb-1 pt-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-text-faint">MTProxyL</p>
          {mtItems.map(link)}
        </>
      )}
      <div className="my-2 border-t border-border" />
      <label className="flex min-h-[42px] items-center gap-3 rounded-lg px-3 text-row text-text-muted hover:bg-surface-2 hover:text-text">
        <Palette size={18} className="shrink-0" />
        <span className="sr-only">Тема</span>
        <select
          value={theme}
          onChange={(e) => {
            if (isTheme(e.target.value)) setTheme(e.target.value);
          }}
          className="min-h-[30px] w-full min-w-0 cursor-pointer rounded-md bg-transparent text-row text-inherit focus:outline-none"
          aria-label="Тема оформления"
        >
          {THEMES.map((value) => (
            <option key={value} value={value} className="bg-surface text-text">{THEME_LABELS[value]}</option>
          ))}
        </select>
      </label>
      <button
        type="button"
        role="menuitem"
        onClick={logout}
        className="flex min-h-[42px] items-center gap-3 rounded-lg px-3 text-left text-row font-medium text-text-muted transition-colors hover:bg-surface-2 hover:text-error"
      >
        <LogOut size={18} className="shrink-0" />
        Выйти{username ? ` (${username})` : ''}
      </button>
    </div>
  );
}
