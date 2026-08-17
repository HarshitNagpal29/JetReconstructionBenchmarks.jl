module BenchmarkSchedulers

export BASIC_SCHEDULES, ALL_SCHEDULES, run_scheduled!, validate_julia_schedule

const BASIC_SCHEDULES = (:default, :dynamic, :static, :greedy)
const ALL_SCHEDULES = (BASIC_SCHEDULES..., :chunked_atomic)

"""
    validate_julia_schedule(schedule; allow_chunked_atomic=false)

Validate a scheduler name and return it as a `Symbol` suitable for dispatch.
"""
function validate_julia_schedule(
    schedule::Union{AbstractString, Symbol};
    allow_chunked_atomic::Bool = false,
)
    resolved = Symbol(schedule)
    valid_schedules = allow_chunked_atomic ? ALL_SCHEDULES : BASIC_SCHEDULES

    resolved in valid_schedules || throw(ArgumentError(
        "Invalid Julia scheduler '$schedule'. Valid values: " *
        join(string.(valid_schedules), ", "),
    ))

    if resolved == :greedy && VERSION < v"1.11"
        throw(ArgumentError("Greedy scheduling requires Julia 1.11 or later"))
    end

    return resolved
end

"""
    run_scheduled!(f, iterations, schedule; chunk_size=8, nworkers=Threads.nthreads())

Call `f(iteration, worker)` exactly once for every integer from `1` through
`iterations`, using the selected scheduler, provided every callback completes
successfully. Callback exceptions propagate to the caller.

For the standard Julia schedulers, `worker` is the executing thread ID. For
`chunked_atomic`, it is a stable worker index and can safely select worker-owned
mutable state.

`chunked_atomic` uses a top-level `Threads.@threads :static` loop. Like Julia's
static scheduler itself, it must not be invoked concurrently or from inside
another threaded loop.
"""
function run_scheduled!(
    f::F,
    iterations::Integer,
    schedule::Symbol;
    chunk_size::Integer = 8,
    nworkers::Integer = Threads.nthreads(),
) where {F}
    iterations >= 0 || throw(ArgumentError("iterations must be non-negative"))
    chunk_size > 0 || throw(ArgumentError("chunk_size must be positive"))
    nworkers > 0 || throw(ArgumentError("nworkers must be positive"))
    schedule in ALL_SCHEDULES || throw(ArgumentError("Unsupported Julia scheduler: $schedule"))

    return _run_scheduled!(
        f,
        Int(iterations),
        Val(schedule);
        chunk_size = Int(chunk_size),
        nworkers = Int(nworkers),
    )
end

function _run_scheduled!(f::F, iterations::Int, ::Val{:default}; kwargs...) where {F}
    Threads.@threads for iteration in 1:iterations
        f(iteration, Threads.threadid())
    end
    return nothing
end

function _run_scheduled!(f::F, iterations::Int, ::Val{:dynamic}; kwargs...) where {F}
    Threads.@threads :dynamic for iteration in 1:iterations
        f(iteration, Threads.threadid())
    end
    return nothing
end

function _run_scheduled!(f::F, iterations::Int, ::Val{:static}; kwargs...) where {F}
    Threads.@threads :static for iteration in 1:iterations
        f(iteration, Threads.threadid())
    end
    return nothing
end

@static if VERSION >= v"1.11"
    function _run_scheduled!(f::F, iterations::Int, ::Val{:greedy}; kwargs...) where {F}
        Threads.@threads :greedy for iteration in 1:iterations
            f(iteration, Threads.threadid())
        end
        return nothing
    end
else
    function _run_scheduled!(::F, ::Int, ::Val{:greedy}; kwargs...) where {F}
        throw(ArgumentError("Greedy scheduling requires Julia 1.11 or later"))
    end
end

function _run_scheduled!(
    f::F,
    iterations::Int,
    ::Val{:chunked_atomic};
    chunk_size::Int,
    nworkers::Int,
) where {F}
    nworkers == Threads.nthreads() || throw(ArgumentError(
        "chunked_atomic requires one worker per Julia thread " *
        "($(Threads.nthreads()) expected, got $nworkers)",
    ))

    next_iteration = Threads.Atomic{Int}(1)

    Threads.@threads :static for worker in 1:nworkers
        while true
            first_iteration = Threads.atomic_add!(next_iteration, chunk_size)
            first_iteration > iterations && break
            last_iteration = min(first_iteration + chunk_size - 1, iterations)

            for iteration in first_iteration:last_iteration
                f(iteration, worker)
            end
        end
    end

    return nothing
end

end
