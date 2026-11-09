# Zig craftsmanship implementation plan

> Execute the user-approved review with subagent-driven development and regression tests. Keep changes reviewable.

Goal: fix the six confirmed correctness defects and simplify the existing allocation-free Zig 0.16 design.

Architecture: retain the fixed-capacity event loop and caller-owned buffers. Use error unions at operation boundaries, a tagged lifecycle for socket ownership, explicit rendering/progress dependencies, and a shared POSIX boundary. Remove unused synchronization and redundant helpers.

- [x] Application output: reproduce unwritable stdout; propagate writer failures through report, formatting, and CLI output to exit status. Pass color explicitly. Replace --threads with --queue-depth (1-224, default 224), updating help and README. Adapt bundled progress observer API during integration.
- [x] Core correctness: add regression tests for case-insensitive questions, excessive wire names, double trailing dots, fractional variance, and validation overflow. Run failing tests; fix using checked arithmetic and standard byte operations.
- [x] Transport: add loopback regression rejecting responses from another endpoint and tests for nonblocking sockets. Connect UDP sockets, use explicit error unions, handle EINTR/EAGAIN and poll failures, and guarantee cleanup. Replace resolution flags and socket sentinels with types.
- [x] Core cleanup: remove ResultsLock/atomics, bundle optional progress callback and context, default resolver port to 53, delete dead fields and forwarding helpers, use standard testing assertions and consistent names. Consolidate C imports and correct portability errors.
- [x] Review spec compliance, then code quality; resolve findings. Run native tests, ReleaseSafe tests, formatting, native release build, Linux cross-build, and CLI smoke tests including failed output. Bring verified changes back to the user's workspace.

Regression commands: `zig build test --summary all`, `zig build test -Doptimize=ReleaseSafe`, `zig fmt --check build.zig src`, `zig build -Doptimize=ReleaseSmall`, `zig build -Dtarget=x86_64-linux-gnu --prefix /tmp/whichdns-linux-check`.

Verified: 88 tests pass in Debug and ReleaseSafe; native Debug/ReleaseSmall and Linux cross-build succeed; `just check` passes with zero lint warnings. CLI smoke checks pass for ordinary output, unwritable stdout, broken pipes, and invalid options. Integrated into the original workspace while preserving the concurrent lint tooling changes.
