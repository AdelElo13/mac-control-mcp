#!/usr/bin/env node
'use strict';

/**
 * End-to-end coverage runner for mac-control-mcp.
 *
 * Spawns the signed, notarized binary from the installed .app bundle,
 * speaks MCP JSON-RPC over stdio, and calls every registered tool at
 * least once. For each tool we use ONE of three strategies:
 *
 *   safe_call         — call with valid args, expect ok=true
 *   invalid_args      — call with missing/bad args, expect isError=true
 *                       with a clean structured reason (no crash)
 *   skip_destructive  — don't call (would alter user state: clipboard
 *                       overwrite, wifi toggle, window shuffle, …)
 *
 * The rationale: "users never hit a surprise error" means every tool
 * that CAN be safely tested returns a clean envelope, and every tool
 * that validates inputs DOES return a structured error rather than a
 * stacktrace. Destructive tools get called by humans / the LLM with
 * real args; the pre-flight validation is what we can test.
 *
 * Exit code: 0 when every tested tool responded with the EXPECTED
 * outcome. Non-zero when any tool crashed / returned an unexpected
 * shape.
 */

const { spawn } = require('child_process');
const path = require('path');
const os = require('os');
const fs = require('fs');

// -----------------------------------------------------------------------------
// Resolve the server binary. Prefer the installed .app bundle (it's the
// artifact users actually run); fall back to .build/debug for dev loops.
// -----------------------------------------------------------------------------
const CANDIDATES = [
  path.join(os.homedir(), 'Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP'),
  path.join(os.homedir(), 'Library/Application Support/Claude/Claude Extensions/local.mcpb.adil-el-ouariachi.mac-control-mcp/MacControlMCP.app/Contents/MacOS/MacControlMCP'),
  path.resolve(__dirname, '../.build/debug/mac-control-mcp'),
];
const BINARY = CANDIDATES.find(p => fs.existsSync(p));
if (!BINARY) {
  console.error('[e2e] no mac-control-mcp binary found. Run build-bundle.sh or swift build first.');
  process.exit(2);
}
console.error(`[e2e] binary: ${BINARY}`);

// -----------------------------------------------------------------------------
// Wire format: NDJSON (newline-delimited JSON). The server accepts both NDJSON
// and Content-Length on input but ONLY emits NDJSON (see MCPProtocol.swift +
// the v0.2.1 release notes — the Claude Desktop MCP client is NDJSON-only,
// so Content-Length outputs would break every production client).
// -----------------------------------------------------------------------------
function frame(obj) {
  return Buffer.from(JSON.stringify(obj) + '\n', 'utf8');
}

function parseFrames(buf) {
  const frames = [];
  let cursor = 0;
  while (cursor < buf.length) {
    const nl = buf.indexOf(0x0a, cursor); // '\n'
    if (nl === -1) break;
    let line = buf.slice(cursor, nl);
    // tolerate trailing \r for \r\n line endings
    if (line.length && line[line.length - 1] === 0x0d) line = line.slice(0, -1);
    cursor = nl + 1;
    if (line.length === 0) continue; // skip blank lines between frames
    const text = line.toString('utf8');
    try {
      frames.push(JSON.parse(text));
    } catch (e) {
      frames.push({ _parseError: e.message, _raw: text });
    }
  }
  return { frames, remainder: buf.slice(cursor) };
}

// -----------------------------------------------------------------------------
// Client driver — sends requests and awaits matching response by id.
// -----------------------------------------------------------------------------
class Client {
  constructor(binary) {
    this.proc = spawn(binary, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.buf = Buffer.alloc(0);
    this.pending = new Map(); // id → {resolve, timer}
    this.nextId = 1;

    this.proc.stdout.on('data', chunk => {
      this.buf = Buffer.concat([this.buf, chunk]);
      const { frames, remainder } = parseFrames(this.buf);
      this.buf = remainder;
      for (const f of frames) {
        const id = f.id;
        if (id != null && this.pending.has(id)) {
          const { resolve, timer } = this.pending.get(id);
          clearTimeout(timer);
          this.pending.delete(id);
          resolve(f);
        }
      }
    });

    this.proc.stderr.on('data', chunk => {
      // Surface stderr for diagnosis but don't fail the test.
      process.stderr.write(`[server stderr] ${chunk}`);
    });

    this.proc.on('exit', (code, sig) => {
      for (const [id, { resolve, timer }] of this.pending) {
        clearTimeout(timer);
        resolve({ id, _serverExited: { code, sig } });
      }
      this.pending.clear();
    });
  }

  request(method, params = {}, timeoutMs = 10000) {
    const id = this.nextId++;
    const req = { jsonrpc: '2.0', id, method, params };
    return new Promise(resolve => {
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          resolve({ id, _timeout: true });
        }
      }, timeoutMs);
      this.pending.set(id, { resolve, timer });
      this.proc.stdin.write(frame(req));
    });
  }

  close() {
    try { this.proc.stdin.end(); } catch {}
    try { this.proc.kill(); } catch {}
  }
}

// -----------------------------------------------------------------------------
// Per-tool test plan. `strategy` ∈ {"safe_call", "invalid_args", "skip"}.
// For safe_call / invalid_args, `args` is what we send. `notes` explains why
// a tool is in the skip list (destructive or requires real UI state).
// -----------------------------------------------------------------------------
const PLAN = {
  // --- Safe: read-only or no-side-effect enumeration ----------------------
  list_apps:                     { strategy: 'safe_call',    args: {} },
  list_displays:                 { strategy: 'safe_call',    args: {}, timeoutMs: 15000 },
  capture_screen:                { strategy: 'skip', notes: 'writes a file; tested elsewhere via Phase 2 suite' },
  focused_app:                   { strategy: 'safe_call',    args: {} },
  permissions_status:            { strategy: 'safe_call',    args: {} },
  clipboard_read:                { strategy: 'safe_call',    args: {} },
  browser_list_tabs:             { strategy: 'safe_call',    args: { browser: 'safari' }, timeoutMs: 25000 },
  browser_get_active_tab:        { strategy: 'safe_call',    args: { browser: 'safari' }, timeoutMs: 25000 },
  list_granted_applications:     { strategy: 'safe_call',    args: {} },
  // Phase 7 reads
  battery_status:                { strategy: 'safe_call',    args: {} },
  system_load:                   { strategy: 'safe_call',    args: {} },
  network_info:                  { strategy: 'safe_call',    args: {} },
  bluetooth_devices:             { strategy: 'safe_call',    args: {} },
  disk_usage:                    { strategy: 'safe_call',    args: {} },
  list_shortcuts:                { strategy: 'safe_call',    args: {} },

  // --- Safe: needs our own pid so there's a real AX tree to walk ----------
  list_elements:                 { strategy: 'safe_call',    args: {}, needsSelfPid: 'pid' },
  list_windows:                  { strategy: 'safe_call',    args: {} },
  get_ui_tree:                   { strategy: 'safe_call',    args: {}, needsSelfPid: 'pid' },
  list_menu_titles:              { strategy: 'safe_call',    args: {}, needsSelfPid: 'pid' },
  list_menu_paths:               { strategy: 'safe_call',    args: { max_depth: 2 }, needsSelfPid: 'pid' },
  find_element:                  { strategy: 'safe_call',    args: { role: 'AXButton' }, needsSelfPid: 'pid' },
  find_elements:                 { strategy: 'safe_call',    args: { role: 'AXButton', limit: 5 }, needsSelfPid: 'pid' },
  query_elements:                { strategy: 'safe_call',    args: { role_regex: '.*', limit: 5 }, needsSelfPid: 'pid' },
  probe_ax_tree:                 { strategy: 'safe_call',    args: {}, needsSelfPid: 'pid' },

  // --- Invalid-args — expect structured validation error ------------------
  click:                         { strategy: 'invalid_args', args: {},              notes: 'requires role/title or x/y' },
  type_text:                     { strategy: 'invalid_args', args: {},              notes: 'requires text' },
  read_value:                    { strategy: 'invalid_args', args: {},              notes: 'requires pid+role/title or element_id' },
  press_key:                     { strategy: 'invalid_args', args: {},              notes: 'requires key' },
  key_down:                      { strategy: 'invalid_args', args: {},              notes: 'requires key' },
  key_up:                        { strategy: 'invalid_args', args: {},              notes: 'requires key' },
  press_key_sequence:            { strategy: 'invalid_args', args: { steps: [] },   notes: 'empty steps rejected' },
  mouse_event:                   { strategy: 'invalid_args', args: {},              notes: 'requires action' },
  drag_and_drop:                 { strategy: 'invalid_args', args: {},              notes: 'requires x1/y1/x2/y2' },
  scroll:                        { strategy: 'invalid_args', args: {}, notes: 'zero/missing delta rejected' },
  convert_coordinates:           { strategy: 'invalid_args', args: {},              notes: 'requires x/y' },
  get_element_attributes:        { strategy: 'invalid_args', args: {},              notes: 'requires element_id' },
  set_element_attribute:         { strategy: 'invalid_args', args: {},              notes: 'requires element_id' },
  perform_element_action:        { strategy: 'invalid_args', args: {},              notes: 'requires element_id' },
  scroll_to_element:             { strategy: 'invalid_args', args: {},              notes: 'requires element_id' },
  focus_window:                  { strategy: 'invalid_args', args: {},              notes: 'requires pid' },
  move_window:                   { strategy: 'invalid_args', args: {},              notes: 'requires pid/index/x/y' },
  resize_window:                 { strategy: 'invalid_args', args: {},              notes: 'requires pid/index/w/h' },
  set_window_state:              { strategy: 'invalid_args', args: {},              notes: 'requires pid/state' },
  move_window_to_display:        { strategy: 'invalid_args', args: {},              notes: 'requires pid/index/display_index' },
  click_menu_path:               { strategy: 'invalid_args', args: {},              notes: 'requires pid/path' },
  capture_window:                { strategy: 'invalid_args', args: {},              notes: 'requires pid' },
  capture_display:               { strategy: 'invalid_args', args: {},              notes: 'requires display_index' },
  ocr_screen:                    { strategy: 'safe_call',    args: {}, timeoutMs: 30000, notes: 'OCR of full screen; slow but valid' },
  browser_navigate:              { strategy: 'invalid_args', args: { browser: 'safari' }, notes: 'requires url', timeoutMs: 20000 },
  browser_new_tab:               { strategy: 'safe_call',    args: { browser: 'safari' }, timeoutMs: 20000, notes: 'browser arg optional (defaults to Safari)' },
  browser_close_tab:             { strategy: 'skip', notes: 'closing a real tab would disrupt the user browsing session' },
  browser_eval_js:               { strategy: 'invalid_args', args: { browser: 'safari' }, notes: 'requires script', timeoutMs: 20000 },
  spotlight_search:              { strategy: 'invalid_args', args: {},              notes: 'requires query' },
  spotlight_open_result:         { strategy: 'skip', notes: 'would confirm the user\'s open Spotlight selection' },
  set_volume:                    { strategy: 'invalid_args', args: {},              notes: 'requires volume' },
  set_dark_mode:                 { strategy: 'invalid_args', args: {},              notes: 'requires enabled' },
  launch_app:                    { strategy: 'invalid_args', args: {},              notes: 'requires bundle_id' },
  activate_app:                  { strategy: 'invalid_args', args: {},              notes: 'requires bundle_id or pid' },
  quit_app:                      { strategy: 'invalid_args', args: {},              notes: 'requires bundle_id or pid' },
  force_quit_app:                { strategy: 'invalid_args', args: {},              notes: 'requires bundle_id or pid' },
  wait_for_element:              { strategy: 'invalid_args', args: {},              notes: 'requires pid + role/title' },
  wait_for_window:               { strategy: 'invalid_args', args: {},              notes: 'requires pid' },
  wait_for_app:                  { strategy: 'invalid_args', args: {},              notes: 'requires bundle_id or name' },
  wait_for_file_dialog:          { strategy: 'invalid_args', args: { timeout_seconds: 0.2 }, timeoutMs: 3000, notes: 'no dialog open → returns isError=true, that is the documented shape' },
  file_dialog_set_path:          { strategy: 'invalid_args', args: {},              notes: 'requires path' },
  file_dialog_select_item:       { strategy: 'invalid_args', args: {},              notes: 'requires name' },
  file_dialog_confirm:           { strategy: 'safe_call',    args: { cancel: true } }, // cancel is the safe no-op path
  file_dialog_cancel:            { strategy: 'safe_call',    args: {} },
  request_permissions:           { strategy: 'safe_call',    args: {} }, // no-op if already granted
  // v0.3.0 Phase 6 — permission control plane
  request_access:                { strategy: 'invalid_args', args: {},              notes: 'requires bundle_id+tier' },
  revoke_access:                 { strategy: 'invalid_args', args: {},              notes: 'requires bundle_id' },
  deny_access:                   { strategy: 'invalid_args', args: {},              notes: 'requires bundle_id' },
  wait_for_ax_notification:      { strategy: 'invalid_args', args: {},              notes: 'requires notification' },
  wait_for_window_state_change:  { strategy: 'invalid_args', args: {},              notes: 'requires pid' },
  // v0.4.0 Phase 7 validation paths
  switch_to_space:               { strategy: 'invalid_args', args: {},              notes: 'requires index 1-9' },
  wifi_set:                      { strategy: 'invalid_args', args: {},              notes: 'requires state' },
  bluetooth_set:                 { strategy: 'invalid_args', args: {},              notes: 'requires state' },
  set_brightness:                { strategy: 'invalid_args', args: {},              notes: 'requires level or direction' },
  night_shift_set:               { strategy: 'invalid_args', args: {},              notes: 'requires state' },
  run_shortcut:                  { strategy: 'invalid_args', args: {},              notes: 'requires name' },
  open_url_scheme:               { strategy: 'invalid_args', args: {},              notes: 'requires url' },
  reveal_in_finder:              { strategy: 'invalid_args', args: { path: '/tmp/__doesnotexist_e2e__' }, notes: 'path-must-exist rejects missing path' },
  quick_look:                    { strategy: 'invalid_args', args: { path: '/tmp/__doesnotexist_e2e__' }, notes: 'path-must-exist rejects missing path' },
  trash_file:                    { strategy: 'invalid_args', args: { path: '/etc/hosts' }, notes: 'refuses paths outside $HOME' },
  right_click:                   { strategy: 'invalid_args', args: {},              notes: 'requires x/y' },
  double_click:                  { strategy: 'invalid_args', args: {},              notes: 'requires x/y' },

  // --- Skip destructive or user-disrupting --------------------------------
  clipboard_write:               { strategy: 'skip', notes: 'overwrites user clipboard' },
  clipboard_clear:               { strategy: 'skip', notes: 'overwrites user clipboard' },
  mission_control:               { strategy: 'skip', notes: 'disrupts UI' },
  app_expose:                    { strategy: 'skip', notes: 'disrupts UI' },
  launchpad:                     { strategy: 'skip', notes: 'disrupts UI' },
  show_desktop:                  { strategy: 'skip', notes: 'disrupts UI' },
  notification_center_toggle:    { strategy: 'skip', notes: 'disrupts UI' },
  control_center_toggle:         { strategy: 'skip', notes: 'disrupts UI' },
  open_airplay_preferences:      { strategy: 'skip', notes: 'opens Settings pane' },
};

// Safe-call tools that need the runner's own pid filled in.
function fillSelfPid(plan) {
  const selfPid = process.pid; // NB: runner pid != server pid, but server spawned by us — for AX testing we use runner's parent pid approach below
  return plan;
}

// -----------------------------------------------------------------------------
// Coverage runner
// -----------------------------------------------------------------------------
async function main() {
  const client = new Client(BINARY);

  // 1. initialize
  const initRes = await client.request('initialize', {
    protocolVersion: '2024-11-05',
    capabilities: {},
    clientInfo: { name: 'e2e-coverage', version: '1.0' },
  });
  if (!initRes || initRes._timeout) {
    console.error('[e2e] initialize timed out — server not responding');
    client.close();
    process.exit(2);
  }
  console.error(`[e2e] server: ${initRes.result?.serverInfo?.name} v${initRes.result?.serverInfo?.version}`);

  // 2. tools/list
  const listRes = await client.request('tools/list', {}, 10000);
  const tools = listRes?.result?.tools || [];
  console.error(`[e2e] server exposes ${tools.length} tools`);

  // 3. Run plan per tool
  const results = { passed: [], failed: [], skipped: [], uncovered: [] };
  const pidArg = await getFrontmostSafePid(client); // for "needsSelfPid" plans

  for (const tool of tools) {
    const name = tool.name;
    const item = PLAN[name];
    if (!item) {
      results.uncovered.push(name);
      continue;
    }
    if (item.strategy === 'skip') {
      results.skipped.push({ name, notes: item.notes });
      continue;
    }

    // Fill in self-pid placeholder if needed
    let args = { ...item.args };
    if (item.needsSelfPid && pidArg != null) {
      args[item.needsSelfPid] = pidArg;
    }

    const res = await client.request('tools/call', { name, arguments: args }, 10000);
    const err = res?._timeout
      ? { reason: 'timeout' }
      : res?._serverExited
        ? { reason: 'server_exited', code: res._serverExited.code }
        : res?.error
          ? { reason: 'json_rpc_error', error: res.error }
          : null;

    if (err) {
      results.failed.push({ name, strategy: item.strategy, err });
      continue;
    }
    const toolRes = res?.result || {};
    const isError = toolRes.isError === true;

    const ok =
      (item.strategy === 'safe_call' && !isError) ||
      (item.strategy === 'invalid_args' && isError);

    if (ok) {
      results.passed.push({ name, strategy: item.strategy });
    } else {
      results.failed.push({
        name,
        strategy: item.strategy,
        mismatch: item.strategy === 'safe_call' ? 'expected ok but got isError' : 'expected isError but got ok',
        payload: toolRes,
      });
    }
  }

  client.close();

  // 4. Report
  const total = tools.length;
  const covered = results.passed.length + results.failed.length + results.skipped.length;
  console.log('');
  console.log('='.repeat(78));
  console.log(` e2e-coverage report`);
  console.log('='.repeat(78));
  console.log(` server tools:          ${total}`);
  console.log(` tested (pass):         ${results.passed.length}`);
  console.log(` tested (fail):         ${results.failed.length}`);
  console.log(` skipped (destructive): ${results.skipped.length}`);
  console.log(` uncovered (no plan):   ${results.uncovered.length}`);
  console.log('');

  if (results.failed.length) {
    console.log('FAILURES:');
    for (const f of results.failed) {
      console.log(`  ✗ ${f.name} [${f.strategy}] — ${f.mismatch || JSON.stringify(f.err)}`);
      if (f.payload && process.env.VERBOSE) {
        console.log(`      payload: ${JSON.stringify(f.payload).slice(0, 200)}…`);
      }
    }
    console.log('');
  }

  if (results.uncovered.length) {
    console.log('UNCOVERED (add to PLAN):');
    for (const n of results.uncovered) console.log(`  ? ${n}`);
    console.log('');
  }

  if (results.skipped.length && process.env.VERBOSE) {
    console.log('SKIPPED (destructive):');
    for (const s of results.skipped) console.log(`  - ${s.name}: ${s.notes}`);
    console.log('');
  }

  const exitCode = results.failed.length === 0 && results.uncovered.length === 0 ? 0 : 1;
  process.exit(exitCode);
}

// -----------------------------------------------------------------------------
// Helper — get a pid that belongs to an AX-enabled app so the "needsSelfPid"
// plans have a real tree to walk. Falls back to the frontmost app's pid.
// -----------------------------------------------------------------------------
async function getFrontmostSafePid(client) {
  const res = await client.request('tools/call', { name: 'focused_app', arguments: {} });
  try {
    const sc = res?.result?.structuredContent;
    const pid = sc?.app?.pid ?? sc?.pid;
    if (typeof pid === 'number') return pid;
  } catch {}
  return null;
}

main().catch(err => {
  console.error('[e2e] runner crashed:', err);
  process.exit(3);
});
