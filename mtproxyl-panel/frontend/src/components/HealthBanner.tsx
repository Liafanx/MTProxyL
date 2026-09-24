import type { ReactNode } from 'react';
import { cn } from '@/lib/utils';
import type { PillState } from '@/components/ui/state-pill';

const TONE: Record<PillState, { wash: string; border: string; text: string }> = {
  ok: {
    wash: 'linear-gradient(135deg, rgb(var(--ok) / 0.14), rgb(var(--ok) / 0.04))',
    border: 'border-ok/30',
    text: 'text-ok',
  },
  warn: {
    wash: 'linear-gradient(135deg, rgb(var(--warn) / 0.14), rgb(var(--warn) / 0.04))',
    border: 'border-warn/30',
    text: 'text-warn',
  },
  error: {
    wash: 'linear-gradient(135deg, rgb(var(--error) / 0.14), rgb(var(--error) / 0.04))',
    border: 'border-error/30',
    text: 'text-error',
  },
  muted: {
    wash: 'linear-gradient(135deg, rgb(var(--muted) / 0.12), rgb(var(--muted) / 0.03))',
    border: 'border-border',
    text: 'text-text-muted',
  },
};

export interface HealthFact {
  key: string;
  label: string;
  value: ReactNode;
}

interface HealthBannerProps {
  state: PillState;
  title: string;
  detail?: string;
  facts?: HealthFact[];
  aside?: ReactNode;
}

/** Баннер состояния: тон заливки — единственный индикатор, слово — пояснение. */
export function HealthBanner({ state, title, detail, facts = [], aside }: HealthBannerProps) {
  const tone = TONE[state];
  return (
    <section
      className={cn('flex flex-col gap-4 rounded-xl border p-4 lg:flex-row lg:items-center lg:justify-between lg:p-5', tone.border)}
      style={{ backgroundImage: tone.wash }}
    >
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <h2 className={cn('text-[20px] font-extrabold leading-tight tracking-[-0.02em] md:text-[22px]', tone.text)}>
            {title}
          </h2>
          {aside}
        </div>
        {detail && <p className="mt-1 text-[13px] leading-relaxed text-text-muted">{detail}</p>}
      </div>
      {facts.length > 0 && (
        <div className="grid shrink-0 grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-4 lg:gap-x-8">
          {facts.map((fact) => (
            <div key={fact.key} className="flex min-w-0 flex-col gap-0.5">
              <span className="truncate text-micro font-semibold uppercase tracking-[0.06em] text-text-faint">{fact.label}</span>
              <span className="truncate text-row font-semibold tabular-nums text-text">{fact.value}</span>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
