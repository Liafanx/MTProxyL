import { AlertTriangle } from 'lucide-react';

interface ErrorAlertProps {
  message: string;
  onRetry?: () => void;
}

export function ErrorAlert({ message, onRetry }: ErrorAlertProps) {
  return (
    <div className="bg-danger/10 border border-danger/30 rounded-lg p-4 flex items-center gap-3">
      <AlertTriangle size={18} className="text-danger shrink-0" />
      <span className="text-sm text-danger flex-1">{message}</span>
      {onRetry && (
        <button
          onClick={onRetry}
          className="text-xs text-danger hover:text-danger/80 underline"
        >
          Retry
        </button>
      )}
    </div>
  );
}
