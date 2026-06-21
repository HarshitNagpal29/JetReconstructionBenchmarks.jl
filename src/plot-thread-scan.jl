#! /usr/bin/env julia
"""
Plot merged thread-scan scaling results.

Input should be the CSV produced by `merge-thread-scan.jl`.
"""

using ArgParse
using CSV
using DataFrames
ENV["GKSwstype"] = "100"
using Plots

const METRIC_COLUMNS = Dict(
    "speedup" => :speedup_median,
    "efficiency" => :efficiency_median,
    "throughput" => :events_per_second_median,
)

const METRIC_LABELS = Dict(
    "speedup" => "Speedup",
    "efficiency" => "Parallel efficiency",
    "throughput" => "Events / second",
)

function parse_command_line(args)
    s = ArgParseSettings(autofix_names = true)
    @add_arg_table! s begin
        "--metric", "-m"
        help = "Metric to plot: speedup, efficiency, throughput"
        arg_type = String
        default = "efficiency"

        "--split-by"
        help = "Column used to create separate plots. Use 'none' for one combined plot."
        arg_type = String
        default = "none"

        "--group-by"
        help = "Comma-separated columns used to define plot lines"
        arg_type = String
        default = "algorithm,strategy,R,p"

        "--title"
        help = "Optional title prefix"
        arg_type = String

        "--format"
        help = "Output format used when OUTPUT is a directory or multiple plots are created"
        arg_type = String
        default = "png"

        "--width"
        help = "Plot width in pixels"
        arg_type = Int
        default = 1100

        "--height"
        help = "Plot height in pixels"
        arg_type = Int
        default = 750

        "--no-ideal"
        help = "Do not draw ideal speedup/efficiency reference line"
        action = :store_true

        "summary_csv"
        help = "CSV produced by merge-thread-scan.jl"
        required = true

        "output"
        help = "Output file or directory"
        required = true
    end

    return parse_args(args, s; as_symbols = true)
end

function split_columns(spec::AbstractString)
    cols = Symbol[]
    for item in split(spec, ",")
        name = strip(item)
        isempty(name) || push!(cols, Symbol(name))
    end
    cols
end

function require_columns(df::DataFrame, cols::Vector{Symbol})
    missing_cols = setdiff(cols, propertynames(df))
    if !isempty(missing_cols)
        error("Missing required column(s): $(join(string.(missing_cols), ", "))")
    end
end

function safe_filename(text::AbstractString)
    safe = replace(text, r"[^A-Za-z0-9_.-]+" => "_")
    strip(safe, ['_', '.', '-'])
end

function value_label(value)
    if value isa AbstractFloat
        return string(round(value; digits = 4))
    end
    string(value)
end

function column_value_label(col::Symbol, value)
    if col == :input_file && !ismissing(value)
        return basename(string(value))
    end
    value_label(value)
end

function row_label(row, cols::Vector{Symbol})
    parts = String[]
    for col in cols
        push!(parts, "$(col)=$(column_value_label(col, row[col]))")
    end
    join(parts, ",\n")
end

function group_title(args, split_col::Union{Nothing, Symbol}, split_value)
    pieces = String[]
    if !isnothing(args[:title])
        push!(pieces, args[:title])
    end
    push!(pieces, METRIC_LABELS[args[:metric]])
    if !isnothing(split_col)
        push!(pieces, "$(split_col): $(column_value_label(split_col, split_value))")
    end
    join(pieces, " - ")
end

function output_path(args, split_col::Union{Nothing, Symbol}, split_value, plot_index::Integer, nplots::Integer)
    output = args[:output]
    format = lstrip(args[:format], '.')

    if output_is_directory(output)
        name = if isnothing(split_col)
            "thread-scan-$(args[:metric])"
        else
            "$(args[:metric])-$(split_col)-$(safe_filename(column_value_label(split_col, split_value)))"
        end
        return joinpath(output, "$name.$format")
    end

    if nplots == 1
        return output
    end

    base, ext = splitext(output)
    suffix = if isnothing(split_col)
        string(plot_index)
    else
        "$(split_col)-$(safe_filename(column_value_label(split_col, split_value)))"
    end
    isempty(ext) && (ext = ".$format")
    return "$(base)-$(suffix)$(ext)"
end

function output_is_directory(output::AbstractString)
    isdir(output) && return true
    _, ext = splitext(output)
    isempty(ext)
end

function draw_reference!(plt, threads, metric::AbstractString)
    isempty(threads) && return
    sorted_threads = sort(unique(threads))
    if metric == "speedup"
        plot!(plt, sorted_threads, sorted_threads;
              label = "ideal",
              line = (:dash, :gray),
              marker = false)
    elseif metric == "efficiency"
        plot!(plt, sorted_threads, ones(length(sorted_threads));
              label = "ideal",
              line = (:dash, :gray),
              marker = false)
    end
end

function plot_one(df::DataFrame, args, metric_col::Symbol, group_cols::Vector{Symbol},
                  split_col::Union{Nothing, Symbol}, split_value)
    plt = plot(
        xlabel = "Threads",
        ylabel = METRIC_LABELS[args[:metric]],
        title = group_title(args, split_col, split_value),
        legend = :outerright,
        size = (args[:width], args[:height]),
        left_margin = 8Plots.mm,
        grid = true,
        marker = :circle,
    )

    for group in groupby(df, group_cols)
        sorted = sort(group, :threads)
        label = row_label(sorted[1, :], group_cols)
        plot!(plt, sorted.threads, sorted[:, metric_col];
              label = label,
              marker = :circle,
              linewidth = 2)
    end

    if !args[:no_ideal]
        draw_reference!(plt, df.threads, args[:metric])
    end

    plt
end

function main()
    args = parse_command_line(ARGS)
    metric = lowercase(args[:metric])
    if !haskey(METRIC_COLUMNS, metric)
        error("Invalid metric '$metric'. Valid metrics are: $(join(keys(METRIC_COLUMNS), ", "))")
    end
    args[:metric] = metric

    df = CSV.read(args[:summary_csv], DataFrame)
    metric_col = METRIC_COLUMNS[metric]
    group_cols = split_columns(args[:group_by])
    split_col = lowercase(args[:split_by]) == "none" ? nothing : Symbol(args[:split_by])

    required = vcat([:threads, metric_col], group_cols)
    isnothing(split_col) || push!(required, split_col)
    require_columns(df, unique(required))

    sort!(df, vcat(filter(!isnothing, [split_col]), group_cols, [:threads]))

    plot_groups = if isnothing(split_col)
        [(missing, df)]
    else
        [(group[1, split_col], DataFrame(group)) for group in groupby(df, split_col)]
    end

    if output_is_directory(args[:output])
        mkpath(args[:output])
    elseif length(plot_groups) > 1
        parent = dirname(args[:output])
        if !isempty(parent) && parent != "."
            mkpath(parent)
        end
    else
        parent = dirname(args[:output])
        if !isempty(parent) && parent != "."
            mkpath(parent)
        end
    end

    for (i, (split_value, group_df)) in enumerate(plot_groups)
        plt = plot_one(group_df, args, metric_col, group_cols, split_col, split_value)
        path = output_path(args, split_col, split_value, i, length(plot_groups))
        savefig(plt, path)
        println(path)
    end
end

main()
