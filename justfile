# Build recipes for whichdns.

binary := "whichdns"
debug_prefix := "zig-out/debug"
release_prefix := "zig-out/release"

# List recipes.
default:
    @just --list

# Build a full debug binary.
debug:
    zig build -Doptimize=Debug -p {{debug_prefix}}
    @echo "Debug binary: {{debug_prefix}}/bin/{{binary}}"

# Build a full ReleaseSmall binary.
release:
    zig build -Doptimize=ReleaseSmall -p {{release_prefix}}
    @echo "Release binary: {{release_prefix}}/bin/{{binary}}"

# Build both binaries.
all: debug release

# Run unit tests.
test:
    zig build test

# Install the pinned linter locally (macOS or Linux).
install-lint:
    sh scripts/install-zlint.sh

# Apply Zig's standard formatting.
fmt:
    zig fmt build.zig src

# Check formatting and community lint rules without modifying source.
lint:
    zig fmt --check build.zig src
    .zig-cache/tools/zlint --config zlint.json --deny-warnings src build.zig

# Run the local quality checks and compile the executable.
check: lint test
    zig build

# Write the gstark/tap formula for a published release (default: the latest).
homebrew tag="":
    sh scripts/homebrew.sh {{tag}}

# Remove build output.
clean:
    /bin/rm -rf zig-out .zig-cache
