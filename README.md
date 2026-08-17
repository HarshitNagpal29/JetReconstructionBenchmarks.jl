# Julia Fastjet Utilities and Benchmarks

This repository has utility scripts and example functions for running jet
reconstruction benchmarks with the
[`JetReconstruction`](https://github.com/JuliaHEP/JetReconstruction.jl) Julia
package, and then comparing to Fastjet and Python implementations.

## Overview

### `src`

Main directory of source files and utilities for benchmarking:

- `benchmark.jl` run timing tests for different backends, allowing switching of
  algorithm, strategy, etc. (will run over multiple event input files)
- `thread-run.jl`, `thread-scan.sh`, and `thread-benchmark-all.sh` run the
  Julia thread-scaling workflow described in `THREAD.md`, including explicit
  Julia scheduler and garbage-collection controls
- `profile-run.jl` profiles the same event-level workload for pp N2Plain,
  pp N2Tiled, and electron-positron N2Plain reconstruction; usage and artifact
  descriptions are in `THREAD.md`
- `merge-thread-scan.jl` and `plot-thread-scan.jl` merge and plot thread-scan
  outputs; they can be used with Julia JSON files and benchmark CSV files
- `generate-benchmarks-{pp,ee,antikt}.sh` example files of how to generate a set
  of benchmark files for various parameters
- `merge-results.jl` merges per run-parameters output CSV files into only large
  results file

Some other utility scripts:

- `hepmc32summary.jl` write CSV files summarising the content of HepMC3 test
  input files (average cluster density)
- `fastjet2json.jl` convert fastjet outputs to JSON files for event validation
tests with Julia
- `findmin-test.jl` tests the speed of finding minima in vectors, using Julia's
  builtin `findmin` and an turbo version that uses `LoopVectorization` (as is
  used in `JetReconstruction.jl`)
- `benchmark-substructure.jl` runs timing tests for substructure utilities in
  `JetReconstruction.jl`

### `fastjet`

Example C++ application that runs fastjet for comparing with other
implementations. Built with CMake.

Use the script `fastjet2json.jl` to convert fastjet outputs to JSON files for
comparison tests with Julia.

### `antikt-python`

Submodule with the Python jet finding code for AntiKt.

### `genevt`

Pythia8 application(s) for producing input HepMC3 files.

TODO: Proper CMake setup, but the source files will take you most of the way.

### `data`

Sorted HepMC3 data files used as reconstruction inputs (compressed).

Note that the `benchmark.jl` script will trigger unpacking of the compressed
data files for running with fastjet or Python codes (which do not directly read
compressed inputs).

### `results`

Archive of results.

Recommended structure is to store in a particular subdirectory the results from
a particular machine, e.g., `M2Pro_OSX_15.3` or `AMD5700_Linux_Alma9.4`.

### `results-v0`

This is an older set of results (2023 and 2024) where the metadata used in the
benchmarking outputs was rather sparse, with few fields and an awkward
convention of storing additional metadata in the output filenames. This was
fragile and not very extensible, so has been archived.

## Benchmarking - Single Runs

Here we describe what to do to measure event/s using `benchmark.jl` with
different versions of the sequential jet algorithm codes for a single set of
parameters, usually over a range of input files.

### Codes Available

#### JetReconstruction.jl

This is the native Julia version of sequential jet reconstruction. It is a
package dependency of this benchmarking package, so the version used will be
whatever is set in the `Manifest.toml`. In particular, if you pick a development
version of the code, you will be able to benchmark different development
branches, etc.

The Julia version used is the one which is used to run `benchmark.jl`, so it is
trivial to switch Julia versions in the usual juliaup way, i.e.,

```sh
julia +1.9 --project src/benchmark.jl ...
```

would also run JetReconstruction with Julia 1.9.

#### Fastjet

There is a small fastjet program in the `fastjet` directory. Use CMake to
compile this to `fastjet/build/fastjet-finder` which is where `benchmark.jl`
expects to find it. e.g.,

```sh
cd fastjet
cmake -S . -B build
cmake --build build
```

Evidently you can use whatever compiler and flags you like.

For FastJet thread scaling, build `fastjet-finder` with OpenMP support. The
executable accepts `--threads` and `--schedule`; `benchmark.jl` forwards
`--worker-threads` to FastJet's `--threads` option when `--code Fastjet` is
selected. See `THREAD.md` for the full Julia-vs-FastJet thread-scaling workflow.

```sh
cd fastjet
cmake -S . -B build -DFASTJET_ENABLE_OPENMP=ON
cmake --build build
```

#### Python

The repository used for the native Python versions of jet reconstruction is
[antikt-python](https://github.com/graeme-a-stewart/antikt-python). This is a
submodule of this repository, so `benchmark.jl` expects to find the correct
Python scripts in `antikt-python/src`.

Note that the Python environment, with dependencies, needs to be setup manually.
Use the `environment.yml` file provided with conda or mamba (you may wish to
tune the main Python version to your needs).

The Python repository contains two versions of the reconstruction algorithms:
one that is pure Python and one that uses NumPy and Numba for acceleration.

Note that the Python codes are limited: only the `AntiKt` algorithm is supported
and only the `N2Plain` and `N2Tiled` strategies can be used. (This is, however,
sufficient to get a feel for the relative speed of these Python codes.)

### Running a Benchmarking Job

The `benchmark.jl` script has quite a few options used for detailed control of
the jobs it runs. The most important ones are:

```sh
julia --project benchmark.jl --code CODE --algorithm ALG --strategy STRAT --nsamples TRIALS INPUT_FILE(S)
```

The `CODE` option selects the code implementation:

| `CODE` | Code Used |
|---|---|
| JetReconstruction | Julia `JetReconstruction.jl` |
| Fastjet | C++ Fastjet |
| AkTPython | AntiKt jet finder in pure Python |
| AkTNumPy | AntiKt jet finder using NumPy and Numba in Python |

`ALG` is the algorithm, in the `JetReconstruction.jl` parlance: `AntiKt`, `CA`,
`Kt`, `GenKt` (for $pp$) and `Durham`, `EEKt` (for $e^+e^-$). Note that for
`GenKt` and `EEKt` the additional argument `--power p` is required to fully
specify the reconstruction.

`STRAT` is the strategy, which is only relevant to $pp$ reconstruction and can
be `N2Plain` or `N2Tiled` (`Best` is also an option, which delegates the
strategy to the application).

`TRIALS` is the number of times to run over the event sample (N.B. the result
which is reported will be the *minimum* value obtained, which is the most stable
benchmark).

`INPUT_FILE` is either:

- A list of specific input files to run over (e.g.,
  `data/events-pp-13TeV-20GeV.hepmc3.gz`), or
- A CSV containing a list of input files with filenames and mean particle
  densities (e.g., `data/events-summary-ee-pp.csv`)

In general the former is used for testing and the latter for full benchmark runs.

### Additional Algorithmic Parameters

- `--radius R`: for algorithms which have a variable radius parameter, this is set to `R` (default 0.4)
- `--power p`: for algorithms which have a variable power, this is set to `p` - for algorithms with a fixed power this must be set *consistently* or the run will be aborted
- `--ptmin PTMIN`: for these benchmarking runs an inclusive jet selection will be done with this `ptmin` cut (this has little influence on the results)
- `--worker-threads N`: worker thread count for external backends; for `Fastjet`
  this is passed to `fastjet-finder --threads N`. For `JetReconstruction`, use
  `julia --threads=N` instead
- `--schedule {static,dynamic,guided}`: OpenMP schedule for `Fastjet`; ignored
  for Julia and other external backends

### Recording Benchmarking Runs

To conduct a benchmarking run there are a few other parameters that should be specified:

- `--results OUTPUT`: write the final CSV data out to `OUTPUT`; if `OUTPUT` is a
  *directory* then `benchmark.jl` will use a unique filename determined from
  the parameters of run - this should be sufficient for a systematic series of
  benchmark runs
- `--code-version`: write the *version* of the code used into the output; there
  is no good way for `benchmark.jl` to detect this, so this is a user
  specified string (e.g., `3.4.3` for Fastjet 3.43.; `0.4.6` for a recent
  version of `JetReconstruction.jl`)
- `--backend`: the backend compiler/interpreter, e.g., `julia` or `gcc`; for
  Python and Julia codes this can be determined automatically; for Fastjet it
  will be set to `C++`, but should really be the compiler that was used to
  compile the application
- `--backend-version`: the version of the backend compiler/interpreter, e.g.,
  for Julia 1.11.5 this will be `1.11.5`; for Python and Julia this can be
  determined automatically, but for the C++ compiler of Fastjet this is not
  possible and must be specified

### Benchmarking Outputs

When the benchmarking runs all important parameters will be written into the final CSV file output.

It is recommended to process these files as `DataFrames`.

Here is an example:

```sh
julia --project=. src/benchmark.jl --code JetReconstruction --algorithm CA --strategy N2Tiled -m 16 -R 1.0 --code-version 0.4.6 --results test.csv data/events-summary-ee-pp.csv 
12×13 DataFrame
 Row │ File                             mean_particles  File_path                          n_samples  time_per_event  code               code_version  algorithm  strategy  R        p      backend  backend_version 
     │ String31                         Float64         String                             Int64      Float64         Code               String        Algorithm  Strategy  Float64  Int64  String   String          
─────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │ events-ee-Z.hepmc3.gz                     43.05  data/events-ee-Z.hepmc3.gz                16         29.5892  JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
   2 │ events-ee-H.hepmc3.gz                     64.97  data/events-ee-H.hepmc3.gz                16         46.5575  JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
   3 │ events-pp-0.5TeV-5GeV.hepmc3.gz          112.62  data/events-pp-0.5TeV-5GeV.hepmc…         16         69.0592  JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
   4 │ events-pp-1TeV-5GeV.hepmc3.gz            160.36  data/events-pp-1TeV-5GeV.hepmc3.…         16        108.462   JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
   5 │ events-pp-2TeV-5Gev.hepmc3.gz            188.21  data/events-pp-2TeV-5Gev.hepmc3.…         16        133.251   JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
   6 │ events-pp-2TeV.hepmc3.gz                 226.98  data/events-pp-2TeV.hepmc3.gz             16        171.804   JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
   7 │ events-pp-5TeV-10GeV.hepmc3.gz           284.15  data/events-pp-5TeV-10GeV.hepmc3…         16        220.633   JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
   8 │ events-pp-8TeV-20GeV.hepmc3.gz           354.18  data/events-pp-8TeV-20GeV.hepmc3…         16        298.599   JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
   9 │ events-pp-13TeV-20GeV.hepmc3.gz          431.18  data/events-pp-13TeV-20GeV.hepmc…         16        379.04    JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
  10 │ events-pp-20TeV-20GeV.hepmc3.gz          524.59  data/events-pp-20TeV-20GeV.hepmc…         16        486.832   JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
  11 │ events-pp-20TeV-50GeV.hepmc3.gz          553.64  data/events-pp-20TeV-50GeV.hepmc…         16        536.417   JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
  12 │ events-pp-30TeV-50GeV.hepmc3.gz          632.29  data/events-pp-30TeV-50GeV.hepmc…         16        632.413   JetReconstruction  0.4.6         CA         N2Tiled       1.0      0  Julia    1.11.5
  ```

The CSV file is generated from the DataFrame in the standard way, but the fields
are easier to read in the DataFrame output above.

## Organising Systematic Benchmark Runs

To run a sweep over parameters of interest there are some shell scripts that can
drive the process - see the files `src/generate-benchmarks*.sh`.

The scripts take one parameter, which is the output directory for all the
results. e.g.,

```sh
./src/generate-benchmarks-ee.sh results/M2Pro_OSX_15.3.2
```

N.B. These example scripts do not set `code-version`, `backend` or
`backend-version`.

### Merging Results

After a systematic sweep script has run there are many output file in the output
directory. To merge these files use the `merge-results.jl` script. e.g.,

```sh
cd results/test_run
julia --project=../.. ../../src/merge-results.jl *.csv
```

The default is to output the merged CSV file to `all-results.csv`, this can be
adjusted with the `--output` option.

## Analysing Results

When a final merged output file has been generated, the analysis usually
proceeds by using a Pluto notebook that ingests the data, makes appropriate
selections and plots the results.

Currently examples for the new style metadata are a work in progress, but the
older style notebooks `results/*-nb.jl` can be mostly recycled for this purpose.
