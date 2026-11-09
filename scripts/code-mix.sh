#!/usr/bin/env sh
# Reports the maintained Zig/C source mix by file count and line count.
#
# Usage: scripts/code-mix.sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

ZIG_FILES=$(find build.zig src -name '*.zig' -type f 2>/dev/null | sort)
C_FILES=$(find src tests -name '*.c' -o -name '*.h' 2>/dev/null | sort || true)

printf 'Zig files:\n'
printf '%s\n' $ZIG_FILES

printf '\nC/C header files:\n'
if [ -n "$C_FILES" ]; then
  printf '%s\n' $C_FILES
else
  printf '  none\n'
fi

printf '\nLine counts:\n'
printf '  Zig: '
# shellcheck disable=SC2086
wc -l $ZIG_FILES | awk 'END {print $1}'
printf '  C/C headers: '
if [ -n "$C_FILES" ]; then
  # shellcheck disable=SC2086
  wc -l $C_FILES | awk 'END {print $1}'
else
  printf '0\n'
fi

printf '\nC files linked by Zig build:\n'
LINKED_C=$(awk '/addCSourceFiles/,/flags/ { if ($0 ~ /".*\.c"/) { gsub(/["]/, ""); gsub(/^[ \t]+/, ""); print "  " $0 } }' build.zig)
if [ -n "$LINKED_C" ]; then
  printf '%s\n' "$LINKED_C"
else
  printf '  none\n'
fi
