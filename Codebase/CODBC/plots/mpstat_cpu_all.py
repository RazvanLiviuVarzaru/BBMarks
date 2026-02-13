import re
from datetime import datetime, timedelta
import matplotlib.pyplot as plt

path = "bench_results/20260213_161045_C2_PLAN8_12/mon/mpstat.txt"   # change if needed

# Find the date in the mpstat header (e.g. 02/13/2026)
date_re = re.compile(r'(\d{2}/\d{2}/\d{4})')
line_re = re.compile(
    r'^(\d{2}:\d{2}:\d{2})\s+(AM|PM)\s+(\S+)\s+'
    r'([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+'
    r'([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s*$'
)

with open(path, "r", errors="ignore") as f:
    txt = f.read()

m = date_re.search(txt)
if not m:
    raise SystemExit("Could not find date like MM/DD/YYYY in mpstat header.")
base_date = datetime.strptime(m.group(1), "%m/%d/%Y").date()

times = []
busy = []
usrsys = []
iowait = []

prev_dt = None
for line in txt.splitlines():
    mm = line_re.match(line.strip())
    if not mm:
        continue

    hhmmss, ampm, cpu = mm.group(1), mm.group(2), mm.group(3)
    if cpu != "all":
        continue

    # columns (same as mpstat header): %usr %nice %sys %iowait %irq %soft %steal %guest %gnice %idle
    usr = float(mm.group(4))
    sys = float(mm.group(6))
    iw  = float(mm.group(7))
    idle = float(mm.group(13))

    dt = datetime.strptime(f"{base_date} {hhmmss} {ampm}", "%Y-%m-%d %I:%M:%S %p")
    # handle midnight rollover if file crosses days
    if prev_dt and dt < prev_dt:
        dt = dt + timedelta(days=1)
    prev_dt = dt

    times.append(dt)
    busy.append(100.0 - idle)
    usrsys.append(usr + sys)
    iowait.append(iw)

if not times:
    raise SystemExit("No 'CPU=all' samples found. Did you run: mpstat -P ALL 1 ?")

plt.figure()
plt.plot(times, busy, label="busy (100-idle)")
plt.plot(times, usrsys, label="usr+sys")
plt.plot(times, iowait, label="iowait")
plt.xlabel("time")
plt.ylabel("percent")
plt.title("CPU utilisation over time (CPU=all)")
plt.legend()
plt.tight_layout()
out = "cpu_util.png"
plt.savefig(out, dpi=160)
print("Wrote", out)
