#!/usr/bin/env bash
# Run every suite. No arguments runs them all; name one or more to run a subset.
#   bash tests/run.sh                # everything available (fakes only, no quota spent)
#   bash tests/run.sh svg gif        # just those
#   bash tests/run.sh --no-render    # skip the browser suite
#   bash tests/run.sh real           # opt-in: against a real provider, spends plan allowance
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
[ ${#want[@]} -gt 0 ] || want=(delegate svg gif install render)
# "real" is opt-in only -- it spends real plan allowance, so it is never in the default set and
# must be named explicitly, same as --no-render opts the browser suite out.

failed=(); ran=0
for suite in "${want[@]}"; do
  case "$suite" in
    render)
      [ "$render" = 1 ] || continue
      printf '\n\033[1m== render\033[0m\n'
      ran=$((ran + 1))
      "$PY" "$HERE/test_render.py" || failed+=(render)
      ;;
    delegate|svg|gif|install|real)
      [ -f "$HERE/test_$suite.sh" ] || { echo "no suite: $suite" >&2; exit 2; }
      printf '\n\033[1m== %s\033[0m\n' "$suite"
      ran=$((ran + 1))
      bash "$HERE/test_$suite.sh" || failed+=("$suite")
      ;;
    *) echo "run.sh: no such suite: $suite (delegate svg gif install render real)" >&2; exit 2 ;;
  esac
done

printf '\n'
if [ ${#failed[@]} -eq 0 ]; then
  printf '\033[32mall %d suite(s) passed\033[0m\n' "$ran"
else
  printf '\033[31mfailed: %s\033[0m\n' "${failed[*]}"; exit 1
fi
