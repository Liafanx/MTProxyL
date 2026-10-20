const assert = require('node:assert/strict');
const fs = require('node:fs'); const path = require('node:path'); const http = require('node:http');
let playwright;
try { playwright = require('playwright-core'); }
catch { playwright = require('/usr/lib/node_modules/playwright-core'); }
// Выключение и включение пользователя на подставных данных: npm run build, затем node tests/panel_users_toggle.cjs
const dist = path.resolve(__dirname, '../mtproxyl-panel/dist');
const server = http.createServer((q, r) => {
  const p = path.resolve(dist, '.' + new URL(q.url, 'http://x').pathname);
  const f = fs.existsSync(p) && fs.statSync(p).isFile() ? p : path.join(dist, 'index.html');
  r.setHeader('Content-Type', {'.js':'text/javascript','.css':'text/css'}[path.extname(f)] || 'text/html');
  fs.createReadStream(f).pipe(r);
});
const mu = (label, enabled) => ({ label, secret: 'a'.repeat(32), created: 0, enabled, max_conns: 0, max_ips: 3, quota_bytes: 0,
  expires: '0', notes: '', total_in: 0, total_out: 0, total_bytes: 5e9, ip_history: [] });
(async () => {
  await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await playwright.chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', args: ['--no-sandbox'] });
  for (const mode of ['manager', 'reanimator']) for (const width of [390, 1440]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const st = { writes: [], bobOn: true };
    await page.route('**/api/**', async (route) => {
      const u = new URL(route.request().url()); const m = route.request().method();
      if (m !== 'GET') st.writes.push(m + ' ' + u.pathname + ' ' + (route.request().postData() || ''));
      let data = {};
      if (u.pathname.endsWith('/auth/me')) data = { username: 'admin' };
      else if (u.pathname.endsWith('/mtproxyl/status')) data = { enabled: true, mode };
      else if (u.pathname.endsWith('/v1/users')) data = [{ username: 'alice', current_connections: 1, active_unique_ips: 1, recent_unique_ips: 0, total_octets: 1 },
        ...(st.bobOn ? [{ username: 'bob', current_connections: 0, active_unique_ips: 0, recent_unique_ips: 0, total_octets: 0 }] : [])];
      else if (u.pathname.endsWith('/mtproxyl/users')) data = [mu('alice', true), mu('bob', st.bobOn), mu('carol', false)];
      else if (u.pathname.endsWith('/toggle')) { st.bobOn = u.pathname.includes('/bob/') ? JSON.parse(route.request().postData()).enabled : st.bobOn; data = { output: 'ok' }; }
      else if (u.pathname.endsWith('/mtproxyl/web')) data = { enabled: false };
      await route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, data }) });
    });
    await page.goto(`${base}/users`);
    const root = width < 1024 ? page.locator('.lg\\:hidden.space-y-3') : page.locator('table');
    await root.getByText('carol').first().waitFor();
    // carol выключена: без ссылки на подробности, есть «Включить»
    const carolRow = width < 1024 ? root.locator('> div', { hasText: 'carol' }) : root.locator('tr', { hasText: 'carol' });
    assert.equal(await carolRow.locator('a').count(), 0, 'disabled user is a link');
    assert.equal(await carolRow.getByTitle('Изменить').count(), mode === 'manager' ? 1 : 0);
    const bobRow = width < 1024 ? root.locator('> div', { hasText: 'bob' }) : root.locator('tr', { hasText: 'bob' });
    await bobRow.getByTitle('Выключить').click();
    await page.getByRole('button', { name: 'Выключить' }).last().click();
    await bobRow.getByTitle('Включить').waitFor({ timeout: 15000 });
    await bobRow.getByTitle('Включить').click();
    await bobRow.getByTitle('Выключить').waitFor({ timeout: 15000 });
    const t = st.writes.filter((w) => w.includes('toggle'));
    assert.deepEqual(t, ['POST /api/mtproxyl/users/bob/toggle {"enabled":false}', 'POST /api/mtproxyl/users/bob/toggle {"enabled":true}']);
    console.log(mode, width, 'ok');
    await page.close();
  }
  await browser.close(); server.close();
})().catch((e) => { console.error(e); process.exit(1); });
