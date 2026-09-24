import { Link } from 'react-router-dom';
import { LoadChart } from '@/components/charts/LoadChart';
import { lastValue, peakValue } from '@/lib/history';
import { formatNumber } from '@/lib/utils';
import type { HistorySeries } from '@/lib/api';

interface LoadCardProps {
  connections?: HistorySeries;
  activeUsers?: HistorySeries;
  telemetryOff: boolean;
  loading: boolean;
  /** Режим Manager: параметр движка можно включить из «Экспертных параметров». */
  manager?: boolean;
}

/** Нагрузка за 30 минут: текущие соединения и активные пользователи. */
export function LoadCard({ connections, activeUsers, telemetryOff, loading, manager = false }: LoadCardProps) {
  const now = lastValue(connections);
  const peak = peakValue(connections);
  const users = lastValue(activeUsers);
  return (
    <section className="rounded-xl border border-border bg-surface p-4">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <h3 className="text-[13px] font-semibold text-text">Нагрузка за 30 минут</h3>
          <p className="mt-0.5 text-micro text-text-muted">Текущие соединения и активные пользователи по данным движка</p>
        </div>
        <div className="flex items-center gap-4 text-micro text-text-muted">
          <span className="flex items-center gap-1.5"><i className="h-2 w-2 rounded-full bg-accent" />соединения</span>
          <span className="flex items-center gap-1.5"><i className="h-2 w-2 rounded-full bg-ok" />пользователи</span>
        </div>
      </div>
      {telemetryOff ? (
        <div className="rounded-lg border border-dashed border-border-strong px-3 py-4">
          <p className="text-meta font-semibold text-text">Runtime‑телеметрия движка выключена</p>
          <p className="mt-1 text-micro leading-relaxed text-text-muted">
            Telemt по умолчанию не отдаёт текущие соединения. Включите параметр{' '}
            <code className="rounded bg-surface-2 px-1 py-0.5 font-mono text-[11px] text-text">server.api.runtime_edge_enabled = true</code>
            {manager ? (
              <>
                {' '}в разделе{' '}
                <Link to="/expert" className="text-accent hover:underline">Экспертные параметры</Link>
                {' '}или командой <code className="rounded bg-surface-2 px-1 py-0.5 font-mono text-[11px] text-text">mtproxyl expert set server.api runtime_edge_enabled true</code>.
              </>
            ) : (
              <>
                {' '}в{' '}
                <Link to="/config" className="text-accent hover:underline">конфигурации Telemt</Link>.
              </>
            )}
            {' '}После применения движок перезапустится, история появится через минуту.
          </p>
        </div>
      ) : (
        <>
          <div className="mb-2 grid grid-cols-3 gap-2">
            <Stat label="Сейчас" value={now === null ? '—' : formatNumber(now)} />
            <Stat label="Пик за окно" value={peak === null ? '—' : formatNumber(peak)} />
            <Stat label="Пользователей" value={users === null ? '—' : formatNumber(users)} />
          </div>
          <LoadChart
            connections={connections?.points ?? []}
            activeUsers={activeUsers?.points ?? []}
            label="Нагрузка за 30 минут"
            emptyLabel={loading ? 'Загрузка истории…' : 'История накапливается: первые точки появятся через минуту'}
          />
          <div className="mt-1 flex justify-between text-[10px] text-text-faint">
            <span>30 мин назад</span>
            <span>15 мин</span>
            <span>сейчас</span>
          </div>
        </>
      )}
    </section>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg bg-bg px-3 py-2">
      <div className="text-[10px] font-semibold uppercase tracking-[0.02em] text-text-faint">{label}</div>
      <div className="mt-0.5 font-mono text-[18px] font-bold leading-none tabular-nums text-text">{value}</div>
    </div>
  );
}
