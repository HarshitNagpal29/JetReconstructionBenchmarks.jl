# Thread Scaling Benchmarks

This document describes the thread-scaling workflow for
`JetReconstruction.jl` event-level benchmarks. It is intended to be run from
the root of this repository.

The workflow is:

```text
src/thread-run.jl
    one benchmark run for one workload and one Julia thread count

src/thread-benchmark-all.sh
    run a full workload suite, merge the JSON results, and make the standard plots

src/thread-scan.sh
    a small driver that runs thread-run.jl for several thread counts

src/merge-thread-scan.jl
    merge the JSON files and compute speedup and parallel efficiency

src/plot-thread-scan.jl
    plot speedup, efficiency, or throughput from the merged CSV
```

For most use cases, use the JSON workflow:

```text
thread-scan.sh -> JSON files -> merge-thread-scan.jl -> summary CSV -> plot-thread-scan.jl
```

The older `src/thread-scan-legacy.sh` script is kept as a simple CSV smoke test,
but it does not record the same metadata and is not recommended for systematic
runs.

The examples below use [`jq`](https://jqlang.org) to inspect JSON files. `jq` is
optional; it is not required by the Julia scripts.

## Input Files

The repository contains compressed HepMC3 input files under `data/`. Useful
starting points are:

```text
data/events-pp-0.5TeV-5GeV.hepmc3.gz     small pp input
data/events-pp-8TeV-20GeV.hepmc3.gz      medium pp input
data/events-pp-30TeV-50GeV.hepmc3.gz     high pp input
data/events-ee-Z.hepmc3.gz               e+e- input
```

For pp studies, common first workloads are:

```text
AntiKt  N2Plain
AntiKt  N2Tiled
CA      N2Plain
CA      N2Tiled
Kt      N2Plain
Kt      N2Tiled
```

For e+e- studies, start with:

```text
Durham  N2Plain
```

Use a thread list that includes one thread:

```text
1 2 4 8
```

The one-thread result is required for speedup and efficiency.

## Single Run

`src/thread-run.jl` runs one workload with the Julia thread count selected by
`julia --threads`.

Example:

```sh
julia --threads=1 --project=. src/thread-run.jl \
  -A AntiKt \
  -S N2Plain \
  -R 0.4 \
  --repeats 1 \
  --nsamples 5 \
  --warmup-events 10 \
  --output results/thread-scaling/example/AntiKt-N2Plain-small-t1.json \
  data/events-pp-0.5TeV-5GeV.hepmc3.gz
```

`--julia-scheduler` selects `default`, `dynamic`, `static`, `greedy`, or
`chunked_atomic` for both warmup and timed loops. `greedy` requires Julia 1.11
or later. The default is Julia's normal `@threads` scheduler.
`chunked_atomic` starts one stable worker per Julia thread; workers claim
disjoint event ranges from an atomic counter. Use `--chunk-size` to control the
number of events in each claim (default: 8); the option can be omitted.

`--gcoff` is a diagnostic option. Warmup runs with normal garbage collection;
GC is disabled only inside each timed sample, then re-enabled and explicitly
run before the next sample. GC-on and GC-off results are distinct workloads and
should not be interpreted as interchangeable throughput measurements.

The JSON output contains:

- run parameters: algorithm, strategy, radius, input file, repeats, samples,
  Julia scheduler, and GC mode
- timing fields: wall time, events/s, time per event
- allocation and GC fields
- raw per-sample measurements under `samples`
- summary statistics under `summary`
- reproducibility metadata: Julia version, hardware, Git commit, package source

The top-level timing values use the fastest sample, following the historical
benchmark convention. For scaling plots and merged summaries, use the median
fields in `summary`; `merge-thread-scan.jl` does this automatically.

If `jq` is available, inspect a result with:

```sh
jq '{success, algorithm, strategy, julia_threads, measured_events, summary}' \
  results/thread-scaling/example/AntiKt-N2Plain-small-t1.json
```

## Thread Sweep

Use `src/thread-scan.sh` to run the same workload for several thread counts. It
writes one JSON file per thread count.

Usage:

```sh
./src/thread-scan.sh --outdir OUTDIR [OPTIONS]
```

Options:

```text
-o, --outdir OUTDIR              output directory for JSON files (required)
-A, --algorithm ALGORITHM        AntiKt, CA, Kt, Durham, ...
-S, --strategy STRATEGY          N2Plain or N2Tiled
-i, --input-file INPUT_FILE      HepMC3 input file
-l, --label LABEL                short label used in filenames, e.g. small
-t, --threads THREADS            quoted list of thread counts, e.g. "1 2 4 8"
-n, --nsamples NSAMPLES          timed samples per thread count
-r, --repeats REPEATS            full event-sample repeats per timed sample
-w, --warmup-events EVENTS       events processed before timing starts
-g, --gcoff                      disable GC during each timed sample
-j, --julia-scheduler SCHEDULER  default, dynamic, static, greedy, or chunked_atomic
-c, --chunk-size N               optional atomic claim size (default: 8)
-R, --radius RADIUS              radius parameter, typically 0.4 for pp workloads
```

Example:

```sh
./src/thread-scan.sh \
  --outdir results/thread-scaling/small/AntiKt-N2Plain \
  --algorithm AntiKt \
  --strategy N2Plain \
  --input-file data/events-pp-0.5TeV-5GeV.hepmc3.gz \
  --label small \
  --threads "1 2 4 8" \
  --nsamples 5 \
  --repeats 1 \
  --warmup-events 10 \
  --radius 0.4
```

Expected files:

```text
results/thread-scaling/small/AntiKt-N2Plain/AntiKt-N2Plain-small-t1.json
results/thread-scaling/small/AntiKt-N2Plain/AntiKt-N2Plain-small-t2.json
results/thread-scaling/small/AntiKt-N2Plain/AntiKt-N2Plain-small-t4.json
results/thread-scaling/small/AntiKt-N2Plain/AntiKt-N2Plain-small-t8.json
```

A non-default scheduler adds `-SCHEDULER` after the strategy. A chunked-atomic
scan also adds `-cN`, recording its chunk size. GC-off adds `-gcoff`, so scans
with different execution modes do not overwrite one another. For example,
`AntiKt-N2Plain-chunked_atomic-c8-gcoff-small-t8.json` uses the default chunk
size of eight events.

Check the run:

```sh
jq -r '[input_filename, .success, .algorithm, .strategy, .julia_threads, .summary.events_per_second_median] | @tsv' \
  results/thread-scaling/small/AntiKt-N2Plain/*.json
```

Every row should have `success` equal to `true`.

## Full Benchmark Campaign

Use `src/thread-benchmark-all.sh` to run a complete benchmark campaign from one
command. It runs `src/thread-scan.sh` for each workload in the selected suite,
merges the JSON files into one summary CSV, and creates the standard efficiency,
speedup, and throughput plots.

The thread list is chosen from powers of two, round tens from 20 upward, and the
requested maximum thread count. Nearby points are filtered to avoid spending
time on almost identical thread counts. For example, `--max-threads 40` gives a
scan like:

```text
1 2 4 8 16 20 30 40
```

Supported workload suites are:

```text
pp      AntiKt/CA/Kt with N2Plain and N2Tiled
ee      Durham with N2Plain
all     both pp and ee workloads
```

The full campaign accepts the same `--gcoff`, `--julia-scheduler`, and optional
`--chunk-size` options. Generated plots group by GC mode and scheduler.

Example:

```sh
./src/thread-benchmark-all.sh \
  --outdir results/thread-scaling/full-small \
  --input-file data/events-pp-0.5TeV-5GeV.hepmc3.gz \
  --label small \
  --max-threads 20 \
  --suite pp \
  --nsamples 5 \
  --repeats 1 \
  --warmup-events 10 \
  --radius 0.4
```

For a quick command preview without running benchmarks:

```sh
./src/thread-benchmark-all.sh \
  --outdir results/thread-scaling/full-small \
  --input-file data/events-pp-0.5TeV-5GeV.hepmc3.gz \
  --label small \
  --max-threads 20 \
  --suite pp \
  --dry-run
```

By default, the script refuses to write into a non-empty output directory. Use
`--force` only when intentionally reusing an existing output directory.

The main outputs are:

```text
results/thread-scaling/full-small/summary.csv
results/thread-scaling/full-small/plots/
```

## FastJet Thread Scaling

The Julia thread-scaling workflow above uses `thread-run.jl` and writes JSON.
FastJet is benchmarked through the existing `src/benchmark.jl` CSV path instead:

```text
benchmark.jl --code Fastjet -> CSV files -> merge-thread-scan.jl -> summary CSV -> plot-thread-scan.jl
```

This keeps the two timing paths simple:

```text
JetReconstruction.jl     run with julia --threads=N
FastJet                  run benchmark.jl --worker-threads=N, forwarded to fastjet-finder --threads N
```

Build `fastjet-finder` with OpenMP before running multi-threaded FastJet
benchmarks:

```sh
cmake -S fastjet -B fastjet/build -DFASTJET_ENABLE_OPENMP=ON
cmake --build fastjet/build
```

For serial FastJet baseline timings, build without OpenMP:

```sh
cmake -S fastjet -B fastjet/build
cmake --build fastjet/build
```

Run one FastJet point with `benchmark.jl`:

```sh
julia --threads=1 --project=. src/benchmark.jl \
  --code Fastjet \
  -A AntiKt \
  -S N2Plain \
  -R 0.4 \
  --nsamples 10 \
  --worker-threads 4 \
  --schedule dynamic \
  --results results/benchmark-scan/small/fastjet/Fastjet-AntiKt-N2Plain-small-t4-dynamic.csv \
  data/events-pp-0.5TeV-5GeV.hepmc3.gz
```

`benchmark.jl` will decompress `.gz` inputs when needed because the FastJet
reader expects plain `.hepmc3` input. The Julia process itself can usually run
with `--threads=1` for FastJet points; the measured thread count is the
`--worker-threads` value that `benchmark.jl` passes to `fastjet-finder`.

For a small FastJet scan:

```sh
mkdir -p results/benchmark-scan/small/fastjet

for threads in 1 2 4 8; do
  julia --threads=1 --project=. src/benchmark.jl \
    --code Fastjet \
    -A AntiKt \
    -S N2Plain \
    -R 0.4 \
    --nsamples 10 \
    --worker-threads "$threads" \
    --schedule dynamic \
    --results "results/benchmark-scan/small/fastjet/Fastjet-AntiKt-N2Plain-small-t${threads}-dynamic.csv" \
    data/events-pp-0.5TeV-5GeV.hepmc3.gz
done
```

For comparison, run the matching Julia points either with `thread-scan.sh` or
with `benchmark.jl`. The `thread-scan.sh` route records more metadata:

```sh
./src/thread-scan.sh \
  --outdir results/benchmark-scan/small/julia/AntiKt-N2Plain \
  --algorithm AntiKt \
  --strategy N2Plain \
  --input-file data/events-pp-0.5TeV-5GeV.hepmc3.gz \
  --label small \
  --threads "1 2 4 8" \
  --nsamples 10 \
  --repeats 1 \
  --warmup-events 10 \
  --radius 0.4
```

Merge both formats with the same script:

```sh
julia --project=. src/merge-thread-scan.jl \
  results/benchmark-scan/small/julia/*/*.json \
  results/benchmark-scan/small/fastjet/*.csv \
  results/benchmark-scan/small/summary.csv
```

When plotting a mixed Julia/FastJet summary, include the backend and schedule in
the line grouping. The default `--group-by algorithm,strategy,R,p` is suitable
for Julia-only plots, but it will mix backends if a summary contains both Julia
and FastJet rows.

```sh
julia --project=. src/plot-thread-scan.jl \
  results/benchmark-scan/small/summary.csv \
  results/benchmark-scan/small/plots \
  --metric efficiency \
  --group-by code,backend,algorithm,strategy,R,p,gcoff,schedule \
  --title "Small pp input"

julia --project=. src/plot-thread-scan.jl \
  results/benchmark-scan/small/summary.csv \
  results/benchmark-scan/small/plots \
  --metric throughput \
  --group-by code,backend,algorithm,strategy,R,p,gcoff,schedule \
  --title "Small pp input" \
  --no-ideal
```

FastJet supports `static`, `dynamic`, and `guided` OpenMP schedules. For small
inputs, `dynamic` can be more stable because event costs are not perfectly
uniform. Record the schedule in the CSV and keep it in the plot grouping when
comparing schedules.

To sanity-check FastJet without the Julia wrapper, run the executable directly
on the uncompressed input:

```sh
fastjet/build/fastjet-finder \
  -A AntiKt \
  -p -1 \
  -s N2Plain \
  -R 0.4 \
  --ptmin 5.0 \
  -m 10 \
  -t 4 \
  --schedule dynamic \
  data/events-pp-0.5TeV-5GeV.hepmc3
```

When interpreting mixed-backend scaling, compare throughput or time per event
as well as efficiency. A backend with a faster one-thread baseline can show a
lower parallel efficiency while still being faster in absolute time. Very short
small-input runs are also noisy; increase `nsamples`, increase `repeats`, or
use a higher-multiplicity input for more stable comparisons.

## Example Workload Matrix

The commands below run a small pp strategy comparison:

```sh
mkdir -p results/thread-scaling/small

./src/thread-scan.sh -o results/thread-scaling/small/AntiKt-N2Plain -A AntiKt -S N2Plain -i data/events-pp-0.5TeV-5GeV.hepmc3.gz -l small -t "1 2 4 8" -n 5 -r 1 -w 10 -R 0.4
./src/thread-scan.sh -o results/thread-scaling/small/AntiKt-N2Tiled -A AntiKt -S N2Tiled -i data/events-pp-0.5TeV-5GeV.hepmc3.gz -l small -t "1 2 4 8" -n 5 -r 1 -w 10 -R 0.4
./src/thread-scan.sh -o results/thread-scaling/small/CA-N2Plain -A CA -S N2Plain -i data/events-pp-0.5TeV-5GeV.hepmc3.gz -l small -t "1 2 4 8" -n 5 -r 1 -w 10 -R 0.4
./src/thread-scan.sh -o results/thread-scaling/small/CA-N2Tiled -A CA -S N2Tiled -i data/events-pp-0.5TeV-5GeV.hepmc3.gz -l small -t "1 2 4 8" -n 5 -r 1 -w 10 -R 0.4
./src/thread-scan.sh -o results/thread-scaling/small/Kt-N2Plain -A Kt -S N2Plain -i data/events-pp-0.5TeV-5GeV.hepmc3.gz -l small -t "1 2 4 8" -n 5 -r 1 -w 10 -R 0.4
./src/thread-scan.sh -o results/thread-scaling/small/Kt-N2Tiled -A Kt -S N2Tiled -i data/events-pp-0.5TeV-5GeV.hepmc3.gz -l small -t "1 2 4 8" -n 5 -r 1 -w 10 -R 0.4
```

For medium or high multiplicity, use the same commands with a different input
file and label:

```text
medium: data/events-pp-8TeV-20GeV.hepmc3.gz
high:   data/events-pp-30TeV-50GeV.hepmc3.gz
```

For a Durham e+e- scan:

```sh
./src/thread-scan.sh \
  --outdir results/thread-scaling/ee/Durham-N2Plain \
  --algorithm Durham \
  --strategy N2Plain \
  --input-file data/events-ee-Z.hepmc3.gz \
  --label eeZ \
  --threads "1 2 4 8" \
  --nsamples 5 \
  --repeats 1 \
  --warmup-events 10 \
  --radius 4.0
```

## Merge Results

After a scan, merge the JSON files into a summary CSV:

```sh
julia --project=. src/merge-thread-scan.jl \
  results/thread-scaling/small/*/*.json \
  results/thread-scaling/small/summary.csv
```

`merge-thread-scan.jl` can also merge CSV files from `benchmark.jl`, or a mix of
JSON and CSV files, as shown in the FastJet section above. The output contains
one row for each workload, backend, GC mode, schedule, and thread count.

Important columns:

```text
code
backend
algorithm
strategy
R
p
input_file
gcoff
threads
schedule
events_per_second_median
baseline_events_per_second_median
speedup_median
efficiency_median
```

Definitions:

```text
events_per_second_median
    Median throughput for the workload at this thread count.

baseline_events_per_second_median
    Median throughput for the same workload at one thread.

speedup_median
    events_per_second_median / baseline_events_per_second_median

efficiency_median
    speedup_median / threads
```

Check the summary:

```sh
head -n 10 results/thread-scaling/small/summary.csv
```

If merging fails with:

```text
Cannot compute speedup: at least one workload has no 1-thread baseline
```

then at least one workload is missing a `threads=1` JSON file. Rerun that
workload with a thread list that includes `1`, then merge again.

## Plot Results

`src/plot-thread-scan.jl` plots the merged CSV.

Supported metrics:

```text
efficiency
speedup
throughput
```

Efficiency plot:

```sh
julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/small/summary.csv \
  results/thread-scaling/small/plots \
  --metric efficiency \
  --title "Small pp input"
```

Speedup plot:

```sh
julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/small/summary.csv \
  results/thread-scaling/small/plots/speedup.png \
  --metric speedup \
  --title "Small pp input"
```

Throughput plot:

```sh
julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/small/summary.csv \
  results/thread-scaling/small/plots/throughput.png \
  --metric throughput \
  --title "Small pp input" \
  --no-ideal
```

By default, the plotter creates one combined plot and one line per
`algorithm,strategy,R,p` combination:

```text
--split-by none
--group-by algorithm,strategy,R,p
```

When a summary contains multiple inputs, GC modes, or schedulers, include those
columns in `--group-by` or choose one of them with `--split-by`. For example:

```text
--split-by input_file
--group-by algorithm,strategy,R,p,gcoff,schedule
```

To put everything in a single plot:

```sh
julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/small/summary.csv \
  results/thread-scaling/small/plots/combined-throughput.png \
  --metric throughput \
  --split-by none \
  --group-by algorithm,strategy,input_file \
  --title "Small pp input" \
  --no-ideal
```

## Quick End-to-End Example

This is the shortest complete workflow:

```sh
mkdir -p results/thread-scaling/example

./src/thread-scan.sh \
  --outdir results/thread-scaling/example/AntiKt-N2Plain \
  --algorithm AntiKt \
  --strategy N2Plain \
  --input-file data/events-pp-0.5TeV-5GeV.hepmc3.gz \
  --label small \
  --threads "1 2 4 8" \
  --nsamples 5 \
  --repeats 1 \
  --warmup-events 10 \
  --radius 0.4

julia --project=. src/merge-thread-scan.jl \
  results/thread-scaling/example/*/*.json \
  results/thread-scaling/example/summary.csv

julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/example/summary.csv \
  results/thread-scaling/example/plots \
  --metric efficiency \
  --title "Small pp input"
```

Check the outputs:

```sh
head -n 10 results/thread-scaling/example/summary.csv
ls -lh results/thread-scaling/example/plots
```

## Profiling N2Plain and N2Tiled

`src/profile-run.jl` is the common profiler for pp N2Plain, pp N2Tiled, and
electron-positron N2Plain reconstruction. Algorithm and strategy are ordinary
command-line options; there is no separate profiler for Durham.

Run an unprofiled AntiKt/N2Tiled control measurement:

```sh
julia --threads=8 --project=. src/profile-run.jl \
  -A AntiKt -S N2Tiled -R 0.4 \
  --julia-scheduler dynamic \
  --profile-mode none \
  --nsamples 5 --repeats 1 --warmup-events 20 \
  --output results/profiles/antikt-n2tiled-control.json \
  data/events-pp-13TeV-20GeV.hepmc3.gz
```

Run the corresponding Durham/N2Plain CPU profile:

```sh
julia --threads=8 --project=. src/profile-run.jl \
  -A Durham -S N2Plain -R 4.0 \
  --julia-scheduler dynamic \
  --profile-mode cpu --nsamples 1 \
  --profile-output results/profiles/durham-n2plain-cpu \
  --output results/profiles/durham-n2plain-cpu.json \
  data/events-ee-H.hepmc3.gz
```

Profiling modes are:

```text
none     control timing without a Julia profiler
cpu      CPU sampling with Profile.@profile
wall     wall-time sampling; requires Julia 1.12 or later
alloc    allocation profiling with Profile.Allocs
```

Profiled modes require `--nsamples 1` and `--profile-output PREFIX`. CPU and
wall profiles write flat, tree, raw serialized, and metadata artifacts.
Allocation profiles write a text report, raw serialized data, and metadata.
Keep `--allocation-sample-rate` small for large events; allocation profiling is
usually most interpretable with one Julia compute thread.

The default `--execution-mode owning` uses the public `jet_reconstruct` path and
works with released JetReconstruction versions. `--execution-mode workspace`
uses reusable N2Plain or N2Tiled storage when those APIs are available. It
requires `--julia-scheduler chunked_atomic`; every static worker owns one
workspace and one inclusive-output vector. `--chunk-size` controls the atomic
claim size and defaults to 8 when omitted.

Warmup, the compilation probe, and the measured region all execute the same
event kernel and scheduler. Nevertheless, the profiler itself has overhead.
Run a matched `--profile-mode none` control and pass its throughput with
`--reference-events-per-second` when reporting an overhead fraction.

## Choosing `nsamples` and `repeats`

`nsamples` controls how many timed measurements are taken for each thread count.

Suggested values:

```text
5       quick smoke test
16      reasonable local benchmark
32+     more stable production benchmark
```

`repeats` controls how many times the full input event sample is processed
inside each timed measurement. For very fast workloads, increasing `repeats`
can reduce noise:

```text
1       quick run
4       more stable for small inputs
8+      useful if individual samples are very short
```

The cost is runtime: larger `nsamples` and larger `repeats` both make the scan
take longer.

## Interpreting Scaling Results

Speedup is:

```text
throughput_at_N_threads / throughput_at_1_thread
```

Efficiency is:

```text
speedup / N_threads
```

Interpretation:

```text
efficiency near 1.0     close to ideal scaling
efficiency below 1.0    sublinear scaling
efficiency above 1.0    possible on noisy short runs; rerun with more samples
```

Small inputs are often noisy because each timed sample is short. For more stable
numbers, use more samples, more repeats, or a higher-multiplicity input.

## Practical Checks

Check JSON success:

```sh
jq -r '[input_filename, .success, .algorithm, .strategy, .julia_threads] | @tsv' \
  results/thread-scaling/example/*/*.json
```

Check available thread counts:

```sh
jq -r '.julia_threads' results/thread-scaling/example/*/*.json | sort -n | uniq -c
```

Check summary columns:

```sh
head -n 1 results/thread-scaling/example/summary.csv
```

Check plot files:

```sh
ls -lh results/thread-scaling/example/plots
```

## Common Pitfalls

### Missing one-thread result

Speedup and efficiency require a one-thread baseline for each workload. Always
include `1` in the thread list.

### Mixing path spellings

`merge-thread-scan.jl` groups workloads by the exact `input_file` string stored
in the JSON. Use the same input path spelling for every thread count of the same
workload. The `src/thread-scan.sh` driver helps by normalising existing
input files before it calls `thread-run.jl`.

### Overwriting JSON files

The JSON filename is based on:

```text
ALGORITHM-STRATEGY[-SCHEDULER[-cCHUNK]][-gcoff]-LABEL-tTHREADS.json
```

Running the same scan into the same directory overwrites previous files. Use a
new output directory for a new benchmark campaign.

### Comparing unlike workloads

Speedup is only meaningful within the same workload: same algorithm, strategy,
radius, power, input file, code, backend, GC mode, and schedule.
`merge-thread-scan.jl` computes baselines using these columns, so keep them
consistent across thread counts.

### Mixed-backend plot grouping

For Julia-only plots containing a single GC mode and scheduler, the default
grouping is enough:

```text
--group-by algorithm,strategy,R,p
```

For comparisons containing multiple modes or backends, include GC mode, backend,
and schedule:

```text
--group-by code,backend,algorithm,strategy,R,p,gcoff,schedule
```
