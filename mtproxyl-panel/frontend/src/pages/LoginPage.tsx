import { useState, FormEvent } from 'react';
import { Navigate } from 'react-router-dom';
import { useAuth } from '@/hooks/useAuth';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { brandingApi } from '@/lib/api';
import { useBranding } from '@/hooks/useBranding';

export function LoginPage() {
  const { username, login } = useAuth();
  const [user, setUser] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const { branding } = useBranding();

  const backgroundURL = branding.has_background
    ? brandingApi.backgroundURL(branding.background_revision)
    : '';

  if (username) {
    return <Navigate to="/" replace />;
  }

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      await login(user, password);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Не удалось войти');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div
      className="min-h-screen flex items-center justify-center bg-background bg-cover bg-center px-4"
      style={backgroundURL ? {
        backgroundImage: `linear-gradient(rgba(8, 11, 18, 0.68), rgba(8, 11, 18, 0.78)), url("${backgroundURL}")`,
      } : undefined}
    >
      <div className="w-full max-w-sm">
        <div className="text-center mb-8">
          <h1 className={backgroundURL ? 'text-2xl font-bold text-white drop-shadow break-words' : 'text-2xl font-bold text-text-primary break-words'}>
            {branding.login_title}
          </h1>
          {branding.login_subtitle && (
            <p className={backgroundURL ? 'text-sm text-white/80 mt-1 drop-shadow' : 'text-sm text-text-secondary mt-1'}>
              {branding.login_subtitle}
            </p>
          )}
        </div>

        <form
          onSubmit={handleSubmit}
          className="bg-surface/95 backdrop-blur-sm border border-border rounded-lg p-6 space-y-4 shadow-xl"
        >
          <div className="space-y-2">
            <Label htmlFor="username">Имя пользователя</Label>
            <Input
              id="username"
              value={user}
              onChange={(e) => setUser(e.target.value)}
              placeholder="admin"
              autoFocus
              required
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="password">Пароль</Label>
            <Input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="••••••••"
              required
            />
          </div>

          {error && (
            <p className="text-sm text-danger">{error}</p>
          )}

          <Button type="submit" className="w-full" disabled={loading}>
            {loading ? 'Вход…' : 'Войти'}
          </Button>
        </form>
      </div>
    </div>
  );
}
