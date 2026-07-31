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

function appendComment(raw: string, username: string): string {
  try {
    const u = new URL(raw);
    u.searchParams.set('comment', username);
    return u.toString();
  } catch {
    const sep = raw.includes('?') ? '&' : '?';
    return raw + sep + 'comment=' + encodeURIComponent(username);
  }
}

export function buildProxyLinks(links: UserLinks | undefined, username: string): ProxyLinkGroup[] {
  if (!links) return [];

  const result: ProxyLinkGroup[] = [];
  const makeLink = (rawUrl: string, domain: string, isDefault: boolean): ProxyLinkOption => ({
      url: appendComment(rawUrl, username),
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
