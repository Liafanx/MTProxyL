import { Routes, Route, Navigate } from 'react-router-dom';
import { AuthContext, useAuthProvider, useAuth } from '@/hooks/useAuth';
import { WsContext, useWsProvider } from '@/hooks/useWebSocket';
import { ThemeContext, useThemeProvider } from '@/hooks/useTheme';
import { AppLayout } from '@/components/layout/AppLayout';
import { LoginPage } from '@/pages/LoginPage';
import { DashboardPage } from '@/pages/DashboardPage';
import { UsersPage } from '@/pages/UsersPage';
import { UserDetailPage } from '@/pages/UserDetailPage';
import { RuntimePage } from '@/pages/RuntimePage';
import { SecurityPage } from '@/pages/SecurityPage';
import { UpstreamsPage } from '@/pages/UpstreamsPage';
import { UpdatePage } from '@/pages/UpdatePage';
import { ConfigPage } from '@/pages/ConfigPage';
import { LogsPage } from '@/pages/LogsPage';
import { ModePage } from '@/pages/ModePage';
import { SettingsPage } from '@/pages/SettingsPage';
import { MaintenancePage } from '@/pages/MaintenancePage';
import { SelfmaskPage } from '@/pages/SelfmaskPage';
import { BackupsPage } from '@/pages/BackupsPage';
import { NftPage } from '@/pages/NftPage';
import { GeoblockPage } from '@/pages/GeoblockPage';
import { RoutesPage } from '@/pages/RoutesPage';
import { TrafficPage } from '@/pages/TrafficPage';
import { ExpertPage } from '@/pages/ExpertPage';
import { SuperExpertPage } from '@/pages/SuperExpertPage';
import { AddonsPage } from '@/pages/AddonsPage';
import { AvailabilityPage } from '@/pages/AvailabilityPage';
import { WarpPage } from '@/pages/WarpPage';
import { TgbotPage } from '@/pages/TgbotPage';
import { MtproxylContext, useMtproxylAvailability } from '@/hooks/useMtproxyl';

function AuthenticatedApp() {
  const { username, loading } = useAuth();
  const ws = useWsProvider();
  const mtproxyl = useMtproxylAvailability();

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <div className="text-text-secondary">Загрузка…</div>
      </div>
    );
  }

  if (!username) {
    return <Navigate to="/login" replace />;
  }

  return (
    <WsContext.Provider value={ws}>
      <MtproxylContext.Provider value={mtproxyl}>
      <Routes>
        <Route element={<AppLayout />}>
          <Route path="/" element={<DashboardPage />} />
          <Route path="/users/:username" element={<UserDetailPage />} />
          <Route path="/users" element={<UsersPage />} />
          <Route path="/runtime" element={<RuntimePage />} />
          <Route path="/security" element={<SecurityPage />} />
          <Route path="/upstreams" element={<UpstreamsPage />} />
          <Route path="/config" element={<ConfigPage />} />
          <Route path="/update" element={<UpdatePage />} />
          <Route path="/logs" element={<LogsPage />} />
          <Route path="/mode" element={<ModePage />} />
          <Route path="/proxy-settings" element={<SettingsPage />} />
          <Route path="/maintenance" element={<MaintenancePage />} />
          <Route path="/selfmask" element={<SelfmaskPage />} />
          <Route path="/backups" element={<BackupsPage />} />
          <Route path="/nft" element={<NftPage />} />
          <Route path="/geoblock" element={<GeoblockPage />} />
          <Route path="/routes" element={<RoutesPage />} />
          <Route path="/traffic" element={<TrafficPage />} />
          <Route path="/expert" element={<ExpertPage />} />
          <Route path="/superexpert" element={<SuperExpertPage />} />
          <Route path="/addons" element={<AddonsPage />} />
          <Route path="/availability" element={<AvailabilityPage />} />
          <Route path="/warp" element={<WarpPage />} />
          <Route path="/tgbot" element={<TgbotPage />} />
        </Route>
      </Routes>
      </MtproxylContext.Provider>
    </WsContext.Provider>
  );
}

export default function App() {
  const auth = useAuthProvider();
  const themeCtx = useThemeProvider();

  return (
    <ThemeContext.Provider value={themeCtx}>
      <AuthContext.Provider value={auth}>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route path="*" element={<AuthenticatedApp />} />
        </Routes>
      </AuthContext.Provider>
    </ThemeContext.Provider>
  );
}
