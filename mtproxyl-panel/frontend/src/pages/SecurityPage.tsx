import { Header } from '@/components/layout/Header';
import { ErrorAlert } from '@/components/ErrorAlert';
import { TelemetryField } from '@/components/TelemetryField';
import { useWsSubscription, useEndpoint } from '@/hooks/useWebSocket';

interface SecurityPostureData {
  api_read_only: boolean;
  api_whitelist_enabled: boolean;
  api_whitelist_entries: number;
  api_auth_header_enabled: boolean;
  proxy_protocol_enabled: boolean;
  log_level: string;
  telemetry_core_enabled: boolean;
  telemetry_user_enabled: boolean;
  telemetry_me_level: string;
}

interface WhitelistData {
  enabled: boolean;
  entries_total: number;
  entries: string[];
  generated_at_epoch_secs: number;
}

interface LimitsData {
  [key: string]: unknown;
}

function flattenObject(obj: Record<string, unknown>, prefix = ''): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj)) {
    const fullKey = prefix ? `${prefix}.${key}` : key;
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      Object.assign(result, flattenObject(value as Record<string, unknown>, fullKey));
    } else {
      result[fullKey] = value;
    }
  }
  return result;
}

const ENDPOINTS = ['/v1/security/posture', '/v1/security/whitelist', '/v1/limits/effective'];

/**
 * Порядок вывода состояния безопасности.
 *
 * Перечислен явно, а не через Object.entries: доступ к API идёт первым, потому
 * что открытый наружу API опаснее любой строчки ниже, а порядок ключей в JSON
 * движка меняться не обязан.
 */
const POSTURE_ORDER: (keyof SecurityPostureData)[] = [
  'api_read_only',
  'api_whitelist_enabled',
  'api_whitelist_entries',
  'api_auth_header_enabled',
  'proxy_protocol_enabled',
  'log_level',
  'telemetry_core_enabled',
  'telemetry_user_enabled',
  'telemetry_me_level',
];

export function SecurityPage() {
  const { data: wsData, errors, connected, refresh } = useWsSubscription('security', ENDPOINTS, 10);

  const posture = useEndpoint<SecurityPostureData>(wsData, '/v1/security/posture');
  const whitelist = useEndpoint<WhitelistData>(wsData, '/v1/security/whitelist');
  const limits = useEndpoint<LimitsData>(wsData, '/v1/limits/effective');

  const firstError = Object.values(errors)[0];
  const flatLimits = limits ? flattenObject(limits) : {};

  return (
    <div>
      <Header title="Безопасность" refreshing={!connected} onRefresh={refresh} />

      <div className="p-4 lg:p-6 space-y-6">
        {firstError && <ErrorAlert message={firstError} onRetry={refresh} />}

        {posture && (
          <div className="bg-surface border border-border rounded-lg p-4">
            <h3 className="text-sm font-medium text-text-secondary mb-1">Состояние безопасности</h3>
            <p className="text-xs text-text-secondary/70 mb-4">
              Как движок сейчас настроен относительно доступа к API и сбора телеметрии.
            </p>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-x-6">
              {POSTURE_ORDER.map((key) => (
                <TelemetryField
                  key={key}
                  fieldKey={key}
                  value={posture[key]}
                  variant="row"
                />
              ))}
            </div>
          </div>
        )}

        <div>
          <h3 className="text-sm font-medium text-text-secondary mb-1">Белый список API</h3>
          <p className="text-xs text-text-secondary/70 mb-3">
            Адреса и подсети, которым движок отвечает на запросы к API. Пустой список при
            включённой проверке означает, что не пройдёт никто.
          </p>
          {whitelist && whitelist.entries.length > 0 ? (
            <div className="bg-surface border border-border rounded-lg p-4">
              <div className="flex flex-wrap gap-2">
                {whitelist.entries.map((ip, i) => (
                  <span key={i} className="bg-background px-3 py-1.5 rounded text-sm text-text-primary font-mono border border-border/50">
                    {ip}
                  </span>
                ))}
              </div>
            </div>
          ) : (
            <div className="bg-surface border border-border rounded-lg p-6 text-center text-text-secondary text-sm">
              Список пуст
            </div>
          )}
        </div>

        {limits && (
          <div className="bg-surface border border-border rounded-lg p-4">
            <h3 className="text-sm font-medium text-text-secondary mb-1">Действующие лимиты</h3>
            <p className="text-xs text-text-secondary/70 mb-3">
              То, что движок применяет прямо сейчас, с учётом персональных настроек
              пользователей и правил по подсетям. Ноль означает «без ограничения».
            </p>
            {Object.keys(flatLimits).length === 0 ? (
              <div className="text-sm text-text-secondary">Лимиты не заданы</div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 gap-x-6">
                {Object.entries(flatLimits).map(([key, value]) => (
                  <TelemetryField key={key} fieldKey={key} value={value} variant="row" />
                ))}
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
