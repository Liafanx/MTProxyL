const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
let playwright;
try { playwright = require('playwright-core'); }
catch { playwright = require('/usr/lib/node_modules/playwright-core'); }

let base = (process.argv[2] || 'https://127.0.0.1:8080/nepanel').replace(/\/$/, '');
const output = fs.mkdtempSync(path.join(os.tmpdir(), 'mtproxyl-panel-visual-'));
const errorText = 'Proxy error: ME init incomplete: no live writers for DC groups [-203, -3, -2, -1, 1, 2, 3, 203, -5, -4, 5]. ' + 'x'.repeat(300);
const now = 1791982800;
const points = (metric) => Array.from({ length: 31 }, (_, i) => ({
  ts: now - 1800 + i * 60, v: metric === 'active_users' ? 1 : (i === 15 ? 20 : 2 + i % 4),
}));
const initialization = {
  status: 'initializing', degraded: false, current_stage: 'background_init', progress_pct: 71,
  started_at_epoch_secs: now - 60, total_elapsed_ms: 60000, transport_mode: 'middle_proxy',
  me: { status: 'initializing', current_stage: 'background_init', progress_pct: 71,
    init_attempt: 322, retry_limit: 'unlimited', last_error: errorText }, components: [],
};
const wsData = {
  '/v1/runtime/initialization': initialization,
  '/v1/runtime/gates': {},
  '/v1/stats/upstreams': { enabled: true, upstreams: [{ upstream_id: 1, address: '203.0.113.17:1080', route_kind: 'socks5',
    healthy: true, weight: 1, fails: 0, scopes: '', last_check_age_secs: 1, effective_latency_ms: 40, dc: [] }] },
  '/v1/stats/dcs': { middle_proxy_enabled: true, dcs: [{ dc: 7, available_endpoints: 1, available_pct: 100,
    required_writers: 1, alive_writers: 1, coverage_pct: 100, fresh_alive_writers: 1, fresh_coverage_pct: 100,
    floor_min: 1, floor_target: 1, floor_max: 1, rtt_ms: 40, load: 1 }] },
  '/v1/stats/me-writers': { middle_proxy_enabled: false },
  '/v1/stats/minimal/all': { data: { network_path: [] } },
  '/v1/health': { status: 'ok' },
  '/v1/stats/summary': { uptime_seconds: 600, configured_users: 1, connections_total: 100,
    connections_bad_total: 0, current_connections: 2, active_users: 1, total_octets: 1000 },
};
const branding = {
  panel_name: 'Тестовая панель', login_title: 'Личный вход', login_subtitle: 'Сохранённый текст',
  has_background: false, panel_background_mode: 'none', has_panel_background: false,
};
const users = ['short', 'long_username_'.repeat(4), 'other'].map((username, index) => ({
  username, current_connections: index + 1, active_unique_ips: index + 1,
  recent_unique_ips: 0, total_octets: (index + 1) * 123456789, max_unique_ips: 5,
  expiration_rfc3339: '2027-10-08T00:00:00Z',
  links: { tls: [`tg://proxy?server=example.com&port=443&secret=ee${'a'.repeat(32)}${'b'.repeat(20)}`] },
}));

async function mock(page) {
  const state = { brandingWait: null, statsWait: null, failBranding: false, writes: [], sockets: [], hold: new Set(), upstreamAddress: '203.0.113.17:1080' };
  await page.addInitScript(() => localStorage.setItem('mtproxyl-panel-theme', 'light'));
  await page.addInitScript(() => {
    window.__testSockets = [];
    const wrap = (Original) => class extends Original {
      constructor(...args) { super(...args); window.__testSockets.push(this); }
      send(data) { this.__lastSent = data; return super.send(data); }
    };
    let Socket = wrap(window.WebSocket);
    Object.defineProperty(window, 'WebSocket', {
      configurable: true, get: () => Socket, set: (value) => { Socket = wrap(value); },
    });
  });
  await page.route('**/api/**', async (route) => {
    const url = new URL(route.request().url());
    if (route.request().method() !== 'GET') state.writes.push(url.pathname);
    let data = {};
    if (url.pathname.endsWith('/auth/me')) data = { username: 'admin' };
    else if (url.pathname.endsWith('/theme')) data = { theme: 'light', colors: {}, configured: true };
    else if (url.pathname.endsWith('/theme/custom')) data = null;
    else if (url.pathname.endsWith('/history/storage')) data = {
      traffic: { enabled: false }, fingerprints: { enabled: false },
      limits: { traffic_max_users: 0, fingerprints_max_records: 2000, fingerprints_retention_days: 30 },
    };
    else if (url.pathname.endsWith('/mtproxyl/status')) data = { enabled: false };
    else if (url.pathname.endsWith('/branding')) {
      if (state.brandingWait) await state.brandingWait;
      if (state.failBranding) {
        await route.fulfill({ status: 503, contentType: 'application/json',
          body: JSON.stringify({ ok: false, error: { message: 'Настройки временно недоступны' } }) });
        return;
      }
      data = branding;
    }
    else if (url.pathname.endsWith('/v1/users')) data = users;
    else if (url.pathname.endsWith('/v1/stats/users/quota')) data = {
      users: [{ username: 'short', data_quota_bytes: 1e12, used_bytes: 7e9, last_reset_epoch_secs: now }],
    };
    else if (url.pathname.endsWith('/mtproxyl/users')) {
      if (state.statsWait) await state.statsWait;
      data = users.map((user) => ({ label: user.username, total_bytes: 7e9, ip_history: [] }));
    }
    else if (url.pathname.endsWith('/mtproxyl/web')) data = {
      enabled: true, domain: 'web.example.com', secret_mode: 'dd', mtproto_enabled: true,
    };
    else if (url.pathname.endsWith('/availability/status')) data = { supported: false };
    else if (url.pathname.endsWith('/history')) {
      data = { range: '30m', requested_from_epoch_secs: now - 1800, retention_secs: 7200,
        series: (url.searchParams.get('metric') || '').split(',').map((metric) => ({
          metric, range: '30m', state: 'ready', requested_from_epoch_secs: now - 1800,
          retention_secs: 7200, points: points(metric),
        })) };
    }
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, data }) });
  });
  await page.routeWebSocket(/\/api\/ws$/, (ws) => {
    const socket = { ws, stalled: false, requests: [] };
    state.sockets.push(socket);
    ws.onMessage((message) => {
      const request = JSON.parse(String(message));
      socket.requests.push(request);
      if (socket.stalled) return;
      for (const endpoint of request.endpoints || []) {
        if (state.hold.has(endpoint)) continue;
        let data = wsData[endpoint] ?? null;
        if (endpoint === '/v1/stats/upstreams') data = { ...data, upstreams: data.upstreams.map(u => ({ ...u, address: state.upstreamAddress })) };
        ws.send(JSON.stringify({ type: 'data', endpoint, data, timestamp: now }));
      }
    });
  });
  return state;
}

async function navigate(page, label) {
  const target = () => page.getByRole('link', { name: label, exact: true })
    .or(page.getByRole('menuitem', { name: label, exact: true })).filter({ visible: true });
  let link = target();
  if (!await link.count()) {
    await page.getByRole('button', { name: 'Ещё разделы', exact: true }).filter({ visible: true }).click();
    link = target();
  }
  await link.click();
}

async function checkNavigation(page, state, width) {
  await page.clock.install();
  await page.goto(`${base}/runtime`);
  await page.getByText('Последняя ошибка', { exact: true }).waitFor();
  state.sockets.at(-1).ws.send(JSON.stringify({ type: 'error', endpoint: '/v1/runtime/me_quality', error: 'runtime-only-error', timestamp: now }));
  await page.getByText('runtime-only-error', { exact: true }).waitFor();
  state.sockets.at(-1).ws.send('invalid-json');
  const boot = await page.evaluate(() => performance.timeOrigin);
  const upstreamEndpoints = ['/v1/stats/upstreams', '/v1/stats/dcs', '/v1/stats/me-writers', '/v1/stats/minimal/all'];
  upstreamEndpoints.forEach((endpoint) => state.hold.add(endpoint));
  await navigate(page, 'Апстримы и DC');
  await page.getByRole('heading', { name: 'Апстримы и DC', exact: true }).waitFor();
  assert.equal(await page.getByText('runtime-only-error', { exact: true }).count(), 0, 'another page error leaked into upstreams');
  assert(await page.locator('.animate-pulse').count() > 0, 'another page cache hides the loading state');
  state.hold.clear();
  await page.getByRole('button', { name: 'Обновить', exact: true }).click();
  await page.getByText('203.0.113.17:1080', { exact: true }).waitFor();
  await page.getByText('DC 7', { exact: true }).waitFor();
  const before = state.sockets.length;
  for (let i = 0; i < 3; i++) {
    await navigate(page, 'Телеметрия');
    await page.getByText('Последняя ошибка', { exact: true }).waitFor();
    await navigate(page, 'Апстримы и DC');
    await page.getByText('203.0.113.17:1080', { exact: true }).waitFor();
  }
  assert.equal(state.sockets.length, before, 'normal navigation opens extra sockets');
  const old = state.sockets.at(-1);
  old.stalled = true;
  state.upstreamAddress = '203.0.113.18:1080';
  await page.evaluate(() => { window.__lateClose = window.__testSockets.at(-1).onclose; });
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: true });
    document.dispatchEvent(new Event('visibilitychange'));
    Object.defineProperty(document, 'hidden', { configurable: true, value: false });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.getByText(state.upstreamAddress, { exact: true }).waitFor({ timeout: 5000 });
  assert(state.sockets.length > before, 'foreground does not restore a stuck socket');
  const restored = state.sockets.length;
  await page.evaluate(() => window.__lateClose(new CloseEvent('close')));
  await page.clock.fastForward(5000);
  assert.equal(state.sockets.length, restored, 'late close of old socket disrupts the new connection');
  state.sockets.at(-1).stalled = true;
  state.upstreamAddress = '203.0.113.19:1080';
  await page.clock.fastForward(20000);
  for (const endpoint of upstreamEndpoints.filter(ep => ep !== '/v1/stats/dcs')) {
    state.sockets.at(-1).ws.send(JSON.stringify({ type: 'data', endpoint, data: wsData[endpoint], timestamp: now }));
  }
  await page.getByText('203.0.113.17:1080', { exact: true }).waitFor();
  await page.clock.fastForward(20000);
  await page.getByText(state.upstreamAddress, { exact: true }).waitFor({ timeout: 5000 });
  state.sockets.at(-1).stalled = true;
  state.upstreamAddress = '203.0.113.20:1080';
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.getByText(state.upstreamAddress, { exact: true }).waitFor({ timeout: 5000 });
  state.sockets.at(-1).stalled = true;
  state.upstreamAddress = '203.0.113.21:1080';
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true })));
  await page.getByText(state.upstreamAddress, { exact: true }).waitFor({ timeout: 5000 });
  state.upstreamAddress = '203.0.113.22:1080';
  state.sockets.at(-1).ws.close({ code: 1001, reason: 'test reconnect' });
  await page.waitForFunction(() => window.__testSockets.at(-1).readyState === WebSocket.CLOSED);
  await page.clock.fastForward(3500);
  await page.getByText(state.upstreamAddress, { exact: true }).waitFor({ timeout: 5000 });
  state.sockets.at(-1).stalled = true;
  state.upstreamAddress = '203.0.113.23:1080';
  await page.getByRole('button', { name: 'Обновить', exact: true }).click();
  await page.getByText(state.upstreamAddress, { exact: true }).waitFor({ timeout: 5000 });
  await page.screenshot({ path: path.join(output, `upstreams-navigation-${width}.png`), fullPage: true });
  await navigate(page, 'Пользователи');
  await page.waitForFunction(() => document.querySelector('input[placeholder="Поиск пользователей…"]'));
  await page.waitForFunction(() => JSON.parse(window.__testSockets.at(-1).__lastSent || '{}').endpoints?.length === 0);
  assert.equal(await page.evaluate(() => performance.timeOrigin), boot, 'navigation reloaded the page');
  assert.deepEqual(state.writes, [], 'navigation changed server settings');
  console.log(`panel navigation ${width}: ok`);
}

async function checkSettings(page, state, width) {
  let release;
  state.brandingWait = new Promise((resolve) => { release = resolve; });
  await page.goto(`${base}/panel-settings`);
  await page.getByText('Загрузка настроек панели…', { exact: true }).waitFor();
  assert.equal(await page.locator('#panel-name').count(), 0, 'default form shown before loading');
  release();
  state.brandingWait = null;
  await page.waitForFunction(() => document.querySelector('#panel-name')?.value === 'Тестовая панель');
  assert.equal(await page.locator('#login-title').inputValue(), branding.login_title);
  assert.equal(await page.locator('#login-subtitle').inputValue(), branding.login_subtitle);
  await page.locator('#panel-name').fill('Черновик');
  assert.equal(await page.locator('#panel-name').inputValue(), 'Черновик');
  await page.screenshot({ path: path.join(output, `settings-${width}.png`), fullPage: true });
  state.failBranding = true;
  await page.reload();
  await page.getByRole('button', { name: 'Повторить загрузку', exact: true }).waitFor();
  assert.equal(await page.locator('#panel-name').count(), 0, 'editable defaults shown after error');
  state.failBranding = false;
  await page.getByRole('button', { name: 'Повторить загрузку', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('#panel-name')?.value === 'Тестовая панель');
  assert.deepEqual(state.writes, [], 'settings changed during loading test');
  console.log(`panel settings ${width}: ok`);
}

async function checkUsers(page, state, width) {
  let release;
  state.statsWait = new Promise((resolve) => { release = resolve; });
  await page.goto(`${base}/users`);
  const table = page.locator('table').first();
  if (width < 1024) {
    await page.getByText('short', { exact: true }).filter({ visible: true }).waitFor();
    release();
    state.statsWait = null;
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `mobile users overflow at ${width}`);
  } else {
    const row = table.locator('tbody tr').filter({ has: page.getByRole('link', { name: 'short', exact: true }) });
    await row.waitFor();
    const widths = () => table.locator('thead th').evaluateAll((cells) => cells.map((cell) => cell.getBoundingClientRect().width));
    const initial = await widths();
    release();
    state.statsWait = null;
    await page.waitForFunction(() => [...document.querySelectorAll('tbody tr')].some((row) =>
      row.querySelector('a')?.textContent === 'short' && row.children[5].textContent !== '-'), null, { timeout: 2000 });
    assert.deepEqual(await widths(), initial, 'columns changed after statistics loaded');
    await page.getByPlaceholder('Поиск пользователей…').fill('short');
    assert.equal(await table.locator('tbody tr').count(), 1);
    assert.deepEqual(await widths(), initial, 'columns changed after filtering');
    await page.getByPlaceholder('Поиск пользователей…').fill('');
    await table.getByText('Активные IP', { exact: true }).click();
    assert.deepEqual(await widths(), initial, 'columns changed after sorting');
    await table.getByText('Соединения', { exact: true }).click();
    assert.deepEqual(await widths(), initial, 'columns changed after sorting connections');
    const overflowing = await table.locator('th, td').evaluateAll((cells) =>
      cells.filter((cell) => cell.scrollWidth > cell.clientWidth + 1).map((cell) => cell.textContent));
    assert.deepEqual(overflowing, [], 'table cell content overflows');
    const links = row.locator('button[title="TLS"], button[title="t.me"], button[title="WEB"]');
    const tops = await links.evaluateAll((buttons) => buttons.map((button) => button.getBoundingClientRect().top));
    assert.equal(tops.length, 3);
    assert(Math.max(...tops) - Math.min(...tops) < 1, 'links wrap unexpectedly');
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `users page overflow at ${width}`);
  }
  await page.screenshot({ path: path.join(output, `users-${width}.png`), fullPage: true });
  console.log(`panel users ${width}: ok`);
}

async function checkLayout(page, width) {
  await page.goto(`${base}/runtime`);
  const label = page.getByText('Последняя ошибка', { exact: true });
  await label.waitFor();
  const row = label.locator('..').locator('..');
  const layout = await row.evaluate((element) => {
    const [label, value] = element.children;
    const a = label.getBoundingClientRect(), b = value.getBoundingClientRect();
    const card = element.parentElement.getBoundingClientRect();
    return { labelWidth: a.width, labelHeight: a.height, valueTop: b.top, labelBottom: a.bottom,
      right: b.right, cardRight: card.right, scroll: element.scrollWidth, client: element.clientWidth };
  });
  assert(layout.labelWidth > 100 && layout.labelHeight < 45, `label collapsed at ${width}: ${JSON.stringify(layout)}`);
  assert(layout.valueTop >= layout.labelBottom, `error overlaps label at ${width}`);
  assert(layout.right <= layout.cardRight + 1 && layout.scroll <= layout.client + 1, `error overflows at ${width}`);
  const card = page.getByRole('heading', { name: 'Инициализация ME', exact: true }).locator('..').locator('..');
  const rows = await card.evaluate((element) => [...element.children].slice(1).map((row) => {
    const label = row.firstElementChild.getBoundingClientRect();
    return { labelWidth: label.width, scroll: row.scrollWidth, client: row.clientWidth };
  }));
  for (const row of rows) assert(row.labelWidth > 55 && row.scroll <= row.client + 1, `ME row overflows at ${width}`);
  await page.screenshot({ path: path.join(output, `runtime-${width}.png`), fullPage: true });

  await page.goto(`${base}/`);
  const chart = page.getByRole('button', { name: /^Нагрузка за 30 минут\./ });
  await chart.waitFor();
  await chart.scrollIntoViewIfNeeded();
  const bounds = await chart.boundingBox();
  if (width < 600) await page.touchscreen.tap(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
  else await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
  const markers = chart.locator(':scope > span[aria-hidden="true"]');
  await page.waitForFunction(() => [...document.querySelectorAll('[role="button"]')]
    .some((element) => element.getAttribute('aria-label')?.includes(': соединения')));
  const dimensions = await markers.evaluateAll((elements) => elements.map((element) => {
    const rect = element.getBoundingClientRect();
    return { width: rect.width, height: rect.height };
  }));
  assert.equal(dimensions.length, 4, `selection markers missing at ${width}`);
  for (const marker of dimensions) assert(Math.abs(marker.width - marker.height) < 0.1, `ellipse at ${width}`);
  assert(dimensions.filter((marker) => marker.width === 10).length === 2, `selection size changed at ${width}`);
  await chart.press('ArrowLeft');
  await chart.press('Escape');
  assert.equal(await markers.count(), 2, `selection did not clear at ${width}`);
  await chart.click({ position: { x: bounds.width / 2, y: bounds.height / 2 } });
  await page.screenshot({ path: path.join(output, `load-${width}.png`), fullPage: true });
  console.log(`panel visual ${width}: ok`);
}

(async () => {
  let server;
  if (process.argv[2] === '--dist') {
    const dist = path.resolve(__dirname, '../mtproxyl-panel/dist');
    assert(fs.existsSync(path.join(dist, 'index.html')), 'build frontend before running the visual test');
    const types = { '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.woff2': 'font/woff2' };
    server = http.createServer((request, response) => {
      const requested = path.resolve(dist, `.${new URL(request.url, 'http://localhost').pathname}`);
      if (!requested.startsWith(`${dist}${path.sep}`) && requested !== dist) {
        response.writeHead(403).end();
        return;
      }
      const file = fs.existsSync(requested) && fs.statSync(requested).isFile() ? requested : path.join(dist, 'index.html');
      response.setHeader('Content-Type', types[path.extname(file)] || 'text/html');
      fs.createReadStream(file).pipe(response);
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    base = `http://127.0.0.1:${server.address().port}`;
  }
  let browser;
  try {
    browser = await playwright.chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', args: ['--no-sandbox'] });
    for (const width of [360, 390, 768, 1440]) {
      const context = await browser.newContext({ ignoreHTTPSErrors: true, hasTouch: width < 600, viewport: { width, height: 1100 } });
      try {
        const page = await context.newPage();
        const errors = [];
        page.on('pageerror', (error) => errors.push(error.message));
        const state = await mock(page);
        if (process.argv.includes('--navigation')) await checkNavigation(page, state, width);
        else {
          await checkLayout(page, width);
          await checkSettings(page, state, width);
          await checkUsers(page, state, width);
        }
        assert.deepEqual(errors, [], `browser errors at ${width}`);
      } finally { await context.close(); }
    }
    console.log(`Screenshots: ${output}`);
  } finally {
    if (browser) await browser.close();
    if (server) await new Promise((resolve) => server.close(resolve));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
