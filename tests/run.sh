#!/usr/bin/env bash
# Run every suite. No arguments runs them all; name one or more to run a subset.
#   bash tests/run.sh                # everything available
#   bash tests/run.sh svg gif        # just those
#   bash tests/run.sh --no-render    # skip the browser suite
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-python3}"

want=(); render=1
for a in "$@"; do
  case "$a" in
    --no-render) render=0 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "run.sh: unknown option $a" >&2; exit 2 ;;
    *) want+=("$a") ;;
  esac
done
[ ${#want[@]} -gt 0 ] || want=(svg gif install render)

failed=(); ran=0
for suite in "${want[@]}"; do
  case "$suite" in
    render)
      [ "$render" = 1 ] || continue
      printf '\n\033[1m== render\033[0m\n'
      ran=$((ran + 1))
      "$PY" "$HERE/test_render.py" || failed+=(render)
      ;;
    svg|gif|install)
      [ -f "$HERE/test_$suite.sh" ] || { echo "no suite: $suite" >&2; exit 2; }
      printf '\n\033[1m== %s\033[0m\n' "$suite"
      ran=$((ran + 1))
      bash "$HERE/test_$suite.sh" || failed+=("$suite")
      ;;
    *) echo "run.sh: no such suite: $suite (svg gif install render)" >&2; exit 2 ;;
  esac
done

printf '\n'
if [ ${#failed[@]} -eq 0 ]; then
  printf '\033[32mall %d suite(s) passed\033[0m\n' "$ran"
else
  printf '\033[31mfailed: %s\033[0m\n' "${failed[*]}"; exit 1
fi
