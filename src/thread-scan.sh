#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  thread-scan.sh -o OUTDIR [OPTIONS]

Run thread-scaling benchmarks and write one JSON file per thread count.

Required:
  -o, --outdir OUTDIR              Output directory for JSON files

Options:
  -A, --algorithm ALGORITHM        Jet algorithm (default: AntiKt)
  -S, --strategy STRATEGY          Reconstruction strategy (default: N2Plain)
  -i, --input-file INPUT_FILE      HepMC3 input file (default: data/events-pp-0.5TeV-5GeV.hepmc3.gz)
  -l, --label LABEL                Short label used in filenames (default: small)
  -t, --threads THREADS            Quoted thread count list (default: "1 2 4 8")
  -n, --nsamples NSAMPLES          Timed samples per thread count (default: 5)
  -r, --repeats REPEATS            Full event-sample repeats per timed sample (default: 1)
  -w, --warmup-events EVENTS       Events processed before timing starts (default: 10)
  -g, --gcoff                      Disable GC during each timed sample
  -j, --julia-scheduler SCHEDULER  default, dynamic, static, greedy, or chunked_atomic
                                      (default: default)
  -c, --chunk-size N               Atomic chunk size for chunked_atomic (default: 8)
  -R, --radius RADIUS              Radius parameter (default: 0.4)
  -h, --help                       Show this help

The greedy scheduler requires Julia 1.11 or later. Scheduler selection applies
to both warmup and timed loops. chunked_atomic assigns each static worker
disjoint chunks claimed from a shared atomic counter.

Example:
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
    --gcoff \
    --julia-scheduler chunked_atomic \
    --radius 0.4
EOF
}

require_value() {
  if [ "$#" -lt 2 ]; then
    usage >&2
    echo "error: option $1 requires a value" >&2
    exit 2
  fi
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
benchmark_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

outdir=""
algorithm="AntiKt"
strategy="N2Plain"
input_file="data/events-pp-0.5TeV-5GeV.hepmc3.gz"
label="small"
threads_list="1 2 4 8"
nsamples="5"
julia_scheduler="default"
chunk_size="8"
repeats="1"
warmup_events="10"
radius="0.4"
gcoff=false

parse_options_with_getopt() {
  local parsed_args
  parsed_args=$(getopt \
    -o o:A:S:i:l:t:n:r:w:R:c:gj:h \
    --long outdir:,algorithm:,strategy:,input-file:,label:,threads:,nsamples:,repeats:,warmup-events:,radius:,chunk-size:,gcoff,julia-scheduler:,help \
    -n thread-scan.sh -- "$@")
  eval set -- "$parsed_args"

  while true; do
    case "$1" in
      -o|--outdir)
        outdir="$2"
        shift 2
        ;;
      -A|--algorithm)
        algorithm="$2"
        shift 2
        ;;
      -S|--strategy)
        strategy="$2"
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
      -t|--threads)
        threads_list="$2"
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
        gcoff=true
        shift
        ;;
      -j|--julia-scheduler)
        julia_scheduler="$2"
        shift 2
        ;;
      -c|--chunk-size)
        chunk_size="$2"
        shift 2
        ;;
      -R|--radius)
        radius="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
    esac
  done

  if [ "$#" -gt 0 ]; then
    usage >&2
    echo "error: unexpected positional argument: $1" >&2
    exit 2
  fi
}

parse_options_manually() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o|--outdir)
        require_value "$@"
        outdir="$2"
        shift 2
        ;;
      -A|--algorithm)
        require_value "$@"
        algorithm="$2"
        shift 2
        ;;
      -S|--strategy)
        require_value "$@"
        strategy="$2"
        shift 2
        ;;
      -i|--input-file)
        require_value "$@"
        input_file="$2"
        shift 2
        ;;
      -l|--label)
        require_value "$@"
        label="$2"
        shift 2
        ;;
      -t|--threads)
        require_value "$@"
        threads_list="$2"
        shift 2
        ;;
      -n|--nsamples)
        require_value "$@"
        nsamples="$2"
        shift 2
        ;;
      -r|--repeats)
        require_value "$@"
        repeats="$2"
        shift 2
        ;;
      -w|--warmup-events)
        require_value "$@"
        warmup_events="$2"
        shift 2
        ;;
      -g|--gcoff)
        gcoff=true
        shift
        ;;
      -R|--radius)
        require_value "$@"
        radius="$2"
        shift 2
        ;;
      -j|--julia-scheduler)
        require_value "$@"
        julia_scheduler="$2"
        shift 2
        ;;
      -c|--chunk-size)
        require_value "$@"
        chunk_size="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --outdir=*)
        outdir="${1#*=}"
        shift
        ;;
      --algorithm=*)
        algorithm="${1#*=}"
        shift
        ;;
      --strategy=*)
        strategy="${1#*=}"
        shift
        ;;
      --input-file=*)
        input_file="${1#*=}"
        shift
        ;;
      --label=*)
        label="${1#*=}"
        shift
        ;;
      --threads=*)
        threads_list="${1#*=}"
        shift
        ;;
      --nsamples=*)
        nsamples="${1#*=}"
        shift
        ;;
      --repeats=*)
        repeats="${1#*=}"
        shift
        ;;
      --warmup-events=*)
        warmup_events="${1#*=}"
        shift
        ;;
      --julia-scheduler=*)
        julia_scheduler="${1#*=}"
        shift
        ;;
      --chunk-size=*)
        chunk_size="${1#*=}"
        shift
        ;;
      --radius=*)
        radius="${1#*=}"
        shift
        ;;
      -*)
        usage >&2
        echo "error: unknown option: $1" >&2
        exit 2
        ;;
      *)
        usage >&2
        echo "error: unexpected positional argument: $1" >&2
        exit 2
        ;;
    esac
  done
}

set +e
getopt --test >/dev/null 2>&1
getopt_test_status=$?
set -e

if [ "$getopt_test_status" -eq 4 ]; then
  parse_options_with_getopt "$@"
else
  parse_options_manually "$@"
fi

if [ -z "$outdir" ]; then
  usage >&2
  echo "error: --outdir is required" >&2
  exit 2
fi

case "$chunk_size" in
  ''|*[!0-9]*)
    echo "error: --chunk-size must be a positive integer, got '$chunk_size'" >&2
    exit 2
    ;;
esac
if [ "$chunk_size" -lt 1 ]; then
  echo "error: --chunk-size must be >= 1, got '$chunk_size'" >&2
  exit 2
fi

case "$julia_scheduler" in
  default|dynamic|static|greedy|chunked_atomic)
    ;;
  *)
    echo "error: --julia-scheduler must be one of: default, dynamic, static, greedy, chunked_atomic" >&2
    exit 2
    ;;
esac

mkdir -p "$outdir"
outdir=$(CDPATH= cd -- "$outdir" && pwd)

case "$input_file" in
  /*)
    ;;
  *)
    input_file="$benchmark_dir/$input_file"
    ;;
esac

if [ ! -f "$input_file" ]; then
  echo "error: input file does not exist: $input_file" >&2
  exit 2
fi

if [ ! -f "$benchmark_dir/src/thread-run.jl" ]; then
  echo "error: could not find src/thread-run.jl from benchmark directory: $benchmark_dir" >&2
  exit 2
fi

cd "$benchmark_dir"

for threads in $threads_list; do
  cmd=(
    julia --threads="$threads" --project=. src/thread-run.jl
    -A "$algorithm" \
    -S "$strategy" \
    -R "$radius" \
    --repeats "$repeats" \
    --nsamples "$nsamples" \
    --warmup-events "$warmup_events" \
    --julia-scheduler "$julia_scheduler" \
    --chunk-size "$chunk_size"
  )
  if [ "$gcoff" = true ]; then
    cmd+=(--gcoff)
  fi

  scheduler_suff=""
  if [ "$julia_scheduler" = "chunked_atomic" ]; then
    scheduler_suff="-chunked_atomic-c${chunk_size}"
  elif [ "$julia_scheduler" != "default" ]; then
    scheduler_suff="-${julia_scheduler}"
  fi
  gc_suff=""
  if [ "$gcoff" = true ]; then
    gc_suff="-gcoff"
  fi
  cmd+=(
    --output "$outdir/${algorithm}-${strategy}${scheduler_suff}${gc_suff}-${label}-t${threads}.json"
    "$input_file"
  )
  "${cmd[@]}"
done
