import { AlertTriangle } from 'lucide-react';

interface ErrorAlertProps {
  message: string;
  onRetry?: () => void;
}

export function ErrorAlert({ message, onRetry }: ErrorAlertProps) {
  return (
    <div className="flex items-center gap-3 rounded-xl border border-error/30 bg-error/10 p-4">
      <AlertTriangle size={18} className="shrink-0 text-error" />
      <span className="flex-1 text-sm text-error">{message}</span>
      {onRetry && (
        <button
          onClick={onRetry}
          className="min-h-[34px] rounded-md bg-error/12 px-3 text-xs font-semibold text-error transition-colors hover:bg-error/20"
        >
          Повторить
        </button>
      )}
    </div>
  );
}
