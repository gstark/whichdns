# whichdns polish implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the tool to whichdns and replace the prototype-grade CLI, dashboard, and report with finished-tool output.

**Architecture:** Split `src/app/main.zig` into `cli`, `term`, `format`, `dashboard`, and `report` modules. `main` only orchestrates. Pure functions (parsing, formatting, column selection, ETA, verdict text) get unit tests through a new app test step. The benchmark core in `src/zig` is untouched except the version string.

**Tech Stack:** Zig 0.16, libc via `@cImport`, no third-party packages.

Spec: `docs/superpowers/specs/2026-10-09-finished-tool-polish-design.md`

---

## File map

| File | Action | Responsibility |
| --- | --- | --- |
| `src/app/main.zig` | rewrite | argv to slice, run, hand off to dashboard and report |
| `src/app/cli.zig` | create | `Options`, `parse`, `writeHelp`, `Diagnostic` |
| `src/app/term.zig` | create | stdout/stderr writers, `Style`, color detection, cursor, SIGINT |
| `src/app/format.zig` | create | `unsigned`, `ms`, `seconds`, `clock`, pad helpers |
| `src/app/dashboard.zig` | create | `Dashboard` struct, progress callback, `etaSeconds` |
| `src/app/report.zig` | create | `Columns`, `selectColumns`, `writeRankedTable`, `writeServerList`, `writeVerdict` |
| `src/app/root_test.zig` | create | aggregates app module tests |
| `build.zig` | modify | binary name, app test step, step descriptions |
| `src/zig/version.zig` | modify | 0.2.0 |
| `justfile`, `scripts/release-macos.sh`, `README.md` | modify | name and docs |

Verification command for every task: `zig build test && zig build`.

---

### Task 1: term.zig and format.zig

**Files:** create `src/app/term.zig`, `src/app/format.zig`, `src/app/root_test.zig`; modify `build.zig`.

- [ ] Add an app test module in `build.zig` rooted at `src/app/root_test.zig` with `link_libc = true` and the `zig_core` import. Hook it to the existing `test` step.
- [ ] `format.zig`: `pub fn unsigned(buf: []u8, v: u64) []const u8`, `pub fn ms(buf: []u8, us: u64) []const u8` (one decimal), `pub fn seconds(buf: []u8, ms_value: u64) []const u8` (one decimal), `pub fn clock(buf: []u8, total_seconds: u64) []const u8` (`m:ss`), `pub fn percent(buf, v) []const u8`.
- [ ] Tests: `ms(14_250) == "14.2"`, `seconds(14_506) == "14.5"`, `clock(64) == "1:04"`, `clock(0) == "0:00"`.
- [ ] `term.zig`: move the stdout writer from main. Add a stderr writer on fd 2. `pub const Style = enum { reset, bold, dim, green, yellow, cyan }` with `code()`. `pub var color_enabled: bool`. `pub fn detectColor(no_color_flag: bool) bool` using `isatty(1)`, `getenv("NO_COLOR")`, `getenv("TERM")`. `pub fn utf8Locale() bool` reads `LC_ALL`, `LC_CTYPE`, `LANG`. `pub fn style(w, s)` writes the code only when color is on. `pub fn hideCursor()`, `showCursor()`, `installInterruptRestore()` (signal handler writes `\x1b[?25h\x1b[0m\n` and `_exit(130)`).
- [ ] Run `zig build test`. Expected: pass.

### Task 2: cli.zig

**Files:** create `src/app/cli.zig`.

- [ ] `pub const Options = struct { timeout_ms: u32 = 1500, iterations: u32 = 3, retries: u32 = 0, pause_ms: u32 = 20, threads: usize = 0, uncached_zone: []const u8 = "", top: usize = 0, wide: bool = false, no_color: bool = false, list_only: bool = false }`.
- [ ] `pub const Action = enum { proceed, show_help, show_version, fail }`.
- [ ] `pub const Diagnostic = struct { buf: [160]u8, len: usize, pub fn text() []const u8 }`. Error messages are formatted into `buf` with `std.fmt.bufPrint`.
- [ ] `pub fn parse(args: []const []const u8, options: *Options, diag: *Diagnostic) Action`. `args` excludes argv[0]. Error forms from the spec.
- [ ] `pub fn writeHelp(w: *std.Io.Writer) void` prints the spec help text. `pub fn writeUsageError(w, diag)` prints `whichdns: <msg>` and the `Try 'whichdns --help'` line.
- [ ] Tests: defaults when empty; each flag sets its field; `--timeout-ms 0` fails with the exact message; `--top` without a value fails with `--top needs a value`; `--bogus` fails with `unknown option '--bogus'`; `--help` returns `.show_help`; `--version` returns `.show_version`; help text contains every flag string.
- [ ] Run `zig build test`. Expected: pass.

### Task 3: report.zig

**Files:** create `src/app/report.zig`.

- [ ] `pub const Column = enum { rank, resolver, address, status, avg, min, max, cached, uncached, dot_com, std_dev, jitter, success, score }` with `header()`, `isNumeric()`, and `cell(row, buf) []const u8`.
- [ ] `pub const Columns = struct { items: [14]Column, len: usize, pub fn slice() }`.
- [ ] `pub fn selectColumns(rows: []const types.RankedRow, wide: bool, uncached_enabled: bool) Columns`. Status appears when wide or any row is not `.reachable`. Uncached appears when wide or `uncached_enabled`. Cached, dot-com, std dev appear when wide.
- [ ] `pub fn writeRankedTable(w, rows, columns)`: measure widths, bold header, dash separator, rows. Status cell colored green or yellow.
- [ ] `pub fn writeServerList(w, servers)`: `Resolver`, `Address`, `Port` headers and the `N built-in resolvers` footer.
- [ ] `pub fn writeVerdict(w, ranked_all: []const types.RankedRow, shown: usize, elapsed_ms: u64)`: `Showing` line (dim, only when shown < total), recommendation line, pass-count line.
- [ ] Tests: `selectColumns` default has 9 columns and no status; wide has 14; uncached enabled adds uncached; a non-reachable row adds status. `writeVerdict` into a fixed buffer writer for the reachable case and the no-reachable case; compare exact strings with color off.
- [ ] Run `zig build test`. Expected: pass.

### Task 4: dashboard.zig

**Files:** create `src/app/dashboard.zig`.

- [ ] `pub const Dashboard = struct { total, validation_total, results, started_us, phase_started_us, last_phase_validating: bool, drawn: bool, last_draw_us, unicode: bool }`.
- [ ] `pub fn init(...)`, `pub fn progress(ctx: ?*anyopaque, done: usize) void` (callback with the 100 ms rate limit), `pub fn draw(self, done)`, `pub fn finish(self, done)` (final draw, show cursor).
- [ ] `pub fn etaSeconds(phase_elapsed_us: u64, done: usize, total: usize) ?u64`: null when `done * 100 < total * 5` or `total == 0`; otherwise `(elapsed * (total - done)) / done`, in seconds.
- [ ] Layout per the spec: label padded to 22, 30-cell bar, percent, `done/total`, elapsed, optional ETA; dim header; ten rows with rank, name 21, address 18, avg ms right 7, success right 5; empty slots print dim `·`.
- [ ] Line count constant `line_count = 2 + 10`; redraw moves up that many lines.
- [ ] Tests: `etaSeconds(1_000_000, 4, 100) == null`; `etaSeconds(10_000_000, 50, 100) == 10`.
- [ ] Run `zig build test`. Expected: pass.

### Task 5: main.zig rewrite

**Files:** rewrite `src/app/main.zig`.

- [ ] Build `args` slice from argv into a `[64][]const u8` stack array; more than 64 arguments fails with `too many arguments`.
- [ ] Dispatch on `cli.parse`: help and version to stdout exit 0, fail prints usage error to stderr exit 2.
- [ ] `--list` writes the server list and exits 0.
- [ ] Detect color, print the two-line banner, run the benchmark with the dashboard callback when interactive, hide cursor and install the SIGINT restore when interactive.
- [ ] On runner or ranking error: show cursor, write `whichdns: benchmark failed: <name>` to stderr, exit 1.
- [ ] After the run: finish the dashboard, write the ranked table with `selectColumns`, then `writeVerdict`.
- [ ] Run `zig build test && zig build && ./zig-out/bin/whichdns --help && ./zig-out/bin/whichdns --bogus; echo $?`. Expected: help text, usage error on stderr, exit 2.

### Task 6: identity

**Files:** modify `build.zig`, `justfile`, `scripts/release-macos.sh`, `src/zig/version.zig`, `README.md`.

- [ ] Binary name `whichdns` in `build.zig`; run step description `Run whichdns`.
- [ ] `justfile` binary variable `whichdns`.
- [ ] Release script: `BINARY_NAME="whichdns"`, target `whichdns-macos-<arch>`.
- [ ] `version.zig`: 0.2.0 in constants, string, and test.
- [ ] README rewritten per the spec section list.
- [ ] Run `scripts/release-macos.sh`. Expected: `Built .../dist/whichdns-macos-arm64`.

### Task 7: end-to-end check

- [ ] Run `./zig-out/bin/whichdns --iterations 1 --timeout-ms 800 --top 8` in a terminal. Check: dashboard draws and clears, cursor returns, table has 9 columns, verdict prints.
- [ ] Run the same piped to a file. Check: no escape codes, no dashboard.
- [ ] Run with `--wide`. Check: 14 columns.
- [ ] Press Ctrl-C mid-run. Check: cursor visible, exit code 130.
