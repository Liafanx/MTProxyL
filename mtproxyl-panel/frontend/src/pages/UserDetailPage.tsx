import { useState, useEffect, useMemo, useCallback } from 'react';
import { useParams, Link } from 'react-router-dom';
import { Header } from '@/components/layout/Header';
import { ErrorAlert } from '@/components/ErrorAlert';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { QuotaBar } from '@/components/QuotaBar';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import {
  Table, TableHeader, TableBody, TableRow, TableHead, TableCell,
} from '@/components/ui/table';
import { usePolling } from '@/hooks/usePolling';
import { useQuota, resetUserQuota } from '@/hooks/useQuota';
import { telemt, panelApi, ApiError } from '@/lib/api';
import { formatBytes } from '@/lib/utils';
import { ArrowLeft, ChevronDown, ChevronRight, Search, AlertTriangle, RotateCcw } from 'lucide-react';

interface UserInfo {
  username: string;
  user_ad_tag?: string;
  max_tcp_conns?: number;
  expiration_rfc3339?: string;
  data_quota_bytes?: number;
  max_unique_ips?: number;
  current_connections: number;
  active_unique_ips: number;
  recent_unique_ips: number;
  total_octets: number;
  active_unique_ips_list?: string[];
  recent_unique_ips_list?: string[];
}

interface GeoIPInfo {
  ip: string;
  country: string;
  country_name: string;
  city: string;
  asn?: number;
  asn_org?: string;
}

function countryFlag(code: string): string {
  if (!code || code === '??' || code.length !== 2) return '';
  const base = 0x1F1E6;
  const first = code.charCodeAt(0) - 65;
  const second = code.charCodeAt(1) - 65;
  return String.fromCodePoint(base + first, base + second);
}

const PAGE_SIZE = 50;

interface IPTableProps {
  ips: string[];
  geoData: Map<string, GeoIPInfo>;
  hasGeo: boolean;
}

function IPTable({ ips, geoData, hasGeo }: IPTableProps) {
  const [search, setSearch] = useState('');
  const [page, setPage] = useState(0);

  useEffect(() => setPage(0), [search]);

  const filtered = useMemo(() => {
    if (!search) return ips;
    const q = search.toLowerCase();
    return ips.filter((ip) => {
      if (ip.toLowerCase().includes(q)) return true;
      const geo = geoData.get(ip);
      if (geo) {
        if (geo.country.toLowerCase().includes(q)) return true;
        if (geo.country_name.toLowerCase().includes(q)) return true;
        if (geo.city.toLowerCase().includes(q)) return true;
        if (geo.asn && String(geo.asn).includes(q)) return true;
        if (geo.asn_org && geo.asn_org.toLowerCase().includes(q)) return true;
      }
      return false;
    });
  }, [ips, search, geoData]);

  const totalPages = Math.ceil(filtered.length / PAGE_SIZE);
  const pageIps = filtered.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <div className="relative flex-1 max-w-xs">
          <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-text-secondary" />
          <input
            type="text"
            placeholder="Search IP, country, city, ASN..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full pl-8 pr-3 py-1.5 text-sm rounded-md border border-border bg-background text-text-primary placeholder:text-text-secondary focus:outline-none focus:ring-1 focus:ring-accent"
          />
        </div>
        <span className="text-xs text-text-secondary">
          {filtered.length} IP{filtered.length !== 1 ? 's' : ''}
        </span>
      </div>

      <div className="border border-border rounded-lg overflow-hidden">
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>IP Address</TableHead>
                {hasGeo && <TableHead>Country</TableHead>}
                {hasGeo && <TableHead>City</TableHead>}
                {hasGeo && <TableHead>ASN</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {pageIps.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={hasGeo ? 4 : 1} className="text-center text-text-secondary py-6">
                    {search ? 'No IPs match your search' : 'No IPs'}
                  </TableCell>
                </TableRow>
              ) : (
                pageIps.map((ip) => {
                  const geo = geoData.get(ip);
                  return (
                    <TableRow key={ip}>
                      <TableCell className="font-mono text-sm">{ip}</TableCell>
                      {hasGeo && (
                        <TableCell>
                          <span className="mr-1.5">{geo ? countryFlag(geo.country) : ''}</span>
                          <span className="text-sm">{geo?.country_name || '—'}</span>
                          {geo?.country && geo.country !== '??' && (
                            <span className="text-xs text-text-secondary ml-1">({geo.country})</span>
                          )}
                        </TableCell>
                      )}
                      {hasGeo && (
                        <TableCell className="text-sm">{geo?.city || '—'}</TableCell>
                      )}
                      {hasGeo && (
                        <TableCell className="text-sm">
                          {geo?.asn ? (
                            <span>
                              <span className="font-mono">{geo.asn}</span>
                              {geo.asn_org && (
                                <span className="text-text-secondary ml-1.5">{geo.asn_org}</span>
                              )}
                            </span>
                          ) : '—'}
                        </TableCell>
                      )}
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </div>
      </div>

      {totalPages > 1 && (
        <div className="flex items-center justify-between text-sm">
          <button
            onClick={() => setPage((p) => Math.max(0, p - 1))}
            disabled={page === 0}
            className="px-3 py-1 rounded border border-border text-text-secondary hover:text-text-primary disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Previous
          </button>
          <span className="text-text-secondary">
            Page {page + 1} of {totalPages}
          </span>
          <button
            onClick={() => setPage((p) => Math.min(totalPages - 1, p + 1))}
            disabled={page >= totalPages - 1}
            className="px-3 py-1 rounded border border-border text-text-secondary hover:text-text-primary disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Next
          </button>
        </div>
      )}
    </div>
  );
}

function CollapsibleSection({ title, count, defaultOpen, children }: {
  title: string;
  count: number;
  defaultOpen?: boolean;
  children: React.ReactNode;
}) {
  const [open, setOpen] = useState(defaultOpen ?? false);

  return (
    <div className="border border-border rounded-lg bg-surface">
      <button
        onClick={() => setOpen(!open)}
        className="w-full flex items-center justify-between p-3 hover:bg-surface-hover transition-colors rounded-lg"
      >
        <div className="flex items-center gap-2">
          {open ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
          <span className="font-medium text-text-primary">{title}</span>
          <Badge variant="outline">{count}</Badge>
        </div>
      </button>
      {open && <div className="px-3 pb-3">{children}</div>}
    </div>
  );
}

export function UserDetailPage() {
  const { username } = useParams<{ username: string }>();
  const { data: users, error, loading, refresh } = usePolling<UserInfo[]>(
    () => telemt.get('/v1/users'),
    10000
  );
  const { quotaByUser, supported: quotaSupported, refresh: refreshQuota } = useQuota(10000);
  const quota = username ? quotaByUser.get(username) : undefined;

  const [resetOpen, setResetOpen] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [resetError, setResetError] = useState('');

  const handleResetQuota = useCallback(async () => {
    if (!username) return;
    setResetting(true);
    setResetError('');
    try {
      await resetUserQuota(username);
      setResetOpen(false);
      refresh();
      refreshQuota();
    } catch (err) {
      setResetError(err instanceof ApiError ? err.message : 'Reset failed');
    } finally {
      setResetting(false);
    }
  }, [username, refresh, refreshQuota]);

  const [geoData, setGeoData] = useState<Map<string, GeoIPInfo>>(new Map());
  const [geoError, setGeoError] = useState<string | null>(null);
  const [geoLoading, setGeoLoading] = useState(false);

  const user = useMemo(
    () => users?.find((u) => u.username === username) ?? null,
    [users, username]
  );

  const allIps = useMemo(() => {
    if (!user) return [];
    const set = new Set<string>();
    for (const ip of user.active_unique_ips_list ?? []) set.add(ip);
    for (const ip of user.recent_unique_ips_list ?? []) set.add(ip);
    return Array.from(set);
  }, [user]);

  useEffect(() => {
    if (allIps.length === 0) return;

    let cancelled = false;
    setGeoLoading(true);

    panelApi.post<GeoIPInfo[]>('/geoip/lookup', { ips: allIps })
      .then((results) => {
        if (cancelled) return;
        const map = new Map<string, GeoIPInfo>();
        for (const info of results) map.set(info.ip, info);
        setGeoData(map);
        setGeoError(null);
      })
      .catch((err) => {
        if (cancelled) return;
        setGeoError(err instanceof Error ? err.message : 'GeoIP lookup failed');
      })
      .finally(() => {
        if (!cancelled) setGeoLoading(false);
      });

    return () => { cancelled = true; };
  }, [allIps]);

  const hasGeo = geoData.size > 0;

  return (
    <div className="min-h-screen">
      <Header title={user ? user.username : 'User Details'} refreshing={loading} onRefresh={refresh} />

      <div className="p-4 lg:p-6 space-y-4">
        <Link
          to="/users"
          className="inline-flex items-center gap-1.5 text-sm text-text-secondary hover:text-text-primary transition-colors"
        >
          <ArrowLeft size={14} />
          Back to Users
        </Link>

        {error && <ErrorAlert message={error.message} onRetry={refresh} />}

        {!loading && !user && (
          <ErrorAlert message={`User "${username}" not found`} />
        )}

        {user && (
          <>
            {/* Metric cards */}
            <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
              <MetricCard label="Connections" value={String(user.current_connections)} />
              <MetricCard label="Active IPs" value={`${user.active_unique_ips}${user.max_unique_ips ? ` / ${user.max_unique_ips}` : ''}`} />
              <MetricCard label="Recent IPs" value={String(user.recent_unique_ips)} />
              <MetricCard label="Traffic" value={formatBytes(user.total_octets)} />
              <MetricCard label="Quota" value={user.data_quota_bytes ? formatBytes(user.data_quota_bytes) : '—'} />
              <MetricCard
                label="Expiration"
                value={user.expiration_rfc3339 ? new Date(user.expiration_rfc3339).toLocaleDateString() : '—'}
              />
            </div>

            {/* Data quota */}
            {quotaSupported && quota && quota.data_quota_bytes > 0 && (
              <div className="bg-surface border border-border rounded-lg p-4 space-y-3">
                <div className="flex items-center justify-between gap-3">
                  <span className="font-medium text-text-primary">Data quota</span>
                  <Button variant="outline" size="sm" onClick={() => setResetOpen(true)}>
                    <RotateCcw size={14} className="mr-1.5" />
                    Reset
                  </Button>
                </div>
                <QuotaBar used={quota.used_bytes} limit={quota.data_quota_bytes} />
                <div className="text-xs text-text-secondary">
                  Last reset:{' '}
                  {quota.last_reset_epoch_secs > 0
                    ? new Date(quota.last_reset_epoch_secs * 1000).toLocaleString()
                    : 'never'}
                </div>
              </div>
            )}

            {resetError && <ErrorAlert message={resetError} />}

            {/* GeoIP status banner */}
            {geoError && (
              <div className="flex items-center gap-2 p-3 rounded-lg border border-yellow-500/30 bg-yellow-500/10 text-sm text-yellow-200">
                <AlertTriangle size={16} className="shrink-0" />
                <span>GeoIP not available: {geoError}. Showing IP addresses without geo data.</span>
              </div>
            )}

            {geoLoading && (
              <div className="text-sm text-text-secondary">Loading GeoIP data...</div>
            )}

            {/* IP sections */}
            <CollapsibleSection
              title="Active IPs"
              count={user.active_unique_ips_list?.length ?? 0}
              defaultOpen={true}
            >
              <IPTable
                ips={user.active_unique_ips_list ?? []}
                geoData={geoData}
                hasGeo={hasGeo}
              />
            </CollapsibleSection>

            <CollapsibleSection
              title="Recent IPs"
              count={user.recent_unique_ips_list?.length ?? 0}
            >
              <IPTable
                ips={user.recent_unique_ips_list ?? []}
                geoData={geoData}
                hasGeo={hasGeo}
              />
            </CollapsibleSection>
          </>
        )}
      </div>

      <ConfirmDialog
        open={resetOpen}
        onClose={() => setResetOpen(false)}
        onConfirm={handleResetQuota}
        title="Reset quota"
        message={`Reset the data-quota counter for "${username}"? Used traffic will be set back to zero.`}
        confirmLabel="Reset"
        loadingLabel="Resetting..."
        confirmVariant="default"
        loading={resetting}
      />
    </div>
  );
}

function MetricCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-surface border border-border rounded-lg p-3">
      <div className="text-xs text-text-secondary">{label}</div>
      <div className="text-lg font-semibold text-text-primary mt-1">{value}</div>
    </div>
  );
}
