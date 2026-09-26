// Teloson · the floor, rendered live.
// 74 seats in seven departments and one desk at the end of the aisle, driven by scroll. Nothing is
// pre-rendered: the walk down the floor, the lights, what is on every screen, the plan that gets
// tabled and the approval that waits are all computed per frame.
import * as THREE from "three";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import { BokehPass } from "three/addons/postprocessing/BokehPass.js";
import { ShaderPass } from "three/addons/postprocessing/ShaderPass.js";
import { SMAAPass } from "three/addons/postprocessing/SMAAPass.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";

const stage = document.querySelector(".floor .stage");
const section = document.getElementById("floor");
const poster = document.querySelector(".floor .poster");
const canvas = document.getElementById("gl");
const isSmall = window.innerWidth < 900;
const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// ---------- the roster (from src/agents/roster.js) ----------
const DEPTS = ["Research & Validation", "Risk & Compliance", "Trading & Execution", "Portfolio Management", "Data & Intelligence", "Digital Assets", "Cross-Asset & Macro"];
const SEATS = [10, 10, 6, 18, 16, 8, 6];   // the real head-count per department, 74 in all
const ROSTER = [
  [["Signal Validation", 1], ["Out-of-Sample Testing", 1], ["Multiple-Testing Control", 1], ["Sample Adequacy", 1], ["Parameter Stability", 0], ["Benchmark Comparison", 1], ["Look-Ahead Audit", 0], ["Cost Sensitivity", 0], ["Regime Coverage", 0], ["Replication", 0]],
  [["Capital Adequacy", 1], ["Position Sizing", 1], ["Drawdown Control", 1], ["Value at Risk", 1], ["Daily Limits", 1], ["Account Permissions", 1], ["Kill Switch", 1], ["Concentration", 0], ["Liquidity", 0], ["Wash Sale", 0]],
  [["Order Routing", 0], ["Preflight", 0], ["Idempotency", 0], ["Slippage", 0], ["Execution Timing", 0], ["Fill Quality", 0]],
  [["Allocation", 0], ["Rebalancing", 0], ["Correlation", 0], ["Market Beta", 0], ["Risk-Adjusted Return", 0], ["Cash Management", 1], ["Holding Horizon", 0], ["Tax Efficiency", 0], ["Technology Sector", 0], ["Financials Sector", 0], ["Energy Sector", 0], ["Healthcare Sector", 0], ["Consumer Sector", 0], ["Industrials Sector", 0], ["Utilities Sector", 0], ["Materials Sector", 0], ["Real Estate Sector", 0], ["Communications Sector", 0]],
  [["News Sentiment", 0], ["Headline Scanner", 0], ["Price-News Divergence", 0], ["Wire Breadth", 0], ["Wire Freshness", 0], ["Live Tape", 0], ["Bid-Ask Spread", 0], ["Intraday Move", 0], ["Market Breadth", 0], ["Quote Staleness", 0], ["Data Provenance", 1], ["Price Adjustment", 0], ["Data Freshness", 0], ["Universe Coverage", 0], ["Series Continuity", 0], ["Provider Limits", 0]],
  [["Crypto Desk Lead", 0], ["Bitcoin Strategist", 0], ["Ethereum & Smart-Contract Lead", 0], ["Altcoin & High-Beta Lead", 0], ["Crypto Volatility", 0], ["Crypto Microstructure", 0], ["24/7 Coverage", 0], ["Crypto Risk", 0]],
  [["Trading Calendar", 0], ["Cross-Asset Allocation", 0], ["Cross-Asset Regime", 0], ["Cross-Asset Correlation", 0], ["Rates & Fixed Income", 0], ["Options Strategist", 0]]
];
const IDS = ["val", "risk", "exec", "pm", "data", "crypto", "macro"];

// ---------- timeline (progress 0..1) ----------
const T = { deptOn: d => 0.067 + d * 0.067, convene: [0.60, 0.79], dim: [0.80, 0.93], chair: [0.80, 0.92], camMid: 0.58, camEnd: 0.95 };
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const lerp = (a, b, t) => a + (b - a) * t;
// a small deterministic random so the floor looks the same on every visit
let seed = 7; const rnd = () => { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; };

// ---------- renderer ----------
const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: "high-performance" });
const DPR = Math.min(window.devicePixelRatio || 1, window.innerWidth > 3000 ? 1 : 1.5);
renderer.setPixelRatio(DPR);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;
renderer.shadowMap.enabled = !isSmall;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x02040a);
scene.fog = new THREE.FogExp2(0x02040a, 0.018);
const camera = new THREE.PerspectiveCamera(isSmall ? 62 : 42, 1, 0.1, 300);
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
if ("environmentIntensity" in scene) scene.environmentIntensity = 0.28;

// ---------- textures drawn in code ----------
function canvasTex(w, h, draw, repeat) {
  const c = document.createElement("canvas"); c.width = w; c.height = h; draw(c.getContext("2d"), w, h);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 8;
  if (repeat) { t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(repeat[0], repeat[1]); }
  return t;
}
function radial(size, inner, outer) { return canvasTex(size, size, (g) => { const r = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2); r.addColorStop(0, inner); r.addColorStop(1, outer); g.fillStyle = r; g.fillRect(0, 0, size, size); }); }
const glowTex = radial(128, "rgba(255,255,255,0.9)", "rgba(255,255,255,0)");
const dotTex = radial(64, "rgba(255,255,255,1)", "rgba(255,255,255,0)");
// carpet tiles, 4×4 per texture, 0.6 m each
const TILE = 0.6, carpetTex = canvasTex(1024, 1024, (g, w, h) => {
  g.fillStyle = "#1b2130"; g.fillRect(0, 0, w, h);
  const img = g.getImageData(0, 0, w, h), d = img.data;
  for (let i = 0; i < d.length; i += 4) { const n = (Math.random() - 0.5) * 22; d[i] += n; d[i + 1] += n; d[i + 2] += n * 1.15; }
  g.putImageData(img, 0, 0);
  for (let ty = 0; ty < 4; ty++) for (let tx = 0; tx < 4; tx++) { const j = (Math.random() - 0.5) * 0.10; g.fillStyle = `rgba(${j > 0 ? 255 : 0},${j > 0 ? 255 : 0},${j > 0 ? 255 : 0},${Math.abs(j)})`; g.fillRect(tx * 256, ty * 256, 256, 256); }
  g.strokeStyle = "rgba(0,0,0,0.42)"; g.lineWidth = 2;
  for (let k = 0; k <= 4; k++) { g.beginPath(); g.moveTo(k * 256, 0); g.lineTo(k * 256, h); g.stroke(); g.beginPath(); g.moveTo(0, k * 256); g.lineTo(w, k * 256); g.stroke(); }
}, [48 / (TILE * 4), 48 / (TILE * 4)]);
// the city at night, a backdrop drawn once
function skyline(w, h, density) {
  return canvasTex(w, h, (g) => {
    const sky = g.createLinearGradient(0, 0, 0, h); sky.addColorStop(0, "#01020a"); sky.addColorStop(0.55, "#050914"); sky.addColorStop(1, "#111a2e");
    g.fillStyle = sky; g.fillRect(0, 0, w, h);
    let x = 0;
    while (x < w) {
      const bw = 24 + rnd() * 110, bh = 60 + Math.pow(rnd(), 1.4) * (h * 0.78), top = h - bh;
      g.fillStyle = `rgb(${5 + rnd() * 6},${7 + rnd() * 6},${12 + rnd() * 8})`; g.fillRect(x, top, bw, bh);
      const cw = 5, ch = 8, lit = 0.18 + rnd() * density, warm = rnd() < 0.6;
      for (let wy = top + 6; wy < h - 4; wy += ch + 3) for (let wx = x + 4; wx < x + bw - 6; wx += cw + 3) {
        if (rnd() > lit) continue; const a = 0.35 + rnd() * 0.65;
        g.fillStyle = (warm ? rnd() < 0.8 : rnd() < 0.3) ? `rgba(255,214,160,${a})` : `rgba(200,220,255,${a})`; g.fillRect(wx, wy, cw, ch);
      }
      if (bh > h * 0.5 && rnd() < 0.5) { g.fillStyle = "rgba(255,70,60,0.9)"; g.fillRect(x + bw / 2 - 1, top - 6, 2, 2); g.fillStyle = "rgba(120,130,150,0.8)"; g.fillRect(x + bw / 2 - 0.5, top - 14, 1, 14); }
      x += bw + 2 + rnd() * 8;
    }
    const haze = g.createLinearGradient(0, h * 0.55, 0, h); haze.addColorStop(0, "rgba(40,60,100,0)"); haze.addColorStop(1, "rgba(60,80,120,0.22)"); g.fillStyle = haze; g.fillRect(0, 0, w, h);
  });
}

// ---------- materials ----------
const SCREEN_COLOR = new THREE.Color(0.92, 0.95, 1.0);
const CHAIR_COLOR = new THREE.Color(0.55, 0.70, 1.0);
const mDesk = new THREE.MeshStandardMaterial({ color: 0x1d2129, roughness: 0.46, metalness: 0.08 });
const mDeskEdge = new THREE.MeshStandardMaterial({ color: 0x14171d, roughness: 0.55, metalness: 0.05 });
const mPanel = new THREE.MeshStandardMaterial({ color: 0x1a1e26, roughness: 0.8, metalness: 0.0 });
const mBezel = new THREE.MeshStandardMaterial({ color: 0x07090d, roughness: 0.32, metalness: 0.3 });
const mChassis = new THREE.MeshStandardMaterial({ color: 0x1b1f27, roughness: 0.6, metalness: 0.2 });
const mSteel = new THREE.MeshStandardMaterial({ color: 0x2b303a, roughness: 0.3, metalness: 0.9 });
const mAlu = new THREE.MeshStandardMaterial({ color: 0x8b9099, roughness: 0.48, metalness: 0.9 });
const mPaper = new THREE.MeshStandardMaterial({ color: 0xaaa69b, roughness: 0.92, metalness: 0.0 });
const mMug = new THREE.MeshStandardMaterial({ color: 0x6d7280, roughness: 0.4, metalness: 0.0 });
const mTurretScreen = new THREE.MeshBasicMaterial({ color: new THREE.Color(0.30, 0.40, 0.62) });
const mMesh = new THREE.MeshStandardMaterial({ color: 0x0f1218, roughness: 0.95, metalness: 0.0, side: THREE.DoubleSide });
const mCushion = new THREE.MeshStandardMaterial({ color: 0x14171e, roughness: 0.9, metalness: 0.0 });
const mPlastic = new THREE.MeshStandardMaterial({ color: 0x0c0e13, roughness: 0.5, metalness: 0.1 });
const mFrost = new THREE.MeshStandardMaterial({ color: 0x7f8ca3, roughness: 0.55, metalness: 0.0, transparent: true, opacity: 0.13, depthWrite: false, side: THREE.DoubleSide });
const mGlass = new THREE.MeshStandardMaterial({ color: 0x000000, roughness: 0.05, metalness: 1.0, transparent: true, opacity: 0.26, envMapIntensity: 1.8, depthWrite: false });
const mWindow = new THREE.MeshStandardMaterial({ color: 0x0a1020, roughness: 0.03, metalness: 0.7, transparent: true, opacity: 0.16, envMapIntensity: 1.2, depthWrite: false, side: THREE.DoubleSide });
const mWall = new THREE.MeshStandardMaterial({ color: 0x0e1117, roughness: 0.9 });
const mCeil = new THREE.MeshStandardMaterial({ color: 0x0c0f15, roughness: 0.95 });
const mColumn = new THREE.MeshStandardMaterial({ color: 0x262a33, roughness: 0.75, metalness: 0.0 });
const mCarpet = new THREE.MeshStandardMaterial({ map: carpetTex, color: 0xffffff, roughness: 0.88, metalness: 0.0 });
const mTroffer = new THREE.MeshBasicMaterial({ color: new THREE.Color(0.86, 0.92, 1.05) });

// ---------- eight kinds of screen, all of them moving ----------
const MONO = "IBM Plex Mono, Menlo, monospace";
const TICKERS = ["SPY", "QQQ", "AAPL", "MSFT", "NVDA", "AMZN", "JPM", "XOM", "BTC", "ETH", "GLD", "TLT", "IWM", "UNH", "SOL", "META"];
const SECTORS = ["Tech", "Fin", "Energy", "Health", "Cons", "Indus", "Util", "Mat", "RE", "Comm", "Semis", "Banks"];
const C = { bg: "#0a0f1c", bar: "#121a2e", ink: "#e6ecf8", ink2: "rgba(230,236,248,0.62)", ink3: "rgba(230,236,248,0.34)", line: "rgba(138,168,216,0.16)", accent: "#8aa8d8", amber: "#f2b866", up: "#62d394", down: "#ea6b5d" };
const SW = 640, SH = 360;
function mkScreen(kind) {
  const c = document.createElement("canvas"); c.width = SW; c.height = SH;
  const g = c.getContext("2d"); const tex = new THREE.CanvasTexture(c); tex.colorSpace = THREE.SRGBColorSpace; tex.anisotropy = 8;
  const st = { kind, c, g, tex, t: 0, prices: TICKERS.map(() => 40 + Math.random() * 500), chg: TICKERS.map(() => (Math.random() - 0.5) * 2.4), vol: TICKERS.map(() => Math.random()), series: Array.from({ length: 90 }, () => 0.5), candles: [], log: [], heat: SECTORS.map(() => Math.random()), bids: Array.from({ length: 12 }, () => Math.random()), asks: Array.from({ length: 12 }, () => Math.random()) };
  for (let i = 0; i < 32; i++) st.candles.push(candle(st));
  for (let i = 0; i < 14; i++) st.log.push(logLine());
  return st;
}
function candle(st) { const o = st.candles.length ? st.candles[st.candles.length - 1].c : 0.5; const cl = Math.max(0.05, Math.min(0.95, o + (Math.random() - 0.5) * 0.12)); return { o, c: cl, h: Math.max(o, cl) + Math.random() * 0.05, l: Math.min(o, cl) - Math.random() * 0.05, v: Math.random() }; }
function logLine() {
  const d = Math.floor(Math.random() * 7), a = ROSTER[d][Math.floor(Math.random() * ROSTER[d].length)][0].toLowerCase().replace(/[^a-z]+/g, ".").replace(/\.$/, "");
  const verbs = ["measure", "ok", "unknown", "hold", "veto=no", "sample=ok", "stale", "fresh", "within limit", "recheck", "heard"];
  const h = 9 + Math.floor(Math.random() * 7), m = Math.floor(Math.random() * 60), s = Math.floor(Math.random() * 60);
  return [`${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`, `${IDS[d]}.${a.split(".").slice(0, 2).join(".")}`, verbs[Math.floor(Math.random() * verbs.length)], (Math.random() * 2 - 1).toFixed(3)];
}
function header(g, title, right) {
  g.fillStyle = C.bg; g.fillRect(0, 0, SW, SH);
  g.fillStyle = C.bar; g.fillRect(0, 0, SW, 36);
  g.fillStyle = C.amber; g.fillRect(0, 0, 4, 36);
  g.fillStyle = C.ink; g.font = `500 15px ${MONO}`; g.textBaseline = "middle"; g.fillText(title, 18, 18);
  if (right) { g.fillStyle = C.accent; g.textAlign = "right"; g.fillText(right, SW - 16, 18); g.textAlign = "left"; }
  g.textBaseline = "alphabetic";
}
function drawScreen(st, now) {
  const { g, kind } = st; st.t++;
  const hhmmss = new Date().toTimeString().slice(0, 8);
  if (kind === 0) { // quote board
    header(g, "QUOTES · US EQUITIES", hhmmss);
    g.font = `12px ${MONO}`; g.fillStyle = C.ink3; g.fillText("SYM", 18, 58); g.fillText("LAST", 150, 58); g.fillText("CHG", 280, 58); g.fillText("VOL", 440, 58);
    g.fillStyle = C.line; g.fillRect(18, 66, SW - 36, 1);
    g.font = `15px ${MONO}`;
    for (let i = 0; i < 14; i++) {
      if (Math.random() < 0.22) { const d = (Math.random() - 0.5) * 0.9; st.prices[i] += d; st.chg[i] += d / 12; st.vol[i] = Math.min(1, st.vol[i] + Math.random() * 0.02); }
      const y = 90 + i * 20, up = st.chg[i] >= 0;
      g.fillStyle = C.ink; g.fillText(TICKERS[i], 18, y);
      g.fillStyle = C.amber; g.textAlign = "right"; g.fillText(st.prices[i].toFixed(2), 220, y);
      g.fillStyle = up ? C.up : C.down; g.fillText((up ? "+" : "") + st.chg[i].toFixed(2) + "%", 350, y); g.textAlign = "left";
      g.fillStyle = "rgba(138,168,216,0.5)"; g.fillRect(440, y - 11, st.vol[i] * 160, 10);
    }
  } else if (kind === 1) { // tape
    header(g, "LIVE TAPE · 1 MIN", "NAV");
    if (st.t % 2 === 0) { st.series.push(Math.max(0.05, Math.min(0.95, st.series[st.series.length - 1] + (Math.random() - 0.5) * 0.07))); st.series.shift(); }
    g.strokeStyle = C.line; g.lineWidth = 1; for (let y = 80; y < SH - 20; y += 50) { g.beginPath(); g.moveTo(18, y); g.lineTo(SW - 18, y); g.stroke(); }
    const X = i => 18 + i * (SW - 36) / 89, Y = v => 70 + (1 - v) * 250;
    g.beginPath(); st.series.forEach((v, i) => i ? g.lineTo(X(i), Y(v)) : g.moveTo(X(i), Y(v))); g.lineTo(X(89), SH); g.lineTo(X(0), SH); g.closePath();
    const fill = g.createLinearGradient(0, 70, 0, SH); fill.addColorStop(0, "rgba(138,168,216,0.28)"); fill.addColorStop(1, "rgba(138,168,216,0)"); g.fillStyle = fill; g.fill();
    g.beginPath(); st.series.forEach((v, i) => i ? g.lineTo(X(i), Y(v)) : g.moveTo(X(i), Y(v))); g.strokeStyle = "#dbe6ff"; g.lineWidth = 2; g.stroke();
    const last = st.series[st.series.length - 1]; g.fillStyle = C.accent; g.beginPath(); g.arc(X(89), Y(last), 4, 0, 7); g.fill();
    g.fillStyle = C.ink; g.font = `500 28px ${MONO}`; g.fillText((1000 + last * 400).toFixed(2), 18, 78);
    g.fillStyle = last > 0.5 ? C.up : C.down; g.font = `14px ${MONO}`; g.fillText((last > 0.5 ? "+" : "") + ((last - 0.5) * 3).toFixed(2) + "% today", 190, 78);
  } else if (kind === 2) { // order book
    header(g, "BOOK · BID / ASK", "L2 · 12");
    g.font = `12px ${MONO}`; g.fillStyle = C.ink3; g.fillText("SIZE", 18, 58); g.textAlign = "right"; g.fillText("BID", 300, 58); g.textAlign = "left"; g.fillText("ASK", 340, 58); g.textAlign = "right"; g.fillText("SIZE", SW - 18, 58); g.textAlign = "left";
    const mid = 187.4 + Math.sin(now / 4000) * 0.4;
    for (let i = 0; i < 12; i++) {
      if (Math.random() < 0.3) { st.bids[i] = Math.random(); st.asks[i] = Math.random(); }
      const y = 74 + i * 23;
      g.fillStyle = "rgba(98,211,148,0.28)"; g.fillRect(310 - st.bids[i] * 230, y, st.bids[i] * 230, 17);
      g.fillStyle = "rgba(234,107,93,0.28)"; g.fillRect(330, y, st.asks[i] * 230, 17);
      g.font = `13px ${MONO}`; g.fillStyle = C.ink2; g.fillText(String(Math.floor(st.bids[i] * 900) + 10), 18, y + 13);
      g.fillStyle = C.up; g.textAlign = "right"; g.fillText((mid - 0.01 * (i + 1)).toFixed(2), 300, y + 13); g.textAlign = "left";
      g.fillStyle = C.down; g.fillText((mid + 0.01 * (i + 1)).toFixed(2), 340, y + 13);
      g.fillStyle = C.ink2; g.textAlign = "right"; g.fillText(String(Math.floor(st.asks[i] * 900) + 10), SW - 18, y + 13); g.textAlign = "left";
    }
  } else if (kind === 3) { // the floor's own log
    header(g, "FLOOR LOG", hhmmss);
    if (Math.random() < 0.55) { st.log.push(logLine()); if (st.log.length > 14) st.log.shift(); }
    g.font = `13px ${MONO}`;
    st.log.forEach((l, i) => { const y = 62 + i * 21, last = i === st.log.length - 1; g.fillStyle = C.ink3; g.fillText(l[0], 18, y); g.fillStyle = last ? C.amber : C.accent; g.fillText(l[1], 100, y); g.fillStyle = last ? C.ink : C.ink2; g.fillText(l[2], 330, y); g.textAlign = "right"; g.fillText(l[3], SW - 18, y); g.textAlign = "left"; });
  } else if (kind === 4) { // heatmap
    header(g, "BREADTH · SECTORS", "5 MIN");
    for (let i = 0; i < 12; i++) {
      if (Math.random() < 0.08) st.heat[i] = Math.random();
      const x = 18 + (i % 4) * 152, y = 52 + Math.floor(i / 4) * 100, v = st.heat[i];
      g.fillStyle = v > 0.5 ? `rgba(98,211,148,${0.16 + (v - 0.5) * 1.3})` : `rgba(234,107,93,${0.16 + (0.5 - v) * 1.3})`;
      g.fillRect(x, y, 146, 94);
      g.fillStyle = C.ink; g.font = `500 14px ${MONO}`; g.fillText(SECTORS[i], x + 12, y + 26);
      g.font = `500 24px ${MONO}`; g.fillText(((v - 0.5) * 4).toFixed(2) + "%", x + 12, y + 66);
    }
  } else if (kind === 5) { // risk gate
    header(g, "RISK · YOUR LIMITS", "GATE");
    const rows = [["Drawdown", Math.random() * 1.2, 10], ["Position cap", 2.1, 5], ["Bad day", Math.random() * 0.8, 3], ["VaR 99", Math.random() * 4 + 6, 20], ["Orders today", Math.floor(Math.random() * 6), 20]];
    g.font = `14px ${MONO}`;
    rows.forEach((r, i) => { const y = 74 + i * 50; g.fillStyle = C.ink2; g.fillText(r[0], 18, y); g.fillStyle = C.ink; g.textAlign = "right"; g.fillText((typeof r[1] === "number" && !Number.isInteger(r[1]) ? r[1].toFixed(2) + "%" : String(r[1])), 330, y); g.textAlign = "left"; g.fillStyle = C.ink3; g.fillText("of " + r[2] + (r[0] === "Orders today" ? "" : "%"), 350, y); g.fillStyle = "rgba(138,168,216,0.14)"; g.fillRect(18, y + 12, SW - 36, 6); g.fillStyle = C.accent; g.fillRect(18, y + 12, (SW - 36) * Math.min(1, r[1] / r[2]), 6); });
    g.fillStyle = C.up; g.font = `500 14px ${MONO}`; g.fillText("● ALL INSIDE BOUNDS", 18, 340);
  } else if (kind === 6) { // candles
    header(g, "BTC · 15 MIN", "24/7");
    if (st.t % 3 === 0) { st.candles.push(candle(st)); st.candles.shift(); }
    g.strokeStyle = C.line; for (let y = 80; y < 270; y += 48) { g.beginPath(); g.moveTo(18, y); g.lineTo(SW - 18, y); g.stroke(); }
    st.candles.forEach((k, i) => {
      const x = 22 + i * 19, up = k.c >= k.o; g.strokeStyle = g.fillStyle = up ? C.up : C.down;
      g.beginPath(); g.moveTo(x + 5, 60 + (1 - k.h) * 210); g.lineTo(x + 5, 60 + (1 - k.l) * 210); g.stroke();
      const top = 60 + (1 - Math.max(k.o, k.c)) * 210, bh = Math.max(2, Math.abs(k.c - k.o) * 210); g.fillRect(x, top, 10, bh);
      g.fillStyle = up ? "rgba(98,211,148,0.35)" : "rgba(234,107,93,0.35)"; g.fillRect(x, 340 - k.v * 50, 10, k.v * 50);
    });
    const last = st.candles[st.candles.length - 1]; g.fillStyle = C.amber; g.font = `500 18px ${MONO}`; g.fillText((58000 + last.c * 9000).toFixed(0), SW - 130, 70);
  } else { // sessions & wires
    header(g, "SESSIONS · WIRES", hhmmss);
    const rows = [["NYSE", "open", true], ["NASDAQ", "open", true], ["CME", "open", true], ["LSE", "closed", false], ["CRYPTO", "24/7", true], ["WIRES", `${11 + Math.floor(Math.random() * 3)} live`, true]];
    g.font = `15px ${MONO}`;
    rows.forEach((r, i) => { const y = 74 + i * 38; g.fillStyle = r[2] ? C.up : C.ink3; g.beginPath(); g.arc(26, y - 5, 4.5, 0, 7); g.fill(); g.fillStyle = C.ink; g.fillText(r[0], 46, y); g.fillStyle = C.ink2; g.fillText(r[1], 230, y); g.fillStyle = C.line; g.fillRect(18, y + 12, SW - 36, 1); });
    g.fillStyle = C.ink3; g.font = `13px ${MONO}`; g.fillText("last headline " + Math.floor(Math.random() * 50) + "s ago · freshness ok", 18, 340);
  }
  st.tex.needsUpdate = true;
}
const SCREENS = [0, 1, 2, 3, 4, 5, 6, 7].map(mkScreen);
SCREENS.forEach(s => drawScreen(s, 0));

// ---------- the floor plan ----------
// The aisle runs down the middle (x = 0) away from the camera (toward -z). Benches of up to four
// seats sit either side of it, three screens a seat, chairs pulled out the way people leave them.
const PITCH = 1.6, ROW = 2.6, AISLE = 1.2, DESK_H = 0.74;
const parts = {};
const part = (name, x, y, z, yaw, s, tilt) => { (parts[name] ||= []).push({ p: [x, y, z], y: yaw || 0, s, tilt: tilt || 0 }); };
const screens = [];      // { pos, yaw, dept, i, kind }
const pools = [];
const seatPos = []; for (let d = 0; d < 8; d++) seatPos.push([]);
let screenCount = 0;
function monitor(x, y, z, yaw, dept, i, isClient) {
  const c = Math.cos(yaw), s = Math.sin(yaw);
  part("bezel", x, y, z, yaw, [0.56, 0.335, 0.016]);
  part("chassis", x - s * 0.02, y, z - c * 0.02, yaw, [0.42, 0.24, 0.026]);
  part("mArm", x - s * 0.06, y - 0.19, z - c * 0.06, yaw, [0.028, 0.44, 0.028]);
  part("mBracket", x - s * 0.035, y, z - c * 0.035, yaw, [0.03, 0.03, 0.06]);
  screens.push({ pos: new THREE.Vector3(x + s * 0.009, y, z + c * 0.009), yaw, dept, i, kind: isClient ? -1 : (screenCount++) % 8 });
}
function seatAt(x, rowZ, dept) {
  const i = seatPos[dept].length;
  const mz = rowZ - 0.22, my = 1.24;
  monitor(x, my, mz, 0, dept, i);
  monitor(x - 0.52, my, mz + 0.12, 26 * Math.PI / 180, dept, i);
  monitor(x + 0.52, my, mz + 0.12, -26 * Math.PI / 180, dept, i);
  seatPos[dept].push({ pos: new THREE.Vector3(x, my, mz), floor: new THREE.Vector3(x, 0, rowZ + 0.6) });
  part("keys", x, DESK_H + 0.012, rowZ + 0.14, 0, [0.44, 0.02, 0.15]);
  part("mouse", x + 0.33, DESK_H + 0.018, rowZ + 0.15, 0, [0.06, 0.03, 0.1]);
  part("turret", x - 0.48, DESK_H + 0.03, rowZ + 0.06, 0.2, [0.2, 0.05, 0.16]);
  part("turretScreen", x - 0.48 + 0.03, DESK_H + 0.056, rowZ + 0.06 - 0.01, 0.2, [0.1, 0.004, 0.05]);
  // what people leave on a desk: a page or two, sometimes a mug
  if (rnd() < 0.55) part("paper", x + (rnd() - 0.5) * 0.5, DESK_H + 0.017, rowZ + 0.06 + (rnd() - 0.5) * 0.2, (rnd() - 0.5) * 0.6, [0.21, 0.004, 0.297]);
  if (rnd() < 0.35) part("mug", x + 0.5 + (rnd() - 0.5) * 0.2, DESK_H + 0.06, rowZ + 0.02 + (rnd() - 0.5) * 0.2, 0, [0.04, 0.09, 0.04]);
  // the chair, pulled out a little and turned a little, never the same twice
  const out = 0.06 + rnd() * 0.3, yaw = (rnd() - 0.5) * 0.7, cz = rowZ + 0.72 + out, cx = x + (rnd() - 0.5) * 0.12;
  const c = Math.cos(yaw), s = Math.sin(yaw);
  const local = (lx, lz) => [cx + c * lx + s * lz, cz - s * lx + c * lz];
  let q = local(0, 0); part("cushion", q[0], 0.47, q[1], yaw, [0.48, 0.07, 0.46]);
  q = local(0, -0.05); part("back", q[0], 0.84, q[1], yaw, [1, 1, 1], 0.1);
  for (const ax of [-0.25, 0.25]) { q = local(ax, 0.02); part("armPost", q[0], 0.58, q[1], yaw, [0.03, 0.2, 0.03]); part("armPad", q[0], 0.69, q[1], yaw, [0.06, 0.02, 0.26]); }
  q = local(0, 0); part("lift", q[0], 0.3, q[1], yaw, [0.03, 0.32, 0.03]); part("hub", q[0], 0.12, q[1], yaw, [0.05, 0.06, 0.05]);
  for (let k = 0; k < 5; k++) { const a = yaw + k * Math.PI * 2 / 5; const dx = Math.sin(a), dz = Math.cos(a); part("leg", cx + dx * 0.16, 0.085, cz + dz * 0.16, a, [0.035, 0.03, 0.32], 0.3); part("caster", cx + dx * 0.32, 0.03, cz + dz * 0.32, a, [1, 1, 1]); }
  pools.push({ pos: new THREE.Vector3(x, 0.004, rowZ + 0.1), yaw: 0, dept });
}
function bench(cx, rowZ, n, dept) {
  const L = PITCH * n + 0.1;
  part("desk", cx, DESK_H, rowZ, 0, [L, 0.03, 0.8]);
  part("deskEdge", cx, DESK_H - 0.025, rowZ + 0.2, 0, [L, 0.02, 0.36]);
  part("modesty", cx, 0.45, rowZ - 0.3, 0, [L - 0.1, 0.5, 0.02]);
  part("tray", cx, 0.62, rowZ - 0.25, 0, [L - 0.3, 0.06, 0.14]);
  part("rail", cx, 0.79, rowZ - 0.3, 0, [L, 0.05, 0.05]);
  part("divider", cx, 0.92, rowZ - 0.415, 0, [L, 0.3, 0.012]);
  for (const sx of [-(L / 2 - 0.03), L / 2 - 0.03]) part("side", cx + sx, DESK_H / 2, rowZ, 0, [0.04, DESK_H, 0.72]);
  for (let i = 0; i < n; i++) seatAt(cx - (PITCH * n) / 2 + PITCH / 2 + PITCH * i, rowZ, dept);
}
// benches in department order, front of the floor first, the right of the aisle first
const benches = []; SEATS.forEach((n, d) => { for (let k = n; k > 0; k -= 4) benches.push([Math.min(4, k), d]); });
benches.forEach(([n, d], b) => { const row = Math.floor(b / 2), right = b % 2 === 0; const L = PITCH * n; const cx = right ? AISLE + L / 2 + 0.05 : -(AISLE + L / 2 + 0.05); bench(cx, -(row + (right ? 0 : 1)) * ROW, n, d); });
const ROWS = Math.ceil(benches.length / 2) + 1, FLOOR_END = -(ROWS - 1) * ROW;
// your desk: at the end of the aisle on a low platform, facing the floor
const CLIENT_Z = FLOOR_END - 4.2, CLIENT = new THREE.Vector3(0, 1.24, CLIENT_Z - 0.3);
part("platform", 0, 0.05, CLIENT_Z + 0.2, 0, [4.6, 0.1, 3.2]);
part("desk", 0, DESK_H + 0.1, CLIENT_Z, 0, [2.3, 0.035, 0.9]);
part("modesty", 0, 0.55, CLIENT_Z - 0.32, 0, [2.2, 0.5, 0.02]);
for (const sx of [-1.12, 1.12]) part("side", sx, DESK_H / 2 + 0.1, CLIENT_Z, 0, [0.04, DESK_H, 0.8]);
part("keys", 0, DESK_H + 0.112, CLIENT_Z + 0.16, 0, [0.44, 0.02, 0.15]);
monitor(-0.34, 1.34, CLIENT_Z - 0.24, 10 * Math.PI / 180, 7, 0, true);
monitor(0.34, 1.34, CLIENT_Z - 0.24, -10 * Math.PI / 180, 7, 1, true);
{ // the chair at your desk, squared up, nobody in it
  const cz = CLIENT_Z + 0.9; part("cushion", 0, 0.57, cz, 0, [0.48, 0.07, 0.46]); part("back", 0, 0.94, cz - 0.05, 0, [1, 1, 1], 0.1);
  for (const ax of [-0.25, 0.25]) { part("armPost", ax, 0.68, cz + 0.02, 0, [0.03, 0.2, 0.03]); part("armPad", ax, 0.79, cz + 0.02, 0, [0.06, 0.02, 0.26]); }
  part("lift", 0, 0.4, cz, 0, [0.03, 0.32, 0.03]); part("hub", 0, 0.22, cz, 0, [0.05, 0.06, 0.05]);
  for (let k = 0; k < 5; k++) { const a = k * Math.PI * 2 / 5; part("leg", Math.sin(a) * 0.16, 0.185, cz + Math.cos(a) * 0.16, a, [0.035, 0.03, 0.32], 0.3); part("caster", Math.sin(a) * 0.32, 0.13, cz + Math.cos(a) * 0.32, a, [1, 1, 1]); }
}
const clientScreens = screens.filter(s => s.kind === -1);
const clientPool = { pos: new THREE.Vector3(0, 0.104, CLIENT_Z + 0.2), yaw: 0, dept: 7 };
seatPos[7].push({ pos: CLIENT.clone(), floor: new THREE.Vector3(0, 0.1, CLIENT_Z + 0.9) });

// the room around it
const ROOM = { xL: -12.5, xR: 12.5, zBack: 9, zFar: CLIENT_Z - 3.2, h: 3.0 };
for (let z = -1.3; z > ROOM.zFar + 1; z -= ROW) for (const x of [-6.6, -3.3, 0, 3.3, 6.6]) part("troffer", x, ROOM.h - 0.012, z, 0, [1.2, 0.02, 0.28]);
for (const x of [-9.6, 9.6]) for (let z = -2; z > ROOM.zFar; z -= 8) part("column", x, ROOM.h / 2, z, 0, [0.5, ROOM.h, 0.5]);
for (let x = ROOM.xL; x <= ROOM.xR + 0.01; x += 1.5) part("mullion", x, ROOM.h / 2, ROOM.zFar, 0, [0.07, ROOM.h, 0.12]);
for (let z = ROOM.zBack; z >= ROOM.zFar; z -= 1.5) part("mullion", ROOM.xR, ROOM.h / 2, z, 0, [0.12, ROOM.h, 0.07]);
part("transom", 0, 2.55, ROOM.zFar, 0, [ROOM.xR - ROOM.xL, 0.08, 0.12]); part("transom", 0, 1.0, ROOM.zFar, 0, [ROOM.xR - ROOM.xL, 0.05, 0.12]);
part("transom", ROOM.xR, 2.55, (ROOM.zBack + ROOM.zFar) / 2, 0, [0.12, 0.08, ROOM.zBack - ROOM.zFar]); part("transom", ROOM.xR, 1.0, (ROOM.zBack + ROOM.zFar) / 2, 0, [0.12, 0.05, ROOM.zBack - ROOM.zFar]);

// ---------- build the meshes ----------
const dummy = new THREE.Object3D(); dummy.rotation.order = "YXZ";
const GEO = {
  rbox: new RoundedBoxGeometry(1, 1, 1, 3, 0.02), box: new THREE.BoxGeometry(1, 1, 1), cyl: new THREE.CylinderGeometry(1, 1, 1, 24),
  back: new THREE.CylinderGeometry(0.27, 0.25, 0.52, 28, 1, true, -0.95, 1.9), cushion: new RoundedBoxGeometry(1, 1, 1, 4, 0.03),
  caster: new THREE.CylinderGeometry(0.028, 0.028, 0.024, 16).rotateZ(Math.PI / 2)
};
const MAT = { desk: [GEO.rbox, mDesk], deskEdge: [GEO.box, mDeskEdge], modesty: [GEO.box, mPanel], tray: [GEO.box, mSteel], rail: [GEO.box, mSteel], divider: [GEO.box, mFrost], side: [GEO.box, mDeskEdge],
  bezel: [GEO.rbox, mBezel], chassis: [GEO.rbox, mChassis], mArm: [GEO.box, mSteel], mBracket: [GEO.box, mSteel], keys: [GEO.rbox, mPlastic], mouse: [GEO.rbox, mPlastic], turret: [GEO.rbox, mPlastic],
  cushion: [GEO.cushion, mCushion], back: [GEO.back, mMesh], armPost: [GEO.box, mPlastic], armPad: [GEO.rbox, mPlastic], lift: [GEO.cyl, mAlu], hub: [GEO.cyl, mPlastic], leg: [GEO.box, mAlu], caster: [GEO.caster, mPlastic],
  paper: [GEO.box, mPaper], mug: [GEO.cyl, mMug], turretScreen: [GEO.box, mTurretScreen],
  platform: [GEO.box, mDeskEdge], troffer: [GEO.box, mTroffer], column: [GEO.box, mColumn], mullion: [GEO.box, mSteel], transom: [GEO.box, mSteel] };
const SHADOWLESS = new Set(["troffer", "divider", "platform", "turretScreen", "paper"]);
for (const name in parts) {
  const list = parts[name], [geo, mat] = MAT[name];
  const m = new THREE.InstancedMesh(geo, mat, list.length);
  list.forEach((it, k) => { dummy.position.set(...it.p); dummy.rotation.set(it.tilt, it.y, 0); dummy.scale.set(...it.s); dummy.updateMatrix(); m.setMatrixAt(k, dummy.matrix); });
  if (!SHADOWLESS.has(name)) { m.castShadow = true; m.receiveShadow = true; }
  scene.add(m);
}
// screens: one instanced mesh per kind, a sheet of glass over all of them
const screenGeo = new THREE.PlaneGeometry(0.53, 0.30);
const screenInst = SCREENS.map((s, kind) => {
  const items = screens.filter(x => x.kind === kind);
  const m = new THREE.InstancedMesh(screenGeo, new THREE.MeshBasicMaterial({ map: s.tex, toneMapped: true }), items.length);
  items.forEach((x, k) => { dummy.position.copy(x.pos); dummy.rotation.set(0, x.yaw, 0); dummy.scale.set(1, 1, 1); dummy.updateMatrix(); m.setMatrixAt(k, dummy.matrix); m.setColorAt(k, new THREE.Color(0, 0, 0)); });
  scene.add(m); return { mesh: m, items };
});
if (!isSmall) {
  const glass = new THREE.InstancedMesh(screenGeo, mGlass, screens.length);
  screens.forEach((x, k) => { dummy.position.copy(x.pos).add(new THREE.Vector3(Math.sin(x.yaw) * 0.003, 0, Math.cos(x.yaw) * 0.003)); dummy.rotation.set(0, x.yaw, 0); dummy.scale.set(1, 1, 1); dummy.updateMatrix(); glass.setMatrixAt(k, dummy.matrix); });
  scene.add(glass);
}
// the wash of screen light on the carpet in front of every seat
const poolInst = new THREE.InstancedMesh(new THREE.PlaneGeometry(2.2, 1.8), new THREE.MeshBasicMaterial({ map: glowTex, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, opacity: 0.16 }), pools.length + 1);
[...pools, clientPool].forEach((p, k) => { dummy.position.copy(p.pos); dummy.rotation.set(-Math.PI / 2, 0, 0); dummy.scale.set(1, 1, 1); dummy.updateMatrix(); poolInst.setMatrixAt(k, dummy.matrix); poolInst.setColorAt(k, new THREE.Color(0, 0, 0)); });
scene.add(poolInst);

// your two monitors: the plan on the left, the risk gate on the right
const planL = document.createElement("canvas"), planR = document.createElement("canvas"); planL.width = planR.width = SW; planL.height = planR.height = SH;
const planTexL = new THREE.CanvasTexture(planL), planTexR = new THREE.CanvasTexture(planR);
planTexL.colorSpace = planTexR.colorSpace = THREE.SRGBColorSpace; planTexL.anisotropy = planTexR.anisotropy = 8;
const clientMats = [new THREE.MeshBasicMaterial({ map: planTexL }), new THREE.MeshBasicMaterial({ map: planTexR })];
clientScreens.forEach((s, k) => { const m = new THREE.Mesh(screenGeo, clientMats[k]); m.position.copy(s.pos); m.rotation.y = s.yaw; scene.add(m); });
let planState = "", planTick = 0;
function drawPlans(state, t) {
  for (const [c, side] of [[planL, "L"], [planR, "R"]]) {
    const g = c.getContext("2d");
    header(g, side === "L" ? "YOUR DESK · APPROVE-FIRST" : "RISK GATE · YOUR LIMITS", new Date().toTimeString().slice(0, 5));
    if (state === "idle") {
      g.fillStyle = C.ink2; g.font = `15px ${MONO}`;
      g.fillText(side === "L" ? "No plan on the table." : "All limits inside bounds.", 18, 80);
      g.fillText(side === "L" ? "The floor is watching. Nothing waits on you." : "Emergency brake 10%  ·  bad day 3%", 18, 108);
      if (side === "L") { g.fillStyle = C.ink3; g.fillText("Queue: empty", 18, 156); g.fillText("Halts: none", 18, 184); g.fillText("Notify: WhatsApp · email", 18, 212); }
      continue;
    }
    if (side === "L") {
      g.fillStyle = C.ink; g.font = `500 28px ${MONO}`; g.fillText("PLAN 0418 · BUY", 18, 86);
      g.fillStyle = C.ink2; g.font = `15px ${MONO}`;
      g.fillText("US large cap · 2.1% of book", 18, 120); g.fillText("limit 0.15% above mid · good for 45 min", 18, 146);
      g.fillStyle = C.ink3; g.fillText("Room convened: 74 seats heard", 18, 190); g.fillText("Vetoes: none · reasoning attached", 18, 216);
      if (state === "approve") {
        const pulse = 0.55 + 0.45 * Math.sin(t * 3);
        g.fillStyle = `rgba(138,168,216,${0.25 + 0.5 * pulse})`; g.fillRect(18, 250, 250, 60);
        g.fillStyle = "#fbfaf7"; g.font = `500 22px ${MONO}`; g.fillText("APPROVE", 48, 289);
        const left = Math.max(0, 44 * 60 + 12 - Math.floor(t) % 600); g.fillStyle = C.amber; g.font = `15px ${MONO}`; g.fillText(`expires ${String(Math.floor(left / 60)).padStart(2, "0")}:${String(left % 60).padStart(2, "0")}`, 300, 289);
      } else {
        g.fillStyle = "rgba(230,236,248,0.14)"; g.fillRect(18, 250, 250, 60);
        g.fillStyle = C.ink3; g.font = `500 17px ${MONO}`; g.fillText("waiting for the room", 34, 289);
      }
    } else {
      const rows = [["Emergency brake", "10%", "book down 0.4%"], ["Position cap", "5%", "would be 2.1%"], ["Bad-day halt", "3%", "day +0.2%"], ["Exit flag", "8%", "n/a"], ["Daily orders", "20", "3 so far"], ["Appetite", "40/100", "sizing 0.42×"]];
      g.font = `14px ${MONO}`;
      rows.forEach((r, k) => { const y = 76 + k * 40; g.fillStyle = C.ink2; g.fillText(r[0], 18, y); g.fillStyle = C.ink; g.fillText(r[1], 260, y); g.fillStyle = state === "approve" ? C.accent : C.ink3; g.fillText(r[2], 380, y); g.fillStyle = C.line; g.fillRect(18, y + 12, SW - 36, 1); });
      g.fillStyle = state === "approve" ? C.up : C.ink3; g.font = `500 15px ${MONO}`;
      g.fillText(state === "approve" ? "● GATE: PASS · nothing to override" : "● GATE: checking", 18, 340);
    }
  }
  planTexL.needsUpdate = planTexR.needsUpdate = true;
}
drawPlans("idle", 0);

// the room: carpet, walls, a ceiling, glass on two sides with the city behind it
const floorMesh = new THREE.Mesh(new THREE.PlaneGeometry(48, 60), mCarpet); floorMesh.rotation.x = -Math.PI / 2; floorMesh.position.set(0, 0, -16); floorMesh.receiveShadow = true; scene.add(floorMesh);
const ceiling = new THREE.Mesh(new THREE.PlaneGeometry(48, 60), mCeil); ceiling.rotation.x = Math.PI / 2; ceiling.position.set(0, ROOM.h, -16); scene.add(ceiling);
const wallL = new THREE.Mesh(new THREE.PlaneGeometry(60, ROOM.h), mWall); wallL.rotation.y = Math.PI / 2; wallL.position.set(ROOM.xL, ROOM.h / 2, -16); scene.add(wallL);
const wallB = new THREE.Mesh(new THREE.PlaneGeometry(48, ROOM.h), mWall); wallB.rotation.y = Math.PI; wallB.position.set(0, ROOM.h / 2, ROOM.zBack); scene.add(wallB);
const glassFar = new THREE.Mesh(new THREE.PlaneGeometry(ROOM.xR - ROOM.xL, ROOM.h), mWindow); glassFar.position.set(0, ROOM.h / 2, ROOM.zFar); scene.add(glassFar);
const glassR = new THREE.Mesh(new THREE.PlaneGeometry(ROOM.zBack - ROOM.zFar, ROOM.h), mWindow); glassR.rotation.y = -Math.PI / 2; glassR.position.set(ROOM.xR, ROOM.h / 2, (ROOM.zBack + ROOM.zFar) / 2); scene.add(glassR);
{
  const far = new THREE.Mesh(new THREE.PlaneGeometry(220, 56), new THREE.MeshBasicMaterial({ map: skyline(2048, 640, 0.35), fog: false })); far.position.set(0, 16, ROOM.zFar - 70); scene.add(far);
  const right = new THREE.Mesh(new THREE.PlaneGeometry(220, 56), new THREE.MeshBasicMaterial({ map: skyline(2048, 640, 0.25), fog: false })); right.rotation.y = -Math.PI / 2; right.position.set(ROOM.xR + 70, 16, -16); scene.add(right);
}

// ---------- lights ----------
scene.add(new THREE.HemisphereLight(0x2e3d5e, 0x161c2a, 0.5));
const sun = new THREE.DirectionalLight(0xdfe8ff, 0.5); sun.position.set(3, 14, -8); sun.target.position.set(0, 0, -14); scene.add(sun, sun.target);
if (!isSmall) {
  sun.castShadow = true; sun.shadow.mapSize.set(2048, 2048); sun.shadow.bias = -0.0004; sun.shadow.normalBias = 0.03; sun.shadow.radius = 3;
  const sc = sun.shadow.camera; sc.left = -15; sc.right = 15; sc.top = 24; sc.bottom = -24; sc.near = 2; sc.far = 40;
}
const deptLights = [];
for (let d = 0; d < 7; d++) {
  const c = seatPos[d].reduce((a, s) => a.add(s.pos), new THREE.Vector3()).multiplyScalar(1 / seatPos[d].length);
  const L = new THREE.PointLight(0xc4d6ff, 0, 9, 2); L.position.copy(c).add(new THREE.Vector3(0, 0.5, 0.9)); scene.add(L); deptLights.push(L);
}
const chairLight = new THREE.PointLight(0x9ec0ff, 0, 8, 2); chairLight.position.copy(CLIENT).add(new THREE.Vector3(0, 0.6, 1.0)); scene.add(chairLight);
const chairSpot = new THREE.SpotLight(0xdfe8ff, 0, 9, 0.5, 0.6, 1.5); chairSpot.position.set(0, ROOM.h - 0.05, CLIENT_Z + 0.6); chairSpot.target.position.set(0, 0.8, CLIENT_Z + 0.3); scene.add(chairSpot, chairSpot.target);

// threads: every seat reports to your desk when a plan convenes
const threadTarget = CLIENT.clone().add(new THREE.Vector3(0, 0.1, 0.2));
const threadFrom = []; for (let d = 0; d < 7; d++) seatPos[d].forEach(s => threadFrom.push(s.pos.clone().add(new THREE.Vector3(0, 0.22, 0))));
const threadPos = new Float32Array(threadFrom.length * 6);
threadFrom.forEach((p, k) => { threadPos.set([p.x, p.y, p.z, threadTarget.x, threadTarget.y, threadTarget.z], k * 6); });
const threadGeo = new THREE.BufferGeometry(); threadGeo.setAttribute("position", new THREE.BufferAttribute(threadPos, 3));
const threadMat = new THREE.LineBasicMaterial({ color: 0x8aa8d8, transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false });
scene.add(new THREE.LineSegments(threadGeo, threadMat));
const dotCount = threadFrom.length, dotPos = new Float32Array(dotCount * 3), dotOffset = threadFrom.map((_, k) => (k * 0.618034) % 1);
const dotGeo = new THREE.BufferGeometry(); dotGeo.setAttribute("position", new THREE.BufferAttribute(dotPos, 3));
const dotMat = new THREE.PointsMaterial({ map: dotTex, color: 0xdbe6ff, size: 0.16, transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false, sizeAttenuation: true });
scene.add(new THREE.Points(dotGeo, dotMat));
let dust = null;
if (!reduced) {
  const n = isSmall ? 120 : 360, arr = new Float32Array(n * 3), vel = [];
  for (let i = 0; i < n; i++) { arr.set([Math.random() * 20 - 10, 0.2 + Math.random() * 2.6, Math.random() * 40 - 34], i * 3); vel.push([(Math.random() - 0.5) * 0.02, (Math.random() - 0.5) * 0.012, (Math.random() - 0.5) * 0.02]); }
  const g = new THREE.BufferGeometry(); g.setAttribute("position", new THREE.BufferAttribute(arr, 3));
  dust = new THREE.Points(g, new THREE.PointsMaterial({ map: dotTex, color: 0x9fb4d8, size: 0.03, transparent: true, opacity: 0.28, blending: THREE.AdditiveBlending, depthWrite: false }));
  dust.userData.vel = vel; scene.add(dust);
}

// ---------- post ----------
const composer = new EffectComposer(renderer);
composer.addPass(new RenderPass(scene, camera));
let bokeh = null;
if (!isSmall && !reduced) { bokeh = new BokehPass(scene, camera, { focus: 9, aperture: 0.00035, maxblur: 0.0055 }); composer.addPass(bokeh); }
const bloom = new UnrealBloomPass(new THREE.Vector2(1, 1), 0.32, 0.55, 0.86);
composer.addPass(bloom);
const grade = new ShaderPass({
  uniforms: { tDiffuse: { value: null }, uVig: { value: 0.42 }, uTime: { value: 0 } },
  vertexShader: "varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }",
  fragmentShader: `uniform sampler2D tDiffuse; uniform float uVig; uniform float uTime; varying vec2 vUv;
    float hash(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233)) + uTime) * 43758.5453); }
    void main(){ vec4 c = texture2D(tDiffuse, vUv); float d = distance(vUv, vec2(0.5)); c.rgb *= 1.0 - uVig * smoothstep(0.35, 0.95, d); c.rgb += (hash(vUv) - 0.5) * 0.028; gl_FragColor = c; }`
});
composer.addPass(grade);
let smaa = null;
if (!isSmall) { smaa = new SMAAPass(1, 1); composer.addPass(smaa); }
composer.addPass(new OutputPass());

let sizedW = 0, sizedH = 0;
function size() {
  const w = stage.clientWidth, h = stage.clientHeight;
  if (!w || !h || (w === sizedW && h === sizedH)) return; // a hidden pane reports 0×0; wait for a real size
  sizedW = w; sizedH = h;
  renderer.setSize(w, h, false); composer.setSize(w, h);
  bloom.resolution.set(Math.round(w / 2), Math.round(h / 2));
  if (smaa) smaa.setSize(w * DPR, h * DPR);
  camera.aspect = w / h; camera.updateProjectionMatrix();
  canvas.style.width = w + "px"; canvas.style.height = h + "px";
}
size(); window.addEventListener("resize", size);
if ("ResizeObserver" in window) new ResizeObserver(size).observe(stage);

// ---------- the walk down the aisle ----------
// Start at the head of the floor, eye height, looking down the aisle with the room to the right of
// the copy. Then walk forward. Then arrive at your desk.
const CAM = isSmall
  ? [new THREE.Vector3(-0.4, 2.9, 7.0), new THREE.Vector3(-0.4, 2.8, -6.5), new THREE.Vector3(0.0, 1.7, CLIENT_Z + 6.2)]
  : [new THREE.Vector3(0.3, 1.8, 6.2), new THREE.Vector3(0.35, 1.7, -6.5), new THREE.Vector3(-0.5, 1.6, CLIENT_Z + 5.6)];
const AIM = isSmall
  ? [new THREE.Vector3(1.3, -1.4, -1.5), new THREE.Vector3(1.5, -1.3, -15), new THREE.Vector3(0.0, 0.7, CLIENT_Z - 0.4)]
  : [new THREE.Vector3(-1.9, 0.5, -9), new THREE.Vector3(-1.7, 0.6, -22), new THREE.Vector3(-1.5, 1.0, CLIENT_Z - 0.4)];
const camPos = new THREE.Vector3(), camAim = new THREE.Vector3(), tmp = new THREE.Vector3();
let mouseX = 0, mouseY = 0, parX = 0, parY = 0;
if (!isSmall && !reduced) window.addEventListener("pointermove", e => { mouseX = (e.clientX / window.innerWidth - 0.5) * 2; mouseY = (e.clientY / window.innerHeight - 0.5) * 2; }, { passive: true });

// ---------- scroll ----------
let target = 0, p = 0, lastT = 0, running = true, firstFrame = true;
const beats = Array.from(document.querySelectorAll(".beat"));
const depts = Array.from(document.querySelectorAll("#depts li"));
const seatEl = document.getElementById("seatcount"), hint = document.getElementById("hint");
const hud = { heard: document.getElementById("hud-heard"), veto: document.getElementById("hud-veto"), state: document.getElementById("hud-state") };
const topBar = document.getElementById("top-bar");
function onScroll() {
  const rect = section.getBoundingClientRect(), vh = window.innerHeight, span = rect.height - vh;
  target = span > 0 ? Math.min(1, Math.max(0, -rect.top / span)) : 0;
  running = rect.bottom > 0 && rect.top < vh;
  const past = rect.bottom <= 40;
  if (past !== topBar.classList.contains("light")) { topBar.classList.toggle("light", past); topBar.classList.toggle("dark", !past); }
  hint.classList.toggle("off", target > 0.02);
}
window.addEventListener("scroll", onScroll, { passive: true }); onScroll();

// ---------- labels: one seat named per department as it comes alive, plus your desk ----------
const labelLayer = document.getElementById("labels");
const labels = [];
function makeLabel(text, sub) { const el = document.createElement("div"); el.className = "seat-label"; el.innerHTML = `<b>${text}</b>${sub ? `<i>${sub}</i>` : ""}`; labelLayer.appendChild(el); return el; }
for (let d = 0; d < 7; d++) {
  // name the first seat on the right of the aisle, where the copy never is
  let i = seatPos[d].findIndex(s => s.pos.x > 0); if (i < 0) i = 0;
  const a = ROSTER[d][i];
  labels.push({ el: makeLabel(a[0], (a[1] ? "veto seat · " : "") + DEPTS[d]), anchor: seatPos[d][i].pos.clone().add(new THREE.Vector3(0, 0.26, 0)), from: T.deptOn(d) + 0.012, to: T.deptOn(d) + 0.11 });
}
labels.push({ el: makeLabel("You", "the only seat that can act"), anchor: CLIENT.clone().add(new THREE.Vector3(0, 0.38, 0.1)), from: 0.9, to: 1.01 });
const proj = new THREE.Vector3();
const hoverEl = makeLabel("", ""); hoverEl.classList.add("hover");
let px = -1, py = -1, hoverSeat = -1;
const allSeats = []; for (let d = 0; d < 7; d++) seatPos[d].forEach((sp, i) => allSeats.push({ pos: sp.pos.clone().add(new THREE.Vector3(0, 0.2, 0)), dept: d, agent: ROSTER[d][i] }));
if (!isSmall) {
  stage.addEventListener("pointermove", e => { const r = stage.getBoundingClientRect(); px = e.clientX - r.left; py = e.clientY - r.top; }, { passive: true });
  stage.addEventListener("pointerleave", () => { px = py = -1; });
}
// the copy on screen right now, so no label ever sits on top of it
function copyRect() {
  const b = beats.find(x => x.classList.contains("on")); if (!b) return null;
  const r = stage.getBoundingClientRect(); let L = 1e9, T2 = 1e9, R = -1e9, B = -1e9;
  b.querySelectorAll(".wrap > *").forEach(el => { const q = el.getBoundingClientRect(); if (q.width === 0) return; L = Math.min(L, q.left - r.left); T2 = Math.min(T2, q.top - r.top); R = Math.max(R, q.right - r.left); B = Math.max(B, q.bottom - r.top); });
  return L < R ? { l: L - 28, t: T2 - 28, r: R + 28, b: B + 28 } : null;
}
const inRect = (x, y, w, h, rc) => rc && x + w > rc.l && x < rc.r && y + h > rc.t && y < rc.b;
function placeLabels(rc) {
  const w = stage.clientWidth, h = stage.clientHeight, placed = [];
  for (const L of labels) {
    let a = 0;
    if (p > L.from && p < L.to) a = Math.min(1, (p - L.from) / 0.015) * Math.min(1, (L.to - p) / 0.02);
    if (a > 0.01) {
      proj.copy(L.anchor).project(camera);
      const ax = (proj.x * 0.5 + 0.5) * w, y = (-proj.y * 0.5 + 0.5) * h - 14, wide = L.el.offsetWidth || 160, tall = 40;
      // to the right of the seat, or to its left when the right would run off the edge or into the copy
      let flip = false, x = ax + 18;
      if (x + wide > w - 16 || inRect(x - 24, y, wide + 24, tall, rc)) { flip = true; x = ax - 18 - wide; }
      const clash = proj.z > 1 || x < 16 || x + wide > w - 16 || y < 90 || y > h - 70 || inRect(x, y, wide + 24, tall, rc) || placed.some(r => Math.abs(r.x - x) < wide + 24 && Math.abs(r.y - y) < tall + 12);
      if (!clash) { placed.push({ x, y }); L.el.classList.toggle("flip", flip); L.el.style.opacity = String(a); L.el.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)`; continue; }
    }
    if (L.el.style.opacity !== "0") L.el.style.opacity = "0";
  }
}
function placeHover(rc) {
  if (px < 0) { if (hoverSeat !== -1) { hoverSeat = -1; hoverEl.style.opacity = "0"; } return; }
  const w = stage.clientWidth, h = stage.clientHeight; let best = -1, bd = 34 * 34, bx = 0, by = 0;
  for (let k = 0; k < allSeats.length; k++) {
    const sd = allSeats[k]; if (deptLevel[sd.dept] < 0.4) continue;
    proj.copy(sd.pos).project(camera); if (proj.z > 1) continue;
    const x = (proj.x * 0.5 + 0.5) * w, y = (-proj.y * 0.5 + 0.5) * h, dd = (x - px) * (x - px) + (y - py) * (y - py);
    if (dd < bd) { bd = dd; best = k; bx = x; by = y; }
  }
  if (best !== hoverSeat) { hoverSeat = best; if (best >= 0) { const a = allSeats[best]; hoverEl.innerHTML = `<b>${a.agent[0]}</b><i>${a.agent[1] ? "veto seat · " : ""}${DEPTS[a.dept]}</i>`; } }
  if (best >= 0) {
    const wide = hoverEl.offsetWidth || 160; let flip = false, x = bx + 18;
    if (x + wide > w - 16 || inRect(x - 24, by - 14, wide + 24, 40, rc)) { flip = true; x = bx - 18 - wide; }
    if (x < 16 || inRect(x, by - 14, wide + 24, 40, rc)) hoverEl.style.opacity = "0";
    else { hoverEl.classList.toggle("flip", flip); hoverEl.style.opacity = "1"; hoverEl.style.transform = `translate(${x.toFixed(1)}px, ${(by - 14).toFixed(1)}px)`; }
  } else hoverEl.style.opacity = "0";
}

// ---------- per-frame ----------
const col = new THREE.Color();
const deptLevel = new Float32Array(8);
let lastLive = -1, lastScreenDraw = 0;
function frame(now) {
  requestAnimationFrame(frame);
  if (!running && !firstFrame) return;
  if (!sizedW) { size(); if (!sizedW) return; } // nothing to draw into yet
  const dt = lastT ? Math.min(0.2, (now - lastT) / 1000) : 0.016; lastT = now;
  p += (target - p) * (1 - Math.exp(-dt / 0.11));
  if (!Number.isFinite(p)) p = target;
  parX += (mouseX - parX) * (1 - Math.exp(-dt / 0.35)); parY += (mouseY - parY) * (1 - Math.exp(-dt / 0.35));
  const t = now / 1000;

  // the screens keep moving, a few times a second, like real panels
  if (now - lastScreenDraw > 140) { lastScreenDraw = now; SCREENS.forEach(s => drawScreen(s, now)); }

  const convenePulse = Math.sin(Math.PI * smooth(T.convene[0], T.convene[1], p));
  const dimK = smooth(T.dim[0], T.dim[1], p);
  for (let d = 0; d < 7; d++) {
    const on = smooth(T.deptOn(d) - 0.01, T.deptOn(d) + 0.045, p);
    const idle = 0.3 + 0.04 * Math.sin(t * 0.7 + d);
    deptLevel[d] = lerp(lerp(idle, 1.0, on) * (1 + 0.35 * convenePulse), 0.2, dimK);
  }
  const chairOn = smooth(T.chair[0], T.chair[1], p);
  deptLevel[7] = lerp(0.08, 1.0, chairOn);
  const vetoK = smooth(T.convene[0], T.convene[0] + 0.05, p) * (1 - smooth(T.convene[1] - 0.04, T.convene[1], p));
  screenInst.forEach(({ mesh, items }, mi) => {
    for (let k = 0; k < items.length; k++) {
      const s = items[k], lv = deptLevel[s.dept] * (0.96 + 0.04 * Math.sin(t * 2.3 + s.i * 1.7 + mi));
      col.copy(SCREEN_COLOR);
      if (vetoK > 0 && ROSTER[s.dept][s.i] && ROSTER[s.dept][s.i][1]) col.lerp(CHAIR_COLOR, vetoK * (0.6 + 0.4 * Math.sin(t * 4 + s.i)));
      mesh.setColorAt(k, col.multiplyScalar(lv * 1.35));
    }
    mesh.instanceColor.needsUpdate = true;
  });
  pools.forEach((pl, k) => poolInst.setColorAt(k, col.copy(SCREEN_COLOR).multiplyScalar(deptLevel[pl.dept] * 0.7)));
  poolInst.setColorAt(pools.length, col.copy(CHAIR_COLOR).multiplyScalar(deptLevel[7] * 1.1)); poolInst.instanceColor.needsUpdate = true;
  deptLights.forEach((L, d) => { L.intensity = 14 * deptLevel[d]; });
  chairLight.intensity = 16 * deptLevel[7]; chairSpot.intensity = 70 * deptLevel[7];
  clientMats.forEach(m => m.color.setScalar(0.16 + 1.25 * deptLevel[7]));

  const state = p > 0.905 ? "approve" : p > T.convene[0] + 0.02 ? "tabled" : "idle";
  if (state !== planState || (state === "approve" && ++planTick % 6 === 0)) { planState = state; drawPlans(state, t); }

  const cv = smooth(T.convene[0], T.convene[0] + 0.05, p) * (1 - smooth(T.convene[1] - 0.05, T.convene[1], p));
  threadMat.opacity = 0.22 * cv; dotMat.opacity = cv;
  if (cv > 0.001) {
    const head = smooth(T.convene[0], T.convene[1] - 0.03, p);
    for (let k = 0; k < dotCount; k++) {
      const u = Math.min(1, Math.max(0, head * 1.35 - dotOffset[k] * 0.35));
      tmp.lerpVectors(threadFrom[k], threadTarget, u * u * (3 - 2 * u));
      dotPos.set([tmp.x, tmp.y + Math.sin(u * Math.PI) * 0.5, tmp.z], k * 3);
    }
    dotGeo.attributes.position.needsUpdate = true;
  }
  if (dust) {
    const a = dust.geometry.attributes.position.array, vel = dust.userData.vel;
    for (let i = 0; i < vel.length; i++) { a[i * 3] += vel[i][0] * dt * 8; a[i * 3 + 1] += vel[i][1] * dt * 8; a[i * 3 + 2] += vel[i][2] * dt * 8; if (a[i * 3 + 1] < 0.15 || a[i * 3 + 1] > 2.8) vel[i][1] *= -1; }
    dust.geometry.attributes.position.needsUpdate = true;
  }

  const k1 = smooth(0, T.camMid, p), k2 = smooth(T.camMid, T.camEnd, p);
  camPos.lerpVectors(CAM[0], CAM[1], k1); if (k2 > 0) camPos.lerp(CAM[2], k2);
  camAim.lerpVectors(AIM[0], AIM[1], k1); if (k2 > 0) camAim.lerp(AIM[2], k2);
  const breathe = reduced ? 0 : 1;
  camPos.x += parX * 0.22 + Math.sin(t * 0.23) * 0.04 * breathe; camPos.y += -parY * 0.1 + Math.sin(t * 0.31) * 0.02 * breathe;
  camera.position.copy(camPos); camera.lookAt(camAim);
  if (bokeh) bokeh.uniforms.focus.value = Math.max(2.5, camPos.distanceTo(camAim) * (0.55 + 0.4 * k2));
  bloom.strength = 0.3 + 0.35 * convenePulse + 0.15 * chairOn;
  grade.uniforms.uTime.value = (t % 100) * 7;

  composer.render();
  if (firstFrame) { firstFrame = false; poster.style.opacity = "0"; }

  const live = SEATS.reduce((acc, n, d) => acc + (p >= T.deptOn(d) ? n : 0), 0);
  if (live !== lastLive) { lastLive = live; seatEl.textContent = live; }
  for (const b of beats) { const on = p >= +b.dataset.from && p < +b.dataset.to; if (on !== b.classList.contains("on")) b.classList.toggle("on", on); }
  depts.forEach((el, d) => { const on = p >= T.deptOn(d); if (on !== el.classList.contains("on")) el.classList.toggle("on", on); });
  if (hud.heard) {
    const heard = Math.round(74 * smooth(T.convene[0], T.convene[1] - 0.04, p));
    hud.heard.textContent = heard; hud.veto.textContent = heard > 0 ? "0" : "–";
    hud.state.textContent = heard < 74 ? (heard ? "convening" : "tabled") : "no vetoes · goes to your desk";
  }
  const rc = copyRect();
  placeLabels(rc); placeHover(rc);
}
requestAnimationFrame(frame);
window.__floor = { get p() { return p; } };
