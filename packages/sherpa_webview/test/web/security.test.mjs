// Chromium security suite for the MCP Apps shell (assets/mcp_app_shell.html).
//
// Run: packages/sherpa_webview/test/web/run.sh   (see README "Security suite")
//
// Setup per test:
// - The shell is served at its real virtual origin https://mcp-view.sherpa.invalid/
//   (Playwright routing; no DNS), with the CSP substituted exactly like the
//   native layers do (same character check, same fallback).
// - A fake native bridge is injected the way Android does it: only into
//   frames whose origin is the shell origin; every message records whether it
//   came from the main frame, and the harness rejects anything else (the
//   native isMainFrame + origin check). iOS mode emulates the main-frame relay.
// - EVERY other request goes through a logging route: a URL in `rig.network`
//   left the renderer; a URL absent from it was blocked before the network
//   (CSP / sandbox). WebSockets are REAL (Playwright's routeWebSocket swaps
//   window.WebSocket for an in-page mock, which would bypass CSP): every
//   connection the browser attempts is logged from CDP
//   `Network.webSocketCreated` (emitted only after the renderer's CSP check),
//   and then fails DNS (`.example`), which is fine — the attempt is the signal.
// - Probes run inside the View frame (its own scripts, or DevTools evaluate in
//   the View's main world, which does not bypass the page's CSP).
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const here = path.dirname(fileURLToPath(import.meta.url));
const pkg = path.resolve(here, '../..');
const SHELL_ORIGIN = 'https://mcp-view.sherpa.invalid';
const SHELL_URL = `${SHELL_ORIGIN}/`;
const TEMPLATE = fs.readFileSync(path.join(pkg, 'assets/mcp_app_shell.html'), 'utf8');
const FIXTURES = JSON.parse(fs.readFileSync(path.join(here, 'fixtures/policies.json'), 'utf8'));
const POLICY = Object.fromEntries(FIXTURES.cases.map((c) => [c.name, c.policy]));
const EXT_APPS = process.env.EXT_APPS_BUNDLE ??
  '/opt/vendor-src/npm/modelcontextprotocol-ext-apps-2.0.3/package/dist/src/app-with-deps.js';
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'base64');

// Mirrors ShellPolicy.renderShell in Kotlin and Swift.
const CSP_CHARS = /^[a-z0-9 :;'*./-]+$/;
const isValidCsp = (csp) => csp.length <= 16384 && CSP_CHARS.test(csp) &&
  csp.startsWith("default-src 'none'; ") && csp.includes("; frame-src 'none';") && csp.includes('; connect-src ');
const renderShell = (csp) => TEMPLATE.replace('__SHERPA_CSP__', isValidCsp(csp) ? csp : POLICY.none);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Runs in every frame of the context before page scripts.
function fakeNativeInit(mode) {
  const ORIGIN = 'https://mcp-view.sherpa.invalid';
  // Android injects only into frames matching the origin rule; an opaque
  // ("null") View frame never matches.
  if (location.origin !== ORIGIN) return;
  const inbox = [];
  Object.defineProperty(window, '__nativeInbox', { value: inbox });
  if (mode === 'android') {
    const listeners = [];
    const host = {
      postMessage(s) {
        inbox.push({ data: String(s), isMainFrame: window.top === window, origin: location.origin });
      },
      addEventListener(type, fn) { if (type === 'message') listeners.push(fn); },
      onmessage: null,
    };
    window.__sherpaHost = host;
    Object.defineProperty(window, '__nativeDeliver', {
      value: (s) => { for (const fn of listeners) fn({ data: s }); if (host.onmessage) host.onmessage({ data: s }); },
    });
  } else {
    // iOS: a WKContentWorld script in the MAIN frame relays {__sherpaOut}
    // self-posts; native calls window.__sherpaShell.receive(string).
    if (window.top !== window) return;
    window.addEventListener('message', (e) => {
      if (e.source === window && e.origin === ORIGIN && e.data && typeof e.data.__sherpaOut === 'string') {
        inbox.push({ data: e.data.__sherpaOut, isMainFrame: true, origin: location.origin });
      }
    });
    Object.defineProperty(window, '__nativeDeliver', { value: (s) => window.__sherpaShell.receive(s) });
  }
}

// Injected at the top of View documents under test.
const PROBES = `<script>
window.__v = [];
document.addEventListener('securitypolicyviolation', (e) => __v.push({ directive: e.effectiveDirective, blocked: e.blockedURI }));
const wait = (p, ms = 2500) => Promise.race([p, new Promise((r) => setTimeout(() => r('timeout'), ms))]);
window.__probe = {
  fetch: (u) => wait(fetch(u).then((r) => 'ok:' + r.status, () => 'blocked')),
  xhr: (u) => wait(new Promise((res) => { try { const x = new XMLHttpRequest(); x.open('GET', u); x.onload = () => res('ok:' + x.status); x.onerror = () => res('blocked'); x.send(); } catch (e) { res('blocked'); } })),
  ws: (u) => wait(new Promise((res) => { try { const s = new WebSocket(u); s.onopen = () => { res('open'); s.close(); }; s.onerror = () => res('error'); } catch (e) { res('threw:' + e.name); } })),
  es: (u) => wait(new Promise((res) => { try { const s = new EventSource(u); s.onopen = () => { res('ok'); s.close(); }; s.onerror = () => { res('blocked'); s.close(); }; } catch (e) { res('blocked'); } })),
  img: (u) => wait(new Promise((res) => { const i = new Image(); i.onload = () => res('ok'); i.onerror = () => res('blocked'); i.src = u; })),
  script: (u) => wait(new Promise((res) => { const s = document.createElement('script'); s.onload = () => res('ok'); s.onerror = () => res('blocked'); s.src = u; document.head.appendChild(s); })),
  style: (u) => wait(new Promise((res) => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.onload = () => res('ok'); l.onerror = () => res('blocked'); l.href = u; document.head.appendChild(l); })),
  font: (u) => wait(new FontFace('probe', 'url(' + u + ')').load().then(() => 'ok', () => 'blocked')),
  media: (u) => wait(new Promise((res) => { const v = document.createElement('video'); v.onloadeddata = () => res('ok'); v.onerror = () => res('blocked'); v.src = u; v.load(); })),
  importModule: (u) => wait(import(u).then(() => 'ok', () => 'blocked')),
  worker: (u) => { try { new Worker(u); return 'created'; } catch (e) { return 'blocked:' + e.name; } },
  blobWorker: () => { try { new Worker(URL.createObjectURL(new Blob(['postMessage(1)'], { type: 'text/javascript' }))); return 'created'; } catch (e) { return 'blocked:' + e.name; } },
  beacon: (u) => { try { return navigator.sendBeacon(u, 'x') ? 'queued' : 'refused'; } catch (e) { return 'blocked'; } },
  frame: (u) => wait(new Promise((res) => { const f = document.createElement('iframe'); f.onload = () => res('loaded'); f.src = u; document.body.appendChild(f); }), 1500),
  cssBackground: (u) => { const d = document.createElement('div'); d.style.backgroundImage = 'url(' + u + ')'; d.style.width = d.style.height = '10px'; document.body.appendChild(d); return new Promise((r) => setTimeout(() => r('set'), 800)); },
  prefetch: (u) => { const l = document.createElement('link'); l.rel = 'prefetch'; l.href = u; document.head.appendChild(l); return new Promise((r) => setTimeout(() => r('set'), 800)); },
};
</script>`;

class Rig {
  constructor(browser) {
    this.browser = browser;
    this.network = [];
    this.sockets = [];
    this.messages = [];
    this.rejected = 0;
    this.dialogs = [];
    this.pages = [];
    this.shellServed = 0;
  }

  static async open(browser, { policy = 'none', mode = 'android', html = '<p>hello</p>', limits, rawShell } = {}) {
    const rig = new Rig(browser);
    rig.context = await browser.newContext();
    await rig.context.addInitScript({ content: `(${fakeNativeInit})(${JSON.stringify(mode)});` });
    await rig.context.route('**/*', (route) => rig.onRoute(route));
    rig.context.on('page', (p) => rig.pages.push(p));
    rig.shellHtml = rawShell ?? renderShell(POLICY[policy] ?? policy);
    rig.page = await rig.context.newPage();
    const cdp = await rig.context.newCDPSession(rig.page);
    await cdp.send('Network.enable');
    cdp.on('Network.webSocketCreated', (e) => rig.sockets.push(e.url));
    rig.page.on('dialog', (d) => { rig.dialogs.push(d.type()); d.dismiss().catch(() => {}); });
    await rig.page.goto(SHELL_URL);
    rig.ready = await rig.next((m) => m.kind === 'ready');
    if (html != null) await rig.load(html, limits);
    return rig;
  }

  onRoute(route) {
    const req = route.request();
    const url = req.url();
    if (url === SHELL_URL && this.shellServed === 0) {
      this.shellServed++;
      return route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: this.shellHtml });
    }
    this.network.push({ url, method: req.method(), type: req.resourceType(), origin: req.headers().origin ?? null, referer: req.headers().referer ?? null });
    const u = new URL(url);
    const headers = { 'access-control-allow-origin': '*', 'cache-control': 'no-store' };
    if (u.pathname.endsWith('.js')) {
      return route.fulfill({ status: 200, contentType: 'text/javascript', headers, body: `window.__loaded = (window.__loaded || []).concat(${JSON.stringify(url)});` });
    }
    if (u.pathname.endsWith('.css')) return route.fulfill({ status: 200, contentType: 'text/css', headers, body: 'body { --probe: 1 }' });
    if (u.pathname.endsWith('.png')) return route.fulfill({ status: 200, contentType: 'image/png', headers, body: PNG });
    if (u.pathname.endsWith('.sse')) return route.fulfill({ status: 200, contentType: 'text/event-stream', headers, body: 'data: hi\n\n' });
    return route.fulfill({ status: 200, contentType: 'application/json', headers, body: JSON.stringify({ ok: true }) });
  }

  hits(host) { return this.network.filter((n) => new URL(n.url).hostname === host); }

  async drain() {
    const raw = await this.page.evaluate(() => (window.__nativeInbox ? window.__nativeInbox.splice(0) : []));
    for (const e of raw) {
      // The native check (Android isMainFrame + sourceOrigin, iOS frameInfo).
      if (!e.isMainFrame || e.origin !== SHELL_ORIGIN) { this.rejected++; continue; }
      this.messages.push(JSON.parse(e.data));
    }
    return this.messages;
  }

  async next(pred, timeout = 5000) {
    const t0 = Date.now();
    for (;;) {
      await this.drain();
      const i = this.messages.findIndex(pred);
      if (i >= 0) return this.messages.splice(i, 1)[0];
      if (Date.now() - t0 > timeout) throw new Error('timed out waiting for a native message');
      await sleep(20);
    }
  }

  async settle(ms = 300) { await sleep(ms); await this.drain(); }

  /** View JSON-RPC messages that reached native. */
  viewMessages(pred = () => true) { return this.messages.filter((m) => m.kind === 'view' && pred(m.message)).map((m) => m.message); }

  async send(obj) { await this.page.evaluate((s) => window.__nativeDeliver(s), JSON.stringify(obj)); }

  async load(html, limits) {
    await this.send({ kind: 'load', html, limits: limits ?? { maxChars: 1048576, burst: 64, perSecond: 32 }, theme: 'light', title: 'Content from Test' });
    await this.next((m) => m.kind === 'frame-loaded');
    this.view = this.page.frames().find((f) => f.parentFrame() === this.page.mainFrame());
    assert.ok(this.view, 'the View frame exists');
  }

  async post(message) { await this.send({ kind: 'post', message }); }

  async close() { await this.context.close(); }
}

let browser;
before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser?.close(); });

const view = (body) => `<!DOCTYPE html><html><head><meta charset="utf-8">${PROBES}</head><body>${body}</body></html>`;
const UNLISTED = 'https://evil.example';

describe('shell bootstrap', () => {
  test('ready reports a valid policy; the View frame is sandboxed allow-scripts with an opaque origin', async () => {
    const rig = await Rig.open(browser);
    try {
      assert.deepEqual(rig.ready, { kind: 'ready', v: 1, cspOk: true });
      const attrs = await rig.page.evaluate(() => {
        const f = document.querySelector('iframe');
        return { sandbox: f.getAttribute('sandbox'), allow: f.getAttribute('allow'), count: document.querySelectorAll('iframe').length, srcdocHead: f.srcdoc.slice(0, 80) };
      });
      assert.equal(attrs.sandbox, 'allow-scripts');
      assert.equal(attrs.count, 1);
      assert.match(attrs.allow, /camera 'none'/);
      assert.ok(attrs.srcdocHead.startsWith('<!DOCTYPE html><meta http-equiv="Content-Security-Policy" content="default-src'));
      assert.equal(await rig.view.evaluate(() => window.origin), 'null');
      assert.equal(rig.view.url(), 'about:srcdoc');
      // The injected policy is the first element of the View's head.
      assert.equal(await rig.view.evaluate(() => document.head.firstElementChild.getAttribute('http-equiv')), 'Content-Security-Policy');
    } finally { await rig.close(); }
  });

  test('without a substituted policy the shell refuses to create the View', async () => {
    const rig = await Rig.open(browser, { rawShell: TEMPLATE, html: null });
    try {
      assert.equal(rig.ready.cspOk, false);
      await rig.send({ kind: 'load', html: '<p>x</p>' });
      const err = await rig.next((m) => m.kind === 'error');
      assert.equal(err.reason, 'shell-misconfigured');
      assert.equal(await rig.page.evaluate(() => document.querySelectorAll('iframe').length), 0);
    } finally { await rig.close(); }
  });

  test('an invalid policy from native falls back to the no-network default', async () => {
    const rig = await Rig.open(browser, { policy: "default-src 'none'; connect-src *\"><script>alert(1)</script>" });
    try {
      assert.equal(await rig.page.evaluate(() => document.querySelector('meta[http-equiv="Content-Security-Policy"]').content), POLICY.none);
      assert.deepEqual(rig.dialogs, []);
    } finally { await rig.close(); }
  });

  test('a second load is refused; teardown removes the frame', async () => {
    const rig = await Rig.open(browser);
    try {
      await rig.send({ kind: 'load', html: '<p>again</p>' });
      assert.equal((await rig.next((m) => m.kind === 'error')).reason, 'already-loaded');
      await rig.send({ kind: 'teardown' });
      await rig.settle(100);
      assert.equal(await rig.page.evaluate(() => document.querySelectorAll('iframe').length), 0);
    } finally { await rig.close(); }
  });

  test('theme context sets the shell colour scheme', async () => {
    const rig = await Rig.open(browser);
    try {
      await rig.send({ kind: 'context', theme: 'dark' });
      await rig.settle(50);
      assert.deepEqual(await rig.page.evaluate(() => [document.documentElement.style.colorScheme, document.querySelector('iframe').style.colorScheme]), ['dark', 'dark']);
    } finally { await rig.close(); }
  });
});

describe('isolation: the View cannot reach the shell, its globals or storage', () => {
  test('parent DOM, shell globals, bridge objects and top location are out of reach', async () => {
    const rig = await Rig.open(browser, { html: view('<p>app</p>') });
    try {
      const r = await rig.view.evaluate(() => {
        const attempt = (f) => { try { const v = f(); return v === undefined ? 'undefined' : 'reached:' + String(v).slice(0, 40); } catch (e) { return e.name; } };
        return {
          parentDocument: attempt(() => parent.document.title),
          parentShell: attempt(() => parent.__sherpaShell.receive),
          parentHost: attempt(() => parent.__sherpaHost.postMessage),
          parentInbox: attempt(() => parent.__nativeInbox.length),
          topLocation: attempt(() => top.location.href),
          ownHost: attempt(() => window.__sherpaHost),
          ownWebkit: attempt(() => window.webkit),
          frameElement: attempt(() => window.frameElement),
        };
      });
      assert.deepEqual(r, {
        parentDocument: 'SecurityError',
        parentShell: 'SecurityError',
        parentHost: 'SecurityError',
        parentInbox: 'SecurityError',
        topLocation: 'SecurityError',
        ownHost: 'undefined',
        ownWebkit: 'undefined',
        frameElement: 'reached:null',
      });
    } finally { await rig.close(); }
  });

  test('no storage: localStorage, sessionStorage, cookies, IndexedDB, Cache API, service workers', async () => {
    const rig = await Rig.open(browser, { html: view('<p>app</p>') });
    try {
      const r = await rig.view.evaluate(async () => {
        const attempt = async (f) => { try { await f(); return 'allowed'; } catch (e) { return e.name || 'error'; } };
        return {
          localStorage: await attempt(() => localStorage.setItem('k', 'v')),
          sessionStorage: await attempt(() => sessionStorage.setItem('k', 'v')),
          cookie: await attempt(() => { document.cookie = 'k=v'; if (!document.cookie.includes('k=v')) throw new Error('not stored'); }),
          indexedDB: await attempt(() => new Promise((res, rej) => { const q = indexedDB.open('x'); q.onsuccess = res; q.onerror = () => rej(q.error); })),
          caches: await attempt(() => caches.open('x')),
          serviceWorker: await attempt(() => navigator.serviceWorker.register('/sw.js')),
        };
      });
      for (const [k, v] of Object.entries(r)) assert.notEqual(v, 'allowed', `${k} must not be usable (${v})`);
    } finally { await rig.close(); }
  });

  test('no popups, no modal dialogs', async () => {
    const rig = await Rig.open(browser, { html: view(`<a id="blank" href="${UNLISTED}/popup" target="_blank">x</a>`) });
    try {
      const r = await rig.view.evaluate(() => {
        let opened;
        try { opened = window.open('https://evil.example/open'); } catch (e) { opened = e.name; }
        try { alert('x'); confirm('y'); prompt('z'); } catch (e) { /* blocked */ }
        return { opened: opened === null ? 'null' : String(opened) };
      });
      await rig.view.click('#blank');
      await rig.settle(400);
      assert.equal(r.opened, 'null');
      assert.deepEqual(rig.dialogs, []);
      assert.equal(rig.pages.length, 1, 'no new page was opened');
      assert.equal(rig.hits('evil.example').length, 0);
    } finally { await rig.close(); }
  });
});

describe('network: CSP blocks every unlisted origin', () => {
  const kinds = ['fetch', 'xhr', 'es', 'img', 'script', 'style', 'font', 'media', 'importModule', 'frame', 'cssBackground', 'prefetch', 'beacon', 'worker'];

  test('no consent: fetch, XHR, WebSocket, EventSource, images, scripts, styles, fonts, media, frames, workers, beacons all blocked', async () => {
    const rig = await Rig.open(browser, { html: view(`<img id="markup" src="${UNLISTED}/markup.png"><p>app</p>`) });
    try {
      const results = {};
      for (const k of kinds) {
        const url = `${UNLISTED}/${k}.${{ img: 'png', script: 'js', importModule: 'js', worker: 'js', style: 'css', es: 'sse' }[k] ?? 'json'}`;
        results[k] = await rig.view.evaluate(([kind, u]) => window.__probe[kind](u), [k, url]);
      }
      results.ws = await rig.view.evaluate((u) => window.__probe.ws(u), 'wss://evil.example/socket');
      results.blobWorker = await rig.view.evaluate(() => window.__probe.blobWorker());
      results.allowedDataImage = await rig.view.evaluate(() => window.__probe.img('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='));
      await rig.settle(300);
      for (const k of ['fetch', 'xhr', 'es', 'img', 'script', 'style', 'font', 'media', 'importModule']) {
        assert.equal(results[k], 'blocked', `${k}: ${results[k]}`);
      }
      assert.notEqual(results.ws, 'open');
      assert.match(results.worker, /^blocked/, 'a cross-origin worker script is refused');
      assert.equal(results.allowedDataImage, 'ok', 'data: images stay allowed');
      assert.deepEqual(rig.network, [], `requests escaped: ${JSON.stringify(rig.network)}`);
      assert.deepEqual(rig.sockets, [], 'the browser never attempted the WebSocket');
      const violations = await rig.view.evaluate(() => window.__v);
      assert.ok(violations.some((v) => v.directive === 'connect-src' && v.blocked.startsWith('wss://evil.example')), 'WebSocket blocked by connect-src');
      const directives = new Set(violations.map((v) => v.directive));
      for (const d of ['connect-src', 'img-src', 'script-src-elem', 'style-src-elem', 'font-src', 'media-src', 'frame-src', 'worker-src']) {
        assert.ok(directives.has(d), `a ${d} violation was reported (${[...directives]})`);
      }
    } finally { await rig.close(); }
  });

  test('the srcdoc document inherits the shell policy as well as getting its own copy', async () => {
    const rig = await Rig.open(browser, { html: view('<p>app</p>') });
    try {
      await rig.view.evaluate(() => window.__probe.fetch('https://evil.example/inherit.json'));
      await rig.settle(200);
      const hits = (await rig.view.evaluate(() => window.__v)).filter((v) => v.blocked.includes('inherit.json'));
      assert.equal(hits.length, 2, 'two enforced policies (inherited + injected) each reported the violation');
    } finally { await rig.close(); }
  });

  test('markup-driven loads (base, links, script, media, object, embed) are blocked too', async () => {
    const html = `<!DOCTYPE html><html><head>
      <base href="${UNLISTED}/base/">
      <link rel="stylesheet" href="${UNLISTED}/markup.css">
      <link rel="preconnect" href="${UNLISTED}">
      <script src="${UNLISTED}/markup.js"></script>
      </head><body><img src="relative.png"><video src="${UNLISTED}/v.mp4"></video>
      <object data="${UNLISTED}/o.swf"></object><embed src="${UNLISTED}/e.swf"></body></html>`;
    const rig = await Rig.open(browser, { html });
    try {
      await rig.settle(1200);
      assert.deepEqual(rig.network, []);
      assert.equal(rig.view.url(), 'about:srcdoc', 'the View frame did not navigate');
      assert.equal(rig.page.url(), SHELL_URL);
    } finally { await rig.close(); }
  });

  test('a View navigating ITSELF (meta refresh, location) is stopped by the shell frame-src before the network', async () => {
    for (const how of [
      `<meta http-equiv="refresh" content="0;url=${UNLISTED}/refresh">`,
      `<script>location.href = '${UNLISTED}/self';</script>`,
      `<script>location.replace('https://api.allowed.example/self');</script>`,
    ]) {
      const rig = await Rig.open(browser, { policy: 'connect', html: `<!DOCTYPE html><html><head>${how}</head><body></body></html>` });
      try {
        await rig.settle(800);
        assert.deepEqual(rig.network, [], `${how}: nothing fetched (${JSON.stringify(rig.network)})`);
        // The frame ends up on the browser's opaque error page (the View
        // only destroyed itself) and the top-level shell is untouched.
        const frames = rig.page.frames();
        assert.equal(frames.length, 2);
        assert.ok(['about:srcdoc', 'chrome-error://chromewebdata/'].includes(frames[1].url()), frames[1].url());
        assert.equal(rig.page.url(), SHELL_URL);
      } finally { await rig.close(); }
    }
  });

  test('consented connectDomains are allowed; everything else stays blocked', async () => {
    const rig = await Rig.open(browser, { policy: 'connect', html: view('<p>app</p>') });
    try {
      const r = await rig.view.evaluate(async () => ({
        fetch: await __probe.fetch('https://api.allowed.example/data.json'),
        xhr: await __probe.xhr('https://api.allowed.example/data.json'),
        ws: await __probe.ws('wss://ws.allowed.example/socket'),
        violations: __v,
        fetchOther: await __probe.fetch('https://evil.example/x.json'),
        fetchHttp: await __probe.fetch('http://api.allowed.example/data.json'),
        imgFromConnect: await __probe.img('https://api.allowed.example/i.png'),
        scriptFromConnect: await __probe.script('https://api.allowed.example/s.js'),
        wsOther: await __probe.ws('wss://evil.example/socket'),
      }));
      assert.equal(r.fetch, 'ok:200');
      assert.equal(r.xhr, 'ok:200');
      for (const k of ['fetchOther', 'fetchHttp', 'imgFromConnect', 'scriptFromConnect']) assert.equal(r[k], 'blocked', k);
      assert.deepEqual([...new Set(rig.network.map((n) => n.url))], ['https://api.allowed.example/data.json']);
      // The consented socket was attempted by the browser (then fails DNS);
      // the unlisted one never was.
      assert.deepEqual(rig.sockets, ['wss://ws.allowed.example/socket']);
      const ws = (await rig.view.evaluate(() => window.__v)).filter((v) => v.blocked.startsWith('wss://'));
      assert.deepEqual([...new Set(ws.map((v) => v.blocked))], ['wss://evil.example/socket']);
      // Opaque origin and no-referrer: the shell's identity never leaks.
      const sent = rig.network.find((n) => n.url === 'https://api.allowed.example/data.json');
      assert.equal(sent.origin, 'null');
      assert.equal(sent.referer, null);
    } finally { await rig.close(); }
  });

  test('consented resourceDomains (incl. wildcard) load scripts, styles and images; connect is separate', async () => {
    const rig = await Rig.open(browser, { policy: 'resources', html: view('<p>app</p>') });
    try {
      const r = await rig.view.evaluate(async () => ({
        script: await __probe.script('https://cdn.allowed.example/lib.js'),
        style: await __probe.style('https://cdn.allowed.example/s.css'),
        img: await __probe.img('https://img.wild.example/a.png'),
        imgApex: await __probe.img('https://wild.example/a.png'),
        fetchCdn: await __probe.fetch('https://cdn.allowed.example/data.json'),
        fetchApi: await __probe.fetch('https://api.allowed.example/data.json'),
        loaded: window.__loaded,
      }));
      assert.equal(r.script, 'ok');
      assert.deepEqual(r.loaded, ['https://cdn.allowed.example/lib.js']);
      assert.equal(r.style, 'ok');
      assert.equal(r.img, 'ok');
      assert.equal(r.imgApex, 'blocked', 'a wildcard does not match the apex');
      assert.equal(r.fetchCdn, 'blocked', 'resource domains are not connect domains');
      assert.equal(r.fetchApi, 'ok:200');
      assert.ok(!rig.network.some((n) => n.url.startsWith('https://wild.example/')));
    } finally { await rig.close(); }
  });

  test('declared but not granted, or granted but not declared: blocked', async () => {
    const rig = await Rig.open(browser, { policy: 'partial-consent', html: view('<p>app</p>') });
    try {
      const r = await rig.view.evaluate(async () => [
        await __probe.fetch('https://api.allowed.example/a.json'),
        await __probe.fetch('https://api.other.example/a.json'),
        await __probe.fetch('https://api.undeclared.example/a.json'),
      ]);
      assert.deepEqual(r, ['ok:200', 'blocked', 'blocked']);
    } finally { await rig.close(); }
  });

  test('nested frames get their own opaque origin and inherit the policy; WebRTC neutering is best effort', async () => {
    const rig = await Rig.open(browser, {
      html: view(`<iframe id="n" srcdoc="<script>
          fetch('https://evil.example/nested.json').then(() => 'ok', () => 'blocked').then((f) =>
            parent.postMessage({ nested: { fetch: f, origin: window.origin, rtc: typeof RTCPeerConnection } }, '*'));
        </script>"></iframe>
        <script>window.addEventListener('message', (e) => { if (e.data && e.data.nested) window.__nested = e.data.nested; });</script>`),
    });
    try {
      await rig.settle(600);
      const r = await rig.view.evaluate(() => {
        const blank = document.createElement('iframe');
        document.body.appendChild(blank);
        let scriptable;
        try { scriptable = typeof blank.contentWindow.fetch; } catch (e) { scriptable = e.name; }
        return { nested: window.__nested, viewRtc: typeof window.RTCPeerConnection, blankScriptable: scriptable };
      });
      assert.equal(r.nested.fetch, 'blocked');
      assert.equal(r.nested.origin, 'null');
      assert.equal(r.blankScriptable, 'SecurityError', 'even an about:blank child is a separate opaque origin');
      assert.deepEqual(rig.network, []);
      assert.equal(r.viewRtc, 'undefined', 'the prelude removes RTCPeerConnection from the View realm');
      // Known gap (README): a nested frame's own realm still has WebRTC,
      // which CSP does not cover.
      console.log(`# nested realm RTCPeerConnection: ${r.nested.rtc}`);
    } finally { await rig.close(); }
  });

  test('the injection fixture produced the no-network policy', () => {
    assert.equal(POLICY.injection, POLICY.none);
    assert.equal(POLICY['declared-not-consented'], POLICY.none);
  });
});

describe('messaging: only the View frame reaches native, within limits', () => {
  test('View JSON-RPC is relayed; host messages arrive with source === parent', async () => {
    const rig = await Rig.open(browser, {
      html: view(`<script>
        window.__got = [];
        window.addEventListener('message', (e) => __got.push({ fromParent: e.source === window.parent, origin: e.origin, data: e.data }));
        parent.postMessage({ jsonrpc: '2.0', id: 1, method: 'ui/initialize', params: { protocolVersion: '2026-01-26' } }, '*');
      </script>`),
    });
    try {
      const m = await rig.next((x) => x.kind === 'view' && x.message.method === 'ui/initialize');
      assert.deepEqual(m.message, { jsonrpc: '2.0', id: 1, method: 'ui/initialize', params: { protocolVersion: '2026-01-26' } });
      await rig.post({ jsonrpc: '2.0', id: 1, result: { protocolVersion: '2026-01-26' } });
      await rig.settle(100);
      const got = await rig.view.evaluate(() => window.__got);
      assert.deepEqual(got, [{ fromParent: true, origin: SHELL_ORIGIN, data: { jsonrpc: '2.0', id: 1, result: { protocolVersion: '2026-01-26' } } }]);
    } finally { await rig.close(); }
  });

  test('forged messages from other frames and malformed messages are dropped', async () => {
    const rig = await Rig.open(browser, {
      html: view(`<iframe id="nested" srcdoc="<script>
          top.postMessage({ jsonrpc: '2.0', id: 'n1', method: 'tools/call', params: { name: 'pan' } }, '*');
          parent.parent.postMessage({ jsonrpc: '2.0', id: 'n2', method: 'ui/open-link', params: { url: 'https://evil.example' } }, '*');
        </script>"></iframe>
        <script>
          parent.postMessage('{"jsonrpc":"2.0","id":"s","method":"ping"}', '*');
          parent.postMessage([1, 2], '*');
          parent.postMessage({ id: 'nojsonrpc', method: 'ping' }, '*');
          parent.postMessage({ jsonrpc: '2.0', id: 'ok', method: 'ping' }, '*');
        </script>`),
    });
    try {
      // A sibling frame in the shell (as if anything else got in).
      await rig.page.evaluate(() => {
        const f = document.createElement('iframe');
        f.srcdoc = `<script>parent.postMessage({ jsonrpc: '2.0', id: 'sib', method: 'tools/call', params: { name: 'x' } }, '*')<\/script>`;
        document.body.appendChild(f);
        window.postMessage({ jsonrpc: '2.0', id: 'self', method: 'ping' }, '*');
      });
      const stats = await rig.next((m) => m.kind === 'stats', 3000);
      const ids = rig.viewMessages().map((m) => m.id);
      assert.deepEqual(ids, ['ok']);
      assert.ok(stats.forged >= 3, `forged counted: ${JSON.stringify(stats)}`);
      assert.ok(stats.malformed >= 3, `malformed counted: ${JSON.stringify(stats)}`);
      assert.equal(rig.rejected, 0);
    } finally { await rig.close(); }
  });

  test('oversized messages are capped and requests get an error', async () => {
    const rig = await Rig.open(browser, {
      html: view(`<script>
        window.__errors = [];
        window.addEventListener('message', (e) => { if (e.data && e.data.error) __errors.push([e.data.id, e.data.error.code]); });
        parent.postMessage({ jsonrpc: '2.0', id: 'big', method: 'ui/message', params: { pad: 'x'.repeat(2 * 1024 * 1024) } }, '*');
        parent.postMessage({ jsonrpc: '2.0', id: 'fits', method: 'ui/message', params: { pad: 'x'.repeat(900 * 1024) } }, '*');
      </script>`),
    });
    try {
      await rig.next((m) => m.kind === 'view' && m.message.id === 'fits');
      await rig.settle(200);
      assert.equal(rig.viewMessages((m) => m.id === 'big').length, 0);
      assert.deepEqual(await rig.view.evaluate(() => window.__errors), [['big', -32600]]);
      assert.equal((await rig.next((m) => m.kind === 'stats', 3000)).oversized, 1);
    } finally { await rig.close(); }
  });

  test('a flood is rate-limited in the shell', async () => {
    const rig = await Rig.open(browser, {
      limits: { maxChars: 1048576, burst: 20, perSecond: 5 },
      html: view(`<script>
        window.__errors = 0;
        window.addEventListener('message', (e) => { if (e.data && e.data.error && e.data.error.code === -32000) __errors++; });
        for (let i = 0; i < 1000; i++) parent.postMessage({ jsonrpc: '2.0', id: i, method: 'ping' }, '*');
      </script>`),
    });
    try {
      const stats = await rig.next((m) => m.kind === 'stats', 3000);
      const relayed = rig.viewMessages().length;
      assert.ok(relayed >= 20 && relayed <= 25, `relayed ${relayed}`);
      assert.ok(stats.rateLimited >= 975, `rate-limited ${stats.rateLimited}`);
      const errors = await rig.view.evaluate(() => window.__errors);
      assert.ok(errors >= 1 && errors <= 10, `error replies capped: ${errors}`);
    } finally { await rig.close(); }
  });

  test('a nested iframe inside the View cannot talk to native', async () => {
    const rig = await Rig.open(browser, {
      html: view(`<iframe id="nested" srcdoc="<script>
          const r = {};
          try { r.topHost = String(top.__sherpaHost); } catch (e) { r.topHost = e.name; }
          try { r.topShell = String(top.__sherpaShell); } catch (e) { r.topShell = e.name; }
          r.ownHost = String(window.__sherpaHost);
          try { top.postMessage({ jsonrpc: '2.0', id: 'nested', method: 'ping' }, '*'); } catch (e) {}
          try { location.href = 'https://mcp-view.sherpa.invalid/'; } catch (e) {}
          parent.postMessage({ nestedReport: r }, '*');
        </script>"></iframe>
        <script>
          window.addEventListener('message', (e) => { if (e.data && e.data.nestedReport) window.__nested = e.data.nestedReport; });
        </script>`),
    });
    try {
      await rig.settle(800);
      const r = await rig.view.evaluate(() => window.__nested);
      assert.deepEqual(r, { topHost: 'SecurityError', topShell: 'SecurityError', ownHost: 'undefined' });
      assert.equal(rig.viewMessages((m) => m.id === 'nested').length, 0);
      assert.equal(rig.network.length, 0, 'the nested frame could not navigate to the shell origin');
      assert.equal(rig.rejected, 0);
    } finally { await rig.close(); }
  });
});

describe('navigation: links reach the host as requests, nothing navigates', () => {
  test('ui/open-link is relayed as a request and is not navigated', async () => {
    const rig = await Rig.open(browser, {
      html: view(`<script>parent.postMessage({ jsonrpc: '2.0', id: 'L', method: 'ui/open-link', params: { url: 'https://evil.example/landing' } }, '*');</script>`),
    });
    try {
      const m = await rig.next((x) => x.kind === 'view' && x.message.method === 'ui/open-link');
      assert.equal(m.message.params.url, 'https://evil.example/landing');
      await rig.settle(300);
      assert.equal(rig.page.url(), SHELL_URL);
      assert.equal(rig.view.url(), 'about:srcdoc');
      assert.equal(rig.network.length, 0);
      assert.equal(rig.pages.length, 1);
    } finally { await rig.close(); }
  });

  test('a plain link click becomes a link-activated notification; the frame stays', async () => {
    const rig = await Rig.open(browser, { html: view(`<a id="a" href="${UNLISTED}/article?x=1">read</a><a id="j" href="javascript:void(0)">js</a>`) });
    try {
      await rig.view.click('#a');
      await rig.view.click('#j');
      const m = await rig.next((x) => x.kind === 'view' && x.message.method === 'sherpa/notifications/link-activated');
      assert.deepEqual(m.message.params, { url: `${UNLISTED}/article?x=1` });
      await rig.settle(300);
      assert.equal(rig.viewMessages((x) => x.method === 'sherpa/notifications/link-activated').length, 0, 'javascript: is not reported');
      assert.equal(rig.view.url(), 'about:srcdoc');
      assert.equal(rig.network.length, 0);
    } finally { await rig.close(); }
  });

  test('form submission and top / self navigation attempts fail', async () => {
    const rig = await Rig.open(browser, {
      policy: 'connect',
      html: view(`
        <form id="get" action="${UNLISTED}/get"><input name="q" value="secret"></form>
        <form id="post" method="post" action="https://api.allowed.example/post"><input name="q" value="secret"></form>
        <form id="top" target="_top" action="${UNLISTED}/top"></form>
        <a id="toplink" target="_top" href="${UNLISTED}/toplink">top</a>
        <script>
          window.__submitEvents = 0;
          document.addEventListener('submit', () => __submitEvents++, true);
        </script>`),
    });
    try {
      const r = await rig.view.evaluate(() => {
        const out = {};
        for (const id of ['get', 'post', 'top']) {
          try { document.getElementById(id).submit(); out[id] = 'called'; } catch (e) { out[id] = e.name; }
          try { document.getElementById(id).requestSubmit(); } catch (e) { /* ignore */ }
        }
        try { top.location.href = 'https://evil.example/toploc'; out.topLocation = 'assigned'; } catch (e) { out.topLocation = e.name; }
        try { top.location.replace('https://evil.example/topreplace'); out.topReplace = 'called'; } catch (e) { out.topReplace = e.name; }
        return out;
      });
      await rig.view.click('#toplink');
      await rig.settle(600);
      // Self-navigation: blocked by the shell's frame-src (error page at most).
      await rig.view.evaluate(() => { location.href = 'https://evil.example/self'; }).catch(() => {});
      await rig.settle(800);
      assert.equal(r.topLocation, 'SecurityError');
      assert.equal(rig.page.url(), SHELL_URL, 'top-level page unchanged');
      assert.equal(rig.pages.length, 1);
      assert.deepEqual(rig.network, [], `nothing left the renderer: ${JSON.stringify(rig.network)}`);
      assert.equal(rig.page.frames().length, 2);
      assert.ok(['about:srcdoc', 'chrome-error://chromewebdata/'].includes(rig.page.frames()[1].url()));
    } finally { await rig.close(); }
  });
});

describe('iOS relay mode', () => {
  test('the main-frame relay carries View traffic both ways; nested frames are still dropped', async () => {
    const rig = await Rig.open(browser, {
      mode: 'ios',
      html: view(`<iframe srcdoc="<script>top.postMessage({ jsonrpc: '2.0', id: 'nested', method: 'ping' }, '*')</script>"></iframe>
        <script>
          window.addEventListener('message', (e) => { if (e.source === window.parent) window.__reply = e.data; });
          parent.postMessage({ jsonrpc: '2.0', id: 'ios', method: 'ping' }, '*');
        </script>`),
    });
    try {
      assert.equal(rig.ready.cspOk, true);
      await rig.next((m) => m.kind === 'view' && m.message.id === 'ios');
      await rig.post({ jsonrpc: '2.0', id: 'ios', result: {} });
      await rig.settle(300);
      assert.deepEqual(await rig.view.evaluate(() => window.__reply), { jsonrpc: '2.0', id: 'ios', result: {} });
      assert.equal(rig.viewMessages((m) => m.id === 'nested').length, 0);
      assert.equal(await rig.page.evaluate(() => typeof window.__sherpaHost), 'undefined');
    } finally { await rig.close(); }
  });
});

describe('SDK compatibility (@modelcontextprotocol/ext-apps App inside the View)', { skip: !fs.existsSync(EXT_APPS) && 'ext-apps bundle not found' }, () => {
  test('handshake, tool data, callServerTool, openLink and auto-resize through the shell under the strict CSP', async () => {
    const bundle = fs.readFileSync(EXT_APPS, 'utf8').replace(/export\{([^}]*)\};?\s*$/, (_, list) =>
      `globalThis.ExtApps={${list.split(',').map((e) => { const [local, exported] = e.trim().split(/\s+as\s+/); return `${exported ?? local}:${local}`; }).join(',')}};`);
    assert.ok(bundle.includes('globalThis.ExtApps='), 'bundle export list rewritten');
    const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><script type="module">${bundle}</script>
      <script type="module">
        const app = new ExtApps.App({ name: 'Probe App', version: '1.0.0' }, {}, { autoResize: true });
        window.__events = [];
        app.ontoolinput = (p) => __events.push(['input', p.arguments]);
        app.ontoolresult = async (r) => {
          __events.push(['result', r.structuredContent]);
          const t = await app.callServerTool({ name: 'refresh', arguments: { city: 'Lisbon' } });
          __events.push(['called', t.structuredContent]);
          const l = await app.openLink({ url: 'https://example.com/more' });
          __events.push(['link', l]);
        };
        await app.connect();
        __events.push(['connected', app.getHostContext().platform]);
      </script></head><body><div style="height:321px">weather</div></body></html>`;
    const rig = await Rig.open(browser, { html });
    try {
      const init = await rig.next((m) => m.kind === 'view' && m.message.method === 'ui/initialize', 8000);
      assert.equal(init.message.params.appInfo.name, 'Probe App');
      assert.equal(init.message.params.protocolVersion, '2026-01-26');
      await rig.post({
        jsonrpc: '2.0', id: init.message.id, result: {
          protocolVersion: '2026-01-26', hostInfo: { name: 'sherpa', version: '0.1.0' },
          hostCapabilities: { openLinks: {}, serverTools: {}, logging: {}, sandbox: { permissions: {}, csp: { connectDomains: [], resourceDomains: [] } } },
          hostContext: { theme: 'light', platform: 'mobile', displayMode: 'inline', availableDisplayModes: ['inline', 'fullscreen'] },
        },
      });
      await rig.next((m) => m.kind === 'view' && m.message.method === 'ui/notifications/initialized');
      const size = await rig.next((m) => m.kind === 'view' && m.message.method === 'ui/notifications/size-changed');
      assert.ok(size.message.params.height >= 321, `auto-resize height ${size.message.params.height}`);
      await rig.post({ jsonrpc: '2.0', method: 'ui/notifications/tool-input', params: { arguments: { city: 'Lisbon' } } });
      await rig.post({ jsonrpc: '2.0', method: 'ui/notifications/tool-result', params: { content: [{ type: 'text', text: '21C' }], structuredContent: { t: 21 } } });
      const call = await rig.next((m) => m.kind === 'view' && m.message.method === 'tools/call');
      assert.equal(call.message.params.name, 'refresh');
      await rig.post({ jsonrpc: '2.0', id: call.message.id, result: { content: [], structuredContent: { t: 22 } } });
      const link = await rig.next((m) => m.kind === 'view' && m.message.method === 'ui/open-link');
      assert.equal(link.message.params.url, 'https://example.com/more');
      await rig.post({ jsonrpc: '2.0', id: link.message.id, result: {} });
      await rig.settle(300);
      const events = await rig.view.evaluate(() => window.__events);
      assert.deepEqual(events, [
        ['connected', 'mobile'],
        ['input', { city: 'Lisbon' }],
        ['result', { t: 21 }],
        ['called', { t: 22 }],
        ['link', {}],
      ]);
      assert.equal(rig.network.length, 0);
    } finally { await rig.close(); }
  });
});
