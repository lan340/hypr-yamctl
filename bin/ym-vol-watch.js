#!/usr/bin/env node
// Внутренняя громкость Яндекс.Музыки для Waybar через CDP.
// Ищет фрейм, где живёт плеер (externalAPI -> audio -> slider).
// HTTP: /ymvol /ymvol/status /ymvol/up /ymvol/down /ymvol/mute /ymvol/set /debug-vol

const http = require("http");
const fs = require("fs");
const { URL } = require("url");

let WebSocket;
try { WebSocket = require("ws"); }
catch {
  try { WebSocket = require("/usr/lib/node_modules/ws"); }
  catch {
    console.error("ws не найден. Установи: sudo npm i -g ws");
    process.exit(1);
  }
}

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
let volCtxId = null;
let volCtxPromise = null;

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

// Concurrency-safe сессия
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
      volCtxId = null;

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
        volCtxId = null;
        cleanupWaiters(new Error("WebSocket closed"));
      });
      socket.on("error", (e) => {
        sessionId = null;
        volCtxId = null;
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
      await send("Page.enable", {}, sessionId).catch(() => {});
      return true;
    } catch (e) {
      try { if (ws) ws.close(); } catch {}
      ws = null;
      sessionId = null;
      volCtxId = null;
      cleanupWaiters(e);
      return false;
    } finally {
      connectingPromise = null;
    }
  })();

  return connectingPromise;
}

async function evalInContext(expression, contextId) {
  const { result } = await send(
    "Runtime.evaluate",
    { expression, returnByValue: true, awaitPromise: true, contextId },
    sessionId
  );
  return result && result.value;
}

function VOL_CMD(cmd, argNum) {
  const arg = Number.isFinite(Number(argNum)) ? Number(argNum) : 0;
  return `(() => {
    const clamp01 = (x)=>Math.max(0, Math.min(1, x));
    const clamp100 = (x)=>Math.max(0, Math.min(100, x));
    const storeKey = "__ym_lastvol";

    const api = window.externalAPI || window.ymExternalAPI || window.YaMusicExternalAPI || null;

    const pickAudio = () => {
      const audios = Array.from(document.querySelectorAll("audio"));
      if (!audios.length) return null;
      return audios.find(a => !a.paused) || audios.find(a => a.readyState >= 2) || audios[0];
    };

    const isVisible = (el) => {
      if (!el) return false;
      const st = getComputedStyle(el);
      if (st.display === "none" || st.visibility === "hidden" || +st.opacity === 0) return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };

    const findSlider = () => {
      const sels = [
        'input[type="range"][aria-label*="громк" i]',
        'input[type="range"][aria-label*="volume" i]',
        '[role="slider"][aria-label*="громк" i]',
        '[data-test-id*="VOLUME" i] input[type="range"]',
        '[class*="volume" i] input[type="range"]',
        'footer input[type="range"]',
        'input[type="range"]'
      ];
      for (const s of sels) {
        const list = Array.from(document.querySelectorAll(s));
        const vis = list.find(isVisible) || list[0];
        if (vis) return { el: vis, sel: s };
      }
      return null;
    };

    const readSliderPct = (el) => {
      if (!el) return null;
      if (el.getAttribute) {
        const now = el.getAttribute("aria-valuenow");
        if (now && !isNaN(+now)) return clamp100(+now);
      }
      if (typeof el.value !== "undefined" && !isNaN(+el.value)) {
        const v = +el.value;
        const min = el.min !== undefined && el.min !== "" ? +el.min : 0;
        const max = el.max !== undefined && el.max !== "" ? +el.max : 100;
        if (isFinite(min) && isFinite(max) && max > min) {
          return clamp100(((v - min) / (max - min)) * 100);
        }
        return clamp100(v);
      }
      return null;
    };

    const setSliderPct = (el, pct) => {
      if (!el) return false;
      const p = clamp100(pct);
      try {
        const min = el.min !== undefined && el.min !== "" ? +el.min : 0;
        const max = el.max !== undefined && el.max !== "" ? +el.max : 100;
        const nv = (isFinite(min) && isFinite(max) && max > min)
          ? (min + (p/100) * (max - min))
          : p;

        if (typeof el.value !== "undefined") el.value = String(nv);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      } catch(e) { return false; }
    };

    const getVol = () => {
      if (api && typeof api.getVolume === "function" && typeof api.setVolume === "function") {
        let v = api.getVolume();
        v = (typeof v === "number" && isFinite(v)) ? v : 1;
        v = clamp01(v);
        return { ok:true, impl:"externalAPI", vol:v, pct: Math.round(v*100), muted: v <= 0.001 };
      }

      const a = pickAudio();
      if (a) {
        const v = clamp01(typeof a.volume === "number" ? a.volume : 1);
        const muted = !!a.muted || v <= 0.001;
        return { ok:true, impl:"audio", vol:v, pct: Math.round(v*100), muted };
      }

      const s = findSlider();
      if (s && s.el) {
        const pct = readSliderPct(s.el);
        if (pct !== null) {
          const v = clamp01(pct/100);
          return { ok:true, impl:"slider", vol:v, pct: Math.round(pct), muted: pct <= 0.1, selector: s.sel };
        }
      }

      return { ok:false, err:"no externalAPI/audio/slider found" };
    };

    const setVolPct = (pct) => {
      const p = clamp100(pct);

      if (api && typeof api.getVolume === "function" && typeof api.setVolume === "function") {
        api.setVolume(clamp01(p/100));
        return getVol();
      }

      const a = pickAudio();
      if (a) {
        if (p > 0.1) a.muted = false;
        a.volume = clamp01(p/100);
        return getVol();
      }

      const s = findSlider();
      if (s && s.el) {
        const ok = setSliderPct(s.el, p);
        return ok ? getVol() : { ok:false, err:"slider set failed", selector:s.sel };
      }

      return { ok:false, err:"no target to set volume" };
    };

    const cmd = ${JSON.stringify(cmd)};
    const arg = ${arg};

    if (cmd === "get") return getVol();
    if (cmd === "set") return setVolPct(arg);
    if (cmd === "up")  { const cur = getVol(); if (!cur.ok) return cur; return setVolPct(cur.pct + arg); }
    if (cmd === "down"){ const cur = getVol(); if (!cur.ok) return cur; return setVolPct(cur.pct - arg); }

    if (cmd === "mute") {
      const cur = getVol();
      if (!cur.ok) return cur;
      const isMuted = !!cur.muted || cur.pct <= 0;

      if (!isMuted) {
        try { localStorage.setItem(storeKey, String(cur.vol)); } catch {}
        return setVolPct(0);
      } else {
        let last = 0.5;
        try { last = parseFloat(localStorage.getItem(storeKey) || "0.5"); } catch {}
        if (!isFinite(last) || last <= 0.001) last = 0.5;
        return setVolPct(last * 100);
      }
    }

    if (cmd === "probe") return getVol();

    if (cmd === "debug") {
      const a = Array.from(document.querySelectorAll("audio"));
      const s = findSlider();
      const picked = pickAudio();
      return {
        ok:true,
        url: (location && location.href) || null,
        hasExternalAPI: !!window.externalAPI,
        apiKeys: (api ? Object.keys(api) : null),
        audioCount: a.length,
        audioPicked: (picked ? { paused: picked.paused, readyState: picked.readyState, volume: picked.volume, muted: picked.muted } : null),
        sliderFound: (s ? { selector: s.sel, ariaNow: s.el.getAttribute && s.el.getAttribute("aria-valuenow"), value: (typeof s.el.value !== "undefined" ? s.el.value : null) } : null),
        probe: getVol()
      };
    }

    return { ok:false, err:"unknown cmd" };
  })()`;
}

function collectFrames(node, acc) {
  if (!node) return;
  if (node.frame && node.frame.id) acc.push(node.frame.id);
  const kids = node.childFrames || [];
  for (const k of kids) collectFrames(k, acc);
}

// Concurrency-safe поиск контекста громкости
async function ensureVolumeContext() {
  const ok = await ensureSession();
  if (!ok) return null;

  if (volCtxId) {
    try {
      const probe = await evalInContext(VOL_CMD("probe", 0), volCtxId);
      if (probe && probe.ok) return volCtxId;
    } catch {}
    volCtxId = null;
  }

  if (volCtxPromise) return volCtxPromise;

  volCtxPromise = (async () => {
    try {
      let tree;
      try { tree = await send("Page.getFrameTree", {}, sessionId); }
      catch { return null; }

      const frameIds = [];
      collectFrames(tree && tree.frameTree, frameIds);

      for (const frameId of frameIds) {
        try {
          const cw = await send("Page.createIsolatedWorld",
            { frameId, worldName: "ym_waybar_vol", grantUniveralAccess: true },
            sessionId
          );
          const ctx = cw && cw.executionContextId;
          if (!ctx) continue;

          const probe = await evalInContext(VOL_CMD("probe", 0), ctx).catch(() => null);
          if (probe && probe.ok) {
            volCtxId = ctx;
            return volCtxId;
          }
        } catch {}
      }
      return null;
    } finally {
      volCtxPromise = null;
    }
  })();

  return volCtxPromise;
}

async function evalVol(cmdExpr) {
  const ctx = await ensureVolumeContext();
  if (!ctx) return null;

  let v = await evalInContext(cmdExpr, ctx).catch(() => null);
  if (v && v.ok) return v;

  volCtxId = null;
  const ctx2 = await ensureVolumeContext();
  if (!ctx2) return v;
  return await evalInContext(cmdExpr, ctx2).catch(() => null);
}

function json(res, code, obj) {
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(obj));
}

function stepFromReq(req, def = 5) {
  try {
    const u = new URL(req.url, "http://127.0.0.1");
    const s = parseInt(u.searchParams.get("step") || "", 10);
    return Number.isFinite(s) ? s : def;
  } catch { return def; }
}

function volText(pct) {
  const n = Math.max(0, Math.min(100, Math.round(pct)));
  if (n === 0) return { text: "󰖁   0%", class: "ymvol muted" };
  if (n < 50)  return { text: `󰕿   ${n}%`, class: "ymvol low" };
  return { text: `󰕾   ${n}%`, class: "ymvol" };
}

// Микрокэш на 400мс для склейки одновременных запросов с двух мониторов (Request Coalescing)
let cachedVol = null;
let cachedVolTime = 0;
const CACHE_TTL_MS = 400;

function invalidateVolCache() {
  cachedVol = null;
  cachedVolTime = 0;
}

const server = http.createServer(async (req, res) => {
  try {
    const u = new URL(req.url, "http://127.0.0.1");
    const path = u.pathname;

    if (path === "/ymvol/status") {
      const v = await evalVol(VOL_CMD("get", 0));
      return json(res, v && v.ok ? 200 : 503, v || { ok:false });
    }

    if (path === "/ymvol") {
      const now = Date.now();
      if (cachedVol && (now - cachedVolTime < CACHE_TTL_MS)) {
        return json(res, 200, cachedVol);
      }
      const v = await evalVol(VOL_CMD("get", 0));
      const pct = (v && v.ok) ? v.pct : null;
      const respObj = pct === null ? { text: "󰕾   --%", class: "ymvol" } : volText(pct);
      cachedVol = respObj;
      cachedVolTime = Date.now();
      return json(res, 200, respObj);
    }

    if (path === "/ymvol/up" && req.method === "POST") {
      invalidateVolCache();
      const step = stepFromReq(req, 5);
      const v = await evalVol(VOL_CMD("up", step));
      return json(res, v && v.ok ? 200 : 503, v || { ok:false });
    }

    if (path === "/ymvol/down" && req.method === "POST") {
      invalidateVolCache();
      const step = stepFromReq(req, 5);
      const v = await evalVol(VOL_CMD("down", step));
      return json(res, v && v.ok ? 200 : 503, v || { ok:false });
    }

    if (path === "/ymvol/mute" && req.method === "POST") {
      invalidateVolCache();
      const v = await evalVol(VOL_CMD("mute", 0));
      return json(res, v && v.ok ? 200 : 503, v || { ok:false });
    }

    if (path === "/ymvol/set" && req.method === "POST") {
      invalidateVolCache();
      const pct = parseInt(u.searchParams.get("pct") || "50", 10);
      const v = await evalVol(VOL_CMD("set", pct));
      return json(res, v && v.ok ? 200 : 503, v || { ok:false });
    }

    if (path === "/debug-vol") {
      const ctx = await ensureVolumeContext();
      const dbg = ctx ? await evalInContext(VOL_CMD("debug", 0), ctx).catch(() => null) : null;
      return json(res, dbg ? 200 : 503, { ctx, dbg });
    }

    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("nope");
  } catch (e) {
    res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
    res.end(String(e));
  }
});

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
      volCtxId = null;
      cleanupWaiters(new Error("Target lost"));
      await ensureSession();
    }
  } catch {
    try { if (ws) ws.close(); } catch {}
    ws = null;
    sessionId = null;
    volCtxId = null;
    cleanupWaiters(new Error("Ping failed"));
  }
}, 10000);

server.listen(17312, "127.0.0.1", () => {
  console.log("ym-vol-watch http://127.0.0.1:17312");
});
