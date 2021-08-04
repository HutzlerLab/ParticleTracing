include("ParticleTracing.jl")
using .Tracing
Tracing.runParticleTracing("geom.surfs", "flow.DAT", stats="stats.csv")