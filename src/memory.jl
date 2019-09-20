# GPU memory management and pooling

## allocation statistics

mutable struct AllocStats
  # pool allocation requests
  pool_nalloc::Int
  pool_nfree::Int
  ## in bytes
  pool_alloc::Int

  # actual CUDA allocations
  actual_nalloc::Int
  actual_nfree::Int
  ## in bytes
  actual_alloc::Int
  actual_free::Int

  pool_time::Float64
  actual_time::Float64
end

const alloc_stats = AllocStats(0, 0, 0, 0, 0, 0, 0, 0, 0)

Base.copy(alloc_stats::AllocStats) =
  AllocStats((getfield(alloc_stats, field) for field in fieldnames(AllocStats))...)


## CUDA allocator

const usage = Ref(0)
const usage_limit = Ref{Union{Nothing,Int}}(nothing)

function actual_alloc(bytes)
  # check the memory allocation limit
  if usage_limit[] !== nothing
    if usage[] + bytes > usage_limit[]
      return nothing
    end
  end

  # try the actual allocation
  try
    alloc_stats.actual_time += Base.@elapsed begin
      buf = Mem.alloc(Mem.Device, bytes)
    end
    alloc_stats.actual_nalloc += 1
    alloc_stats.actual_alloc += bytes
    usage[] += bytes
    return buf
  catch ex
    ex == CUDAdrv.ERROR_OUT_OF_MEMORY || rethrow()
  end

  return nothing
end

function actual_free(buf)
  alloc_stats.actual_nfree += 1
  alloc_stats.actual_free += sizeof(buf)
  usage[] -= sizeof(buf)

  if CUDAdrv.isvalid(buf.ctx)
    alloc_stats.actual_time += Base.@elapsed Mem.free(buf)
  end

  return
end


## pool timings

using TimerOutputs

const pool_to = TimerOutput()

macro pool_timeit(args...)
    TimerOutputs.timer_expr(__module__, false, :($CuArrays.pool_to), args...)
end


## pool implementations

# API:
# - init()
# - deinit()
# - alloc(sz)::Mem.Buffer
# - free(::Mem.Buffer)
# - used_memory()
# - cached_memory()

include("memory/binned.jl")
include("memory/simple.jl")
include("memory/split.jl")
include("memory/dummy.jl")

const pool = Ref{Union{Nothing,Module}}(nothing)

const requested = Dict{Mem.Buffer,Int}()

@inline function alloc(sz)
  @assert pool[] !== nothing "Cannot allocate before CuArrays has been initialized."
  alloc_stats.pool_time += Base.@elapsed begin
    @pool_timeit "pooled alloc" buf = pool[].alloc(sz)
  end
  if buf === nothing
    @error "Out of GPU memory trying to allocate $(Base.format_bytes(sz))"
    pool[].dump()
    memory_status()
    throw(OutOfMemoryError())
  end

  @assert sizeof(buf) >= sz
  alloc_stats.pool_nalloc += 1
  alloc_stats.pool_alloc += sz
  @assert !haskey(requested, buf)
  requested[buf] = sz

  return buf
end

@inline function free(buf)
  @assert haskey(requested, buf)
  delete!(requested, buf)

  alloc_stats.pool_nfree += 1
  alloc_stats.pool_time += Base.@elapsed begin
    @pool_timeit "pooled free" pool[].free(buf)
  end

  return
end

function __init_memory__()
  if haskey(ENV, "CUARRAYS_MEMORY_LIMIT")
    usage_limit[] = parse(Int, ENV["CUARRAYS_MEMORY_LIMIT"])
  end

  if haskey(ENV, "CUARRAYS_MEMORY_POOL")
    memory_pool!(
      if ENV["CUARRAYS_MEMORY_POOL"] == "binned"
        BinnedPool
      elseif ENV["CUARRAYS_MEMORY_POOL"] == "simple"
        SimplePool
      elseif ENV["CUARRAYS_MEMORY_POOL"] == "split"
        SplittingPool
      elseif ENV["CUARRAYS_MEMORY_POOL"] == "none"
        DummyPool
      else
        error("Invalid allocator selected")
      end)
  else
    memory_pool!()
  end

  # if the user hand-picked an allocator, be a little verbose
  if haskey(ENV, "CUARRAYS_MEMORY_POOL")
    atexit(()->begin
      Core.println("""
        CuArrays.jl $(nameof(pool[])) statistics:
         - $(alloc_stats.pool_nalloc) pool allocations: $(Base.format_bytes(alloc_stats.pool_alloc)) in $(round(alloc_stats.pool_time; digits=2))s
         - $(alloc_stats.actual_nalloc) CUDA allocations: $(Base.format_bytes(alloc_stats.actual_alloc)) in $(round(alloc_stats.actual_time; digits=2))s""")
    end)
  end
end

function memory_pool!(mod::Module=BinnedPool)
  if pool[] !== nothing
    pool[].deinit()
  end

  TimerOutputs.reset_timer!(pool_to)

  pool[] = mod
  mod.init()

  return
end


## utilities

using Printf

macro allocated(ex)
    quote
        let
            local f
            function f()
                b0 = alloc_stats.pool_alloc
                $(esc(ex))
                alloc_stats.pool_alloc - b0
            end
            f()
        end
    end
end

macro time(ex)
    quote
        local gpu_mem_stats0 = copy(alloc_stats)
        local cpu_mem_stats0 = Base.gc_num()
        local cpu_time0 = time_ns()

        local val = $(esc(ex))

        local cpu_time1 = time_ns()
        local cpu_mem_stats1 = Base.gc_num()
        local gpu_mem_stats1 = copy(alloc_stats)

        local cpu_time = (cpu_time1 - cpu_time0) / 1e9
        local gpu_gc_time = gpu_mem_stats1.pool_time - gpu_mem_stats0.pool_time
        local gpu_alloc_count = gpu_mem_stats1.pool_nalloc - gpu_mem_stats0.pool_nalloc
        local gpu_lib_time = gpu_mem_stats1.actual_time - gpu_mem_stats0.actual_time
        local gpu_alloc_size = gpu_mem_stats1.pool_alloc - gpu_mem_stats0.pool_alloc
        local cpu_mem_stats = Base.GC_Diff(cpu_mem_stats1, cpu_mem_stats0)
        local cpu_gc_time = cpu_mem_stats.total_time / 1e9
        local cpu_alloc_count = Base.gc_alloc_count(cpu_mem_stats)
        local cpu_alloc_size = cpu_mem_stats.allocd

        Printf.@printf("%10.6f seconds", cpu_time)
        for (typ, gctime, libtime, bytes, allocs) in
            (("CPU", cpu_gc_time, 0, cpu_alloc_size, cpu_alloc_count),
             ("GPU", gpu_gc_time, gpu_lib_time, gpu_alloc_size, gpu_alloc_count))
          if bytes != 0 || allocs != 0
              allocs, ma = Base.prettyprint_getunits(allocs, length(Base._cnt_units), Int64(1000))
              if ma == 1
                  Printf.@printf(" (%d%s %s allocation%s: ", allocs, Base._cnt_units[ma], typ, allocs==1 ? "" : "s")
              else
                  Printf.@printf(" (%.2f%s %s allocations: ", allocs, Base._cnt_units[ma], typ)
              end
              print(Base.format_bytes(bytes))
              if gctime > 0
                  Printf.@printf(", %.2f%% gc time", 100*gctime/cpu_time)
                if libtime > 0
                    Printf.@printf(" of which %.2f%% spent allocating", 100*libtime/gctime)
                end
              end
              print(")")
          elseif gctime > 0
              Printf.@printf(", %.2f%% %s gc time", 100*gctime/cpu_time, typ)
          end
        end
        println()

        val
    end
end

function memory_status()
  free_bytes, total_bytes = CUDAdrv.Mem.info()
  used_bytes = total_bytes - free_bytes
  used_ratio = used_bytes / total_bytes

  @printf("Effective GPU memory usage: %.2f%% (%s/%s)\n",
          100*used_ratio, Base.format_bytes(used_bytes),
          Base.format_bytes(total_bytes))

  @printf("CuArrays GPU memory usage: %s", Base.format_bytes(usage[]))
  if usage_limit[] !== nothing
    @printf(" (capped at %s)", Base.format_bytes(usage_limit[]))
  end
  println()

  alloc_used_bytes = pool[].used_memory()
  alloc_cached_bytes = pool[].cached_memory()
  alloc_total_bytes = alloc_used_bytes + alloc_cached_bytes

  @printf("%s usage: %s (%s allocated, %s cached)\n", nameof(pool[]),
          Base.format_bytes(alloc_total_bytes), Base.format_bytes(alloc_used_bytes),
          Base.format_bytes(alloc_cached_bytes))

  requested_bytes = reduce(+, values(requested); init=0)

  @printf("%s efficiency: %.2f%% (%s requested, %s allocated)\n", nameof(pool[]),
          100*requested_bytes/usage[],
          Base.format_bytes(requested_bytes),
          Base.format_bytes(usage[]))

  # check if the memory usage as counted by the CUDA allocator wrapper
  # matches what is reported by the pool implementation
  discrepancy = usage[] - alloc_total_bytes
  if discrepancy != 0
    @debug "Discrepancy of $(Base.format_bytes(discrepancy)) between memory pool and allocator"
  end
end

pool_timings() = (show(pool_to; allocations=false, sortby=:name); println())

pool_dump() = pool[].dump()
