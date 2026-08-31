import { buildProxyLinks, buildWebLink, extractSecret, mergeUserStats } from './usersPage.helpers';
import type { MtproxylUser } from '@/lib/api';


function assertDeepEqual(actual: unknown, expected: unknown) {
  const actualJson = JSON.stringify(actual);
  const expectedJson = JSON.stringify(expected);
  if (actualJson !== expectedJson) {
    throw new Error(`Expected ${expectedJson}, got ${actualJson}`);
  }
}

const tlsLinks = buildProxyLinks(
  {
    tls: [
      'tg://proxy?server=edge.example&port=443&secret=tls-default',
      'tg://proxy?server=edge.example&port=443&secret=tls-mask',
    ],
    tls_domains: [
      {
        domain: 'cdn.example',
        link: 'tg://proxy?server=edge.example&port=443&secret=tls-mask',
      },
    ],
  },
);

assertDeepEqual(
  tlsLinks.map((group) => ({
    label: group.label,
    links: group.links.map((link) => ({
      domain: link.domain,
      isDefault: link.isDefault,
      url: link.url,
    })),
  })),
  [
    {
      label: 'TLS',
      links: [
        {
          domain: 'edge.example',
          isDefault: true,
          url: 'tg://proxy?server=edge.example&port=443&secret=tls-default',
        },
        {
          domain: 'cdn.example',
          isDefault: false,
          url: 'tg://proxy?server=edge.example&port=443&secret=tls-mask',
        },
      ],
    },
  ],
);

assertDeepEqual(
  buildProxyLinks(
    {
      secure: ['tg://proxy?server=secure.example&port=443&secret=secure-secret'],
    },
  ).map((group) => [group.label, group.links.map((link) => [link.domain, link.isDefault])]),
  [['Secure', [['secure.example', true]]]],
);

assertDeepEqual(
  buildProxyLinks(
    {
      classic: ['tg://proxy?server=classic.example&port=443&secret=classic-secret'],
    },
  ).map((group) => [group.label, group.links.map((link) => [link.domain, link.isDefault])]),
  [['Classic', [['classic.example', true]]]],
);

assertDeepEqual(
  buildProxyLinks(
    {
      tls: ['tg://proxy?server=edge.example&port=443&secret=tls-default'],
      secure: ['tg://proxy?server=secure.example&port=443&secret=secure-secret'],
    },
  ).map((group) => ({
    label: group.label,
    links: group.links.map((link) => link.domain),
  })),
  [
    { label: 'TLS', links: ['edge.example'] },
    { label: 'Secure', links: ['secure.example'] },
  ],
);

const mtproxylUsers: MtproxylUser[] = [
  {
    label: 'alice', secret: 'x', created: 0, enabled: true,
    max_conns: 0, max_ips: 0, quota_bytes: 0, expires: '0', notes: '',
    total_in: 100, total_out: 200, total_bytes: 300,
    ip_history: [{ ip: '1.2.3.4', first_seen: 10, last_seen: 20 }],
  },
];

assertDeepEqual(
  mergeUserStats([{ username: 'alice' }, { username: 'bob' }], mtproxylUsers),
  [
    { username: 'alice', total_bytes: 300, ip_history: [{ ip: '1.2.3.4', first_seen: 10, last_seen: 20 }] },
    { username: 'bob', total_bytes: undefined, ip_history: [] },
  ],
);

// Список ещё не загрузился — сливаемся с пустым, а не падаем.
// usePolling до первого ответа отдаёт null, а не undefined: принимаем оба,
// иначе страница пользователей не собирается (tsc: TS2345).
assertDeepEqual(
  mergeUserStats([{ username: 'alice' }], undefined),
  [{ username: 'alice', total_bytes: undefined, ip_history: [] }],
);

assertDeepEqual(
  mergeUserStats([{ username: 'alice' }], null),
  [{ username: 'alice', total_bytes: undefined, ip_history: [] }],
);

// ── WEB-ссылки ──────────────────────────────────────────────────────────────
// Движок их не отдаёт, поэтому собираем из секрета: у ee-ссылки он лежит между
// префиксом и доменом в hex, у dd — сразу за префиксом.
const SECRET = '0123456789abcdef0123456789abcdef';
const web = { enabled: true, domain: 'web.example.com', secret_mode: 'dd' };

assertDeepEqual(
  extractSecret({ tls: [`tg://proxy?server=a.ru&port=443&secret=ee${SECRET}6578616d706c65`] }),
  SECRET,
);
assertDeepEqual(extractSecret({ secure: [`tg://proxy?server=a.ru&port=443&secret=dd${SECRET}`] }), SECRET);
assertDeepEqual(extractSecret({ classic: [`tg://proxy?server=a.ru&port=443&secret=${SECRET}`] }), SECRET);

assertDeepEqual(
  buildWebLink({ classic: [`tg://proxy?server=a.ru&port=443&secret=${SECRET}`] }, web),
  `tg://webproxy?server=web.example.com&secret=dd${SECRET}`,
);
// plain — секрет голым, без префикса.
assertDeepEqual(
  buildWebLink({ classic: [`tg://proxy?server=a.ru&port=443&secret=${SECRET}`] }, { ...web, secret_mode: 'plain' }),
  `tg://webproxy?server=web.example.com&secret=${SECRET}`,
);
// Выключенный WEB и отсутствие статуса ссылку не дают.
assertDeepEqual(buildWebLink({ classic: [`tg://proxy?secret=${SECRET}`] }, { ...web, enabled: false }), undefined);
assertDeepEqual(buildWebLink({ classic: [`tg://proxy?secret=${SECRET}`] }, undefined), undefined);

// В группах ссылка появляется отдельной группой WEB.
const groups = buildProxyLinks({ classic: [`tg://proxy?server=a.ru&port=443&secret=${SECRET}`] }, web);
assertDeepEqual(groups.map((g) => g.label), ['Classic', 'WEB']);

const webOnlyGroups = buildProxyLinks(
  { classic: [`tg://proxy?server=a.ru&port=443&secret=${SECRET}`] },
  { ...web, mtproto_enabled: false },
);
assertDeepEqual(webOnlyGroups.map((g) => g.label), ['WEB']);

console.log('usersPage.helpers: WEB-ссылки — ок');
