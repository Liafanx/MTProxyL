import { useState, useEffect, FormEvent } from 'react';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

interface UserFormData {
  username: string;
  secret?: string;
  user_ad_tag?: string;
  max_tcp_conns?: number | '';
  expiration_rfc3339?: string;
  data_quota_bytes?: number | '';
  max_unique_ips?: number | '';
}

interface UserFormDialogProps {
  open: boolean;
  onClose: () => void;
  onSubmit: (data: Record<string, unknown>) => Promise<void>;
  initialData?: Partial<UserFormData>;
  mode: 'create' | 'edit';
}

const emptyForm: UserFormData = {
  username: '',
  secret: '',
  user_ad_tag: '',
  max_tcp_conns: '',
  expiration_rfc3339: '',
  data_quota_bytes: '',
  max_unique_ips: '',
};

export function UserFormDialog({ open, onClose, onSubmit, initialData, mode }: UserFormDialogProps) {
  const [form, setForm] = useState<UserFormData>(emptyForm);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (open) {
      const init = { ...emptyForm, ...initialData };
      // Treat 0 as "not set" for numeric limit fields so the form shows empty
      // and PATCH will not send 0 (which telemt interprets as "block user")
      if (init.max_tcp_conns === 0) init.max_tcp_conns = '';
      if (init.data_quota_bytes === 0) init.data_quota_bytes = '';
      if (init.max_unique_ips === 0) init.max_unique_ips = '';
      setForm(init);
      setError('');
    }
  }, [open, initialData]);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError('');

    try {
      const payload: Record<string, unknown> = {};

      if (mode === 'create') {
        payload.username = form.username;
      }
      if (form.secret) payload.secret = form.secret;
      if (form.user_ad_tag) payload.user_ad_tag = form.user_ad_tag;
      if (form.max_tcp_conns !== '' && form.max_tcp_conns !== undefined && Number(form.max_tcp_conns) > 0) {
        payload.max_tcp_conns = Number(form.max_tcp_conns);
      }
      if (form.expiration_rfc3339) payload.expiration_rfc3339 = form.expiration_rfc3339;
      if (form.data_quota_bytes !== '' && form.data_quota_bytes !== undefined && Number(form.data_quota_bytes) > 0) {
        payload.data_quota_bytes = Number(form.data_quota_bytes);
      }
      if (form.max_unique_ips !== '' && form.max_unique_ips !== undefined && Number(form.max_unique_ips) > 0) {
        payload.max_unique_ips = Number(form.max_unique_ips);
      }

      await onSubmit(payload);
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed');
    } finally {
      setLoading(false);
    }
  };

  const set = (key: keyof UserFormData) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((prev) => ({ ...prev, [key]: e.target.value }));

  return (
    <Dialog open={open} onClose={onClose}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{mode === 'create' ? 'Create User' : 'Edit User'}</DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="space-y-4 py-4">
          {mode === 'create' && (
            <div className="space-y-1.5">
              <Label htmlFor="username">Username *</Label>
              <Input
                id="username"
                value={form.username}
                onChange={set('username')}
                placeholder="user1"
                required
                pattern="[A-Za-z0-9_.\-]+"
              />
            </div>
          )}

          <div className="space-y-1.5">
            <Label htmlFor="secret">Secret (32 hex, auto if empty)</Label>
            <Input
              id="secret"
              value={form.secret}
              onChange={set('secret')}
              placeholder="auto-generate"
              pattern="[0-9a-fA-F]{32}"
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="ad_tag">Ad Tag (32 hex)</Label>
            <Input
              id="ad_tag"
              value={form.user_ad_tag}
              onChange={set('user_ad_tag')}
              placeholder="optional"
              pattern="[0-9a-fA-F]{32}"
            />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="max_tcp">Max TCP Conns</Label>
              <Input
                id="max_tcp"
                type="number"
                value={form.max_tcp_conns}
                onChange={set('max_tcp_conns')}
                min={0}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="max_ips">Max Unique IPs</Label>
              <Input
                id="max_ips"
                type="number"
                value={form.max_unique_ips}
                onChange={set('max_unique_ips')}
                min={0}
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="quota">Data Quota (bytes)</Label>
            <Input
              id="quota"
              type="number"
              value={form.data_quota_bytes}
              onChange={set('data_quota_bytes')}
              min={0}
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="expiration">Expiration (RFC3339)</Label>
            <Input
              id="expiration"
              value={form.expiration_rfc3339}
              onChange={set('expiration_rfc3339')}
              placeholder="2025-12-31T23:59:59Z"
            />
          </div>

          {error && <p className="text-sm text-danger">{error}</p>}

          <DialogFooter>
            <Button variant="outline" type="button" onClick={onClose} disabled={loading}>
              Cancel
            </Button>
            <Button type="submit" disabled={loading}>
              {loading ? 'Saving...' : mode === 'create' ? 'Create' : 'Save'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
