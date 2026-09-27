type ParsedAddress = { family: 4 | 6; value: bigint; width: number };

function parseIPv4(address: string): ParsedAddress | null {
  const parts = address.split('.');
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part) || Number(part) > 255)) return null;
  const value = parts.reduce((n, part) => (n << 8n) | BigInt(Number(part)), 0n);
  return { family: 4, value, width: 32 };
}

function parseIPv6(address: string): ParsedAddress | null {
  let value = address.toLowerCase();
  if (value.includes('.')) {
    const colon = value.lastIndexOf(':');
    const embedded = parseIPv4(value.slice(colon + 1));
    if (colon < 0 || !embedded) return null;
    value = `${value.slice(0, colon + 1)}${(embedded.value >> 16n).toString(16)}:${(embedded.value & 0xffffn).toString(16)}`;
  }
  const halves = value.split('::');
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const count = left.length + right.length;
  if (halves.length === 1 ? count !== 8 : count >= 8) return null;
  const groups = [...left, ...Array(8 - count).fill('0'), ...right];
  if (groups.some((group) => !/^[0-9a-f]{1,4}$/.test(group))) return null;
  const parsed = groups.reduce((n, group) => (n << 16n) | BigInt(`0x${group}`), 0n);
  return { family: 6, value: parsed, width: 128 };
}

function parseAddress(address: string): ParsedAddress | null {
  return address.includes(':') ? parseIPv6(address) : parseIPv4(address);
}

/** Returns the exact address or CIDR rule covering an IP, if any. */
export function findBlockingEntry(ip: string, entries: string[]): string | null {
  const target = parseAddress(ip);
  if (!target) return null;
  for (const entry of entries) {
    const slash = entry.indexOf('/');
    const network = parseAddress(slash < 0 ? entry : entry.slice(0, slash));
    if (!network || network.family !== target.family) continue;
    const prefixText = slash < 0 ? String(network.width) : entry.slice(slash + 1);
    if (!/^\d+$/.test(prefixText)) continue;
    const prefix = Number(prefixText);
    if (prefix < 0 || prefix > network.width) continue;
    const shift = BigInt(network.width - prefix);
    if ((target.value >> shift) === (network.value >> shift)) return entry;
  }
  return null;
}
