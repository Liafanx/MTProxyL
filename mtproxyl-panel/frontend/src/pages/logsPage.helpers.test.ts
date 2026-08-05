import { parseLogLineParts } from './logsPage.helpers';

const line = '2026-06-01T15:21:14+0300 vds36685.1cent.network telemt[617885]: 2026-06-01T12:21:14.709741Z  WARN telemt::proxy::middle_relay::desync: peer=127.0.0.1:50586 real_peer=141.227.174.31:17268 user=Kkoryush';
const parts = parseLogLineParts(line);

const expectedKinds = [
  'timestamp',
  'plain',
  'host',
  'plain',
  'service',
  'plain',
  'timestamp',
  'plain',
  'level-warn',
  'plain',
  'key',
  'ip',
  'plain',
  'key',
  'ip',
  'plain',
  'key',
  'plain',
];

const gotKinds = parts.map((part) => part.kind);
if (JSON.stringify(gotKinds) !== JSON.stringify(expectedKinds)) {
  throw new Error(`Expected kinds ${JSON.stringify(expectedKinds)}, got ${JSON.stringify(gotKinds)}`);
}

const service = parts.find((part) => part.kind === 'service');
if (service?.text !== 'telemt[617885]:') {
  throw new Error(`Expected service token telemt[617885]:, got ${service?.text}`);
}

const timestamp = parts.find((part) => part.kind === 'timestamp');
if (timestamp?.text !== '2026-06-01T15:21:14+0300') {
  throw new Error(`Expected timestamp token, got ${timestamp?.text}`);
}

const host = parts.find((part) => part.kind === 'host');
if (host?.text !== 'vds36685.1cent.network') {
  throw new Error(`Expected host token, got ${host?.text}`);
}
