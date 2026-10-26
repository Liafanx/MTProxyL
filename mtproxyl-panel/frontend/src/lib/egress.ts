import type { Egress } from '@/lib/api';

/** Через что движок выходит к Telegram — коротко, для дашборда. */
export function egressText(e: Egress): string {
  switch (e.via) {
    case 'awg': {
      const spare = e.awg && e.awg.order.length > 1 && e.awg.order[0] !== e.name ? ' (запасной)' : '';
      return `свой AWG «${e.name}»${spare}${e.egress_ip ? ` · ${e.egress_ip}` : ''}`;
    }
    case 'donor':
      return `донор ${e.name}${e.egress_ip ? ` · ${e.egress_ip}` : ''}`;
    case 'warp':
      return `WARP${e.name ? ` · ${e.name}` : ''}`;
    default:
      return 'напрямую';
  }
}

/** Коротко для баннера: полное — во всплывающей подсказке. */
export function egressShort(e: Egress): string {
  const name = e.name.length > 16 ? `${e.name.slice(0, 15)}…` : e.name;
  switch (e.via) {
    case 'awg':
      return `AWG «${name}»`;
    case 'donor':
      return 'донор';
    case 'warp':
      return 'WARP';
    default:
      return 'напрямую';
  }
}
