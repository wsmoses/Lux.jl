## Quite a few of these are borrowed from Flux.jl

# Misc
nfan() = 1, 1 # fan_in, fan_out
nfan(n) = 1, n # A vector is treated as a n×1 matrix
nfan(n_out, n_in) = n_in, n_out # In case of Dense kernels: arranged as matrices
nfan(dims::Tuple) = nfan(dims...)
nfan(dims...) = prod(dims[1:end-2]) .* (dims[end-1], dims[end]) # In case of convolution kernels

# Neural Network Initialization
## NOTE: Would be great if these could be moved into its own package and NN frameworks
##       could just import it.
"""
    zeros32(rng::AbstractRNG, size...) = zeros(Float32, size...)

Return an `Array{Float32}` of zeros of the given `size`. (`rng` is ignored)
"""
zeros32(rng::AbstractRNG, args...; kwargs...) = zeros(rng, Float32, args...; kwargs...)

"""
    ones32(rng::AbstractRNG, size...) = ones(Float32, size...)

Return an `Array{Float32}` of ones of the given `size`. (`rng` is ignored)
"""
ones32(rng::AbstractRNG, args...; kwargs...) = ones(rng, Float32, args...; kwargs...)

Base.zeros(rng::AbstractRNG, args...; kwargs...) = zeros(args...; kwargs...)
Base.ones(rng::AbstractRNG, args...; kwargs...) = ones(args...; kwargs...)

"""
    glorot_uniform(rng::AbstractRNG, size...; gain = 1)

Return an `Array{Float32}` of the given `size` containing random numbers drawn from a uniform distribution on the interval ``[-x, x]``, where `x = gain * sqrt(6 / (fan_in + fan_out))`. This method is described in [1] and also known as Xavier initialization.

# References

[1] Glorot, Xavier, and Yoshua Bengio. "Understanding the difficulty of training deep feedforward neural networks." _Proceedings of the thirteenth international conference on artificial intelligence and statistics_. 2010.
"""
function glorot_uniform(rng::AbstractRNG, dims::Integer...; gain::Real=1)
    scale = Float32(gain) * sqrt(24.0f0 / sum(nfan(dims...)))
    return (rand(rng, Float32, dims...) .- 0.5f0) .* scale
end

"""
    glorot_normal(rng::AbstractRNG, size...; gain = 1)

Return an `Array{Float32}` of the given `size` containing random numbers drawn from a normal distribution with standard deviation `gain * sqrt(2 / (fan_in + fan_out))`. This method is described in [1] and also known as Xavier initialization.

# References

[1] Glorot, Xavier, and Yoshua Bengio. "Understanding the difficulty of training deep feedforward neural networks." _Proceedings of the thirteenth international conference on artificial intelligence and statistics_. 2010.
"""
function glorot_normal(rng::AbstractRNG, dims::Integer...; gain::Real=1)
    std = Float32(gain) * sqrt(2.0f0 / sum(nfan(dims...)))
    return randn(rng, Float32, dims...) .* std
end

# PRNG Handling
replicate(rng::AbstractRNG) = copy(rng)
replicate(rng::CUDA.RNG) = deepcopy(rng)

# Training Check
@inline istraining() = false
@inline istraining(st::NamedTuple) = st.training

# Linear Algebra
@inline _norm(x; dims=Colon()) = sqrt.(sum(abs2, x; dims=dims))
@inline _norm_except(x::AbstractArray{T,N}, except_dim=N) where {T,N} = _norm(x; dims=filter(i -> i != except_dim, 1:N))

# Convolution
function convfilter(rng::AbstractRNG, filter::NTuple{N,Integer}, ch::Pair{<:Integer,<:Integer};
                    init = glorot_uniform, groups = 1) where N
    cin, cout = ch
    @assert cin % groups == 0 "Input channel dimension must be divisible by groups."
    @assert cout % groups == 0 "Output channel dimension must be divisible by groups."
    return init(rng, filter..., cin÷groups, cout)
end

expand(N, i::Tuple) = i
expand(N, i::Integer) = ntuple(_ -> i, N)

_maybetuple_string(pad) = string(pad)
_maybetuple_string(pad::Tuple) = all(==(pad[1]), pad) ? string(pad[1])  : string(pad)

# Padding
struct SamePad end

calc_padding(lt, pad, k::NTuple{N,T}, dilation, stride) where {T,N}= expand(Val(2*N), pad)

function calc_padding(lt, ::SamePad, k::NTuple{N,T}, dilation, stride) where {N,T}
    # Ref: "A guide to convolution arithmetic for deep learning" https://arxiv.org/abs/1603.07285
    # Effective kernel size, including dilation
    k_eff = @. k + (k - 1) * (dilation - 1)
    # How much total padding needs to be applied?
    pad_amt = @. k_eff - 1
    # In case amount of padding is odd we need to apply different amounts to each side.
    return Tuple(mapfoldl(i -> [cld(i, 2), fld(i,2)], vcat, pad_amt))
end

# Handling ComponentArrays
## NOTE: We should probably upsteam some of these
Base.zero(c::ComponentArray{T,N,<:CuArray{T}}) where {T,N} = ComponentArray(zero(getdata(c)), getaxes(c))

Base.vec(c::ComponentArray{T,N,<:CuArray{T}}) where {T,N} = getdata(c)

Base.:-(x::ComponentArray{T,N,<:CuArray{T}}) where {T,N} = ComponentArray(-getdata(x), getaxes(x))

function Base.similar(c::ComponentArray{T,N,<:CuArray{T}}, l::Vararg{Union{Integer,AbstractUnitRange}}) where {T,N}
    return similar(getdata(c), l)
end

function Functors.functor(::Type{<:ComponentArray}, c)
    return NamedTuple{propertynames(c)}(getproperty.((c,), propertynames(c))), ComponentArray
end

function Optimisers.update!(st, ps::ComponentArray, gs::ComponentArray)
    Optimisers.update!(st, NamedTuple(ps), NamedTuple(gs))
    return st, ps
end

function ComponentArrays.make_carray_args(nt::NamedTuple)
    data, ax = ComponentArrays.make_carray_args(Vector, nt)
    data = length(data) == 0 ? Float32[] : (length(data)==1 ? [data[1]] : reduce(vcat, data))
    return (data, ax)
end

## For being able to print empty ComponentArrays
function ComponentArrays.last_index(f::FlatAxis)
    nt = ComponentArrays.indexmap(f)
    length(nt) == 0 && return 0
    return ComponentArrays.last_index(last(nt))
end

ComponentArrays.recursive_length(nt::NamedTuple{(), Tuple{}}) = 0

# Return Nothing if field not present
function safegetproperty(x::Union{ComponentArray,NamedTuple}, k::Symbol)
    k ∈ propertynames(x) && return getproperty(x, k)
    return nothing
end

# Getting typename
get_typename(::T) where {T} = Base.typename(T).wrapper