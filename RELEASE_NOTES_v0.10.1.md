# mac-control-mcp v0.10.1

A maintenance release. It fixes the four failure patterns that showed up most often in a month of real agent use, taken from the tool-failure log of one heavily used install (Claude Code, Claude Desktop and Codex on the same Mac). No tool was removed or renamed; every new parameter is optional.

## `mcp_server_info` no longer tells you to kill working sessions

v0.10.0 listed every other `MacControlMCP` process and suggested `kill <all of them>`. Every MCP client runs its own server, so on a busy machine that list held the live servers of every other Claude Code, Claude Desktop and Codex session, plus Claude Desktop's `disclaimer` wrapper processes. Anyone following the hint broke mac-control in all of them; on the reporting machine that was 21 processes, all of them in use.

Each other instance is now classified:

- `connected`: its client is alive. Leave it alone.
- `outdated`: its client is alive but it runs a different build. Restart that client to load the new one.
- `orphaned`: its client is gone (the process was re-parented to launchd). Only these, plus their wrapper, appear in the `kill` suggestion.

`other_instances` entries now carry `parent_pid`, `client` (`Claude Desktop`, `Claude Code`, `Codex` or the program name), `client_pid`, `version` (read from the bundle's Info.plist) and `status`. Wrapper processes are no longer counted as server instances.

## Screenshots can be written to an agent's scratchpad

`output_path` refused Claude Code's scratchpad (`/tmp/claude-<uid>/…`), the directory agents are told to use for temporary files. Every `/tmp` path was rejected because another user could swap a path component between validation and the write.

That risk is absent when the first directory below `/tmp` is a real directory owned by you with mode `0700`, because nobody else can create, rename or replace anything inside it. Such directories are now accepted, with the check done through `lstat`, so a symlink in that position does not count. `/tmp` itself and group- or world-accessible directories stay rejected. The error message names the accepted locations.

## `wait_for_window` accepts the arguments agents actually send

Calls with `app`, `title` or `timeout_ms` failed or silently waited the 5 s default.

- **Targets:** `pid`, `bundle_id` or `app`/`name` (Dock name, case-insensitive). A name or bundle id is resolved again on every poll, so the tool also waits for an app that is still launching.
- **Aliases:** `title` works as an alias of `title_contains`. `timeout_ms` and `timeout` (seconds) are aliases of `timeout_seconds`. `timeout_seconds` wins when more than one is given; the maximum stays 60 s.
- **Timeouts:** a timeout reports `app_running`, which says whether the app was never found or was found without a matching window.

## `activate_app` verifies the app is really in front

- **Running check:** a `bundle_id` of an app that is not running returned `Could not activate app.` It now returns `error_code: not_running` with a hint to use `launch_app`.
- **Verified front:** `ok: true` used to mean only that macOS accepted the request. Since macOS 14, the system may ignore activation requests from background processes. `activate_app` now checks `frontmostApplication`. When the app is not in front it retries through the Accessibility attribute `AXFrontmost`, then through a LaunchServices open of the running app.
  - `ok` is true only when the app is verified frontmost.
  - `status` is `activated`, `not_running` or `activation_refused`.
  - `method` says which step worked; `frontmost` reports the app that is actually in front.
- **Name targets:** `name` and its alias `app` accept the Dock name. Among several processes with the same bundle id, the regular (Dock) app is preferred over helpers. Hidden apps are unhidden first.

## Tests

Fifteen new tests in `V0_10_1FixesTests`:

- process-table parsing and instance classification, including wrappers, orphans behind a wrapper and outdated builds;
- reading the bundle version;
- private `/tmp` directories against shared ones, traversal and planted symlinks;
- the `wait_for_window` aliases and errors;
- app resolution by pid, bundle id and name;
- `activate_app` against an app that is not running.

The full suite (785 tests) was run twice on this branch and twice on `main`. On both branches the same two tests fail in a full run:

- the 50 ms wall-clock guard for search aliases (measured 67–77 ms under full-suite load);
- the strict Finder menu baseline in `RealAppMatrixTests`.

Both pass when run alone, on both branches. The ControlZoo matrix failed once with `-25204` in one full-suite run on this branch, then passed in two isolated runs.
