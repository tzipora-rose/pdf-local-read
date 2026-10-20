// Copyright (C) 2026 tzipora-rose
// Copyright (C) 2024-2025 Model Context Protocol a Series of LF Projects, LLC
//
// This file is part of pdf-local-read.
//
// pdf-local-read is free software: you can redistribute it and/or modify it under the
// terms of the GNU Affero General Public License, version 3, as published by
// the Free Software Foundation.
//
// pdf-local-read is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
// more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with pdf-local-read. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-only

// check-schema-dialect.mjs   [ marker: PDF-LOCAL-READ-SCHEMACHECK ]
//
// Builds the INSTALLED pdf-viewer server in this process, asks it for its tool list over the MCP
// protocol the way a client does, and runs every tool's output schema through a model of the gate
// Claude Code applies before it will send a tools/call. Read-only: writes nothing, opens no network.
//
//   node check-schema-dialect.mjs [--dist <pdf-viewer dist folder>]
//
// Exit 0 = PASS, 1 = FAIL, 2 = could not run. The last line printed is always the verdict.
//
// The gate model is Claude Code 2.1.281's (its bundled MCP SDK's default AjvJsonSchemaValidator,
// which refuses any schema whose $schema is not JSON Schema 2020-12). It proves only what it was
// transcribed from: if a later Claude Code changes that gate, re-read the gate from the new code.
//
// Quoted code: DIALECTS_2020 and the test of $schema in makeGate, the options both Ajv instances are made with,
// and the lookup of a schema by its $id repeat the MCP TypeScript SDK's AjvJsonSchemaValidator. The SDK's code is
// under the MIT License and the Apache License 2.0, as its license file sets out; a copy, as published, is in
// third-party/modelcontextprotocol/LICENSE.

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const out = (s = '') => { process.stdout.write(s + '\n'); };
function finish(code, verdict) {
  process.stdout.write(verdict + '\n', () => process.exit(code));
}
setTimeout(() => finish(2, 'COULD NOT RUN - no verdict within 60 s'), 60000).unref();

function resolveDist() {
  const i = process.argv.indexOf('--dist');
  if (i !== -1) {
    const v = process.argv[i + 1];
    if (!v) return { error: '--dist needs a folder' };
    return { dist: path.resolve(v), how: '--dist' };
  }
  if (process.env.PDF_VIEWER_DIST) return { dist: path.resolve(process.env.PDF_VIEWER_DIST), how: 'PDF_VIEWER_DIST' };
  const rel = ['Claude', 'Claude Extensions', 'ant.dir.gh.anthropic.pdf-server-mcp', 'dist'];
  const tried = [];
  if (process.env.LOCALAPPDATA) tried.push(path.join(process.env.LOCALAPPDATA, 'Packages', 'Claude_pzs8sxrjxfjjc', 'LocalCache', 'Roaming', ...rel));
  if (process.env.APPDATA) tried.push(path.join(process.env.APPDATA, ...rel));
  for (const d of tried) if (fs.existsSync(path.join(d, 'server.js'))) return { dist: d, how: "the app's extension folder" };
  return { error: 'pdf-viewer dist folder not found (tried: ' + (tried.join(' ; ') || 'LOCALAPPDATA and APPDATA are unset') + '); pass --dist <folder>' };
}

// A client-side stand-in for the stdio pipe: the server's replies come back through send().
class MemoryTransport {
  #waiting = new Map();
  async start() {}
  async close() {}
  async send(message) {
    const done = message && message.id !== undefined ? this.#waiting.get(message.id) : undefined;
    if (done) { this.#waiting.delete(message.id); done(message); }
  }
  request(id, method, params) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#waiting.delete(id); reject(new Error(method + ': no response within 15 s')); }, 15000);
      this.#waiting.set(id, (m) => { clearTimeout(timer); resolve(m); });
      this.onmessage({ jsonrpc: '2.0', id, method, params });
    });
  }
  notify(method) { this.onmessage({ jsonrpc: '2.0', method }); }
}

const DIALECTS_2020 = new Set(['https://json-schema.org/draft/2020-12/schema', 'http://json-schema.org/draft/2020-12/schema']);

function makeGate(Ajv2020, addFormats) {
  let ajv;
  return (schema) => {
    if ('$schema' in schema && typeof schema.$schema === 'string' && !DIALECTS_2020.has(schema.$schema.replace(/#$/, ''))) {
      return { ok: false, why: 'declares ' + schema.$schema + ', and the gate accepts only 2020-12' };
    }
    if (!ajv) { ajv = new Ajv2020({ strict: false, validateFormats: true, validateSchema: false, allErrors: true }); addFormats(ajv); }
    try {
      const v = ('$id' in schema && typeof schema.$id === 'string') ? (ajv.getSchema(schema.$id) ?? ajv.compile(schema)) : ajv.compile(schema);
      return { ok: true, validate: (d) => (v(d) ? null : ajv.errorsText(v.errors)) };
    } catch (e) {
      return { ok: false, why: 'does not compile: ' + e.message };
    }
  };
}

function makeV1Client(Ajv, addFormats) {
  let ajv;
  return (schema) => {
    if (!ajv) { ajv = new Ajv({ strict: false, validateFormats: true, validateSchema: false, allErrors: true }); addFormats(ajv); }
    try {
      const v = ajv.compile(schema);
      return { ok: true, validate: (d) => (v(d) ? null : ajv.errorsText(v.errors)) };
    } catch (e) {
      return { ok: false, why: 'does not compile: ' + e.message };
    }
  };
}

// display_pdf's valid result must keep the shape of one the real server produced (this one did, with only its
// path made generic), or a PASS proves nothing about real results.
const SAMPLES = {
  display_pdf: {
    good: { viewUUID: '7fb725bc-4b92-42f1-9c38-b0ca3d4f6f47', url: 'C:/Users/example/Documents/sample.pdf', initialPage: 1, totalBytes: 47026 },
    broken: [
      ['viewUUID missing', { url: 'C:/x.pdf', initialPage: 1, totalBytes: 1 }],
      ['totalBytes as a string', { viewUUID: 'u', url: 'C:/x.pdf', initialPage: 1, totalBytes: '47026' }],
      ['a form field with an unknown key', { viewUUID: 'u', url: 'C:/x.pdf', initialPage: 1, totalBytes: 1, formFields: [{ name: 'n', type: 't', page: 1, x: 0, y: 0, width: 1, height: 1, extra: 1 }] }],
    ],
  },
  read_pdf_bytes: {
    good: { url: 'C:/x.pdf', bytes: '', offset: 0, byteCount: 0, totalBytes: 0, hasMore: false },
    broken: [['hasMore missing', { url: 'C:/x.pdf', bytes: '', offset: 0, byteCount: 0, totalBytes: 0 }]],
  },
  save_pdf: {
    good: { filePath: 'C:/x.pdf', mtimeMs: 1 },
    broken: [['mtimeMs as a string', { filePath: 'C:/x.pdf', mtimeMs: '1' }]],
  },
};

async function main() {
  const r = resolveDist();
  if (r.error) return finish(2, 'COULD NOT RUN - ' + r.error);
  const { dist, how } = r;
  out('dist: ' + dist + '  (from ' + how + ')');
  if (!fs.existsSync(path.join(dist, 'server.js'))) return finish(2, 'COULD NOT RUN - no server.js in ' + dist);

  let ver = 'unknown';
  try { ver = JSON.parse(fs.readFileSync(path.join(dist, '..', 'manifest.json'), 'utf8')).version; } catch {}

  const req = createRequire(path.join(dist, '..', 'package.json'));
  let Ajv2020, Ajv, addFormats;
  let noValidator = '';
  try {
    const m20 = req('ajv/dist/2020'); Ajv2020 = m20.default || m20.Ajv2020 || m20;
    const m07 = req('ajv'); Ajv = m07.default || m07.Ajv || m07;
    const mf = req('ajv-formats'); addFormats = mf.default || mf;
  } catch (e) {
    // pdf-viewer 2.0.0 ships no ajv: then only the gate's first rule, the declared dialect, can be tested here.
    noValidator = e.message;
  }

  const muted = [];
  const saved = {};
  let server;
  for (const k of ['log', 'info', 'warn', 'error', 'debug']) { saved[k] = console[k]; console[k] = (...a) => { muted.push(a.join(' ')); }; }
  try {
    const mod = await import(pathToFileURL(path.join(dist, 'server.js')).href);
    if (typeof mod.createServer !== 'function') throw new Error('server.js exports no createServer');
    server = mod.createServer({ enableInteract: true });
  } catch (e) {
    Object.assign(console, saved);
    return finish(2, 'COULD NOT RUN - the installed server could not be built: ' + e.message);
  }
  Object.assign(console, saved);

  const t = new MemoryTransport();
  let tools;
  try {
    await server.connect(t);
    const init = await t.request(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'check-schema-dialect', version: '1.0.0' } });
    if (init.error) throw new Error('initialize: ' + init.error.message);
    t.notify('notifications/initialized');
    const listed = await t.request(2, 'tools/list', {});
    if (listed.error) throw new Error('tools/list: ' + listed.error.message);
    tools = (listed.result && listed.result.tools) || [];
  } catch (e) {
    return finish(2, 'COULD NOT RUN - the protocol exchange with the server failed: ' + e.message);
  }

  const withSchema = tools.filter((x) => x.outputSchema);
  out('server: pdf-viewer ' + ver + ', ' + tools.length + ' tools listed, ' + withSchema.length + ' with an output schema');
  const display = withSchema.find((x) => x.name === 'display_pdf');
  if (!display) return finish(2, 'COULD NOT RUN - the tool list has no display_pdf with an output schema, so there is nothing this check knows how to judge');

  if (noValidator) {
    const declares2020 = (s) => !('$schema' in s) || (typeof s.$schema === 'string' && DIALECTS_2020.has(s.$schema.replace(/#$/, '')));
    const off = [];
    for (const tool of withSchema) {
      const ok = declares2020(tool.outputSchema);
      if (!ok) off.push(tool.name);
      out('  ' + tool.name.padEnd(15) + ' $schema=' + (tool.outputSchema.$schema ?? '(none)') + '  gate: ' + (ok ? 'pass (dialect)' : 'BLOCKED (dialect)'));
    }
    if (declares2020({ ...display.outputSchema, $schema: 'http://json-schema.org/draft-07/schema#' })) {
      return finish(2, 'COULD NOT RUN - the dialect test accepted a draft-07 schema, so its verdicts mean nothing');
    }
    out("control: the dialect test refuses display_pdf's schema re-declared as draft-07, so it is armed");
    out('note: this extension ships no JSON Schema validator (' + noValidator.split('\n')[0] + '), so validation itself was not tested');
    if (off.length) return finish(1, "FAIL - Claude Code's gate blocks " + off.join(', ') + ' (an output schema declares a dialect other than 2020-12)');
    return finish(0, 'PASS (dialect only) - all ' + withSchema.length + ' output schemas declare JSON Schema 2020-12');
  }

  const gate = makeGate(Ajv2020, addFormats);
  const v1 = makeV1Client(Ajv, addFormats);
  const blocked = [];
  const problems = [];
  for (const tool of withSchema) {
    const s = tool.outputSchema;
    const parts = ['$schema=' + (s.$schema ?? '(none)')];
    const g = gate(s);
    if (!g.ok) {
      blocked.push(tool.name);
      parts.push('gate: BLOCKED (' + g.why + ')');
      out('  ' + tool.name.padEnd(15) + ' ' + parts.join('  '));
      continue;
    }
    parts.push('gate: pass');
    const sm = SAMPLES[tool.name];
    if (sm) {
      const err = g.validate(sm.good);
      if (err) { problems.push(tool.name + ': a valid result was rejected (' + err + ')'); parts.push('valid result: REJECTED'); }
      else parts.push('valid result: accepted');
      let rejected = 0;
      for (const [label, sample] of sm.broken) {
        if (g.validate(sample)) rejected++;
        else problems.push(tool.name + ': a broken result was accepted (' + label + ')');
      }
      parts.push('broken results: ' + rejected + '/' + sm.broken.length + ' rejected');
    }
    const c = v1(s);
    if (!c.ok) { problems.push(tool.name + ': an SDK 1.x client cannot compile it (' + c.why + ')'); parts.push('SDK 1.x client: CANNOT COMPILE'); }
    else if (sm && c.validate(sm.good)) { problems.push(tool.name + ': an SDK 1.x client rejects a valid result'); parts.push('SDK 1.x client: REJECTS a valid result'); }
    else parts.push('SDK 1.x client: accepts');
    out('  ' + tool.name.padEnd(15) + ' ' + parts.join('  '));
  }

  const redeclared = { ...display.outputSchema, $schema: 'http://json-schema.org/draft-07/schema#' };
  if (makeGate(Ajv2020, addFormats)(redeclared).ok) {
    problems.push('the gate model accepted a draft-07 schema, so its verdicts mean nothing');
    out('control: FAILED - the gate model accepted display_pdf\'s schema re-declared as draft-07');
  } else {
    out("control: the gate model refuses display_pdf's schema re-declared as draft-07, so it is armed");
  }

  if (blocked.length) {
    for (const p of problems) out('  - ' + p);
    return finish(1, "FAIL - Claude Code's gate blocks " + blocked.join(', ') + ' (draft-07 output schemas); install-pdf-read.ps1 with the app closed applies the fix');
  }
  if (problems.length) {
    for (const p of problems) out('  - ' + p);
    return finish(1, 'FAIL - ' + problems.length + ' problem(s); first: ' + problems[0]);
  }
  return finish(0, 'PASS - all ' + withSchema.length + " output schemas pass Claude Code's gate, and validation still rejects broken results");
}

main().catch((e) => finish(2, 'COULD NOT RUN - ' + ((e && e.message) || e)));
