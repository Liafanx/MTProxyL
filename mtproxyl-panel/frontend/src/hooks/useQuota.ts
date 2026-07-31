import { useState, useEffect, useCallback, useRef } from 'react';
import { telemt } from '@/lib/api';
import { QUOTA_ENDPOINT } from './useQuotaEndpoint';

export interface QuotaEntry {
  username: string;
  data_quota_bytes: number;
  used_bytes: number;
  last_reset_epoch_secs: number;
}

interface QuotaListData {
  users: QuotaEntry[];
}

export interface UseQuotaResult {
  /** Quota usage keyed by username. Only users with a positive quota are present. */
  quotaByUser: Map<string, QuotaEntry>;
  /** False when the telemt build predates the quota endpoint (graceful degradation). */
  supported: boolean;
  refresh: () => void;
}

export function resetUserQuota(username: string): Promise<unknown> {
  return telemt.post(`/v1/users/${encodeURIComponent(username)}/reset-quota`, {});
}

export function useQuota(intervalMs = 10000): UseQuotaResult {
  const [quotaByUser, setQuotaByUser] = useState<Map<string, QuotaEntry>>(new Map());
  const [supported, setSupported] = useState(true);
  // The endpoint's existence is a property of the telemt version, so once we see
  // it succeed we keep the feature enabled and ignore later transient errors.
  const everSupported = useRef(false);

  const doFetch = useCallback(async () => {
    try {
      const data = await telemt.get<QuotaListData>(QUOTA_ENDPOINT);
      const map = new Map<string, QuotaEntry>();
      for (const entry of data.users ?? []) map.set(entry.username, entry);
      everSupported.current = true;
      setQuotaByUser(map);
      setSupported(true);
    } catch {
      if (!everSupported.current) setSupported(false);
    }
  }, []);

  useEffect(() => {
    doFetch();
    const id = setInterval(doFetch, intervalMs);
    return () => clearInterval(id);
  }, [doFetch, intervalMs]);

  return { quotaByUser, supported, refresh: doFetch };
}
