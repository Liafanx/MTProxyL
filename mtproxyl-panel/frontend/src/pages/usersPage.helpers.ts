import type { MtproxylUser, MtproxylUserIP } from '@/lib/api';

export interface UserStats {
  /** undefined — у MTProxyL нет записи об этом пользователе (superexpert). */
  total_bytes?: number;
  ip_history: MtproxylUserIP[];
}

/**
 * Докладывает к живым данным движка (сессионным, обнуляются при рестарте)
 * накопленный трафик и историю IP из MTProxyL — они на диске и живут дольше.
 * Оба режима отдают их одинаково через /api/mtproxyl/users, matching по label.
 */
export function mergeUserStats<T extends { username: string }>(
  liveUsers: T[],
  // null — usePolling ещё не получил первый ответ; undefined — вызов без
  // списка вовсе. Оба означают «данных MTProxyL пока нет», и оба должны
  // отдавать живых пользователей как есть, а не ронять страницу.
  mtproxylUsers: MtproxylUser[] | null | undefined
): (T & UserStats)[] {
  const byLabel = new Map((mtproxylUsers ?? []).map((u) => [u.label, u]));
  return liveUsers.map((u) => {
    const m = byLabel.get(u.username);
    return { ...u, total_bytes: m?.total_bytes, ip_history: m?.ip_history ?? [] };
  });
}

export interface TlsDomainLink {
  domain: string;
  link: string;
}

export interface UserLinks {
  classic?: string[];
  secure?: string[];
  tls?: string[];
  tls_domains?: TlsDomainLink[];
}

export interface ProxyLinkOption {
  url: string;
  domain: string;
  isDefault: boolean;
}

export interface ProxyLinkGroup {
  label: string;
  links: ProxyLinkOption[];
}

function getServer(raw: string): string {
  try {
    return new URL(raw).searchParams.get('server') ?? '';
  } catch {
    return raw.match(/[?&]server=([^&]*)/)?.[1] ?? '';
  }
}

export function buildProxyLinks(links: UserLinks | undefined): ProxyLinkGroup[] {
  if (!links) return [];

  const result: ProxyLinkGroup[] = [];
  // Ссылку отдаём ровно такой, какой её собрал движок. Раньше сюда дописывался
  // &comment=<пользователь>: в Telegram это подпись прокси, но метка —
  // внутреннее имя учётной записи, и попадать к клиенту ей незачем.
  const makeLink = (rawUrl: string, domain: string, isDefault: boolean): ProxyLinkOption => ({
      url: rawUrl,
      domain,
      isDefault,
  });
  const addGroup = (label: string, groupLinks: ProxyLinkOption[]) => {
    if (groupLinks.length > 0) result.push({ label, links: groupLinks });
  };

  if (links.tls?.length) {
    const maskByLink = new Map((links.tls_domains ?? []).map((d) => [d.link, d.domain]));
    const tls = links.tls
      .map((url) => makeLink(url, maskByLink.get(url) ?? getServer(url), !maskByLink.has(url)))
      .sort((a, b) => Number(b.isDefault) - Number(a.isDefault));
    addGroup('TLS', tls);
  }
  addGroup('Secure', (links.secure ?? []).map((url) => makeLink(url, getServer(url), true)));
  addGroup('Classic', (links.classic ?? []).map((url) => makeLink(url, getServer(url), true)));

  return result;
}

/**
 * Достаёт секрет пользователя из его же ссылки tg://.
 *
 * Список пользователей секрет не отдаёт, но в ссылках он есть — в TLS-ссылках
 * с префиксом ee и именем домена в hex, в classic — как есть. Берём classic
 * или secure: там секрет лежит без обвеса.
 */
export function extractSecret(links: UserLinks | undefined): string | undefined {
  const raw = links?.classic?.[0] ?? links?.secure?.[0];
  if (!raw) return undefined;
  const secret = (() => {
    try {
      return new URL(raw).searchParams.get('secret') ?? '';
    } catch {
      return raw.match(/[?&]secret=([^&]*)/)?.[1] ?? '';
    }
  })();
  // secure-ссылки несут тот же секрет с префиксом dd — для показа он лишний.
  const bare = secret.replace(/^dd/, '');
  return /^[0-9a-fA-F]{32}$/.test(bare) ? bare : undefined;
}
