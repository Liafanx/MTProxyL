import { AlertTriangle, CheckCircle2, Loader2, X } from 'lucide-react';
import type { MtproxylOperation } from '@/lib/api';

const OPERATION_LABELS: Record<string, string> = {
  'mode:manager': 'Переключение в режим Manager',
  'mode:reanimator': 'Переключение в режим Reanimator',
  'selfmask:apply': 'Настройка Selfmask',
  'selfmask:nginx-custom-on': 'Включение пользовательского nginx.conf',
  'selfmask:nginx-custom-off': 'Возврат стандартного nginx.conf',
  'web:enable': 'Включение WEB Proxy',
  'web:disable': 'Отключение WEB Proxy',
  'selfmask:pq-install': 'Установка PQ OpenSSL',
  'backup:restore': 'Восстановление из бэкапа',
  'nft:apply': 'Применение правил лимитера',
  'nft:remove': 'Снятие правил лимитера',
  'nft:service': 'Установка службы лимитера',
  'nft:smart': 'Включение режима Smart (By-MEKO)',
  'nft:drop': 'Сброс счётчиков',
  'nft:ios1': 'Включение iOS Fix v1',
  'nft:ios1-off': 'Отключение iOS Fix v1',
  'nft:ios2': 'Включение iOS Fix v2',
  'nft:ios2-off': 'Отключение iOS Fix v2',
  'nft:zapret2': 'Установка Zapret2',
  'nft:zapret2-start': 'Запуск Zapret2',
  'nft:zapret2-stop': 'Остановка Zapret2',
  'nft:zapret2-rm': 'Удаление Zapret2',
  'nft:zapret2-wscale': 'Настройка окна Zapret2',
  'nft:preset:classic': 'Переключение лимитера в classic',
  'nft:preset:smart': 'Переключение лимитера в smart',
  'geoblock:mode:blacklist': 'Включение блокировки выбранных стран',
  'geoblock:mode:whitelist': 'Включение доступа только выбранным странам',
  'geoblock:reapply': 'Переприменение блокировки стран',
  'tgbot:install': 'Установка телеграм-бота',
};

function label(name?: string): string {
  if (!name) return 'Операция';
  if (OPERATION_LABELS[name]) return OPERATION_LABELS[name];
  // Имена вида "geoblock:add:ir" собираются с аргументом на конце.
  if (name.startsWith('geoblock:add:')) {
    return `Добавление страны ${name.slice('geoblock:add:'.length).toUpperCase()}`;
  }
  return name;
}

/** «3 мин 20 с» читается быстрее, чем «200». */
function humanElapsed(seconds?: number): string {
  if (!seconds || seconds < 1) return '';
  if (seconds < 60) return `${seconds} с`;
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return s === 0 ? `${m} мин` : `${m} мин ${s} с`;
}

/**
 * Последние строки вывода — то, что команда делает прямо сейчас.
 *
 * Показываем хвост, а не всё: пользователю нужен текущий шаг, а полный лог
 * появится по завершении.
 */
function tail(text: string, lines: number): string {
  const all = text.trimEnd().split('\n');
  return all.slice(Math.max(0, all.length - lines)).join('\n');
}

interface OperationProgressProps {
  operation: MtproxylOperation | null;
  /**
   * Закрыть блок с результатом. Без него отчёт о завершившейся операции висит
   * до следующего запуска и возвращается после перезагрузки страницы.
   */
  onDismiss?: () => void;
}

/** Крестик в углу блока — единственный способ убрать отчёт о прошлой операции. */
function DismissButton({ onDismiss }: { onDismiss?: () => void }) {
  if (!onDismiss) return null;
  return (
    <button
      type="button"
      onClick={onDismiss}
      aria-label="Закрыть"
      title="Закрыть"
      className="shrink-0 -mt-1 -mr-1 p-1 rounded text-text-secondary hover:text-text-primary hover:bg-background/60 transition-colors"
    >
      <X size={16} />
    </button>
  );
}

/**
 * Shows the state of a background MTProxyL command.
 *
 * These commands take minutes, so the UI reports progress instead of blocking
 * on a request that would time out. While it runs the command's own output is
 * echoed here — without it a slow step (downloading PQ nginx, waiting on
 * certbot) is indistinguishable from a hang.
 */
export function OperationProgress({ operation, onDismiss }: OperationProgressProps) {
  if (!operation || operation.phase === 'idle') return null;

  if (operation.phase === 'running') {
    const elapsed = humanElapsed(operation.elapsed_seconds);
    const live = operation.progress ? tail(operation.progress, 6) : '';
    return (
      <div className="bg-accent/10 border border-accent/30 rounded-lg p-4 flex items-start gap-3">
        <Loader2 size={18} className="text-accent shrink-0 animate-spin mt-0.5" />
        <div className="flex-1 min-w-0">
          <div className="text-sm text-text-primary">
            {label(operation.name)}…{elapsed && <span className="text-text-secondary"> ({elapsed})</span>}
          </div>
          <div className="text-xs text-text-secondary mt-0.5">
            Операция выполняется, это может занять несколько минут. Страницу можно не держать
            открытой.
          </div>
          {live ? (
            <pre className="text-xs text-text-secondary mt-2 whitespace-pre-wrap break-words font-mono bg-background/60 border border-border rounded p-2 max-h-40 overflow-y-auto">
              {live}
            </pre>
          ) : (
            <div className="text-xs text-text-secondary/70 mt-2">Ожидание первых сообщений…</div>
          )}
        </div>
      </div>
    );
  }

  if (operation.phase === 'failed') {
    return (
      <div className="bg-danger/10 border border-danger/30 rounded-lg p-4 flex items-start gap-3">
        <AlertTriangle size={18} className="text-danger shrink-0 mt-0.5" />
        <div className="flex-1 min-w-0">
          <div className="text-sm text-danger">
            {label(operation.name)} — ошибка
            {operation.elapsed_seconds ? (
              <span className="text-text-secondary"> (через {humanElapsed(operation.elapsed_seconds)})</span>
            ) : null}
          </div>
          {operation.error && (
            <pre className="text-xs text-danger/90 mt-1 whitespace-pre-wrap break-words font-mono">
              {operation.error}
            </pre>
          )}
          {operation.progress && (
            <details className="mt-2">
              <summary className="text-xs text-text-secondary cursor-pointer">
                Показать полный вывод
              </summary>
              <pre className="text-xs text-text-secondary mt-1 whitespace-pre-wrap break-words font-mono max-h-64 overflow-y-auto">
                {operation.progress}
              </pre>
            </details>
          )}
        </div>
        <DismissButton onDismiss={onDismiss} />
      </div>
    );
  }

  return (
    <div className="bg-success/10 border border-success/30 rounded-lg p-4 flex items-start gap-3">
      <CheckCircle2 size={18} className="text-success shrink-0 mt-0.5" />
      <div className="flex-1 min-w-0">
        <div className="text-sm text-success">
          {label(operation.name)} — готово
          {operation.elapsed_seconds ? (
            <span className="text-text-secondary"> (за {humanElapsed(operation.elapsed_seconds)})</span>
          ) : null}
        </div>
        {operation.output && (
          <pre className="text-xs text-text-secondary mt-1 whitespace-pre-wrap break-words font-mono max-h-48 overflow-y-auto">
            {operation.output}
          </pre>
        )}
      </div>
      <DismissButton onDismiss={onDismiss} />
    </div>
  );
}
