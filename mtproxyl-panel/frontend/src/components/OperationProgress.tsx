import { AlertTriangle, CheckCircle2, Loader2 } from 'lucide-react';
import type { MtproxylOperation } from '@/lib/api';

const OPERATION_LABELS: Record<string, string> = {
  'mode:manager': 'Переключение в режим Manager',
  'mode:reanimator': 'Переключение в режим Reanimator',
  'selfmask:setup': 'Настройка Selfmask',
  'backup:restore': 'Восстановление из бэкапа',
};

function label(name?: string): string {
  if (!name) return 'Операция';
  return OPERATION_LABELS[name] ?? name;
}

interface OperationProgressProps {
  operation: MtproxylOperation | null;
}

/**
 * Shows the state of a background MTProxyL command.
 *
 * These commands take minutes, so the UI reports progress instead of blocking
 * on a request that would time out.
 */
export function OperationProgress({ operation }: OperationProgressProps) {
  if (!operation || operation.phase === 'idle') return null;

  if (operation.phase === 'running') {
    return (
      <div className="bg-accent/10 border border-accent/30 rounded-lg p-4 flex items-center gap-3">
        <Loader2 size={18} className="text-accent shrink-0 animate-spin" />
        <div className="flex-1 min-w-0">
          <div className="text-sm text-text-primary">{label(operation.name)}…</div>
          <div className="text-xs text-text-secondary mt-0.5">
            Операция выполняется, это может занять несколько минут. Страницу можно не держать открытой.
          </div>
        </div>
      </div>
    );
  }

  if (operation.phase === 'failed') {
    return (
      <div className="bg-danger/10 border border-danger/30 rounded-lg p-4 flex items-start gap-3">
        <AlertTriangle size={18} className="text-danger shrink-0 mt-0.5" />
        <div className="flex-1 min-w-0">
          <div className="text-sm text-danger">{label(operation.name)} — ошибка</div>
          {operation.error && (
            <pre className="text-xs text-danger/90 mt-1 whitespace-pre-wrap break-words font-mono">
              {operation.error}
            </pre>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="bg-success/10 border border-success/30 rounded-lg p-4 flex items-start gap-3">
      <CheckCircle2 size={18} className="text-success shrink-0 mt-0.5" />
      <div className="flex-1 min-w-0">
        <div className="text-sm text-success">{label(operation.name)} — готово</div>
        {operation.output && (
          <pre className="text-xs text-text-secondary mt-1 whitespace-pre-wrap break-words font-mono max-h-48 overflow-y-auto">
            {operation.output}
          </pre>
        )}
      </div>
    </div>
  );
}
