export solve_problems

"""
    solve_problems(solver, solver_name, problems; kwargs...)

Apply a solver to a set of problems.

#### Arguments
* `solver`: the function name of a solver;
* `solver_name`: name of the solver;
* `problems`: the set of problems to pass to the solver, as an iterable of
  `AbstractNLPModel`. It is recommended to use a generator expression (necessary for
  CUTEst problems).

#### Keyword arguments
* `solver_logger::AbstractLogger`: logger wrapping the solver call (default: `NullLogger`);
* `reset_problem::Bool`: reset the problem's counters before solving (default: `true`);
* `skipif::Function`: function to be applied to a problem and return whether to skip it
  (default: `x->false`);
* `colstats::Vector{Symbol}`: summary statistics for the logger to output during the
benchmark (default: `[:name, :nvar, :ncon, :status, :elapsed_time, :objective, :dual_feas, :primal_feas]`);
* `info_hdr_override::Dict{Symbol,String}`: header overrides for the summary statistics
  (default: use default headers);
* `prune`: do not include skipped problems in the final statistics (default: `true`);
* any other keyword argument to be passed to the solver.

#### Solver-specific statistics
* Solvers can attach solver-specific information to the returned execution
  statistics object (the `s` returned by the solver). Fields contained in
  `s.solver_specific` that are scalar (i.e. not `AbstractVector`) are
  automatically appended as extra columns to the returned `DataFrame`.
* Columns for solver-specific keys are created when the first successful
  solver run returns such keys. If earlier problems were skipped or raised
  exceptions, those earlier rows will contain `missing` for these columns.
* Vector-valued entries in `s.solver_specific` are not added as individual
  columns (they are ignored by `solve_problems` when creating columns).
* When a problem is skipped or an exception occurs, the corresponding
  solver-specific columns are filled with `missing` for that row.
* To set solver-specific values from inside a solver you can use the
  solver's API / callbacks (see tests for examples where a callback calls
  `set_solver_specific!(stats, :key, value)`) — the key will appear as a
  column in the final statistics (if scalar) for all subsequently processed
  problems.

#### Return value
* a `DataFrame` where each row is a problem, minus the skipped ones if `prune` is true.
"""
function solve_problems(
  solver,
  solver_name::TName,
  problems;
  solver_logger::AbstractLogger = NullLogger(),
  reset_problem::Bool = true,
  skipif::Function = x -> false,
  colstats::Vector{Symbol} = [
    :solver_name,
    :name,
    :nvar,
    :ncon,
    :status,
    :iter,
    :elapsed_time,
    :objective,
    :dual_feas,
    :primal_feas,
  ],
  info_hdr_override::Dict{Symbol, String} = Dict{Symbol, String}(:solver_name => "Solver"),
  prune::Bool = true,
  kwargs...,
) where {TName}
  f_counters = collect(fieldnames(Counters))
  fnls_counters = collect(fieldnames(NLSCounters))[2:end] # Excludes :counters
  ncounters = length(f_counters) + length(fnls_counters)
  types = [
    TName
    Int
    String
    Int
    Int
    Int
    Symbol
    Float64
    Float64
    Int
    Float64
    Float64
    fill(Int, ncounters)
    String
  ]
  names = [
    :solver_name
    :id
    :name
    :nvar
    :ncon
    :nequ
    :status
    :objective
    :elapsed_time
    :iter
    :dual_feas
    :primal_feas
    f_counters
    fnls_counters
    :extrainfo
  ]
  stats = DataFrame(names .=> [T[] for T in types])

  specific = Symbol[]

  col_idx = indexin(colstats, names)

  first_problem = true
  nb_unsuccessful_since_start = 0
  @info log_header(colstats, types[col_idx], hdr_override = info_hdr_override)

  for (id, problem) in enumerate(problems)
    if reset_problem
      NLPModels.reset!(problem)
    end
    nequ = problem isa AbstractNLSModel ? problem.nls_meta.nequ : 0
    problem_info = [id; problem.meta.name; problem.meta.nvar; problem.meta.ncon; nequ]
    skipthis = skipif(problem)
    if skipthis
      if first_problem && !prune
        nb_unsuccessful_since_start += 1
      end
      prune || push!(
        stats,
        [
          solver_name
          problem_info
          :exception
          Inf
          Inf
          0
          Inf
          Inf
          fill(0, ncounters)
          "skipped"
          fill(missing, length(specific))
        ],
      )
      finalize(problem)
    else
      try
        s = with_logger(solver_logger) do
          solver(problem; kwargs...)
        end
        if first_problem
          for (k, v) in s.solver_specific
            if !(typeof(v) <: AbstractVector)
              insertcols!(
                stats,
                ncol(stats) + 1,
                k => Vector{Union{typeof(v), Missing}}(undef, nb_unsuccessful_since_start),
              )
              push!(specific, k)
            end
          end
          first_problem = false
        end
        counters_list =
          problem isa AbstractNLSModel ?
          [getfield(problem.counters.counters, f) for f in f_counters] :
          [getfield(problem.counters, f) for f in f_counters]
        nls_counters_list =
          problem isa AbstractNLSModel ? [getfield(problem.counters, f) for f in fnls_counters] :
          zeros(Int, length(fnls_counters))
        push!(
          stats,
          [
            solver_name
            problem_info
            s.status
            s.objective
            s.elapsed_time
            s.iter
            s.dual_feas
            s.primal_feas
            counters_list
            nls_counters_list
            ""
            [s.solver_specific[k] for k in specific]
          ],
        )
      catch e
        @error "caught exception" e
        if first_problem
          nb_unsuccessful_since_start += 1
        end
        push!(
          stats,
          [
            solver_name
            problem_info
            :exception
            Inf
            Inf
            0
            Inf
            Inf
            fill(0, ncounters)
            string(e)
            fill(missing, length(specific))
          ],
        )
      finally
        finalize(problem)
      end
    end
    (skipthis && prune) || @info log_row(stats[end, col_idx])
  end
  return stats
end
