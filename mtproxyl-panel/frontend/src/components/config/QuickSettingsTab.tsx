import { useState, useEffect } from 'react';
import { parse, stringify } from '@iarna/toml';
import { ChevronDown, ChevronUp } from 'lucide-react';

interface QuickSettingsTabProps {
  content: string;
  onChange: (content: string) => void;
  mode?: 'api' | 'file';
}

interface FormValues {
  // Server
  'server.port'?: number;
  'server.listen_addr_ipv4'?: string;
  'server.listen_addr_ipv6'?: string;

  // Middle Proxy
  'general.use_middle_proxy'?: boolean;
  'general.ad_tag'?: string;
  'general.middle_proxy_nat_ip'?: string;
  'general.middle_proxy_nat_probe'?: boolean;

  // Censorship
  'censorship.tls_domain'?: string;
  'censorship.mask'?: boolean;
  'censorship.mask_host'?: string;
  'censorship.tls_emulation'?: boolean;

  // Network
  'network.ipv4'?: boolean;
  'network.ipv6'?: boolean;
  'network.prefer'?: number;

  // Timeouts
  'timeouts.client_handshake'?: number;
  'timeouts.tg_connect'?: number;
  'timeouts.client_ack'?: number;
}

// Convert inline empty tables like `key = {}` to proper TOML sections like `[parent.key]`
// Telemt doesn't understand inline empty tables.
function inlineTablesToSections(toml: string): string {
  const lines = toml.split('\n');
  const result: string[] = [];
  let currentSection = '';

  for (const line of lines) {
    const sectionMatch = line.match(/^\[([^\]]+)\]$/);
    if (sectionMatch) {
      currentSection = sectionMatch[1];
      result.push(line);
      continue;
    }

    const inlineMatch = line.match(/^(\w+)\s*=\s*\{\s*\}$/);
    if (inlineMatch) {
      const key = inlineMatch[1];
      const fullSection = currentSection ? `${currentSection}.${key}` : key;
      result.push('');
      result.push(`[${fullSection}]`);
      continue;
    }

    result.push(line);
  }

  return result.join('\n');
}

export function QuickSettingsTab({ content, onChange, mode = 'file' }: QuickSettingsTabProps) {
  const [formValues, setFormValues] = useState<FormValues>({});
  const [parseError, setParseError] = useState<string | null>(null);
  const [expandedSections, setExpandedSections] = useState<Record<string, boolean>>({
    server: true,
    middleProxy: true,
    censorship: true,
    network: false,
    timeouts: false,
  });

  useEffect(() => {
    try {
      const parsed = parse(content) as any;
      const values: FormValues = {};

      // Extract values
      if (parsed.server) {
        if (parsed.server.port !== undefined) values['server.port'] = parsed.server.port;
        if (parsed.server.listen_addr_ipv4) values['server.listen_addr_ipv4'] = parsed.server.listen_addr_ipv4;
        if (parsed.server.listen_addr_ipv6) values['server.listen_addr_ipv6'] = parsed.server.listen_addr_ipv6;
      }

      if (parsed.general) {
        if (parsed.general.use_middle_proxy !== undefined) values['general.use_middle_proxy'] = parsed.general.use_middle_proxy;
        if (parsed.general.ad_tag) values['general.ad_tag'] = parsed.general.ad_tag;
        if (parsed.general.middle_proxy_nat_ip) values['general.middle_proxy_nat_ip'] = parsed.general.middle_proxy_nat_ip;
        if (parsed.general.middle_proxy_nat_probe !== undefined) values['general.middle_proxy_nat_probe'] = parsed.general.middle_proxy_nat_probe;
      }

      if (parsed.censorship) {
        if (parsed.censorship.tls_domain) values['censorship.tls_domain'] = parsed.censorship.tls_domain;
        if (parsed.censorship.mask !== undefined) values['censorship.mask'] = parsed.censorship.mask;
        if (parsed.censorship.mask_host) values['censorship.mask_host'] = parsed.censorship.mask_host;
        if (parsed.censorship.tls_emulation !== undefined) values['censorship.tls_emulation'] = parsed.censorship.tls_emulation;
      }

      if (parsed.network) {
        if (parsed.network.ipv4 !== undefined) values['network.ipv4'] = parsed.network.ipv4;
        if (parsed.network.ipv6 !== undefined) values['network.ipv6'] = parsed.network.ipv6;
        if (parsed.network.prefer !== undefined) values['network.prefer'] = parsed.network.prefer;
      }

      if (parsed.timeouts) {
        if (parsed.timeouts.client_handshake !== undefined) values['timeouts.client_handshake'] = parsed.timeouts.client_handshake;
        if (parsed.timeouts.tg_connect !== undefined) values['timeouts.tg_connect'] = parsed.timeouts.tg_connect;
        if (parsed.timeouts.client_ack !== undefined) values['timeouts.client_ack'] = parsed.timeouts.client_ack;
      }

      setFormValues(values);
      setParseError(null);
    } catch (err: any) {
      setParseError(err.message);
    }
  }, [content]);

  const handleFieldChange = (key: keyof FormValues, value: any) => {
    const newValues = { ...formValues };

    if (value === '' || value === null || value === undefined) {
      delete newValues[key];
    } else {
      newValues[key] = value;
    }

    setFormValues(newValues);
    updateContent(newValues);
  };

  const updateContent = (values: FormValues) => {
    try {
      const parsed = parse(content) as any;

      // Apply updates
      Object.entries(values).forEach(([key, value]) => {
        const parts = key.split('.');
        let current = parsed;

        for (let i = 0; i < parts.length - 1; i++) {
          if (!current[parts[i]]) {
            current[parts[i]] = {};
          }
          current = current[parts[i]];
        }

        current[parts[parts.length - 1]] = value;
      });

      // Remove deleted keys
      const allKeys: (keyof FormValues)[] = [
        'server.port', 'server.listen_addr_ipv4', 'server.listen_addr_ipv6',
        'general.use_middle_proxy', 'general.ad_tag', 'general.middle_proxy_nat_ip', 'general.middle_proxy_nat_probe',
        'censorship.tls_domain', 'censorship.mask', 'censorship.mask_host', 'censorship.tls_emulation',
        'network.ipv4', 'network.ipv6', 'network.prefer',
        'timeouts.client_handshake', 'timeouts.tg_connect', 'timeouts.client_ack',
      ];

      allKeys.forEach((key) => {
        if (!(key in values)) {
          const parts = key.split('.');
          let current = parsed;

          for (let i = 0; i < parts.length - 1; i++) {
            if (!current[parts[i]]) return;
            current = current[parts[i]];
          }

          delete current[parts[parts.length - 1]];
        }
      });

      const newContent = inlineTablesToSections(
        stringify(parsed).replace(/(\d)_(?=\d)/g, '$1')
      );
      onChange(newContent);
    } catch (err: any) {
      console.error('Failed to update content:', err);
    }
  };

  const toggleSection = (section: string) => {
    setExpandedSections((prev) => ({ ...prev, [section]: !prev[section] }));
  };

  if (parseError) {
    return (
      <div className="p-4">
        <div className="p-4 bg-red-500/10 border border-red-500/20 rounded-lg text-red-600">
          <p className="font-semibold">Не удалось разобрать TOML</p>
          <p className="text-sm mt-1">{parseError}</p>
          <p className="text-sm mt-2">Исправьте синтаксис в редакторе конфига — быстрые настройки недоступны, пока файл не разбирается.</p>
        </div>
      </div>
    );
  }

  return (
    <div className="p-4 space-y-4 max-w-4xl">
      {/* Server Settings */}
      {mode === 'file' && (
        <Section
          title="Настройки сервера"
          expanded={expandedSections.server}
          onToggle={() => toggleSection('server')}
        >
          <Field label="Порт" description="TCP-порт для входящих подключений (рекомендуется 443)">
            <input
              type="number"
              value={formValues['server.port'] ?? ''}
              onChange={(e) => handleFieldChange('server.port', e.target.value ? parseInt(e.target.value) : undefined)}
              placeholder="443"
              className="input"
            />
          </Field>

          <Field label="Адрес IPv4" description="Адрес привязки IPv4">
            <input
              type="text"
              value={formValues['server.listen_addr_ipv4'] ?? ''}
              onChange={(e) => handleFieldChange('server.listen_addr_ipv4', e.target.value || undefined)}
              placeholder="0.0.0.0"
              className="input"
            />
          </Field>

          <Field label="Адрес IPv6" description="Адрес привязки IPv6">
            <input
              type="text"
              value={formValues['server.listen_addr_ipv6'] ?? ''}
              onChange={(e) => handleFieldChange('server.listen_addr_ipv6', e.target.value || undefined)}
              placeholder="::"
              className="input"
            />
          </Field>
        </Section>
      )}

      {/* Middle Proxy */}
      <Section
        title="Middle Proxy"
        expanded={expandedSections.middleProxy}
        onToggle={() => toggleSection('middleProxy')}
      >
        <Field label="Использовать Middle Proxy" description="Подключение через серверы Telegram Middle-End (обязательно для ad_tag)">
          <input
            type="checkbox"
            checked={formValues['general.use_middle_proxy'] ?? false}
            onChange={(e) => handleFieldChange('general.use_middle_proxy', e.target.checked)}
            className="checkbox"
          />
        </Field>

        <Field label="Ad Tag" description="32-символьный hex Ad-Tag от @MTProxybot">
          <input
            type="text"
            value={formValues['general.ad_tag'] ?? ''}
            onChange={(e) => handleFieldChange('general.ad_tag', e.target.value || undefined)}
            placeholder="00000000000000000000000000000000"
            maxLength={32}
            className="input"
          />
        </Field>

        <Field label="NAT IP" description="Публичный IPv4-адрес сервера (пусто — определить автоматически)">
          <input
            type="text"
            value={formValues['general.middle_proxy_nat_ip'] ?? ''}
            onChange={(e) => handleFieldChange('general.middle_proxy_nat_ip', e.target.value || undefined)}
            placeholder="Автоопределение через STUN"
            className="input"
          />
        </Field>

        <Field label="NAT Probe" description="Автоопределение публичного IP через STUN-серверы">
          <input
            type="checkbox"
            checked={formValues['general.middle_proxy_nat_probe'] ?? false}
            onChange={(e) => handleFieldChange('general.middle_proxy_nat_probe', e.target.checked)}
            className="checkbox"
          />
        </Field>
      </Section>

      {/* Censorship & Masking */}
      <Section
        title="Обход цензуры и маскировка"
        expanded={expandedSections.censorship}
        onToggle={() => toggleSection('censorship')}
      >
        <Field label="TLS-домен" description="SNI-домен для FakeTLS (выберите популярный незаблокированный сайт)">
          <input
            type="text"
            value={formValues['censorship.tls_domain'] ?? ''}
            onChange={(e) => handleFieldChange('censorship.tls_domain', e.target.value || undefined)}
            placeholder="www.google.com"
            className="input"
          />
        </Field>

        <Field label="Маскировка" description="Перенаправлять неудачные рукопожатия на настоящий сайт">
          <input
            type="checkbox"
            checked={formValues['censorship.mask'] ?? false}
            onChange={(e) => handleFieldChange('censorship.mask', e.target.checked)}
            className="checkbox"
          />
        </Field>

        <Field label="Хост маскировки" description="Целевой хост для маскировки (по умолчанию tls_domain)">
          <input
            type="text"
            value={formValues['censorship.mask_host'] ?? ''}
            onChange={(e) => handleFieldChange('censorship.mask_host', e.target.value || undefined)}
            placeholder="Как TLS-домен"
            className="input"
          />
        </Field>

        <Field label="Эмуляция TLS" description="Загружать и повторять настоящую цепочку TLS-сертификатов">
          <input
            type="checkbox"
            checked={formValues['censorship.tls_emulation'] ?? false}
            onChange={(e) => handleFieldChange('censorship.tls_emulation', e.target.checked)}
            className="checkbox"
          />
        </Field>
      </Section>

      {/* Network */}
      {mode === 'file' && (
        <Section
          title="Сеть"
          expanded={expandedSections.network}
          onToggle={() => toggleSection('network')}
        >
          <Field label="IPv4" description="Использовать IPv4 для исходящих соединений">
            <input
              type="checkbox"
              checked={formValues['network.ipv4'] ?? false}
              onChange={(e) => handleFieldChange('network.ipv4', e.target.checked)}
              className="checkbox"
            />
          </Field>

          <Field label="IPv6" description="Использовать IPv6 для исходящих соединений">
            <input
              type="checkbox"
              checked={formValues['network.ipv6'] ?? false}
              onChange={(e) => handleFieldChange('network.ipv6', e.target.checked)}
              className="checkbox"
            />
          </Field>

          <Field label="Приоритет" description="Предпочитать IPv4 (4) или IPv6 (6)">
            <select
              value={formValues['network.prefer'] ?? ''}
              onChange={(e) => handleFieldChange('network.prefer', e.target.value ? parseInt(e.target.value) : undefined)}
              className="input"
            >
              <option value="">Не задано</option>
              <option value="4">IPv4</option>
              <option value="6">IPv6</option>
            </select>
          </Field>
        </Section>
      )}

      {/* Timeouts */}
      <Section
        title="Таймауты (секунды)"
        expanded={expandedSections.timeouts}
        onToggle={() => toggleSection('timeouts')}
      >
        <Field label="Рукопожатие клиента" description="Максимальное время на завершение рукопожатия">
          <input
            type="number"
            value={formValues['timeouts.client_handshake'] ?? ''}
            onChange={(e) => handleFieldChange('timeouts.client_handshake', e.target.value ? parseInt(e.target.value) : undefined)}
            placeholder="15"
            className="input"
          />
        </Field>

        <Field label="Подключение к Telegram" description="Максимальное время установки TCP-соединения с Telegram">
          <input
            type="number"
            value={formValues['timeouts.tg_connect'] ?? ''}
            onChange={(e) => handleFieldChange('timeouts.tg_connect', e.target.value ? parseInt(e.target.value) : undefined)}
            placeholder="10"
            className="input"
          />
        </Field>

        <Field label="ACK клиента" description="Максимальное бездействие клиента до разрыва соединения">
          <input
            type="number"
            value={formValues['timeouts.client_ack'] ?? ''}
            onChange={(e) => handleFieldChange('timeouts.client_ack', e.target.value ? parseInt(e.target.value) : undefined)}
            placeholder="300"
            className="input"
          />
        </Field>
      </Section>
    </div>
  );
}

function Section({
  title,
  expanded,
  onToggle,
  children,
}: {
  title: string;
  expanded: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  return (
    <div className="border border-border rounded-lg overflow-hidden">
      <button
        onClick={onToggle}
        className="w-full px-4 py-3 flex items-center justify-between bg-surface hover:bg-surface-hover transition-colors"
      >
        <span className="font-semibold text-text-primary">{title}</span>
        {expanded ? <ChevronUp className="w-5 h-5" /> : <ChevronDown className="w-5 h-5" />}
      </button>
      {expanded && <div className="p-4 space-y-4 bg-background">{children}</div>}
    </div>
  );
}

function Field({
  label,
  description,
  children,
}: {
  label: string;
  description: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-1">
      <label className="block text-sm font-medium text-text-primary">{label}</label>
      <p className="text-xs text-text-secondary">{description}</p>
      {children}
    </div>
  );
}
