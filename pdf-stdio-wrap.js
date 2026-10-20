/*
 * pdf-stdio-wrap.js   [ marker: PDF-LOCAL-READ-WRAPPER ]
 *
 * Lets Claude (the Claude desktop app's built-in pdf-viewer extension) read local PDFs on Windows. Installed by
 * install-pdf-read.ps1 as the extension's dist/index.js; the real entry point is kept as dist/index.real.js.
 *
 * THE BUG IT WORKS AROUND
 *   The pdf-viewer server only opens files under an allowed-directories Set. On Windows that Set ends up empty:
 *   refreshRoots() calls allowedLocalDirs.clear() before re-adding the client's roots, and the server's own
 *   fileUrlToPath() turns a Windows root such as file:///C:/ into "/C:/", which path.resolve() makes "C:\C:", so
 *   statSync fails, the error is swallowed by a bare catch {}, and nothing is re-added. Every folder the server was
 *   started with (command-line folders, and in 2.0.0 the "PDF Directories" setting) is wiped with it.
 *
 * WHAT IT DOES (in the same process, through the server's own exports; nothing is spawned)
 *   1. Adds the folders named in pdf-local-read.json ("directories") to process.argv, which the server's own
 *      parseArgs() reads, so main() registers them through its supported command-line path.
 *   2. Imports the server's exported allowedLocalDirs Set and changes what its clear() does: it still empties the
 *      Set, then puts back the folders the server was started with, as the Set held them at the first clear(). Those
 *      are the folders from step 1 and every other folder given on the command line (in 2.0.0, its own "PDF
 *      Directories" setting). refreshRoots() only adds after it clears, so the client's roots are still replaced
 *      whenever the client sends a new list (they register at all only once install-pdf-read.ps1 has applied the
 *      roots fix), and a root the client no longer sends stops being readable.
 *
 * LOGGING
 *   Minimal by default: a few lines per launch, size-capped. Full per-message logging turns on when the file
 *   DIAG-ON.flag exists in the toolkit folder: create it and restart the app; delete it to go back to quiet.
 *   PDF_WRAP_DIAG=1 does the same only for a wrapper started by hand, because the app passes its extensions a fixed
 *   list of environment variables that omits it. The log is pdf-read.log in the toolkit folder, else in the app's
 *   logs folder, else beside this file.
 *
 * FINDING THE TOOLKIT
 *   This file runs from inside the extension, so its own folder is not the toolkit. It reads the toolkit folder and
 *   the folders to grant from pdf-local-read.json beside it, which install-pdf-read.ps1 writes and
 *   uninstall-pdf-read.ps1 removes. It never creates a folder.
 *
 * SAFETY: pass-through never alters a byte of the protocol; a logging error cannot block the pipe; nothing extra is
 * ever written to stdout. Reversible with uninstall-pdf-read.ps1.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REAL = path.join(__dirname, 'index.real.js');
const SERVER = path.join(__dirname, 'server.js');
const LINK = path.join(__dirname, 'pdf-local-read.json');

function isDir(p) { try { return fs.statSync(p).isDirectory(); } catch (e) { return false; } }

const LINKED = (() => {
  let raw, cfg;
  try { raw = fs.readFileSync(LINK, 'utf8'); } catch (e) { return { dir: null, why: 'no pdf-local-read.json beside the wrapper', dirs: [] }; }
  try { cfg = JSON.parse(raw.replace(/^\uFEFF/, '')); } catch (e) { return { dir: null, why: 'pdf-local-read.json is not valid JSON', dirs: [] }; }
  const listed = Array.isArray(cfg && cfg.directories) ? cfg.directories : [];
  const dirs = listed.filter((d) => typeof d === 'string' && path.isAbsolute(d) && isDir(d));
  const skipped = listed.filter((d) => !dirs.includes(d));
  const dir = cfg && cfg.toolkit;
  if (typeof dir !== 'string' || !path.isAbsolute(dir)) return { dir: null, why: 'pdf-local-read.json names no absolute toolkit folder', dirs, skipped };
  if (!isDir(dir)) return { dir: null, why: 'the toolkit folder it names does not exist: ' + dir, dirs, skipped };
  return { dir, why: '', dirs, skipped };
})();
const TOOLKIT = LINKED.dir;
const TOOLKIT_NOTE = TOOLKIT || ('NOT FOUND (' + LINKED.why + ')');

// full per-message logging only when explicitly asked for; default OFF (minimal).
const DIAG = (() => {
  try { if (process.env.PDF_WRAP_DIAG === '1') return true; } catch (e) {}
  try { if (TOOLKIT && fs.existsSync(path.join(TOOLKIT, 'DIAG-ON.flag'))) return true; } catch (e) {}
  return false;
})();

// ---- pick a writable log path; rotate if it grows past the cap ----
function pickLog() {
  const appLogs = process.env.APPDATA ? path.join(process.env.APPDATA, 'Claude', 'logs') : null;
  for (const dir of [TOOLKIT, appLogs, __dirname]) {
    if (!dir || !isDir(dir)) continue;
    try {
      const p = path.join(dir, 'pdf-read.log');
      try { const st = fs.statSync(p); if (st.size > 512 * 1024) fs.renameSync(p, p + '.old'); } catch (e) {}
      fs.appendFileSync(p, '');
      return p;
    } catch (e) { /* try next */ }
  }
  return null;
}
const LOG = pickLog();
const ts = () => new Date().toISOString();
// The app starts several server processes that share one log, so every line after a SESSION header names its process.
const PID = 'pid=' + process.pid;
function w(s) { if (!LOG) return; try { fs.appendFileSync(LOG, s + '\n'); } catch (e) {} }
function wp(s) { w(PID + ' ' + s); }

process.stderr.write('[pdf-local-read] wrapper active (diag=' + DIAG + '). toolkit=' + TOOLKIT_NOTE + ' log=' + LOG + '\n');
w('\n==== SESSION ' + ts() + '  ' + PID + '  (diag=' + DIAG + ') ====');
wp('[wrap] toolkit=' + TOOLKIT_NOTE);
wp('[wrap] read access: ' + (LINKED.dirs.length ? JSON.stringify(LINKED.dirs) : '(no folders of its own)') + (LINKED.skipped && LINKED.skipped.length ? '  skipped, not existing folders: ' + JSON.stringify(LINKED.skipped) : ''));
wp('[wrap] argv=' + JSON.stringify(process.argv.slice(2)) + '  real-exists=' + fs.existsSync(REAL));

// ---- diagnostic-only per-message teeing (installed only when DIAG) ----
function summarize(line) {
  let extra = '';
  try {
    const o = JSON.parse(line);
    const b = [];
    if (o.method !== undefined) b.push('method=' + o.method);
    if (o.id !== undefined) b.push('id=' + JSON.stringify(o.id));
    if (o.params && o.params.capabilities !== undefined) b.push('CAPS=' + JSON.stringify(o.params.capabilities));
    if (o.params && o.params.name !== undefined) b.push('tool=' + o.params.name);
    if (o.result !== undefined) b.push('result=' + JSON.stringify(o.result).slice(0, 900));
    if (o.error !== undefined) b.push('ERROR=' + JSON.stringify(o.error));
    extra = ' {' + b.join(' ') + '}';
  } catch (e) {}
  return extra;
}
function tee(tag, chunk) {
  try {
    const s = Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk);
    wp('[' + ts() + '] ' + tag + '  +' + ((chunk == null) ? 0 : chunk.length) + 'B');
    for (const line of s.split('\n')) {
      if (!line.trim()) continue;
      wp('    ' + tag + summarize(line) + '  ::  ' + line.slice(0, 4000));
    }
  } catch (e) {}
}

if (DIAG) {
  const realOut = process.stdout.write.bind(process.stdout);
  process.stdout.write = function (chunk, enc, cb) { try { tee('SRV->APP', chunk); } catch (e) {} return realOut(chunk, enc, cb); };
  function wrapReg(orig) {
    return function (event, handler) {
      if (event === 'data' && typeof handler === 'function') {
        const wrapped = function (chunk) { try { tee('APP->SRV', chunk); } catch (e) {} return handler.apply(this, arguments); };
        return orig.call(process.stdin, event, wrapped);
      }
      return orig.call(process.stdin, event, handler);
    };
  }
  process.stdin.on = wrapReg(process.stdin.on.bind(process.stdin));
  process.stdin.addListener = wrapReg(process.stdin.addListener.bind(process.stdin));
}

// server's own [pdf-server] stderr lines -> our log (small; confirms the registration). Passthrough.
const realErr = process.stderr.write.bind(process.stderr);
process.stderr.write = function (chunk, enc, cb) {
  try {
    const s = (Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk)).replace(/\s+$/, '');
    if (s) wp('[' + ts() + '] SRV-STDERR  ' + s);
  } catch (e) {}
  return realErr(chunk, enc, cb);
};

// ============================ THE FIX ============================
// 1) the granted folders as command-line folders, which the server's parseArgs() and main() register
const given = process.argv.slice(2);
const toAdd = LINKED.dirs.filter((d) => !given.includes(d));
if (toAdd.length) {
  process.argv.push(...toAdd);
  wp('[wrap] added the granted folders to argv -> ' + JSON.stringify(process.argv.slice(2)));
}

// 2) the server's shared allowedLocalDirs Set: each clear() keeps the folders the server was started with
let clears = 0;
let startedWith = null;
try {
  const serverMod = await import(pathToFileURL(SERVER).href);
  const dirs = serverMod.allowedLocalDirs;
  if (dirs && typeof dirs.add === 'function' && typeof dirs.clear === 'function') {
    const emptySet = dirs.clear.bind(dirs);
    dirs.clear = function () {
      clears++;
      if (startedWith === null) startedWith = [...dirs];
      emptySet();
      for (const d of startedWith) dirs.add(d);
      if (DIAG || clears === 1) wp('[' + ts() + '] allowedLocalDirs.clear() #' + clears + ': kept the folders the server was started with ' + JSON.stringify(startedWith));
    };
    for (const d of LINKED.dirs) dirs.add(path.resolve(d));
    wp('[wrap] FIX ACTIVE: patched allowedLocalDirs -> ' + JSON.stringify([...dirs]));
  } else {
    wp('[wrap] WARNING: allowedLocalDirs not found on server.js exports (fix may be degraded)');
  }
} catch (e) {
  wp('[wrap] WARNING: could not patch allowedLocalDirs: ' + ((e && e.message) || e));
}

// run the real server in-process
import(pathToFileURL(REAL).href).catch((e) => {
  const msg = (e && (e.stack || e.message)) || String(e);
  try { realErr('[pdf-local-read] FAILED to import real server: ' + msg + '\n'); } catch (_) {}
  wp('[wrap] IMPORT FAILED: ' + msg);
});
