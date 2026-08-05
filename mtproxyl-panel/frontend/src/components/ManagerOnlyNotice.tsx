import { Info } from 'lucide-react';
import { Card, CardContent } from '@/components/ui/card';

/**
 * Заглушка для разделов, доступных только в режиме Manager.
 *
 * В режиме Reanimator MTProxyL обслуживает чужой telemt и не владеет его
 * конфигом, поэтому бэкапы и исходящие маршруты там отклоняются самим
 * MTProxyL. Показываем причину вместо кнопок, которые всё равно упадут.
 */
export function ManagerOnlyNotice({ feature }: { feature: string }) {
  return (
    <Card>
      <CardContent className="pt-4 flex items-start gap-3">
        <Info size={18} className="text-text-secondary shrink-0 mt-0.5" />
        <div className="text-sm text-text-secondary space-y-2">
          <p>
            <span className="text-text-primary">{feature}</span> доступны только в режиме{' '}
            <span className="text-text-primary">Manager</span>.
          </p>
          <p>
            Сейчас MTProxyL работает в режиме Reanimator: он обслуживает чужой telemt и не
            владеет его конфигурацией, поэтому такие операции недоступны — их отклоняет сам
            MTProxyL.
          </p>
          <p>
            Переключить режим можно на странице{' '}
            <span className="text-text-primary">«Режим работы»</span>.
          </p>
        </div>
      </CardContent>
    </Card>
  );
}
