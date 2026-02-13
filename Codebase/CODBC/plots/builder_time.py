import csv, math
import matplotlib.pyplot as plt

path = "bench_results/20260213_161045_C2_PLAN8_12/results.csv"   # change if needed
FILTER_RC0 = False     # set True to only include exit_code==0

# Read rows
rows = []
with open(path, newline="") as f:
    r = csv.DictReader(f)
    for row in r:
        rc = int(row["exit_code"])
        if FILTER_RC0 and rc != 0:
            continue
        rows.append({
            "batch": int(row["batch"]),
            "plan_p": int(row.get("plan_p") or row["make_parallel"]),
            "plan_rep": int(row.get("plan_rep") or 1),
            "dur": float(row["duration_s"]),
        })

if not rows:
    raise SystemExit("No rows found (or everything filtered out).")

# Compute makespan per (plan_p, plan_rep) batch group
# (This matches your 'one batch = one P value & one repetition' model)
by_group = {}
for r in rows:
    key = (r["plan_p"], r["plan_rep"], r["batch"])
    by_group.setdefault(key, []).append(r["dur"])

groups = []
for (P, rep, batch), durs in sorted(by_group.items()):
    makespan = max(durs)
    groups.append((P, rep, batch, makespan))

# Percentile helper (nearest-rank)
def pctl(sorted_vals, p):
    n = len(sorted_vals)
    k = max(1, math.ceil(p*n)) - 1
    return sorted_vals[k]

# Aggregate makespans per P (across reps/batches)
byP = {}
for P, rep, batch, makespan in groups:
    byP.setdefault(P, []).append(makespan)

Ps = sorted(byP.keys())
med = []
p95 = []
mean = []

print("P  n_batches  mean_makespan  median  p95  max")
for P in Ps:
    v = sorted(byP[P])
    n = len(v)
    mean_v = sum(v)/n
    med_v = pctl(v, 0.50)
    p95_v = pctl(v, 0.95)
    print(f"{P:<2} {n:<9} {mean_v:>13.2f} {med_v:>7.2f} {p95_v:>5.2f} {v[-1]:>5.2f}")
    mean.append(mean_v)
    med.append(med_v)
    p95.append(p95_v)

# Plot: scatter per batch + lines per P
plt.figure()

# scatter points (each repetition/batch)
xs = [P for (P, rep, batch, m) in groups]
ys = [m for (P, rep, batch, m) in groups]
plt.scatter(xs, ys, label="batch makespan (each rep)")

# summary lines
plt.plot(Ps, med, marker="o", label="median makespan")
plt.plot(Ps, p95, marker="o", label="p95 makespan")
plt.plot(Ps, mean, marker="o", label="mean makespan")

plt.xlabel("make_parallel (-j)")
plt.ylabel("batch makespan (s)")
plt.title("Batch makespan vs parallelism (max duration per batch)")
plt.legend()
plt.tight_layout()

out = "batch_makespan_vs_parallel.png"
plt.savefig(out, dpi=160)
print("Wrote", out)

