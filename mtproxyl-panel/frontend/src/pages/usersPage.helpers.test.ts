import { buildProxyLinks, mergeUserStats } from './usersPage.helpers';
import type { MtproxylUser } from '@/lib/api';

const username = 'alice';

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
  username,
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
          url: 'tg://proxy?server=edge.example&port=443&secret=tls-default&comment=alice',
        },
        {
          domain: 'cdn.example',
          isDefault: false,
          url: 'tg://proxy?server=edge.example&port=443&secret=tls-mask&comment=alice',
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
    username,
  ).map((group) => [group.label, group.links.map((link) => [link.domain, link.isDefault])]),
  [['Secure', [['secure.example', true]]]],
);

assertDeepEqual(
  buildProxyLinks(
    {
      classic: ['tg://proxy?server=classic.example&port=443&secret=classic-secret'],
    },
    username,
  ).map((group) => [group.label, group.links.map((link) => [link.domain, link.isDefault])]),
  [['Classic', [['classic.example', true]]]],
);

assertDeepEqual(
  buildProxyLinks(
    {
      tls: ['tg://proxy?server=edge.example&port=443&secret=tls-default'],
      secure: ['tg://proxy?server=secure.example&port=443&secret=secure-secret'],
    },
    username,
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
