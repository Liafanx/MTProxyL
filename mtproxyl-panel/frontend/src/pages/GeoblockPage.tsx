import { useCallback, useEffect, useState } from 'react';
import { X } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import { OperationProgress } from '@/components/OperationProgress';
import { mtproxylNetApi } from '@/lib/api';
import { useMtproxylOperation } from '@/hooks/useMtproxyl';

/** Turns a country code into its flag emoji via regional indicator symbols. */
function flag(code: string): string {
  if (!/^[a-zA-Z]{2}$/.test(code)) return '';
  return String.fromCodePoint(
    ...code
      .toUpperCase()
      .split('')
      .map((c) => 0x1f1e6 + c.charCodeAt(0) - 65),
  );
}

const COUNTRY_NAMES: Record<string, string> = {
  ru: 'Россия', us: 'США', cn: 'Китай', ir: 'Иран', de: 'Германия',
  fr: 'Франция', gb: 'Великобритания', ua: 'Украина', by: 'Беларусь',
  kz: 'Казахстан', in: 'Индия', br: 'Бразилия', nl: 'Нидерланды',
};

export function GeoblockPage() {
  const [countries, setCountries] = useState<string[]>([]);
  const [code, setCode] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [removing, setRemoving] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const st = await mtproxylNetApi.geoblock();
      setCountries(st.countries);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить список');
    } finally {
      setLoading(false);
    }
  }, []);

  const { operation, start, running } = useMtproxylOperation(load);

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

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-text-primary">Блокировка по странам</h1>
        <p className="text-sm text-text-secondary mt-1">
          Диапазоны адресов выбранных стран блокируются на порту прокси. Списки берутся с
          ipdeny.com, поэтому первое добавление страны занимает время.
        </p>
      </div>

      {error && <ErrorAlert message={error} onRetry={load} />}
      <OperationProgress operation={operation} />

      <Card>
        <CardHeader>
          <CardTitle>Добавить страну</CardTitle>
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
              Заблокировать
            </Button>
            <span className="text-xs text-text-secondary">
              Двухбуквенный код ISO 3166-1
            </span>
          </form>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Заблокированные страны</CardTitle>
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
                  <span>{flag(c)}</span>
                  <span className="text-text-primary uppercase">{c}</span>
                  {COUNTRY_NAMES[c] && (
                    <span className="text-text-secondary text-xs">{COUNTRY_NAMES[c]}</span>
                  )}
                  <button
                    onClick={() => remove(c)}
                    disabled={removing === c || running}
                    title="Разблокировать"
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
    </div>
  );
}
