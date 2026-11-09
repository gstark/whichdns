# whichdns

Compare DNS resolvers from your Mac or Linux machine. `whichdns` benchmarks your
current system DNS configuration alongside 125 public resolvers, then ranks
usable resolvers by reliability first and successful lookup latency second.
It runs natively on Apple Silicon and provides a terminal dashboard or JSON Lines.
It never changes your DNS settings.

## Why whichdns

whichdns is inspired by [DNS Benchmark](https://www.grc.com/dns/benchmark.htm)
by Steve Gibson at GRC. The general idea and the measurements follow DNS Benchmark.
Like DNS Benchmark, whichdns times three types of lookup for each resolver:
cached names, random subdomains of popular domains, and random `.com` names.
Random names do not guarantee cache misses. See
[What the benchmark measures](#what-the-benchmark-measures).

DNS Benchmark is a Windows program. There is no native version for ARM, and no
native x86 version for macOS or Linux. You can run it under Wine, but that is
not a good substitute. whichdns runs natively on macOS and Linux, on both ARM
and x86.

whichdns can also write its progress and results as JSON Lines, so scripts and
AI agents can use the results.

## Build and run

Requires Zig 0.16 and the system C library. No project runtime dependencies.
Zig 0.17 cannot build this release. `sh scripts/install-zig.sh` installs a
checksum-verified Zig 0.16.0 into `.zig-cache/tools/zig-0.16.0/`; CI uses it too.

```sh
zig build -Doptimize=ReleaseSmall
./zig-out/bin/whichdns --top 10
```

A default run uses three passes and normally takes about three minutes plus
validation. Each successful pass has 50 samples in each of three categories.

```sh
whichdns --list                     # inspect system + public endpoints
whichdns --system-only --list       # inspect the current DNS configuration
whichdns --system-only              # benchmark just configured resolvers
whichdns --public-only --top 10     # benchmark the public catalog
whichdns --server 192.168.1.1        # add a custom endpoint to the default inventory
whichdns --server '[::1]:5353,10.0.0.1' # custom IPv6 and port, comma-separated lists
whichdns --add-server 192.168.1.1    # save a custom endpoint for every future run
whichdns --remove-server 192.168.1.1 # forget it again
whichdns --system-only --iterations 1 --json > results.jsonl
```

System endpoints are marked `[system]` in reports and `S` in the live dashboard.
The inventory merges duplicate numeric address/port/scope combinations. A public
resolver that is also configured locally keeps its public name and system marker.

On macOS discovery reads `scutil --dns`, including VPN and scoped resolver entries.
On Linux it reads `/etc/resolv.conf`, including a local stub resolver if configured.
Both IPv4 and IPv6 endpoints are supported. IPv6 link-local addresses retain their
interface scopes, such as `fe80::1%en0`.

Queries go directly to each discovered endpoint. This compares those servers;
it does not simulate macOS per-domain routing or guarantee that a VPN-only resolver
will answer public names. A local caching proxy is measured as configured, including
its forwarding behavior. Multiple configured endpoints may share an upstream.

If discovery fails, the default run warns and uses public/custom endpoints.
`--system-only` fails instead of silently benchmarking something else. Custom
endpoints are additional to the selected system/public inventory.

## Saved custom servers

`--add-server` saves endpoints to a configuration file, and every later run
includes them as custom endpoints. `--remove-server` deletes them again. Both
options accept comma-separated lists, repeat, edit the file, report each
endpoint, and exit without benchmarking. `--no-config` skips the file for one run.

The file is `$XDG_CONFIG_HOME/whichdns/servers` when `XDG_CONFIG_HOME` is an
absolute path, otherwise `$HOME/.config/whichdns/servers`. It holds one numeric
endpoint per line; `#` starts a comment. whichdns creates missing directories
with owner-only permissions. Endpoints compare numerically, so `1.1.1.1` and
`1.1.1.1:53` are the same entry. An invalid line fails the run with its line
number. Removing an endpoint that is not saved exits with status 1.

## Options

| Option | Meaning |
| --- | --- |
| `--system-only` | Use configured resolvers, plus any custom endpoints |
| `--public-only` | Skip system discovery; use the public catalog plus custom endpoints |
| `--server LIST` | Add numeric endpoints, comma-separated; repeatable, up to 32 per run |
| `--add-server LIST` | Save endpoints to the configuration file and exit |
| `--remove-server LIST` | Delete endpoints from the configuration file and exit |
| `--no-config` | Ignore the saved custom servers for this run |
| `--top N` | Display only the best N rows; all selected resolvers are still tested |
| `--iterations N` | Full passes, 1–100; default 3 |
| `--timeout-ms N` | Per-query deadline, 1–60000; default 1500 |
| `--retries N` | Additional attempts for transient benchmark failures, 0–10; default 0 |
| `--pause-ms N` | Interval between samples to one resolver, 0–5000; default 400 |
| `--queue-depth N` | Maximum outstanding queries across resolvers, 1–224; default 224 |
| `--random-zone ZONE` | Use this zone for random-subdomain queries |
| `--wide` | Include status, minimum, maximum, and cached standard deviation |
| `--no-color` | Disable colors; also honors `NO_COLOR` |
| `--json` | Write events as JSON Lines on stdout |
| `--list` | Print the selected, deduplicated inventory and exit |
| `--version` | Print the version |
| `-h`, `--help` | Print help |

`--system-only` and `--public-only` are mutually exclusive, and so are
`--add-server` and `--remove-server`. Endpoints accept
`1.1.1.1`, `127.0.0.1:5353`, `::1`, or `[fe80::1%en0]:53`. Hostnames are rejected
so resolving a benchmark target cannot depend on another DNS server.

Exit codes: 0 for a completed run, 1 for a runtime/output failure, 2 for invalid
arguments. A completed run can have no recommendable resolver; inspect its summary.

## What the benchmark measures

Every pass rotates through 50 popular domains and runs these categories:

- **Cached:** an A query primes the name, then a second query to the same socket
  measures its successful address lookup. A failed prime counts as a failed
  benchmark attempt and does not contribute latency.
- **Random subdomain:** an A query for a run-specific random label beneath each
  popular domain, or beneath `--random-zone`. Valid address, NXDOMAIN, and
  validated NODATA outcomes count as successful lookups.
- **Random .com:** an A query for a random label directly beneath `.com`.
  NXDOMAIN and validated NODATA count as successful lookups. An address response
  disqualifies the resolver as redirecting/intercepting unknown names.

Random names do **not** guarantee cache misses or authoritative-server queries.
DNSSEC proofs and wildcard data can let a resolver synthesize an answer from its
cache. These columns measure random-name lookup latency, not verified cold-cache
recursion. See [RFC 8198](https://www.rfc-editor.org/info/rfc8198/).

Before measurement, every resolver must return an expected negative response to
a random nonexistent TLD and pass five positive A/AAAA probes. Validation can retry
one transient failure. Resolvers failing characterization receive no timed work.
Answers must match the question and contain a valid requested address, possibly
through a bounded CNAME chain. NODATA requires a well-formed SOA for the relevant
zone. DNS errors, malformed replies, and truncated responses never add to successful
latency. The tool benchmarks UDP only; it does not follow truncation with TCP.

One connected socket per resolver keeps its source port stable. There is at most
one outstanding query to each resolver, with concurrency across resolvers. Initial
send offsets share one starting time. Low `--pause-ms` values may trigger resolver
rate limits and change the result. The default cached workload also sends priming
queries, so sample frequency and packet frequency differ.

## Ranking and conclusions

A usable resolver has passed characterization and produced a successful measured
outcome in every category. Usable resolvers sort before diagnostic rows. Within
that group, the exact success ratio sorts first, then the equally weighted mean
of the three successful category means. Resolver name/address/port break ties.

`Score` is the successful-attempt ratio scaled to 0–1000 for usable resolvers;
it does not hide a latency penalty. The displayed integer success percentage
can tie while the exact ratios differ. Failed replies never make an average faster.
Jitter and standard deviation use successful cached samples only.

A resolver that times out on 5 benchmark attempts in a row is dropped. It gets no
more queries, and its status is `dropped` ("stopped responding"). Its success
percentage covers only the attempts made before the drop. Without this rule, an
unresponsive resolver costs a full timeout for every remaining sample and
delays the end of the run by many minutes.

A recommendation requires every recorded benchmark attempt to succeed. Retries
remain separate attempts, so a recovered timeout still affects reliability.
If none qualifies, the summary explicitly declines to recommend a resolver.
The summary reports actual wire queries sent, including primes and retries,
rather than claiming every resolver received the planned query count.

Run again at another time of day before changing settings. Benchmarks are snapshots.

## Terminal and JSON output

A capable terminal shows a live dashboard that redraws in place on the normal
screen, so scrollback keeps only the final report. The dashboard fits the current
width and height. On completion it is replaced by the report. Ctrl-C or SIGTERM
leaves the last frame visible and restores the cursor. Piped output and
`TERM=dumb` use plain reports.

During benchmarking, the ETA follows the slowest unfinished resolver, because
each resolver's samples are paced separately.

```sh
whichdns --json | jq -c 'select(.type == "progress") | [.phase, .percent]'
whichdns --json | jq 'select(.type == "result" and .sources.system)'
whichdns --json --top 3 | jq 'select(.type == "summary") | .fastest'
```

Each JSON line is flushed immediately. Events are `start`, `progress`, `result`,
and a final `summary`. Discovery fallback may emit a `warning` before `start`.
Failures emit `error` with `kind`, `message`, and `code` when stdout is writable.
`--list --json` emits `server` records; `--version --json` emits `version`.
`--add-server --json` and `--remove-server --json` emit one `config` record per
endpoint with `path`, `address`, `port`, and `change` (`added`, `already_present`,
`removed`, or `absent`). Configuration file failures use error kind `config`.
`--help` always prints text. JSON mode writes no normal diagnostics to stderr.

Endpoint-bearing records include `address`, `port`, and
`"sources":{"system":true,"custom":false,"public":false}`. Result records also
include `attempts`, `resolved`, `queries_sent`, `recommendable`, `status`, `score`,
`success_percent`, and integer microsecond measurements: `avg_us`, `min_us`,
`max_us`, `std_dev_us`, `cached_avg_us`, `random_subdomain_avg_us`, and
`random_com_avg_us`. Zero latency with zero resolved attempts means no measurement.

Summary fields include `resolver_count`, `system_count`, `reachable_count`,
`reliable_count`, `shown_count`, `queries_sent`, `attempts`, `resolved`, `elapsed_ms`,
and `fastest`. Counts cover the entire run regardless of `--top`. `fastest` is
`null` when no resolver met recommendation criteria.

Version 0.3 replaces `--uncached-zone` with `--random-zone` and the JSON fields
`uncached_avg_us` / `dot_com_avg_us` with
`random_subdomain_avg_us` / `random_com_avg_us`. The start configuration uses
`random_zone`. Ranking and score semantics also changed as described above.

## Development

```sh
just install-lint                 # pinned checksum-verified ZLint
just check                        # formatting, lint, tests, debug build
zig build test -Doptimize=ReleaseSafe
just release                      # zig-out/release/bin/whichdns
scripts/release-macos.sh           # tested, stripped native macOS artifact
```

The allocation-free core lives in `src/core/`; the CLI and discovery live in
`src/app/`. `query_session.zig` owns pure lifecycle transitions,
`udp_queued_runner.zig` owns socket I/O, `dns_packet.zig` owns parsing and semantic
classification, and `ranking.zig` owns ranking and the shared summary.
There is one production benchmark engine. Tests use its session transitions and
local UDP responders, including malformed/error replies, deadlines, retries,
source-port filtering, priming, pacing, and exact query accounting.

## License

MIT. See [LICENSE](LICENSE).
