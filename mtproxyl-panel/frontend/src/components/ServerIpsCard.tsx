import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import type { NftServerIPs } from '@/lib/api';

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col sm:flex-row sm:gap-2">
      <span className="text-text-secondary sm:w-44 shrink-0">{label}</span>
      <span className="text-text-primary break-words min-w-0">{value}</span>
    </div>
  );
}

/** Публичные адреса прокси (SERVER_IPS) и на каких из них работают правила. */
export function ServerIpsCard({ info }: { info: NftServerIPs }) {
  const selected =
    info.server_ips === ''
      ? 'не задано — один адрес'
      : `${info.server_ips === 'all' ? 'все с интерфейсов: ' : ''}${info.selected.join(', ') || 'нет'}`;
  return (
    <Card>
      <CardHeader>
        <CardTitle>Адреса сервера</CardTitle>
      </CardHeader>
      <CardContent className="space-y-1.5 text-sm">
        <Row label="Выбрано (SERVER_IPS)" value={selected} />
        <Row label="На интерфейсах" value={info.detected.join(', ') || 'публичных IPv4 нет (NAT)'} />
        <Row label="MTProto и WEB" value={`все адреса сервера, порт ${info.listen_port}`} />
        <Row label="SYN-лимитер" value={info.nft} />
        <Row label="Zapret2" value={info.zapret2} />
        <Row label="Ссылки" value={info.links_host || 'адрес определяется автоматически'} />
        <p className="text-xs text-text-secondary pt-1">
          Список задаётся в «Настройках прокси» (SERVER_IPS: all или адреса через запятую).
          Чтобы правила NFT или Zapret2 работали только на этих адресах, укажите
          «server» в NFT_SERVER_IP или ZAPRET2_FILTER_IP ниже. Ссылки на каждый адрес:
          mtproxyl ips links &lt;пользователь&gt;.
        </p>
      </CardContent>
    </Card>
  );
}
