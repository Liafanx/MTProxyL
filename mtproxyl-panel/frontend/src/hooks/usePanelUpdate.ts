import { useCallback, useEffect, useState } from 'react';
import { panelApi } from '@/lib/api';

export interface PanelUpdateInfo {
  current_version: string;
  latest_version: string;
  update_available: boolean;
  release_url: string;
}

export function panelVersionLabel(version: string) {
  return version.replace(/^mtproxyl-panel-v/, '').replace(/^v(?=\d)/, '');
}

export function usePanelUpdate() {
  const [info, setInfo] = useState<PanelUpdateInfo | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const load = useCallback(async () => {
    setLoading(true);
    try {
      setInfo(await panelApi.get<PanelUpdateInfo>('/panel/update/check'));
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Не удалось проверить версию панели');
    } finally { setLoading(false); }
  }, []);
  useEffect(() => {
    void load();
    const timer = window.setInterval(() => { void load(); }, 300_000);
    return () => window.clearInterval(timer);
  }, [load]);
  return { info, error, loading, load };
}
