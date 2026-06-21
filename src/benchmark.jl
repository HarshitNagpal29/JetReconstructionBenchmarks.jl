#! /usr/bin/env julia
"""
Run jet reconstruction over a standard set of input files, with
varying initial particle densities
"""

using ArgParse
using Logging
using JSON
using CSV
using DataFrames
using EnumX
using CodecZlib
using Printf
using Statistics
using UnicodePlots

using LorentzVectorHEP
using JetReconstruction

# Backends for the jet reconstruction
@enumx T=Code Backends JetReconstruction Fastjet AkTPython AkTNumPy CJetReconstruction
const AllCodeBackends = [String(Symbol(x)) for x in instances(Backends.Code)]

# Parsing for Enum types
function ArgParse.parse_item(opt::Type{E}, s::AbstractString) where {E <: Enum}
    insts = instances(E)
    p = findfirst(x -> Symbol(x) == Symbol(s), insts)
    if isnothing(p)
        throw(ErrorException("Invalid value for enum $opt: $s"))
    end
    return insts[p]
end

function determine_backend_version(code::Backends.Code)
    if code == Backends.JetReconstruction
        return string(VERSION)
    elseif code == Backends.Fastjet
        return "unknown"
    elseif code in (Backends.AkTPython, Backends.AkTNumPy)
        output = read(`python --version`, String)
        m = match(r"Python (\d+\.\d+\.\d+)", output)
        if isnothing(m)
            return "unknown"
        end
        return m[1]
    end
    "unknown"
end

function determine_backend(code::Backends.Code)
    if code == Backends.JetReconstruction
        return "Julia"
    elseif code == Backends.Fastjet
        return "C++"
    elseif code in (Backends.AkTPython, Backends.AkTNumPy)
        return "Python"
    end
    "unknown"
end

function hepmc3gunzip(input_file::AbstractString)
    unpacked_file = replace(input_file, ".gz" => "")
    if !isfile(unpacked_file)
        @info "Unpacking $(input_file) to $(unpacked_file)"
        in = GzipDecompressorStream(open(input_file))
        out = open(unpacked_file, "w")
        write(out, in)
        close(in)
        close(out)
    end
    unpacked_file
end

function summarise_trial_times(trial_timing::AbstractVector{<:Real})
    (
        n_samples = length(trial_timing),
        mean = mean(trial_timing),
        std = length(trial_timing) > 1 ? std(trial_timing) : 0.0,
        median = median(trial_timing),
        minimum = minimum(trial_timing),
        maximum = maximum(trial_timing),
        q25 = quantile(trial_timing, 0.25),
        q75 = quantile(trial_timing, 0.75),
        iqr = quantile(trial_timing, 0.75) - quantile(trial_timing, 0.25),
    )
end

function filter_outliers_iqr(trial_timing::AbstractVector{<:Real}, stats; outlier_band::Real = 2.0)
    min_val = stats.q25 - outlier_band * stats.iqr
    max_val = stats.q75 + outlier_band * stats.iqr
    trial_timing[(time -> min_val <= time <= max_val).(trial_timing)]
end

function pprint_trial_stats(stats)
    " - average time per event " * @sprintf("%.2f", stats.mean) * " ± " *
    @sprintf("%.2f", stats.std) * " μs\n" *
    " - median time per event " * @sprintf("%.2f", stats.median) * " μs\n" *
    " - lowest time per event " * @sprintf("%.2f", stats.minimum) * " μs"
end

function print_statistics(trial_timing::AbstractVector{<:Real};
                          outlier_exclusion::Bool = true,
                          outlier_band::Real = 2.0,
                          plot::Bool = false)
    stats = summarise_trial_times(trial_timing)
    println("Full statistics ($(stats.n_samples) samples)")
    println(pprint_trial_stats(stats))

    filtered_stats = nothing
    if outlier_exclusion
        no_outliers = filter_outliers_iqr(trial_timing, stats; outlier_band = outlier_band)
        filtered_stats = summarise_trial_times(no_outliers)
        println("Excluding outliers at $(outlier_band)xIQR (leaving $(filtered_stats.n_samples) of $(stats.n_samples) samples)")
        println(pprint_trial_stats(filtered_stats))
    end

    if plot
        bin_width = ceil(2 * stats.iqr / stats.n_samples^(1 / 3))
        if bin_width <= 0 || !isfinite(bin_width)
            bin_width = 1
        end
        nbins = min(max(ceil(Int, (stats.maximum - stats.minimum) / bin_width), 1), 80)

        println(histogram(trial_timing, nbins = nbins, vertical = true,
                          title = "Histogram of event time per trial"))
        println(lineplot(collect(1:length(trial_timing)), trial_timing,
                         title = "Runtime per event across trials"))
    end

    (full = stats, outlier_excluded = filtered_stats)
end

const TIMING_STAT_KEYS = (:mean, :std, :median, :minimum, :maximum, :q25, :q75, :iqr)
const TIMING_STAT_COLUMNS = Dict(
    :mean => :time_per_event_mean,
    :std => :time_per_event_std,
    :median => :time_per_event_median,
    :minimum => :time_per_event_min,
    :maximum => :time_per_event_max,
    :q25 => :time_per_event_q25,
    :q75 => :time_per_event_q75,
    :iqr => :time_per_event_iqr,
)

function empty_timing_stat_columns()
    Dict(key => Union{Missing, Float64}[] for key in TIMING_STAT_KEYS)
end

function push_timing_stats!(event_timing_stats, stats)
    for key in TIMING_STAT_KEYS
        push!(event_timing_stats[key], getproperty(stats, key))
    end
end

function push_external_timing_stats!(event_timing_stats, time_per_event::Real)
    for key in TIMING_STAT_KEYS
        push!(event_timing_stats[key], key == :minimum ? Float64(time_per_event) : missing)
    end
end

function julia_jet_process_avg_time(events::Vector{Vector{T}};
    ptmin::Float64 = 5.0,
    radius::Float64 = 0.4,
    p::Union{Real, Nothing} = nothing,
    algorithm::JetAlgorithm.Algorithm = JetAlgorithm.AntiKt,
    strategy::RecoStrategy.Strategy,
    nsamples::Integer = 1,
    repeats::Int = 1) where {T <: JetReconstruction.FourMomentum}
    @info "Will process $(size(events)[1]) events, repeating $(repeats) time(s)"
    
    n_events = length(events)
    
    # Warmup code if we are doing a multi-sample timing run
    if nsamples > 1
        @info "Doing initial warm-up run"
        for event in events
            _ = inclusive_jets(jet_reconstruct(event, R = radius,
            algorithm = algorithm, p = p, strategy = strategy); ptmin = ptmin)
        end
    end
    
    # Threading?
    threads = Threads.nthreads()
    if threads > 1
        @info "Will use $threads threads"
    end
    
    # Now setup timers and run the loop
    trial_timing = zeros(Float64, nsamples)
    
    for irun in 1:nsamples
        t_start = time_ns()
        Threads.@threads for event_counter ∈ 1:n_events * repeats
            event_idx = mod1(event_counter, n_events)
            inclusive_jets(jet_reconstruct(events[event_idx], R = radius,
            algorithm = algorithm, p = p, strategy = strategy), ptmin = ptmin)
        end
        t_stop = time_ns()
        dt_μs = convert(Float64, t_stop - t_start) * 1.e-3
        trial_timing[irun] = dt_μs / (n_events * repeats)
        if nsamples > 1
            @info "$(irun)/$(nsamples) $(dt_μs)"
        end
    end
    
    trial_timing
end

function external_benchmark_avg_time(input_file::AbstractString;
                                     ptmin::Float64 = 5.0,
                                     radius::Float64 = 0.4,
                                     p::Union{Real, Nothing} = nothing,
                                     algorithm::JetAlgorithm.Algorithm = JetAlgorithm.AntiKt,
                                     strategy::RecoStrategy.Strategy,
                                     nsamples::Integer = 1,
                                     backend::Backends.Code = Backends.Fastjet,
                                     threads::Integer = 1,
                                     schedule::Union{String, Nothing} = nothing)
    if threads < 1
        throw(ArgumentError("threads must be at least 1"))
    end
    if !isnothing(schedule) && !(schedule in ("static", "dynamic", "guided"))
        throw(ArgumentError("schedule must be one of static, dynamic, guided"))
    end

    # FastJet reader cannot handle gzipped files
    if endswith(input_file, ".gz")
        input_file = hepmc3gunzip(input_file)
    end
    
    # Get consistent algorithm power
    p = JetReconstruction.get_algorithm_power(p = p, algorithm = algorithm)
    
    if backend == Backends.Fastjet
        bench_dir = "fastjet"
        bench_name = "fastjet-finder"
    elseif backend == Backends.CJetReconstruction
        bench_dir = "cjetreconstruction"
        bench_name = "cjetreconstruction-finder"
    else 
        @error "Unsupported backend for external benchmark: $backend"
        return 0.0
    end
    bench_bin = joinpath(@__DIR__, "..", bench_dir, "build", bench_name)
    bench_args = String[]
    push!(bench_args, "-A", string(Symbol(algorithm)))
    if !isnothing(p)
        push!(bench_args, "-p", string(p))
    end
    push!(bench_args, "-s", string(strategy))
    push!(bench_args, "-R", string(radius))
    push!(bench_args, "--ptmin", string(ptmin))
    push!(bench_args, "-m", string(nsamples))
    if backend == Backends.Fastjet
        if threads > 1
            push!(bench_args, "-t", string(threads))
        end
        if !isnothing(schedule)
            push!(bench_args, "--schedule", schedule)
        end
    elseif threads != 1 || !isnothing(schedule)
        @warn "Ignoring thread/schedule options for unsupported external backend" backend threads schedule
    end
    @info "Benchmark command: $bench_bin $bench_args $input_file"
    bench_output = read(`$bench_bin $bench_args $input_file`, String)
    m = match(r"Lowest time per event ([\d.eE+-]+) us", bench_output)
    if isnothing(m)
        @error "Failed to parse output from external benchmark script" bench_output
        return 0.0
    end
    min = tryparse(Float64, m[1])
    if isnothing(min)
        @error "Failed to parse lowest time from external benchmark script" bench_output
        return 0.0
    end
    min
end

function python_jet_process_avg_time(backend::Backends.Code,
    input_file::AbstractString;
    ptmin::Float64 = 5.0,
    radius::Float64 = 0.4,
    p::Union{Real, Nothing} = nothing,
    algorithm::JetAlgorithm.Algorithm = JetAlgorithm.AntiKt,
    strategy::RecoStrategy.Strategy,
    nsamples::Integer = 1)
    
    # Python reader cannot handle gzipped files
    if endswith(input_file, ".gz")
        input_file = hepmc3gunzip(input_file)
    end

    # There are some limitations in the Python code - only AntiKt is supported,
    # and the strategy has to be manually set
    if algorithm != JetAlgorithm.AntiKt
        @error "Only AntiKt is supported for Python backend"
        return 0.0
    end
    if strategy == RecoStrategy.Best
        @error "Best strategy is not supported for Python backend - use N2Plain or N2Tiled"
        return 0.0
    end

    py_args = String[]
    py_script = joinpath(@__DIR__, "..", "antikt-python", "src")
    if strategy == RecoStrategy.N2Plain
        py_script = joinpath(py_script, "antikt-basic.py")
    elseif strategy == RecoStrategy.N2Tiled 
        py_script = joinpath(py_script, "antikt-tiledN2cluster.py")
    else
        @error "Invalid strategy for Python: $strategy"
        return 0.0
    end

    # Accelerated or not?
    if backend == Backends.AkTNumPy
        py_args = ["--numba"]
    end
    
    # Ensure that all events are processed
    push!(py_args, "--maxevents", "100")

    push!(py_args, "--radius", string(radius))
    push!(py_args, "--ptmin", string(ptmin))
    
    push!(py_args, "--trials", string(nsamples))
    @info "Python command: $py_script $py_args $input_file"
    py_output = read(`$py_script $py_args $input_file`, String)
    min = tryparse(Float64, match(r"Minimum time per event ([\d\.]+) us", py_output)[1])
    if isnothing(min)
        @error "Failed to parse output from Python script"
        return 0.0
    end
    min
end

function parse_command_line(args)
    s = ArgParseSettings(autofix_names = true)
    @add_arg_table! s begin
    "--ptmin"
    help = "Minimum p_t for final jets (GeV)"
    arg_type = Float64
    default = 5.0
    
    "--radius", "-R"
    help = "Radius parameter for jet merging"
    arg_type = Float64
    default = 0.4
    
    "--algorithm", "-A"
    help = """Algorithm to use for jet reconstruction: $(join(JetReconstruction.AllJetRecoAlgorithms, ", "))"""
    arg_type = JetAlgorithm.Algorithm
    default = JetAlgorithm.AntiKt
    
    "--power", "-p"
    help = """Power value for jet reconstruction"""
    arg_type = Float64
    
    "--strategy", "-S"
    help = """Strategy for the algorithm, valid values: $(join(JetReconstruction.AllJetRecoStrategies, ", "))"""
    arg_type = RecoStrategy.Strategy
    default = RecoStrategy.Best
    
    "--nsamples", "-m"
    help = "Number of measurement points to acquire."
    arg_type = Int
    default = 16
    
    "--nsamples-override"
    help = "Override for sample number for specific event files"
    nargs = '+'
    
    "--repeats"
    help = "Run over whole event sample this number of times"
    arg_type = Int
    default = 1
    
    "--code"
    help = """Code backend to use for the jet reconstruction: $(join(AllCodeBackends, ", "))"""
    arg_type = Backends.Code
    default = Backends.JetReconstruction
    
    "--code-version"
    help = "Specific version string for the code backend used"
    arg_type = String
    default = "unknown"

    "--backend"
    help = """Backend used by the code - will be set automatically for Python and Julia, but Fastjet may benefit from being set manually (e.g., gcc or clang)"""
    arg_type = String

    "--backend-version"
    help = """Specific version string for the backend used - will be set automatically for Python and Julia, but Fastjet may benefit from being set manually"""
    arg_type = String

    "--worker-threads"
    help = "Number of worker threads to use in an external backend such as FastJet"
    arg_type = Int
    default = 1

    "--schedule"
    help = "Schedule for the algorithm (if supported)"
    arg_type = String

    "--info"
    help = "Print info level log messages"
    action = :store_true
    
    "--debug"
    help = "Print debug level log messages"
    action = :store_true

    "--plot"
    help = "Plot a terminal histogram and runtime series for Julia backend trial times"
    action = :store_true
    
    "--results"
    help = """Write results in CSV format to this directory/file. If a directory is given, a file named 'BACKEND-ALGORITHM-STRATEGY-RADIUS.csv' will be created."""
    
    "files"
    help = "HepMC3 event files in to process or CSV file listing event files"
    required = true
    nargs = '+'
end
return parse_args(args, s; as_symbols = true)
end

function main()
    args = parse_command_line(ARGS)
    if args[:debug]
        logger = ConsoleLogger(stdout, Logging.Debug)
    elseif args[:info]
        logger = ConsoleLogger(stdout, Logging.Info)
    else
        logger = ConsoleLogger(stdout, Logging.Warn)
    end
    global_logger(logger)
    
    # If we have a CSV file, open it and read
    if endswith(args[:files][1], ".csv")
        if length(args[:files]) > 1
            println("When CSV input is given, only one file can be used")
            exit(1)
        end
        hepmc3_files_df = CSV.read(args[:files][1], DataFrame)
        input_file_path = dirname(args[:files][1])
        input_files = hepmc3_files_df[:, :File]
        input_files_full = map(fname -> joinpath(input_file_path, fname), input_files)
        hepmc3_files_df[:, :File_path] = input_files_full
    else
        # It's just a plain list of files
        input_files_full = args[:files]
        hepmc3_files_df = DataFrame("File_path" => input_files_full)
        hepmc3_files_df[:, :File] = map(basename, hepmc3_files_df[:, :File_path])
        hepmc3_files_df[:, :mean_particles] .= -1
    end

    # Get consistent algorithm power
    power = JetReconstruction.get_algorithm_power(p = args[:power], algorithm = args[:algorithm])
    
    event_timing = Float64[]
    event_timing_stats = empty_timing_stat_columns()
    n_samples = Int[]
    for event_file in hepmc3_files_df[:, :File_path]
        if event_file in args[:nsamples_override]
            samples = tryparse(Int, args[:nsamples_override][1])
            @info "Overriding samples for $(event_file) to $samples"
        else
            samples = args[:nsamples]
        end
        push!(n_samples, samples)
        
        if args[:code] == Backends.JetReconstruction
            # Try to read events into the correct type!
            if JetReconstruction.is_ee(args[:algorithm])
                JetType = EEJet
            else
                JetType = PseudoJet
            end
            events::Vector{Vector{JetType}} = read_final_state_particles(event_file, JetType)
            trial_timing = julia_jet_process_avg_time(events; ptmin = args[:ptmin],
            radius = args[:radius],
            algorithm = args[:algorithm],
            p = args[:power],
            strategy = args[:strategy],
            nsamples = samples, repeats = args[:repeats])
            timing_stats = print_statistics(trial_timing; plot = args[:plot])
            time_per_event = timing_stats.full.minimum
            push_timing_stats!(event_timing_stats, timing_stats.full)
        elseif args[:code] ∈ (Backends.Fastjet, Backends.CJetReconstruction)
            time_per_event = external_benchmark_avg_time(event_file; ptmin = args[:ptmin],
            radius = args[:radius],
            algorithm = args[:algorithm],
            p = args[:power],
            strategy = args[:strategy],
            nsamples = samples,
            backend = args[:code],
            threads = args[:worker_threads],
            schedule = args[:schedule])
        elseif args[:code] in (Backends.AkTPython, Backends.AkTNumPy)
            time_per_event = python_jet_process_avg_time(args[:code], event_file; ptmin = args[:ptmin],
            radius = args[:radius],
            algorithm = args[:algorithm],
            p = args[:power],
            strategy = args[:strategy],
            nsamples = samples)
        end

        if args[:code] != Backends.JetReconstruction
            push_external_timing_stats!(event_timing_stats, time_per_event)
        end
        
        push!(event_timing, time_per_event)
    end
    # Add results to the DataFrame
    hepmc3_files_df[:, :n_samples] = n_samples
    hepmc3_files_df[:, :time_per_event] = event_timing
    for key in TIMING_STAT_KEYS
        hepmc3_files_df[:, TIMING_STAT_COLUMNS[key]] = event_timing_stats[key]
    end

    # Decorate the DataFrame with the metadata of the runs
    hepmc3_files_df[:, :code] .= args[:code]
    hepmc3_files_df[:, :code_version] .= args[:code_version]
    hepmc3_files_df[:, :algorithm] .= args[:algorithm]
    hepmc3_files_df[:, :strategy] .= args[:strategy]
    hepmc3_files_df[:, :radius] .= args[:radius]
    hepmc3_files_df[:, :power] .= power
    run_threads = args[:code] == Backends.JetReconstruction ? Threads.nthreads() : args[:worker_threads]
    run_schedule = args[:code] == Backends.Fastjet ? something(args[:schedule], "static") : missing
    hepmc3_files_df[:, :threads] .= run_threads
    hepmc3_files_df[:, :schedule] .= run_schedule

    backend = isnothing(args[:backend]) ? determine_backend(args[:code]) : args[:backend]
    backend_version = isnothing(args[:backend_version]) ? determine_backend_version(args[:code]) : args[:backend_version]
    hepmc3_files_df[:, :backend] .= backend
    hepmc3_files_df[:, :backend_version] .= backend_version

    println(hepmc3_files_df)
    
    # Write out the results
    if !isnothing(args[:results])
        if isdir(args[:results])
            thread_suffix = run_threads == 1 ? "" : "_T$(run_threads)"
            schedule_suffix = ismissing(run_schedule) || run_threads == 1 ? "" : "_$(run_schedule)"
            results_file = joinpath(args[:results],
            "$(args[:code])_$(args[:code_version])_$(args[:algorithm])_" *
            "$(args[:strategy])_R$(args[:radius])_P$(power)_$(backend)_$(backend_version)" *
            "$(thread_suffix)$(schedule_suffix).csv")
        else
            results_file = args[:results]
        end
        @info "Writing results to $(results_file)"
        mkpath(dirname(results_file))
        CSV.write(results_file, hepmc3_files_df)
    end
    
    nothing
end

main()
