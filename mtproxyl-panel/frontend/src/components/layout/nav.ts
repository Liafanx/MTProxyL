import type { LucideIcon } from 'lucide-react';
import { LayoutDashboard, Users, Activity, Shield, Network, Settings, ArrowUpCircle, ScrollText, ToggleLeft, Globe, Globe2, Archive, ShieldAlert, MapPin, Route, SlidersHorizontal, Gauge, FileCode, Puzzle, Radar, Wrench, Bot, Waypoints, ShieldBan, PanelTop, Cable, KeyRound, Router } from 'lucide-react';

export interface NavItem {
  to: string;
  icon: LucideIcon;
  label: string;
  /** Раздел требует владения конфигом движка (режим Manager). */
  managerOnly?: boolean;
  /** Раздел имеет смысл только для движка telemt: у mtdd его нет. */
  telemtOnly?: boolean;
  /** Показывается в нижних табах и на рельсе. */
  primary?: boolean;
}

export const PANEL_NAV_ITEMS: NavItem[] = [
  { to: '/', icon: LayoutDashboard, label: 'Дашборд', primary: true },
  { to: '/availability', icon: Radar, label: 'Доступность из России' },
  { to: '/users', icon: Users, label: 'Пользователи', primary: true },
  { to: '/runtime', icon: Activity, label: 'Телеметрия', telemtOnly: true, primary: true },
  { to: '/security', icon: Shield, label: 'Безопасность', telemtOnly: true },
  { to: '/upstreams', icon: Network, label: 'Апстримы и DC', telemtOnly: true },
  { to: '/config', icon: Settings, label: 'Конфигурация', telemtOnly: true },
  { to: '/panel-settings', icon: PanelTop, label: 'Настройки панели' },
  { to: '/update', icon: ArrowUpCircle, label: 'Обновление' },
  { to: '/logs', icon: ScrollText, label: 'Логи' },
];

// Показываются только при включённом мосте MTProxyL.
export const MTPROXYL_NAV_ITEMS: NavItem[] = [
  { to: '/mode', icon: ToggleLeft, label: 'Режим работы' },
  { to: '/proxy-settings', icon: SlidersHorizontal, label: 'Настройки прокси', managerOnly: true, telemtOnly: true },
  { to: '/selfmask', icon: Globe, label: 'Selfmask' },
  { to: '/web', icon: Globe2, label: 'WEB Proxy', telemtOnly: true },
  { to: '/traffic', icon: Gauge, label: 'Трафик', primary: true },
  { to: '/shaping', icon: Gauge, label: 'Ограничение скорости' },
  { to: '/nft', icon: ShieldAlert, label: 'Лимитер и защита' },
  { to: '/geoblock', icon: MapPin, label: 'Блокировка стран' },
  { to: '/ipblock', icon: ShieldBan, label: 'Блокировка IP адресов' },
  { to: '/warp', icon: Waypoints, label: 'Telegram через WARP', telemtOnly: true },
  { to: '/donor', icon: Cable, label: 'Туннель AWG до донора', telemtOnly: true },
  { to: '/awg', icon: Router, label: 'Telegram через свой AWG', telemtOnly: true },
  { to: '/backups', icon: Archive, label: 'Бэкапы', managerOnly: true },
  { to: '/routes', icon: Route, label: 'Маршруты', managerOnly: true, telemtOnly: true },
  { to: '/expert', icon: SlidersHorizontal, label: 'Экспертные параметры', managerOnly: true, telemtOnly: true },
  { to: '/superexpert', icon: FileCode, label: 'Супер эксперт', managerOnly: true, telemtOnly: true },
  { to: '/maintenance', icon: Wrench, label: 'Обслуживание' },
  { to: '/control-api', icon: KeyRound, label: 'API управления' },
  { to: '/tgbot', icon: Bot, label: 'Телеграм-бот' },
  { to: '/addons', icon: Puzzle, label: 'Дополнения' },
];

export function isNavItemActive(to: string, pathname: string): boolean {
  if (to === '/') return pathname === '/';
  return pathname === to || pathname.startsWith(`${to}/`);
}

/** Пункты панели с учётом движка: у mtdd нет телеметрии, безопасности, апстримов и конфига telemt. */
export function panelItems(engineKind: string = 'telemt'): NavItem[] {
  return PANEL_NAV_ITEMS.filter((i) => !i.telemtOnly || engineKind !== 'mtdd');
}

/** Путь, недоступный текущему движку (для заглушки при прямом заходе по URL). */
export function isTelemtOnlyPath(pathname: string): boolean {
  return [...PANEL_NAV_ITEMS, ...MTPROXYL_NAV_ITEMS].some((i) => i.telemtOnly && isNavItemActive(i.to, pathname));
}

/** Видимые пункты MTProxyL с учётом режима и движка. */
export function mtproxylItems(enabled: boolean, mode: string, engineKind: string = 'telemt'): NavItem[] {
  if (!enabled) return [];
  return MTPROXYL_NAV_ITEMS.filter((i) => (!i.managerOnly || mode === 'manager') && (!i.telemtOnly || engineKind !== 'mtdd'));
}

/** Первичные пункты для табов и рельсы: до четырёх, «Трафик» только при мосте. */
export function primaryItems(enabled: boolean, mode: string, engineKind: string = 'telemt'): NavItem[] {
  const items = [...panelItems(engineKind), ...mtproxylItems(enabled, mode, engineKind)].filter((i) => i.primary);
  if (!enabled) items.push(PANEL_NAV_ITEMS.find((i) => i.to === '/logs')!);
  return items.slice(0, 4);
}
