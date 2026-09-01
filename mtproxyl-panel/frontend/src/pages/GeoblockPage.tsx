import { useCallback, useEffect, useState } from 'react';
import { Flag, X } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { mtproxylNetApi } from '@/lib/api';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';

function CountryFlag({ code }: { code: string }) {
  const [failed, setFailed] = useState(false);
  if (failed) return <Flag size={16} aria-label={`Флаг ${code.toUpperCase()}`} />;
  return (
    <img
      src={`https://flagcdn.com/24x18/${code.toLowerCase()}.png`}
      width={24}
      height={18}
      alt={`Флаг ${code.toUpperCase()}`}
      referrerPolicy="no-referrer"
      loading="lazy"
      onError={() => setFailed(true)}
      className="rounded-sm"
    />
  );
}

const COUNTRY_NAMES: Record<string, string> = {
  ru: 'Россия', us: 'США', cn: 'Китай', ir: 'Иран', de: 'Германия',
  fr: 'Франция', gb: 'Великобритания', ua: 'Украина', by: 'Беларусь',
  kz: 'Казахстан', in: 'Индия', br: 'Бразилия', nl: 'Нидерланды',
};

export function GeoblockPage() {
  const [countries, setCountries] = useState<string[]>([]);
  const [mode, setMode] = useState<'blacklist' | 'whitelist'>('blacklist');
  const [rulesActive, setRulesActive] = useState(false);
  const [portsMatch, setPortsMatch] = useState(true);
  const [serviceEnabled, setServiceEnabled] = useState(false);
  const [code, setCode] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [removing, setRemoving] = useState<string | null>(null);
  const [confirmWhitelist, setConfirmWhitelist] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const st = await mtproxylNetApi.geoblock();
      setCountries(st.countries);
      setMode(st.mode || 'blacklist');
      setRulesActive(st.rules_active);
      setPortsMatch(st.ports_match ?? true);
      setServiceEnabled(st.service_enabled);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить список');
    } finally {
      setLoading(false);
    }
  }, []);

  const { operation, start, dismiss, running } = useMtproxylOperation(load, ['geoblock:']);

  useEffect(() => {
    void load();
  }, [load]);

  const add = async () => {
    const c = code.trim().toLowerCase();
    if (!/^[a-z]{2}$/.test(c)) {
      setError('Код страны состоит из двух букв, например ru или ir');
      return;
    }
    try {
      // Blocking a country downloads its whole CIDR list, so this runs in the
      // background rather than blocking the request.
      start(await mtproxylNetApi.geoblockAdd(c));
      setCode('');
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось добавить страну');
    }
  };

  const remove = async (c: string) => {
    setRemoving(c);
    try {
      await mtproxylNetApi.geoblockRemove(c);
      setError(null);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось удалить страну');
    } finally {
      setRemoving(null);
    }
  };

  const changeMode = async (next: 'blacklist' | 'whitelist') => {
    setConfirmWhitelist(false);
    if (next === mode) return;
    try {
      start(await mtproxylNetApi.geoblockMode(next));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сменить режим');
    }
  };

  const reapply = async () => {
    try {
      start(await mtproxylNetApi.geoblockReapply());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переприменить правила');
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Блокировка по странам</h1>
        <p className="text-sm text-text-secondary mt-1">
          {mode === 'whitelist'
            ? 'На публичных портах прокси и WEB разрешены только выбранные страны.'
            : 'Диапазоны адресов выбранных стран блокируются на публичных портах прокси и WEB.'}
          Списки берутся с ipdeny.com, поэтому первое добавление страны занимает время.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={load} />}
      <OperationProgress operation={operation} onDismiss={dismiss} />

      <Card>
        <CardHeader>
          <CardTitle>Режим</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="flex flex-wrap gap-2">
            <Button
              variant={mode === 'blacklist' ? 'default' : 'outline'}
              onClick={() => void changeMode('blacklist')}
              disabled={running}
            >
              Блокировать выбранные
            </Button>
            <Button
              variant={mode === 'whitelist' ? 'default' : 'outline'}
              onClick={() => setConfirmWhitelist(true)}
              disabled={running || countries.length === 0}
            >
              Разрешать только выбранные
            </Button>
            {countries.length > 0 && (
              <Button variant="outline" onClick={() => void reapply()} disabled={running}>
                Переприменить
              </Button>
            )}
          </div>
          <div className="text-xs text-text-secondary space-y-1">
            <div>
              Правила: {rulesActive ? (portsMatch ? 'активны' : 'нужно переприменить на текущие порты') : countries.length > 0 ? 'не применены' : 'список пуст'}
            </div>
            <div>После перезагрузки: {serviceEnabled ? 'восстановятся автоматически' : 'служба не включена'}</div>
            {countries.length === 0 && (
              <div>Для реверсивного режима сначала добавьте хотя бы одну страну.</div>
            )}
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{mode === 'whitelist' ? 'Добавить разрешённую страну' : 'Добавить заблокированную страну'}</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="flex flex-wrap items-center gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              void add();
            }}
          >
            <Input
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="ru"
              maxLength={2}
              className="max-w-[120px]"
            />
            <Button type="submit" disabled={running}>
              Добавить
            </Button>
            <span className="text-xs text-text-secondary">
              Двухбуквенный код ISO 3166-1
            </span>
          </form>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{mode === 'whitelist' ? 'Разрешённые страны' : 'Заблокированные страны'}</CardTitle>
        </CardHeader>
        <CardContent>
          {loading && countries.length === 0 ? (
            <div className="text-sm text-text-secondary">Загрузка…</div>
          ) : countries.length === 0 ? (
            <div className="text-sm text-text-secondary">Список пуст</div>
          ) : (
            <div className="flex flex-wrap gap-2">
              {countries.map((c) => (
                <span
                  key={c}
                  className="inline-flex items-center gap-2 bg-surface-hover border border-border rounded-full pl-3 pr-1 py-1 text-sm"
                >
                  <CountryFlag code={c} />
                  <span className="text-text-primary uppercase">{c}</span>
                  {COUNTRY_NAMES[c] && (
                    <span className="text-text-secondary text-xs">{COUNTRY_NAMES[c]}</span>
                  )}
                  <button
                    onClick={() => remove(c)}
                    disabled={removing === c || running}
                    title="Удалить из списка"
                    className="p-1 rounded-full hover:bg-danger/15 hover:text-danger disabled:opacity-40"
                  >
                    <X size={14} />
                  </button>
                </span>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      <ConfirmDialog
        open={confirmWhitelist}
        title="Включить реверсивную блокировку?"
        message="Подключаться к прокси смогут только адреса выбранных стран. Остальные страны будут заблокированы на публичных портах."
        confirmLabel="Включить"
        onConfirm={() => void changeMode('whitelist')}
        onClose={() => setConfirmWhitelist(false)}
      />
    </div>
  );
}
