import { Link } from 'react-router-dom';
import { useMtproxyl } from '@/hooks/useMtproxyl';
import { isRuntimeEdgeGate, reasonText } from '@/lib/gated';

interface GatedNoticeProps {
  title: string;
  reason?: string;
  /** Гейт группы runtime edge: подсказать параметр движка. */
  runtimeEdge?: boolean;
  /** Другой параметр движка, который нужно включить. */
  setting?: string;
}

/** Пояснение вместо пустой секции, когда движок закрыл источник гейтом. */
export function GatedNotice({ title, reason, runtimeEdge = false, setting }: GatedNoticeProps) {
  const { enabled, mode } = useMtproxyl();
  const manager = enabled && mode === 'manager';
  const param = setting ?? (runtimeEdge && isRuntimeEdgeGate(reason) ? 'server.api.runtime_edge_enabled' : undefined);
  return (
    <div className="rounded-xl border border-dashed border-border-strong bg-surface px-4 py-3">
      <p className="text-meta font-semibold text-text">{title}</p>
      <p className="mt-1 text-micro leading-relaxed text-text-muted">
        Недоступно: {reasonText(reason)}.
        {param && (
          <>
            {' '}Включите{' '}
            <code className="rounded bg-surface-2 px-1 py-0.5 font-mono text-[11px] text-text">{param} = true</code>
            {manager ? (
              <>
                {' '}в разделе <Link to="/expert" className="text-accent hover:underline">Экспертные параметры</Link>.
              </>
            ) : (
              <>
                {' '}в <Link to="/config" className="text-accent hover:underline">конфигурации Telemt</Link>.
              </>
            )}
          </>
        )}
      </p>
    </div>
  );
}
