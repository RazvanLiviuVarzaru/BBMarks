# 2 parallel builds, 3 batches with compile -j {7 8 9}, 1 repetion per -j
./bench_builds.sh 2 "7 8 12" 1

# One build, varying make parallel 1/8, one batch
./bench_builds.sh 1 1 1
./bench_builds.sh 1 8 1

# 10 parallel builds, -j 2, one batch
./bench_builds.sh 10 2 1

# Queue simulation:10 parallel builders, -j3, 5 batches
./bench_builds.sh 10 3 5   # 5 waves of 10 builds