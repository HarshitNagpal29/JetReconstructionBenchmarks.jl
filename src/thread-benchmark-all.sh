#!/usr/bin/env bash
set -euo pipefail
# This script runs a full thread-scaling benchmark campaign across standard workloads.
usage() {
  cat <<'EOF'
Usage:
  thread-benchmark-all.sh --outdir OUTDIR [OPTIONS]

Run a full thread-scaling benchmark campaign across standard workloads.

Required:
  -o, --outdir OUTDIR              Output directory for all results

Options:
  -i, --input-file INPUT_FILE      HepMC3 input file
  -l, --label LABEL                Label used in filenames
  -m, --max-threads N              Maximum Julia thread count
  -n, --nsamples N                 Timed samples per thread count
  -r, --repeats N                  Repeats per timed sample
  -w, --warmup-events N            Warmup events
  -g, --gcoff                      Turn off garbage collection during timing
  -R, --radius R                   Jet radius
  -h, --help                       Show this help
  --dry-run                        Print commands without running them
  --suite SUITE                    Workload suite: pp, ee, all (default: pp)
  --force                          Allow writing into a non-empty output directory
EOF
}

require_positive_integer() {
  name="$1"
  value="$2"

  case "$value" in
    ''|*[!0-9]*)
      echo "error: $name must be a positive integer, got '$value'" >&2
      exit 2
      ;;
  esac

  if [ "$value" -lt 1 ]; then
    echo "error: $name must be >= 1, got '$value'" >&2
    exit 2
  fi
}

outdir=""
input_file="data/events-pp-0.5TeV-5GeV.hepmc3.gz"
label="small"
max_threads="8"
nsamples="5"
repeats="1"
warmup_events="10"
gcoff="false"
radius="0.4"
dry_run="false"
suite="pp"
force="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--outdir)
      outdir="$2"
      shift 2
      ;;
    -i|--input-file)
      input_file="$2"
      shift 2
      ;;
    -l|--label)
      label="$2"
      shift 2
      ;;
    -m|--max-threads)
      max_threads="$2"
      shift 2
      ;;
    -n|--nsamples)
      nsamples="$2"
      shift 2
      ;;
    -r|--repeats)
      repeats="$2"
      shift 2
      ;;
    -w|--warmup-events)
      warmup_events="$2"
      shift 2
      ;;
    -g|--gcoff)
      gcoff="true"
      shift
      ;;
    -R|--radius)
      radius="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    --suite)
      suite="$2"
      shift 2
      ;;
    --force)
      force="true"
      shift
      ;;
    *)
      usage >&2
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$outdir" ]; then
  usage >&2
  echo "error: --outdir is required" >&2
  exit 2
fi

require_positive_integer "--max-threads" "$max_threads"
require_positive_integer "--nsamples" "$nsamples"
require_positive_integer "--repeats" "$repeats"
require_positive_integer "--warmup-events" "$warmup_events"

threads_list=""

add_thread_count() {
  value="$1"

  if [ "$value" -gt "$max_threads" ]; then
    return
  fi

  case " $threads_list " in
    *" $value "*)
      ;;
    *)
      threads_list="$threads_list $value"
      ;;
  esac
}


# Powers of two
threads=1
while [ "$threads" -le "$max_threads" ]; do
  add_thread_count "$threads"
  threads=$((threads * 2))
done

# Round tens from 20 upward
threads=20
while [ "$threads" -le "$max_threads" ]; do
  add_thread_count "$threads"
  threads=$((threads + 10))
done

# Always include the requested maximum
add_thread_count "$max_threads"

threads_list=$(echo "$threads_list" | xargs -n1 | sort -n | xargs)

if [ "$max_threads" -gt 20 ]; then
  filtered_threads=""
  previous=""

  for threads in $threads_list; do
    if [ -z "$previous" ]; then
      filtered_threads="$threads"
      previous="$threads"
      continue
    fi

    gap=$((threads - previous))

    if [ "$gap" -le 2 ]; then
      if [ $((previous % 10)) -eq 0 ] && [ "$previous" -ge 20 ]; then
        filtered_threads="${filtered_threads% $previous}"
      elif [ $((threads % 10)) -eq 0 ] && [ "$threads" -ge 20 ] && [ "$threads" -ne "$max_threads" ]; then
        continue
      fi
    fi

    filtered_threads="$filtered_threads $threads"
    previous="$threads"
  done

  threads_list="$filtered_threads"
fi

echo "threads: $threads_list"

pp_workloads="
AntiKt N2Plain
AntiKt N2Tiled
CA N2Plain
CA N2Tiled
Kt N2Plain
Kt N2Tiled
"

ee_workloads="
Durham N2Plain
"

case "$suite" in
  pp)
    workloads="$pp_workloads"
    ;;
  ee)
    workloads="$ee_workloads"
    ;;
  all)
    workloads="$pp_workloads
$ee_workloads"
    ;;
  *)
    echo "error: --suite must be one of: pp, ee, all" >&2
    exit 2
    ;;
esac

if [ -d "$outdir" ] && [ -n "$(find "$outdir" -mindepth 1 -maxdepth 1 -print -quit)" ] && [ "$force" != "true" ]; then
  echo "error: output directory already exists and is not empty: $outdir" >&2
  echo "       use --force to write into it anyway" >&2
  exit 2
fi

mkdir -p "$outdir"

echo "Running benchmark campaign"
echo "  suite: $suite"
echo "  output: $outdir"
echo "  input: $input_file"
echo "  label: $label"
echo "  threads: $threads_list"
echo

echo "$workloads" | while read -r algorithm strategy; do
  if [ -z "$algorithm" ]; then
    continue
  fi

  workload_outdir="$outdir/$algorithm-$strategy"

  echo "Running $algorithm $strategy"
  cmd=(
    ./src/thread-scan.sh
    --outdir "$workload_outdir"
    --algorithm "$algorithm"
    --strategy "$strategy"
    --input-file "$input_file"
    --label "$label"
    --threads "$threads_list"
    --nsamples "$nsamples"
    --repeats "$repeats"
    --warmup-events "$warmup_events"
)
  if [ "$gcoff" = "true" ]; then
    cmd+=(--gcoff)
  fi
  cmd+=(--radius "$radius")

  if [ "$dry_run" = "true" ]; then
    printf '  '
    printf '%q ' "${cmd[@]}"
    printf '\n'
  else
    "${cmd[@]}"
  fi

  echo
done

summary_csv="$outdir/summary.csv"

if [ "$dry_run" = "true" ]; then
  echo "Dry run: skipping merge and plots"
  exit 0
fi

echo "Merging JSON results"
julia --project=. src/merge-thread-scan.jl \
  "$outdir"/*/*.json \
  "$summary_csv"

echo "Wrote summary: $summary_csv"

plots_dir="$outdir/plots"
mkdir -p "$plots_dir"

echo "Plotting results"

julia --project=. src/plot-thread-scan.jl \
  "$summary_csv" \
  "$plots_dir" \
  --metric efficiency \
  --title "$label"

julia --project=. src/plot-thread-scan.jl \
  "$summary_csv" \
  "$plots_dir" \
  --metric speedup \
  --title "$label"

julia --project=. src/plot-thread-scan.jl \
  "$summary_csv" \
  "$plots_dir" \
  --metric throughput \
  --title "$label" \
  --no-ideal

echo "Wrote plots:"
ls -lh "$plots_dir"

echo
echo "Done."
echo "Summary CSV: $summary_csv"
echo "Plots directory: $plots_dir"
echo "Thread counts: $threads_list"
echo "Suite: $suite"
