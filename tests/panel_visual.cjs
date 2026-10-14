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
  '/v1/health': { status: 'ok' },
  '/v1/stats/summary': { uptime_seconds: 600, configured_users: 1, connections_total: 100,
    connections_bad_total: 0, current_connections: 2, active_users: 1, total_octets: 1000 },
};

async function mock(page) {
  await page.addInitScript(() => localStorage.setItem('mtproxyl-panel-theme', 'light'));
  await page.route('**/api/**', async (route) => {
    const url = new URL(route.request().url());
    let data = {};
    if (url.pathname.endsWith('/auth/me')) data = { username: 'admin' };
    else if (url.pathname.endsWith('/theme')) data = null;
    else if (url.pathname.endsWith('/theme/custom')) data = null;
    else if (url.pathname.endsWith('/mtproxyl/status')) data = { enabled: false };
    else if (url.pathname.endsWith('/v1/users')) data = [];
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
    ws.onMessage((message) => {
      const request = JSON.parse(String(message));
      for (const endpoint of request.endpoints || []) {
        if (wsData[endpoint]) ws.send(JSON.stringify({ type: 'data', endpoint, data: wsData[endpoint], timestamp: now }));
      }
    });
  });
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
        await mock(page);
        await checkLayout(page, width);
        assert.deepEqual(errors, [], `browser errors at ${width}`);
      } finally { await context.close(); }
    }
    console.log(`Screenshots: ${output}`);
  } finally {
    if (browser) await browser.close();
    if (server) await new Promise((resolve) => server.close(resolve));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
