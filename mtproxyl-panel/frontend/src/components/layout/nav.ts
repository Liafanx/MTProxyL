import type { LucideIcon } from 'lucide-react';
import { LayoutDashboard, Users, Activity, Shield, Network, Settings, ArrowUpCircle, ScrollText, ToggleLeft, Globe, Globe2, Archive, ShieldAlert, MapPin, Route, SlidersHorizontal, Gauge, FileCode, Puzzle, Radar, Wrench, Bot, Waypoints, ShieldBan, PanelTop } from 'lucide-react';

export interface NavItem {
  to: string;
  icon: LucideIcon;
  label: string;
  /** Раздел требует владения конфигом движка (режим Manager). */
  managerOnly?: boolean;
  /** Показывается в нижних табах и на рельсе. */
  primary?: boolean;
}

export const PANEL_NAV_ITEMS: NavItem[] = [
  { to: '/', icon: LayoutDashboard, label: 'Дашборд', primary: true },
  { to: '/availability', icon: Radar, label: 'Доступность из России' },
  { to: '/users', icon: Users, label: 'Пользователи', primary: true },
  { to: '/runtime', icon: Activity, label: 'Телеметрия', primary: true },
  { to: '/security', icon: Shield, label: 'Безопасность' },
  { to: '/upstreams', icon: Network, label: 'Апстримы и DC' },
  { to: '/config', icon: Settings, label: 'Конфигурация' },
  { to: '/panel-settings', icon: PanelTop, label: 'Настройки панели' },
  { to: '/update', icon: ArrowUpCircle, label: 'Обновление' },
  { to: '/logs', icon: ScrollText, label: 'Логи' },
];

// Показываются только при включённом мосте MTProxyL.
export const MTPROXYL_NAV_ITEMS: NavItem[] = [
  { to: '/mode', icon: ToggleLeft, label: 'Режим работы' },
  { to: '/proxy-settings', icon: SlidersHorizontal, label: 'Настройки прокси', managerOnly: true },
  { to: '/selfmask', icon: Globe, label: 'Selfmask' },
  { to: '/web', icon: Globe2, label: 'WEB Proxy', managerOnly: true },
  { to: '/traffic', icon: Gauge, label: 'Трафик', primary: true },
  { to: '/nft', icon: ShieldAlert, label: 'Лимитер и защита' },
  { to: '/geoblock', icon: MapPin, label: 'Блокировка стран' },
  { to: '/ipblock', icon: ShieldBan, label: 'Блокировка IP адресов' },
  { to: '/warp', icon: Waypoints, label: 'Telegram через WARP' },
  { to: '/backups', icon: Archive, label: 'Бэкапы', managerOnly: true },
  { to: '/routes', icon: Route, label: 'Маршруты', managerOnly: true },
  { to: '/expert', icon: SlidersHorizontal, label: 'Экспертные параметры', managerOnly: true },
  { to: '/superexpert', icon: FileCode, label: 'Супер эксперт', managerOnly: true },
  { to: '/maintenance', icon: Wrench, label: 'Обслуживание' },
  { to: '/tgbot', icon: Bot, label: 'Телеграм-бот' },
  { to: '/addons', icon: Puzzle, label: 'Дополнения' },
];

export function isNavItemActive(to: string, pathname: string): boolean {
  if (to === '/') return pathname === '/';
  return pathname === to || pathname.startsWith(`${to}/`);
}

/** Видимые пункты MTProxyL с учётом режима. */
export function mtproxylItems(enabled: boolean, mode: string): NavItem[] {
  if (!enabled) return [];
  return MTPROXYL_NAV_ITEMS.filter((i) => !i.managerOnly || mode === 'manager');
}

/** Первичные пункты для табов и рельсы: до четырёх, «Трафик» только при мосте. */
export function primaryItems(enabled: boolean, mode: string): NavItem[] {
  const items = [...PANEL_NAV_ITEMS, ...mtproxylItems(enabled, mode)].filter((i) => i.primary);
  if (!enabled) items.push(PANEL_NAV_ITEMS.find((i) => i.to === '/logs')!);
  return items.slice(0, 4);
}
