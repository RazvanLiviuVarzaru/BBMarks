# Build performance comparison

Compares machines (for example bare metal with dedicated storage against a
cloud VM with shared storage) by configuring, compiling and testing MariaDB
server 10.11 from source in the `bb-worker:debian12` container.

Nothing is mounted. The clone, build directory and MTR vardir all live in the
container's filesystem, so the storage measured is whatever backs docker
(`docker info --format '{{.DockerRootDir}}'`). ccache is disabled. MTR does
not run with `--mem`.

## Phases

| Phase | What it does | Mostly measures |
|---|---|---|
| `clone` | `git clone --depth 1` + submodules | network (reported, not comparable) |
| `configure` | `cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo` | single core, small file I/O |
| `compile` | `cmake --build -j<jobs>` | CPU, metadata and small file I/O |
| `mtr-serial` | fixed test list, `--parallel=1 --noreorder` | fsync latency, same order every run |
| `mtr-parallel` | same list, `--parallel=<jobs>` | I/O under concurrency (order across workers varies) |

The test list is in `build_bench.sh` (`TESTS`): InnoDB redo log, doublewrite,
import/export, undo truncation, purge and buffer pool resizing,
mariabackup, binlog and mysqldump for I/O, plus charset, JSON, optimizer,
decimal and prepared statement tests for CPU. None of them need a debug build
or `--big-test`.

## Running

Run on the first machine:

```bash
./build_bench.sh --jobs 8
```

Use the commit it printed in `env.txt` on the second machine, with the same
`--jobs`, so both build the same source:

```bash
./build_bench.sh --jobs 8 --commit <sha from the first run>
```

Options: `--jobs N` (default 8), `--iterations K` (default 1, fresh container
each time), `--branch` (default `10.11`), `--commit SHA`, `--image`,
`--out DIR` (default `./results/<host>-<timestamp>`).

## Results

Each run writes to its `--out` directory:

- `env.txt`: CPU, memory, kernel, virtualization, docker storage and the
  backing device, image digest, commit
- `phases.tsv`: per phase wall, user and sys seconds, and host PSI stall
  seconds (`/proc/pressure/io` and `cpu`)
- `summary.tsv`: median wall time per phase
- `mtr-{serial,parallel}-<i>.tsv`: per test result and milliseconds
- `<phase>-<i>.log`: raw output

Copy both result directories to one place and compare them:

```bash
./compare.sh results/baremetal-… results/cloudvm-…
```

This prints phase medians and per test medians side by side with the B/A
ratio, with the tests that differ most listed first. It warns if the two runs
built different commits.
