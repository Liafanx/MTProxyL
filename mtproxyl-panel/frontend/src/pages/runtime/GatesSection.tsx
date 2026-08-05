import { TelemetryField } from '@/components/TelemetryField';

interface GatesSectionProps {
  gates: Record<string, unknown> | null;
}

export function GatesSection({ gates }: GatesSectionProps) {
  if (!gates) return null;

  // Filter out startup fields (they're shown on Dashboard)
  const filtered = Object.fromEntries(
    Object.entries(gates).filter(([key]) =>
      !key.startsWith('startup_')
    )
  );

  if (Object.keys(filtered).length === 0) return null;

  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
      {Object.entries(filtered).map(([key, value]) => (
        <TelemetryField key={key} fieldKey={key} value={value} />
      ))}
    </div>
  );
}
