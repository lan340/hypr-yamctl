#!/usr/bin/env node
// CommonJS мост ♥ для Waybar: подключается к CDP Я.Музыки,
// определяет лайк (♥/♡), переключает его без фокуса,
// отдаёт удобный для Waybar JSON и самовосстанавливается.

const http = require("http");
const fs = require("fs");

// ws с фоллбеком на глобальный путь
let WebSocket;
try { WebSocket = require("ws"); }
catch {
  try { WebSocket = require("/usr/lib/node_modules/ws"); }
  catch {
    console.error("ws не найден. Установи: sudo npm i -g ws");
    process.exit(1);
  }
}

// читаем порт DevTools сперва из профиля devtools, потом обычного
function readDevTools() {
  const tryRead = (dir) => {
    try {
      const txt = fs.readFileSync(`${process.env.HOME}/.config/${dir}/DevToolsActivePort`, "utf8")
        .trim().split("\n");
      const port = parseInt(txt[0], 10);
      const path = (txt[1] || "").trim();
      if (Number.isFinite(port) && path.startsWith("/devtools/browser/")) {
        return { port, browserWS: `ws://127.0.0.1:${port}${path}` };
      }
    } catch {}
    return null;
  };
  return tryRead("yandex-music-devtools") || tryRead("yandex-music");
}

let ws = null;
let sessionId = null;
let msgId = 0;
const waiters = new Map();
let connectingPromise = null;

// Очистка зависших промисов с реджектом при разрыве WebSocket
function cleanupWaiters(err) {
  const e = err || new Error("WebSocket closed");
  for (const [id, w] of waiters.entries()) {
    if (w.timer) clearTimeout(w.timer);
    w.reject(e);
  }
  waiters.clear();
}

function sendRaw(obj, timeoutMs = 2500) {
  return new Promise((resolve, reject) => {
    const id = ++msgId;
    obj.id = id;

    const timer = setTimeout(() => {
      waiters.delete(id);
      reject(new Error(`CDP request timed out (method: ${obj.method})`));
    }, timeoutMs);

    waiters.set(id, { resolve, reject, timer });

    try {
      if (!ws || ws.readyState !== 1) {
        clearTimeout(timer);
        waiters.delete(id);
        return reject(new Error("WebSocket not connected"));
      }
      ws.send(JSON.stringify(obj));
    } catch (e) {
      clearTimeout(timer);
      waiters.delete(id);
      reject(e);
    }
  });
}

async function send(method, params = {}, sid = null, timeoutMs = 2500) {
  const payload = { method, params };
  if (sid) payload.sessionId = sid;
  return sendRaw(payload, timeoutMs);
}

// Concurrency-safe сессия: если несколько клиентов запрашивают сессию одновременно,
// они разделяют один и тот же промис подключения, вместо того чтобы закрывать сокет друг друга
async function ensureSession() {
  if (ws && ws.readyState === 1 && sessionId) return true;
  if (connectingPromise) return connectingPromise;

  connectingPromise = (async () => {
    try {
      const info = readDevTools();
      if (!info) return false;

      if (ws) {
        try { ws.close(); } catch {}
        cleanupWaiters(new Error("Reconnecting WebSocket"));
        ws = null;
      }
      sessionId = null;

      const socket = new WebSocket(info.browserWS);
      ws = socket;

      await new Promise((ok, err) => {
        const timer = setTimeout(() => {
          try { socket.close(); } catch {}
          err(new Error("WebSocket connection timeout"));
        }, 2500);

        socket.once("open", () => {
          clearTimeout(timer);
          ok();
        });
        socket.once("error", (e) => {
          clearTimeout(timer);
          err(e);
        });
      });

      socket.on("message", (raw) => {
        let m;
        try { m = JSON.parse(raw); } catch { return; }
        if (m.id && waiters.has(m.id)) {
          const { resolve, reject, timer } = waiters.get(m.id);
          if (timer) clearTimeout(timer);
          waiters.delete(m.id);
          if (m.error) reject(m.error); else resolve(m.result);
        }
      });

      socket.on("close", () => {
        sessionId = null;
        cleanupWaiters(new Error("WebSocket closed"));
      });
      socket.on("error", (e) => {
        sessionId = null;
        cleanupWaiters(e);
      });

      await send("Target.setDiscoverTargets", { discover: true });
      const { targetInfos } = await send("Target.getTargets");

      const pick = (arr) =>
        arr.find(t => /music-application:/i.test(t.url)) ||
        arr.find(t => /music\.yandex/i.test(t.url)) ||
        arr.find(t => /yandex|яндекс|музык/i.test((t.title || ""))) ||
        arr.find(t => t.type === "page");

      const target = pick(targetInfos || []);
      if (!target) return false;

      const attach = await send("Target.attachToTarget", { targetId: target.targetId, flatten: true });
      sessionId = (attach && attach.sessionId) || null;
      if (!sessionId) return false;

      await send("Runtime.enable", {}, sessionId);
      return true;
    } catch (e) {
      try { if (ws) ws.close(); } catch {}
      ws = null;
      sessionId = null;
      cleanupWaiters(e);
      return false;
    } finally {
      connectingPromise = null;
    }
  })();

  return connectingPromise;
}

// eval с авто-reconnect (одна повторная попытка)
async function evalOnPage(expression) {
  try {
    const ok = await ensureSession();
    if (!ok) throw new Error("No CDP session");
    const { result } = await send(
      "Runtime.evaluate",
      { expression, returnByValue: true, awaitPromise: true },
      sessionId
    );
    return result && result.value;
  } catch (e) {
    try { if (ws) ws.close(); } catch {}
    ws = null; sessionId = null;
    cleanupWaiters(e);
    const ok2 = await ensureSession();
    if (!ok2) throw e;
    const { result } = await send(
      "Runtime.evaluate",
      { expression, returnByValue: true, awaitPromise: true },
      sessionId
    );
    return result && result.value;
  }
}

// ——— выбор лайка ТОЛЬКО из контейнера плеера (низ страницы/есть play и слайдер) ———
const LIKE_QUERY = `(() => {
  const isVisible = (el) => {
    if (!el) return false;
    const st = getComputedStyle(el);
    if (st.display === 'none' || st.visibility === 'hidden' || +st.opacity === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const looksLikePlayer = (root) => {
    if (!root) return false;
    if (!isVisible(root)) return false;
    const hasPlay = root.querySelector('[aria-label*="пауза" i], [aria-label*="воспроизв" i], [data-test-id*="PLAY" i]');
    const hasTimeline = root.querySelector('input[type="range"], [role="slider"]');
    return Boolean(hasPlay && hasTimeline);
  };
  const likeBtns = Array.from(document.querySelectorAll('button[data-test-id="LIKE_BUTTON"]')).filter(isVisible);
  const pairs = likeBtns.map(btn => {
    let c = btn.closest('[data-test-id*="PLAYER" i], [class*="player" i], [class*="Player" i], footer, [role="contentinfo"]');
    if (c && !looksLikePlayer(c)) {
      let p = c.parentElement;
      while (p && p !== document.body && !looksLikePlayer(p)) p = p.parentElement;
      if (looksLikePlayer(p)) c = p;
    }
    return { btn, container: c };
  }).filter(x => looksLikePlayer(x.container));
  if (!pairs.length) return { ok: true, liked: false };
  pairs.sort((a, b) => (b.container.getBoundingClientRect().top - a.container.getBoundingClientRect().top));
  const btn = pairs[0].btn;
  const pressed = (btn.getAttribute('aria-pressed') || btn.getAttribute('aria-checked') || '').toLowerCase();
  const cls = ((btn.className || '') + ' ' + (btn.getAttribute('class') || '')).trim();
  const likedByAttr = pressed === 'true';
  const likedByClass = /(?:\\blik(?:e|ed).*on|like_on|button_like_on|is-active|active)\\b/i.test(cls);
  const use = btn.querySelector('use'); const href = use && (use.getAttribute('href') || use.getAttribute('xlink:href') || '');
  const likedByIcon = href ? /like_(?:on|filled|active)|liked|heart_(?:full|on)/i.test(href) : false;
  return { ok: true, liked: Boolean(likedByAttr || likedByClass || likedByIcon) };
})()`;

const LIKE_TOGGLE = `(() => {
  const isVisible = (el) => {
    if (!el) return false;
    const st = getComputedStyle(el);
    if (st.display === 'none' || st.visibility === 'hidden' || +st.opacity === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const looksLikePlayer = (root) => {
    if (!root) return false;
    if (!isVisible(root)) return false;
    const hasPlay = root.querySelector('[aria-label*="пауза" i], [aria-label*="воспроизв" i], [data-test-id*="PLAY" i]');
    const hasTimeline = root.querySelector('input[type="range"], [role="slider"]');
    return Boolean(hasPlay && hasTimeline);
  };
  const likeBtns = Array.from(document.querySelectorAll('button[data-test-id="LIKE_BUTTON"]')).filter(isVisible);
  const pairs = likeBtns.map(btn => {
    let c = btn.closest('[data-test-id*="PLAYER" i], [class*="player" i], [class*="Player" i], footer, [role="contentinfo"]');
    if (c && !looksLikePlayer(c)) {
      let p = c.parentElement;
      while (p && p !== document.body && !looksLikePlayer(p)) p = p.parentElement;
      if (looksLikePlayer(p)) c = p;
    }
    return { btn, container: c };
  }).filter(x => looksLikePlayer(x.container));
  if (!pairs.length) return { ok:false };
  pairs.sort((a, b) => (b.container.getBoundingClientRect().top - a.container.getBoundingClientRect().top));
  pairs[0].btn.click();
  return { ok:true };
})()`;

// Диагностика кандидатов сердечка
const LIKE_DEBUG = `(() => {
  const sels = [
    'button[aria-label*="нравится" i]',
    'button[aria-label*="like" i]',
    '[data-testid*="like" i] button',
    '[data-testid*="player"][data-testid*="like" i]',
    'button[class*="like" i]',
    '[class*="like"][role="button"]',
    '[class*="player"] button[class*="like" i]',
    '[class*="like" i]',
    '[aria-label*="лайк" i]',
    '[aria-label*="нравится" i]'
  ];
  const uniq = new Set();
  const found = [];
  for (const s of sels) {
    document.querySelectorAll(s).forEach(el => {
      if (!el || uniq.has(el)) return;
      uniq.add(el);
      const get = (k) => (el.getAttribute(k) || '');
      const pressed = get('aria-pressed') || get('aria-checked');
      const cls = ((el.className || '') + ' ' + (el.getAttribute('class') || '')).trim();
      const role = get('role');
      const dl = (el.dataset && (el.dataset.liked || el.dataset.state || el.dataset.testid)) || '';
      let html = '';
      try { html = el.outerHTML.slice(0, 600); } catch {}
      found.push({ selectorHit: s, tag: (el.tagName||'').toLowerCase(), role, pressed, dataset: dl, class: cls.slice(0, 240), html });
    });
  }
  return { count: found.length, items: found.slice(0, 10) };
})()`;

// Микрокэш на 400мс для склейки одновременных запросов с двух мониторов (Request Coalescing)
let cachedWaybar = null;
let cachedWaybarTime = 0;
const CACHE_TTL_MS = 400;

// HTTP API
const server = http.createServer(async (req, res) => {
  try {
    if (req.url === "/status") {
      const val = await evalOnPage(LIKE_QUERY).catch(() => null);
      res.writeHead(val ? 200 : 503, { "Content-Type": "application/json; charset=utf-8" });
      return res.end(JSON.stringify(val || { ok: false }));
    }

    if (req.url === "/waybar") {
      const now = Date.now();
      if (cachedWaybar && (now - cachedWaybarTime < CACHE_TTL_MS)) {
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        return res.end(cachedWaybar);
      }

      const val = await evalOnPage(LIKE_QUERY).catch(() => null);
      const liked = !!(val && val.ok && val.liked);
      const body = JSON.stringify({
        text: " ",               // текст скрыт в CSS
        class: liked ? "liked" : "unliked"
      });
      cachedWaybar = body;
      cachedWaybarTime = Date.now();

      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      return res.end(body);
    }

    if (req.url === "/debug-like") {
      const val = await evalOnPage(LIKE_DEBUG).catch(() => null);
      res.writeHead(val ? 200 : 503, { "Content-Type": "application/json; charset=utf-8" });
      return res.end(JSON.stringify(val || { ok: false }));
    }

    if (req.url === "/toggle" && req.method === "POST") {
      cachedWaybar = null; // Инвалидируем кэш при переключении
      const ok = await ensureSession();
      if (!ok) {
        res.writeHead(503, { "Content-Type": "application/json" });
        return res.end('{"ok":false}');
      }
      await evalOnPage(LIKE_TOGGLE);
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end('{"ok":true}');
    }

    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("nope");
  } catch (e) {
    res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
    res.end(String(e));
  }
});

// Периодический «пинг» и автопереподключение
setInterval(async () => {
  try {
    if (!ws || ws.readyState !== 1 || !sessionId) { await ensureSession(); return; }
    const { targetInfos } = await send("Target.getTargets");
    const ok = (targetInfos || []).some(t =>
      /music-application:/i.test(t.url) ||
      /music\.yandex/i.test(t.url) ||
      /yandex|яндекс|музык/i.test((t.title || "")) ||
      t.type === "page"
    );
    if (!ok) {
      try { ws.close(); } catch {}
      ws = null;
      sessionId = null;
      cleanupWaiters(new Error("Target lost"));
      await ensureSession();
    }
  } catch {
    try { if (ws) ws.close(); } catch {}
    ws = null;
    sessionId = null;
    cleanupWaiters(new Error("Ping failed"));
  }
}, 10000);

process.on("uncaughtException", e => console.error("uncaughtException:", e));
process.on("unhandledRejection", e => console.error("unhandledRejection:", e));

server.listen(17311, "127.0.0.1", () => {
  console.log("ym-like-watch http://127.0.0.1:17311");
});
