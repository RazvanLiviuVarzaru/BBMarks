#!/bin/bash
#
# Benchmark configuring, compiling and testing MariaDB server from source
# inside a container, to compare machines (CPU and storage).
#
# Everything happens in the container's own filesystem (no mounts), so the
# storage measured is the one backing docker on this machine.
#
# Usage: build_bench.sh [--jobs N] [--iterations K] [--branch B]
#                       [--commit SHA] [--image IMAGE] [--out DIR]

set -euo pipefail

readonly REPO="https://github.com/MariaDB/server"
readonly PHASES=(clone configure compile mtr-serial mtr-parallel)

# I/O heavy: redo log, doublewrite, tablespace import, undo truncation,
# purge, buffer pool resize, backups, binlog, dump.
# CPU heavy: charsets, JSON, optimizer, decimal arithmetic, prepared
# statements.
# None of them need a debug build or --big-test.
readonly TESTS=(
  innodb.log_file_size_online
  innodb.doublewrite
  innodb.innodb-wl5522
  innodb.undo_truncate
  innodb.purge_secondary
  innodb.instant_alter
  innodb.innodb_buffer_pool_resize
  mariabackup.full_backup
  mariabackup.incremental_backup
  mariabackup.xb_partition
  binlog.binlog_innodb
  main.mysqldump
  main.ctype_utf8mb4
  main.func_json
  main.subselect
  main.join
  main.type_newdecimal
  main.derived
  main.ps
)

jobs=8
iterations=1
branch="10.11"
commit=""
image="quay.io/mariadb-foundation/bb-worker:debian12"
out=""
container="bench-$$"

usage() {
  sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
}

log() {
  echo "[$(date +'%H:%M:%S')] $*"
}

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
}

#######################################
# Prints the cumulative "some" stall time of a PSI resource, in seconds.
# Arguments:
#   PSI resource name (io, cpu).
# Outputs:
#   Seconds with millisecond precision, nothing if PSI is unavailable.
#######################################
psi_total() {
  awk '/^some/ { split($5, a, "="); printf "%.3f", a[2] / 1e6 }' \
    "/proc/pressure/$1" 2>/dev/null || true
}

#######################################
# Runs a command in the container as one timed phase.
# Globals:
#   container, out
# Arguments:
#   Iteration number, phase name, shell command to run in the container.
# Outputs:
#   Appends a row to phases.tsv, writes the command output to
#   <phase>-<iteration>.log.
# Returns:
#   Exit status of the command.
#######################################
run_phase() {
  local iter="$1" phase="$2" cmd="$3"
  local logfile="${out}/${phase}-${iter}.log"
  local io0 cpu0 io1 cpu1 t0 t1 times user sys
  local rc=0

  log "iteration ${iter}: ${phase}"
  io0="$(psi_total io)"
  cpu0="$(psi_total cpu)"
  t0="$(date +%s.%N)"
  times="$(docker exec "${container}" bash -c \
    "TIMEFORMAT='%U %S'; { time ( ${cmd} ) >/tmp/phase.log 2>&1; } 2>&1")" \
    || rc=$?
  t1="$(date +%s.%N)"
  io1="$(psi_total io)"
  cpu1="$(psi_total cpu)"
  docker cp "${container}:/tmp/phase.log" "${logfile}" >/dev/null 2>&1 \
    || true

  read -r user sys <<<"${times:-- -}"
  awk -v i="${iter}" -v p="${phase}" -v t0="${t0}" -v t1="${t1}" \
    -v u="${user}" -v s="${sys}" -v io0="${io0}" -v io1="${io1}" \
    -v c0="${cpu0}" -v c1="${cpu1}" -v rc="${rc}" '
    function d(a, b) {
      return (a == "" || b == "") ? "-" : sprintf("%.3f", b - a)
    }
    BEGIN {
      printf "%s\t%s\t%.3f\t%s\t%s\t%s\t%s\t%s\n",
        i, p, t1 - t0, u, s, d(io0, io1), d(c0, c1), rc
    }' >>"${out}/phases.tsv"
  log "iteration ${iter}: ${phase} done in" \
    "$(awk -v a="${t0}" -v b="${t1}" 'BEGIN { printf "%.1f", b - a }')s" \
    "(exit ${rc})"
  return "${rc}"
}

#######################################
# Extracts per-test results from an MTR log.
# Arguments:
#   MTR log file.
# Outputs:
#   TSV rows: test (with combination, if any), result, milliseconds.
#######################################
parse_mtr() {
  local q="'"
  local name="([a-z_0-9]+\.[^ ]+( ${q}[^${q}]*${q})?)"
  local result="\[ (pass|fail|skipped|disabled) \]"
  sed -nE "s/^${name} +(w[0-9]+ +)?${result} *([0-9]*).*/\1\t\4\t\5/p" \
    "$1"
}

#######################################
# Writes host, docker and build settings to env.txt.
# Globals:
#   out, image, branch, jobs, iterations, TESTS
#######################################
write_env() {
  local digest docker_root dev

  digest="$(docker image inspect --format '{{index .RepoDigests 0}}' \
    "${image}" 2>/dev/null || echo "${image}")"
  docker_root="$(docker info --format '{{.DockerRootDir}}')"
  dev="$(findmnt -no SOURCE -T "${docker_root}" 2>/dev/null || true)"
  {
    echo "host:           $(hostname -f 2>/dev/null || hostname)"
    echo "date:           $(date -Is)"
    echo "cpu:            $(lscpu | sed -n 's/^Model name: *//p' | head -1)"
    echo "nproc:          $(nproc)"
    echo "memory:         $(free -h | awk '/^Mem:/ { print $2 }')"
    echo "kernel:         $(uname -r)"
    echo "virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"
    echo "docker:         $(docker version --format '{{.Server.Version}}')"
    echo "storage driver: $(docker info --format '{{.Driver}}')"
    echo "docker root:    ${docker_root}"
    echo "backing fs:     $(findmnt -no SOURCE,FSTYPE,OPTIONS \
      -T "${docker_root}" 2>/dev/null || true)"
    if [[ -b "${dev}" ]]; then
      echo "block device:   $(lsblk -sno NAME,TYPE,ROTA,MODEL "${dev}" \
        | tr -s ' ' | paste -sd ';')"
    fi
    echo "image:          ${digest}"
    echo "branch:         ${branch}"
    echo "jobs:           ${jobs}"
    echo "iterations:     ${iterations}"
    echo "tests:          ${TESTS[*]}"
  } >"${out}/env.txt"
}

#######################################
# Writes the median wall time per phase over all iterations.
# Globals:
#   out, PHASES
# Outputs:
#   summary.tsv
#######################################
write_summary() {
  local phase
  {
    printf 'phase\tmedian_wall_s\truns\n'
    for phase in "${PHASES[@]}"; do
      awk -F'\t' -v p="${phase}" '$2 == p { print $3 }' \
        "${out}/phases.tsv" \
        | sort -n \
        | awk -v p="${phase}" '
          { v[NR] = $1 }
          END {
            if (!NR) exit
            m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
            printf "%s\t%.1f\t%d\n", p, m, NR
          }'
    done
  } >"${out}/summary.tsv"
}

#######################################
# Runs one clone/configure/compile/MTR cycle in a fresh container.
# Globals:
#   container, image, branch, commit, jobs, out, REPO, TESTS
# Arguments:
#   Iteration number.
#######################################
run_iteration() {
  local iter="$1"
  local sha mode par

  cleanup
  docker run -d --name "${container}" -e CCACHE_DISABLE=1 \
    "${image}" sleep infinity >/dev/null

  # Clone is network bound; it is timed but reported apart from the rest
  if ! run_phase "${iter}" clone "
      set -e
      cd ~
      git clone -q --depth 1 --branch '${branch}' '${REPO}' server
      cd server
      if [[ -n '${commit}' && \"\$(git rev-parse HEAD)\" != '${commit}' ]]
      then
        git fetch -q --depth 1 origin '${commit}'
        git checkout -q FETCH_HEAD
      fi
      git submodule -q update --init --recursive --depth 1"; then
    err "clone failed, see ${out}/clone-${iter}.log"
    return 1
  fi

  sha="$(docker exec "${container}" \
    git -C /home/buildbot/server rev-parse HEAD)"
  echo "commit (iteration ${iter}): ${sha}" >>"${out}/env.txt"
  # Later iterations use the same commit even if the branch moved
  commit="${commit:-${sha}}"

  run_phase "${iter}" configure \
    "cmake -S ~/server -B ~/build -DCMAKE_BUILD_TYPE=RelWithDebInfo" \
    || return 1
  run_phase "${iter}" compile "cmake --build ~/build -j${jobs}" \
    || return 1

  for mode in serial parallel; do
    if [[ "${mode}" == serial ]]; then
      par=1
    else
      par="${jobs}"
    fi
    # MTR exits non-zero on test failures; the run still counts
    run_phase "${iter}" "mtr-${mode}" "
      unset MTR_MEM
      cd ~/build/mysql-test
      perl mysql-test-run.pl --parallel=${par} --noreorder --force \
        --max-test-fail=0 --retry=0 ${TESTS[*]}" || true
    parse_mtr "${out}/mtr-${mode}-${iter}.log" \
      >"${out}/mtr-${mode}-${iter}.tsv"
  done
}

main() {
  local i

  while (( $# > 0 )); do
    case "$1" in
      --jobs) jobs="$2"; shift 2 ;;
      --iterations) iterations="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --commit) commit="$2"; shift 2 ;;
      --image) image="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        err "unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done

  out="${out:-./results/$(hostname -s)-$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "${out}"
  out="$(cd "${out}" && pwd)"

  if (( jobs > $(nproc) )); then
    err "WARNING: --jobs ${jobs} is larger than nproc ($(nproc))"
  fi

  trap cleanup EXIT

  log "pulling ${image}"
  docker pull -q "${image}" >/dev/null
  write_env
  printf 'iteration\tphase\twall_s\tuser_s\tsys_s\tio_stall_s' \
    >"${out}/phases.tsv"
  printf '\tcpu_stall_s\texit\n' >>"${out}/phases.tsv"

  for (( i = 1; i <= iterations; i++ )); do
    run_iteration "${i}" || err "iteration ${i} aborted"
  done

  write_summary
  log "results in ${out}"
  column -t -s $'\t' "${out}/summary.tsv"
}

main "$@"
