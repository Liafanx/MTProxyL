import { buildProxyLinks } from './usersPage.helpers';

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
