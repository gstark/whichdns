# Benchmark correctness and system DNS implementation plan

Goal: implement all nine audit findings and compare the current DNS configuration with public resolvers by default.

Architecture: one queued transport driven by explicit query transitions; semantic DNS response classification; category-owned statistics and a shared factual summary; a deduplicated inventory of system, custom, and public endpoints. Preserve the allocation-free core and native macOS CLI.

- [x] Discover macOS resolvers using scutil --dns and Linux resolvers using resolv.conf. Preserve system provenance, deduplicate numeric endpoints, support IPv6 and custom endpoints, expose system-only/public-only selection, and test parsing and failure paths.
- [x] Validate address RDATA and CNAME chains. Classify positive, negative, DNS error, and truncated replies at the DNS boundary. Reproduce malformed/irrelevant records before fixing.
- [x] Replace duplicated server counters with category aggregation. Measure expected successful outcomes only. Compare reliability before latency; recommend only fully successful, characterized resolvers. Test the 90-percent-SERVFAIL ranking regression.
- [x] Replace recursive send/settlement with queued actions. Drain replies before follow-up sends. Use per-server ready scheduling and one initial epoch. Retain and extend loopback/fault tests. Remove the sequential reference runner and blocking transport.
- [x] Share factual summary data between text and JSON; report actual query sends and system provenance. Rename random-name measurements without promising cache misses.
- [x] Make the dashboard fit terminal width and height, redraw safely on resize, and fall back to plain output for dumb terminals.
- [x] Review all changes for spec coverage and maintainability. Run formatting, lint, Debug and ReleaseSafe tests, native release and Linux cross-builds, CLI JSON/list/error smoke tests, and a limited current-system benchmark.

The preceding review supplies the accepted design and reproduction cases. Implement in this session using regression tests and subagent assistance for isolated resolver discovery, followed by independent review. No DNS settings are changed.

## Verification

- 116 tests pass in Debug and ReleaseSafe, including regressions first observed failing for SERVFAIL ranking, malformed A records, extended DNS errors, counter bounds, contradictory NXDOMAIN answers, invalid custom zones, pending-query progress, and literal dots in SOA mailbox labels.
- Formatting, ZLint (zero errors/warnings), and `git diff --check` pass.
- Native Apple Silicon ReleaseSmall and x86_64 Linux musl ReleaseSafe builds pass. Clock calls use Zig's standard libc declarations to avoid an opaque musl C-import timespec.
- CLI JSON inventory identifies four configured endpoints, including IPv6. Invalid custom zones produce one usage error and exit 2.
- PTY checks cover resize from 40x10 to 20x5, periodic redraws, Ctrl-C exit 130 with screen/cursor restoration, and plain output fallback.
- A system-only live run exposed an overly strict SOA mailbox parser: a valid label containing literal dots caused one failure per resolver. A regression test reproduces the response shape; the fix validates SOA wire names without treating their labels as hostnames. See [RFC 1035 section 8](https://www.rfc-editor.org/rfc/rfc1035.html#section-8). The final default-paced rerun is recorded below.
- Independent core and application reviews found no remaining material blockers after the final fixes.
- Final default-paced system-only rerun: four configured endpoints (including IPv6), 824 wire queries, 600/600 successful samples, all four eligible for recommendation. Completed in about 60 seconds.
