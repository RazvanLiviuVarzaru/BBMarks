#!/bin/bash
#
# Compares two build_bench.sh result directories: median wall time per
# phase, then median time per MTR test, each with the B/A ratio.
#
# Usage: compare.sh RESULTS_A RESULTS_B

set -euo pipefail

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

#######################################
# Prints the commits recorded in a result directory, one per line.
# Arguments:
#   Result directory.
#######################################
commits() {
  sed -n 's/^commit (iteration [0-9]*): //p' "$1/env.txt" | sort -u
}

#######################################
# Prints median milliseconds per test over all iterations of one MTR mode.
# Arguments:
#   Result directory, MTR mode (serial, parallel).
# Outputs:
#   TSV rows: test, median ms. Only passed tests are counted.
#######################################
test_medians() {
  cat "$1"/mtr-"$2"-*.tsv \
    | awk -F'\t' '$2 == "pass" && $3 != "" { print $1 "\t" $3 }' \
    | sort -t$'\t' -k1,1 -k2,2n \
    | awk -F'\t' '
      function flush() {
        if (n) printf "%s\t%s\n", t,
          (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
      }
      $1 != t { flush(); t = $1; n = 0 }
      { v[++n] = $2 }
      END { flush() }'
}

#######################################
# Joins two "key<TAB>value" streams and prints them with the B/A ratio.
# Arguments:
#   File with A values, file with B values, key column title, and
#   optionally "by-ratio" to sort rows by descending ratio.
#######################################
side_by_side() {
  local rows
  rows="$(awk -F'\t' '
    NR == FNR { a[$1] = $2; next }
    ($1 in a) {
      r = (a[$1] > 0) ? sprintf("%.2f", $2 / a[$1]) : "-"
      printf "%s\t%s\t%s\t%s\n", $1, a[$1], $2, r
    }' "$1" "$2")"
  if [[ "${4:-}" == by-ratio ]]; then
    rows="$(sort -t$'\t' -k4,4nr <<<"${rows}")"
  fi
  printf '%s\tA\tB\tB/A\n%s\n' "$3" "${rows}" | column -t -s $'\t'
}

main() {
  local a b mode tmp

  if (( $# != 2 )); then
    err "usage: $0 RESULTS_A RESULTS_B"
    exit 1
  fi
  a="$1"
  b="$2"

  if [[ "$(commits "${a}")" != "$(commits "${b}")" ]]; then
    err "WARNING: the runs built different commits:"
    err "  A: $(commits "${a}" | paste -sd ' ')"
    err "  B: $(commits "${b}" | paste -sd ' ')"
  fi

  echo "A: $(sed -n 's/^host: *//p' "${a}/env.txt") (${a})"
  echo "B: $(sed -n 's/^host: *//p' "${b}/env.txt") (${b})"
  echo
  side_by_side <(tail -n +2 "${a}/summary.tsv") \
    <(tail -n +2 "${b}/summary.tsv") "phase (median s)"

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now, tmp is local
  trap "rm -rf '${tmp}'" EXIT
  for mode in serial parallel; do
    if ! compgen -G "${a}/mtr-${mode}-*.tsv" >/dev/null \
      || ! compgen -G "${b}/mtr-${mode}-*.tsv" >/dev/null; then
      continue
    fi
    test_medians "${a}" "${mode}" >"${tmp}/a"
    test_medians "${b}" "${mode}" >"${tmp}/b"
    echo
    side_by_side "${tmp}/a" "${tmp}/b" "mtr-${mode} test (median ms)" \
      by-ratio
  done
}

main "$@"
