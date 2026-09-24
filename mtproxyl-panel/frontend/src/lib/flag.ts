/** Флаг-эмодзи по коду страны ISO 3166-1 alpha-2. */
export function countryFlag(code?: string): string {
  if (!code || code.length !== 2 || code === '??') return '';
  const base = 0x1f1e6 - 65;
  const upper = code.toUpperCase();
  return String.fromCodePoint(base + upper.charCodeAt(0), base + upper.charCodeAt(1));
}
