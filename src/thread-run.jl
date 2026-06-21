#! /usr/bin/env julia
"""
Run Julia jet reconstruction over input events, running
over all threads used.

This script is not intended to be run directly, but 
controlled by the thread-scan.{jl,sh} script.
"""

using ArgParse
using Logging
using JSON
using CSV
using DataFrames
using EnumX
using CodecZlib
using Statistics
using Dates
using Pkg

using LorentzVectorHEP
using JetReconstruction

# Backends for the jet reconstruction
@enumx T=Backend Backends Julia FastJet
const AllBackends = [String(Symbol(x)) for x in instances(Backends.Backend)]

# Parsing for EnumX types
function ArgParse.parse_item(opt::Type{E}, s::AbstractString) where {E <: Enum}
    insts = instances(E)
    p = findfirst(x -> Symbol(x) == Symbol(s), insts)

    if isnothing(p)
        throw(ErrorException("Invalid value for enum $opt: $s"))
    end

    return insts[p]
end

function julia_jet_process_threads(events::Vector{Vector{T}};
                                    ptmin::Float64 = 5.0,
                                    distance::Float64 = 0.4,
                                    p::Union{Real, Nothing} = nothing,
                                    algorithm::JetAlgorithm.Algorithm = JetAlgorithm.AntiKt,
                                    strategy::RecoStrategy.Strategy,
                                    nsamples::Integer = 1,
                                    repeats::Int = 1,
                                    gcoff::Bool = false,
                                    warmup_events::Int = 10) where T <: JetReconstruction.FourMomentum
    @info "Will process $(size(events)[1]) events"

    # Set consistent power
    p = JetReconstruction.get_algorithm_power(p = p, algorithm = algorithm)

    n_events = length(events)

    actual_warmup_events = min(max(warmup_events, 0), n_events)
    if actual_warmup_events > 0
        @info "Doing warmup over $(actual_warmup_events) events"
        Threads.@threads for event_counter ∈ 1:actual_warmup_events
            event_idx = event_counter
            inclusive_jets(jet_reconstruct(events[event_idx]; algorithm = algorithm, R = distance, p = p,
                                           strategy = strategy), ptmin = ptmin)
        end
    else
        @info "No warmup events will be processed"
    end


    # Threading
    nthreads = Threads.nthreads()
    if nthreads > 1
        @info "Will use $nthreads threads"
    end

    # Now setup timers and run the loop
    cumulative_time = 0.0
    cumulative_time2 = 0.0
    lowest_time = typemax(Float64)
    selected_allocated_bytes = 0
    selected_gc_time_seconds = 0.0

    samples = Dict{String, Any}[]

    GC.gc()
    for irun in 1:nsamples
        gc_was_enabled = true
        timed = try
            if gcoff
                gc_was_enabled = GC.enable(false)
            end
            @timed Threads.@threads for event_counter ∈ 1:n_events * repeats
                event_idx = mod1(event_counter, n_events)
                inclusive_jets(jet_reconstruct(events[event_idx]; algorithm = algorithm, R = distance, p = p,
                                               strategy = strategy), ptmin = ptmin)
            end
        finally
            if gcoff
                GC.enable(gc_was_enabled)
            end
        end
        dt_seconds = timed.time
        dt_μs = dt_seconds * 1e6
        allocated_bytes = timed.bytes
        gc_time_seconds = timed.gctime

        sample_wall_time_seconds = dt_seconds
        sample_time_per_event_seconds = dt_seconds / (n_events * repeats)
        sample_events_per_second = (n_events * repeats) / dt_seconds
        sample_allocated_bytes_per_event = allocated_bytes / (n_events * repeats)
        sample_gc_fraction = dt_seconds == 0 ? 0.0 : gc_time_seconds / dt_seconds

        push!(samples, Dict(
            "sample_index" => irun,
            "wall_time_seconds" => sample_wall_time_seconds,
            "events_per_second" => sample_events_per_second,
            "time_per_event_seconds" => sample_time_per_event_seconds,
            "allocated_bytes_total" => allocated_bytes,
            "allocated_bytes_per_event" => sample_allocated_bytes_per_event,
            "gc_time_seconds" => gc_time_seconds,
            "gc_fraction" => sample_gc_fraction,
        ))

        if nsamples > 1
            @info "$(irun)/$(nsamples) $(dt_μs)"
        end
        cumulative_time += dt_μs
        cumulative_time2 += dt_μs^2
        if dt_μs < lowest_time
            lowest_time = dt_μs
            selected_allocated_bytes = allocated_bytes
            selected_gc_time_seconds = gc_time_seconds
        end
    end

    mean = cumulative_time / nsamples
    cumulative_time2 /= nsamples
    if nsamples > 1
        sigma = sqrt(nsamples / (nsamples - 1) * (cumulative_time2 - mean^2))
    else
        sigma = 0.0
    end
    # Event rate in Hz (lowest time is in μs)
    event_rate = (n_events * repeats / lowest_time) * 1_000_000

    # Average time per event
    mean /= n_events * repeats
    sigma /= n_events * repeats
    lowest_time /= n_events * repeats
    # Why also record the lowest time? 
    # 
    # The argument is that on a "busy" machine, the run time of an application is
    # always TrueRunTime+Overheads, where Overheads is a nuisance parameter that
    # adds jitter, depending on the other things the machine is doing. Therefore
    # the minimum value is (a) more stable and (b) reflects better the intrinsic
    # code performance.
    nthreads, lowest_time, event_rate, p, actual_warmup_events, selected_allocated_bytes, selected_gc_time_seconds,
    samples
end

function parse_command_line(args)
    s = ArgParseSettings(autofix_names = true)
    @add_arg_table! s begin
        "--ptmin"
        help = "Minimum p_t for final jets (GeV)"
        arg_type = Float64
        default = 5.0

        "--distance", "-R"
        help = "Distance parameter for jet merging"
        arg_type = Float64
        default = 0.4

        "--algorithm", "-A"
        help = """Algorithm to use for jet reconstruction: $(join(JetReconstruction.AllJetRecoAlgorithms, ", "))"""
        arg_type = JetAlgorithm.Algorithm
        default = JetAlgorithm.AntiKt

        "--power", "-p"
        help = "Power value for jet reconstruction"
        arg_type = Float64

        "--strategy", "-S"
        help = """Strategy for the algorithm, valid values: $(join(JetReconstruction.AllJetRecoStrategies, ", "))"""
        arg_type = RecoStrategy.Strategy
        default = RecoStrategy.Best

        "--nsamples", "-m"
        help = "Number of measurement points to acquire."
        arg_type = Int
        default = 16

        "--repeats"
        help = "Run over whole event sample this number of times"
        arg_type = Int
        default = 1

        "--warmup-events"
        help = "Number of events to run before timing starts"
        arg_type = Int
        default = 10    

        "--backend"
        help = """Backend to use for the jet reconstruction: $(join(AllBackends, ", "))"""
        arg_type = Backends.Backend
        default = Backends.Julia

        "--gcoff"
        help = "Turn off garbage collection during timing"
        action = :store_true

        "--info"
        help = "Print info level log messages"
        action = :store_true

        "--debug"
        help = "Print debug level log messages"
        action = :store_true

        "--output", "-o"
        help = "Optional JSON output file for one benchmark result"
        arg_type = String

        "file"
        help = "HepMC3 event file in to process"
        required = true

    end
    return parse_args(args, s; as_symbols = true)
end

function write_json_result(output_path::AbstractString, result::Dict)
    parent = dirname(output_path)

    if !isempty(parent) && parent != "."
        mkpath(parent)
    end

    open(output_path, "w") do io
        JSON.print(io, result, 4)
        println(io)
    end
end

function try_readchomp(cmd::Cmd)
    try
        return readchomp(cmd)
    catch
        return nothing
    end
end

function package_field(package_info, field::Symbol)
    hasproperty(package_info, field) || return nothing
    value = getproperty(package_info, field)
    return isnothing(value) ? nothing : string(value)
end

function package_metadata(package_name::AbstractString)
    for (_, package_info) in Pkg.dependencies()
        if package_info.name == package_name
            return Dict(
                "name" => package_info.name,
                "version" => package_field(package_info, :version),
                "uuid" => package_field(package_info, :uuid),
                "tree_hash" => package_field(package_info, :tree_hash),
                "git_revision" => package_field(package_info, :git_revision),
                "git_source" => package_field(package_info, :git_source),
                "is_direct_dep" => package_info.is_direct_dep,
                "is_tracking_path" => package_info.is_tracking_path,
                "is_tracking_repo" => package_info.is_tracking_repo,
                "source" => package_info.source,
            )
        end
    end

    return Dict(
        "name" => package_name,
        "version" => nothing,
        "uuid" => nothing,
        "tree_hash" => nothing,
        "git_revision" => nothing,
        "git_source" => nothing,
        "is_direct_dep" => nothing,
        "is_tracking_path" => nothing,
        "is_tracking_repo" => nothing,
        "source" => nothing,
    )
end

function git_metadata()
    repo_root = try_readchomp(`git rev-parse --show-toplevel`)

    return Dict(
        "repo_root" => repo_root,
        "commit" => try_readchomp(`git rev-parse HEAD`),
        "short_commit" => try_readchomp(`git rev-parse --short HEAD`),
        "branch" => try_readchomp(`git branch --show-current`),
        "is_dirty" => try_readchomp(`git status --porcelain`) != "",
        "remote_origin" => try_readchomp(`git remote get-url origin`),
    )
end

function hardware_metadata()
    cpu_info = Sys.cpu_info()
    cpu_model = isempty(cpu_info) ? nothing : cpu_info[1].model

    return Dict(
        "machine" => Sys.MACHINE,
        "kernel" => Sys.KERNEL,
        "cpu_threads" => Sys.CPU_THREADS,
        "cpu_model" => cpu_model,
        "total_memory_bytes" => Sys.total_memory(),
    )
end

function runtime_metadata(args)
    command = vcat([Base.julia_cmd().exec[1]], Base.julia_cmd().exec[2:end], PROGRAM_FILE, ARGS)

    return Dict(
        "benchmark_command" => join(command, " "),
        "julia_executable" => Sys.BINDIR,
        "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(),
        "julia_project" => Base.active_project(),
        "julia_load_path" => copy(LOAD_PATH),
        "julia_gc_num" => string(Base.gc_num()),
        "environment" => Dict(
            "JULIA_NUM_THREADS" => get(ENV, "JULIA_NUM_THREADS", nothing),
            "JULIA_NUM_GC_THREADS" => get(ENV, "JULIA_NUM_GC_THREADS", nothing),
            "JULIA_EXCLUSIVE" => get(ENV, "JULIA_EXCLUSIVE", nothing),
            "JULIA_CPU_TARGET" => get(ENV, "JULIA_CPU_TARGET", nothing),
        ),
    )
end

iqr(xs) = quantile(xs, 0.75) - quantile(xs, 0.25)
function build_sample_summary(samples::Vector{Dict{String, Any}})
    wall_times = Float64[sample["wall_time_seconds"] for sample in samples]
    event_rates = Float64[sample["events_per_second"] for sample in samples]
    allocations = Float64[sample["allocated_bytes_total"] for sample in samples]
    gc_fractions = Float64[sample["gc_fraction"] for sample in samples]

    return Dict(
        "wall_time_seconds_min" => minimum(wall_times),
        "wall_time_seconds_median" => median(wall_times),
        "wall_time_seconds_max" => maximum(wall_times),
        "wall_time_seconds_iqr" => iqr(wall_times),

        "events_per_second_min" => minimum(event_rates),
        "events_per_second_median" => median(event_rates),
        "events_per_second_max" => maximum(event_rates),
        "events_per_second_iqr" => iqr(event_rates),

        "allocated_bytes_total_min" => minimum(allocations),
        "allocated_bytes_total_median" => median(allocations),
        "allocated_bytes_total_max" => maximum(allocations),
        "allocated_bytes_total_iqr" => iqr(allocations),

        "gc_fraction_min" => minimum(gc_fractions),
        "gc_fraction_median" => median(gc_fractions),
        "gc_fraction_max" => maximum(gc_fractions),
        "gc_fraction_iqr" => iqr(gc_fractions),
    )
end
function main()
    args = parse_command_line(ARGS)
    if args[:debug]
        logger = ConsoleLogger(stderr, Logging.Debug)
    elseif args[:info]
        logger = ConsoleLogger(stderr, Logging.Info)
    else
        logger = ConsoleLogger(stderr, Logging.Warn)
    end
    global_logger(logger)

    # Try to read events into the correct type!
    if JetReconstruction.is_ee(args[:algorithm])
        JetType = EEJet
    else
        JetType = PseudoJet
    end
    events::Vector{Vector{JetType}} = read_final_state_particles(args[:file], JetType)
    if isnothing(args[:algorithm]) && isnothing(args[:power])
        @warn "Neither algorithm nor power specified, defaulting to AntiKt"
        args[:algorithm] = JetAlgorithm.AntiKt
    end

    nthreads, time_per_event_μs, event_rate_hz, resolved_p, actual_warmup_events, selected_allocated_bytes, selected_gc_time_seconds, samples = julia_jet_process_threads(events, ptmin = args[:ptmin],
                                                distance = args[:distance],
                                                algorithm = args[:algorithm],
                                                p = args[:power],
                                                strategy = args[:strategy],
                                                nsamples = args[:nsamples], repeats = args[:repeats],
                                                gcoff = args[:gcoff],
                                                warmup_events = args[:warmup_events])
    summary = build_sample_summary(samples)
    git_info = git_metadata()
    hardware_info = hardware_metadata()
    runtime_info = runtime_metadata(args)
    jetreconstruction_info = package_metadata("JetReconstruction")

    measured_events = length(events) * args[:repeats]
    wall_time_seconds = time_per_event_μs * 1e-6 * measured_events

    result = Dict(
    "success" => true,
    "error_message" => "",
    "algorithm" => string(Symbol(args[:algorithm])),
    "strategy" => string(Symbol(args[:strategy])),
    "R" => args[:distance],
    "p" => resolved_p,
    "input_file" => args[:file],
    "input_event_count" => length(events),
    "measured_events" => measured_events,
    "nsamples" => args[:nsamples],
    "repeats" => args[:repeats],
    "warmup_events" => actual_warmup_events,
    "julia_version" => string(VERSION),
    "julia_threads" => nthreads,
    "sample_index" => nothing,
    "timing_choice" => "minimum_of_samples",
    "wall_time_seconds" => wall_time_seconds,
    "events_per_second" => event_rate_hz,
    "time_per_event_seconds" => time_per_event_μs * 1e-6,
    "allocated_bytes_total" => selected_allocated_bytes,
    "allocated_bytes_per_event" => selected_allocated_bytes / measured_events,
    "gc_time_seconds" => selected_gc_time_seconds,
    "gc_fraction" => wall_time_seconds == 0 ? 0.0 : selected_gc_time_seconds / wall_time_seconds,
    "samples" => samples,
    "summary" => summary,
    "hardware" => hardware_info,
    "git" => git_info,
    "packages" => Dict(
        "JetReconstruction" => jetreconstruction_info,
    ),
    "benchmark_command" => runtime_info["benchmark_command"],
    "runtime" => runtime_info,
    "package_commit" => jetreconstruction_info["tree_hash"],
    "process_id" => getpid(),
    "timestamp" => string(now())
    )
    output_path = get(args, :output, nothing)
    if isnothing(output_path) || isempty(output_path)
        println("$(nthreads),$(time_per_event_μs),$(event_rate_hz)")
    else
        write_json_result(output_path, result)
    end
end

main()
