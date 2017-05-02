export Model, back!, update!, param

# Basic model API

"""
    (m::Model)(X...) => Y

A "model" is a function with state. For example, a logistic regression is the
function

    x -> σ(x * W + b)

where `W` and `b` are a trainable matrix and vector of weights repectively. The
`Model` abstract type is used loosely; in general the concept of a model is
closer to a protocol, and models don't need to inherit from this type. Normal
Julia functions are models with 0 parameters, for example.
"""
abstract type Model end

"""
    back!(m::Model, ΔY, X...) => ΔX

Backpropagate the gradient `ΔY` through the model `m`, accumulating the
gradients of any parameters. Returns the gradient of the input `X`. Gradients
may be arrays or tuples of arrays (for multiple inputs/outputs).
"""
back!(m::Model, Δ, xs...) = error("Backprop not implemented for $(typeof(m))")

"""
    update!(m::Model, η) => m

Update the parameters of the model `m` using the accumulated gradients from
`back!`, using the learning rate `η`.
"""
update!(m, η) = m

"""
    graph(m::Model) => ::IVertex{Any} | nothing

Returns the graph representation of the model, if any. Most models are built
from lower-level components and can simply implement this method to get most of
Flux's functionality. If this method isn't available, functionality like
backpropagation or conversion for backend must be implemented on a case-by-case
basis. Alternatively, one can implement this method and override individual
methods as necessary.
"""
graph(m) = nothing

"""
`runmodel(m, ...)` is like `m(...)`, i.e. it runs the forward pass. However,
unlike direct calling, it does not try to apply batching and simply uses the
inputs directly.

This function should be considered an implementation detail; it will be
eventually be replaced by a non-hacky way of doing batching.
"""
function runmodel end

# Model parameters

# TODO: should be AbstractArray?
"""
A `Param` object stores a parameter array along with its gradient.
When converting to backends like TensorFlow, identical `Param`s will
result in identical variable objects.
"""
struct Param{T}
  x::T
  Δx::T
end

"""
    param(x::T) => ::Param{T}

Convenience method for creating a `Param` object for a given array.
"""
param(x) = Param(x, zero(x))

state(p::Param) = p.x

"""
    update!(p::Param)

Apply the accumulated updates to the value of the parameter.
"""
function update!(p::Param, η)
  p.x .-= p.Δx .* η
  p.Δx[:] = 0
  return p
end

state(x) = x

Base.size(p::Param) = size(p.x)
Base.size(p::Param, n) = size(p.x, n)

function Base.show(io::IO, p::Param)
  print(io, "Param", size(p.x))
end

Base.copy!(xs, p::Param) = copy!(xs, p.x)
Base.copy!(p::Param, xs) = copy!(p.x, xs)

# Anonymous models

export Capacitor

struct Capacitor <: Model
  graph::IVertex{Any}
end

(m::Capacitor)(xs...) = interpmodel(m, xs...)

graph(cap::Capacitor) = cap.graph

# Recurrent Models

mutable struct Stateful <: Model
  model
  istate::Vector{Any}
  ostate::Vector{Any}
end

Stateful(model, state) = Stateful(model, state, state)

function (m::Stateful)(x)
  m.istate = m.ostate
  state, y = runmodel(m.model, (m.istate...,), x)
  m.ostate = collect(state)
  return y
end

function back!(m::Stateful, Δ, x)
  back!(m.model, ((zeros.(m.ostate)...,), Δ), (m.istate...,), x)[2:end]
end

update!(m::Stateful, η) = update!(m.model, η)

stateless(m) = m
stateless(m::Stateful) = m.model

struct SeqModel <: Model
  model
  steps::Int
end

runseq(f, xs::Tuple...) = f(xs...)
runseq(f, xs::AbstractArray...) = stack(f(map(x -> (unstack(x,2)...,), xs)...), 2)
runseq(f, xs::BatchSeq...) = rebatchseq(runseq(f, rawbatch.(xs)...))

function (m::SeqModel)(x)
  runseq(x) do x
    @assert length(x) == m.steps "Expected seq length $(m.steps), got $(size(x, 2))"
    m.model(x)
  end
end

back!(m::SeqModel, Δ, x) = (runseq((Δ, x) -> back!(m.model, Δ, x)[1], Δ, x),)

update!(m::SeqModel, η) = update!(m.model, η)