module Tracing

using Distributed
using Random
using LinearAlgebra
using NearestNeighbors
using CSV
using DataFrames
using Printf
using OnlineStats
using SpecialFunctions

import Base: convert

# Data structures and functions for tracking trajectory statistics

# Statistics to be recorded for each grid cell. Currently includes velocity, time, number of collisions, and free path
struct TrajStats
    v::OnlineStat
    t::OnlineStat
    ncolls::OnlineStat
    lfree::OnlineStat
end

@inline TrajStats() = TrajStats(CovMatrix(2), Variance(), Variance(), Variance())

# Grid of TrajStats, including spatial information for indexing
struct StatsArray
    stats::Matrix{TrajStats}
    minr::Float64
    maxr::Float64
    rbins::Int
    minz::Float64
    maxz::Float64
    zbins::Int
    rstep::Float64
    zstep::Float64
end

@inline function StatsArray(minr, maxr, rbins, minz, maxz, zbins)
    stats = Array{TrajStats}(undef, rbins, zbins)
    for i in 1:rbins
        for j in 1:zbins
            stats[i,j] = TrajStats()
        end
    end
    return StatsArray(stats, minr, maxr, rbins, minz, maxz, zbins, rbins/(maxr-minr), zbins/(maxz-minz))
end

# Updates a StatsArray given a position and the value of the statistics
@inline function updateStats!(s::StatsArray, x, v, t, ncolls, lfree)
    r = sqrt(x[1]^2+x[2]^2)
    ridx = min(s.rbins, 1+floor(Int, s.rstep*(r-s.minr)))
    zidx = min(s.zbins, 1+floor(Int, s.zstep*(x[3]-s.minz)))
    fit!(s.stats[ridx, zidx].v, [(-x[2]*v[1]+x[1]*v[2])/sqrt(x[1]^2+x[2]^2),v[3]])
    fit!(s.stats[ridx, zidx].t, t)
    fit!(s.stats[ridx, zidx].ncolls, ncolls)
    fit!(s.stats[ridx, zidx].lfree, lfree)
    return s.stats[ridx, zidx]
end

# Merges two StatsArrays by merging each statistic for each cell
# TODO: Improve performance by only merging cells that the particle passed through (keep track of active cells)?
@inline function merge!(a::StatsArray, b::StatsArray)
    for i in 1:a.rbins
        for j in 1:a.zbins
            OnlineStats.merge!(a.stats[i,j].v, b.stats[i,j].v)
            OnlineStats.merge!(a.stats[i,j].t, b.stats[i,j].t)
            OnlineStats.merge!(a.stats[i,j].ncolls, b.stats[i,j].ncolls)
            OnlineStats.merge!(a.stats[i,j].lfree, b.stats[i,j].lfree)
        end
    end
    return a
end

# Converts a StatsArray to a matrix with rows r, z, n, t, tvar, vr, vz, vrcov, vzcov, vrvzcov, ncolls, ncollsvar, lfree, lfreevar
@inline function convert(::Type{Matrix}, s::StatsArray)
    M = Array{Float64}(undef, s.rbins*s.zbins, 14)
    idx = 1
    for i in 1:s.rbins
        for j in 1:s.zbins
            stats = s.stats[i,j]
            M[idx,1] = s.minr+(i-0.5)/s.rstep
            M[idx,2] = s.minz+(j-0.5)/s.zstep
            M[idx,3] = stats.t.n
            M[idx,4] = stats.t.??
            M[idx,5] = stats.t.??2
            M[idx,6] = stats.v.b[1]
            M[idx,7] = stats.v.b[2]
            M[idx,8] = stats.v.A[1,1]
            M[idx,9] = stats.v.A[2,2]
            M[idx,10] = stats.v.A[1,2]
            M[idx,11] = stats.ncolls.??
            M[idx,12] = stats.ncolls.??2
            M[idx,13] = stats.lfree.??
            M[idx,14] = stats.lfree.??2
            idx += 1
        end
    end
    return M
end

# Converts a StatsArray to a DataFrame with rows r, z, n, t, tvar, vr, vz, vrcov, vzcov, vrvzcov, ncolls, ncollsvar, lfree, lfreevar
@inline function convert(::Type{DataFrame}, s::StatsArray)
    m = convert(Matrix, s)
    df = DataFrame(m, [:r, :z, :n, :t, :tvar, :vr, :vz, :vrvar, :vzvar, :vrvzcov, :ncolls, :ncollsvar, :lfree, :lfreevar])
    return df
end

# Parse command line arguments
args = Dict(
    "geom" => "",
    "flow" => "",
    "n" => 10000,
    "z" => 0.035,
    "r" => 0.0,
    "vz" => 0.0,
    "vr" => 0.0,
    "T" => 0.0,
    "m" => 4.0,
    "M" => 191.0,
    "sigma" => 130E-20,
    "omega" => 0.0,
    "zmin" => -Inf,
    "zmax" => Inf,
    "pflip" => 0.0,
    "saveall" => 0,
    "stats" => nothing,
    "exitstats" => nothing
)

# Set global constants
MASS_PARTICLE = args["M"] # AMU
MASS_BUFFER_GAS = args["m"] # AMU
MASS_REDUCED = MASS_PARTICLE * MASS_BUFFER_GAS /
    (MASS_PARTICLE + MASS_BUFFER_GAS) # AMU
kB = 8314.46 # AMU m^2 / (s^2 K)
??_BUFFER_GAS_PARTICLE = args["sigma"] # m^2
outputFile = stdout

# Setup for rejection sampling of collision velocities

# Parameters for proposal distribution for rejection sampling
struct SampleParams
    ??_vg::Float64
    ??_vg::Float64
    ??_??::Float64
end

# Table of parameters for proposal distribution for rejection sampling for different values of temperature T and relative velocity U
struct LookupTable
    Tmin::Float64
    Tstep::Float64
    Tmax::Float64
    nT::Int64
    Umin::Float64
    Ustep::Float64
    Umax::Float64
    nU::Int64
    table::Matrix{SampleParams}
end

# Evaluates the PDF of a Gaussian distribution with mean ?? and standard deviation ?? at x
@inline function g(x, ??, ??)
    exp(-0.5*((x-??)/??)^2)/(??*sqrt(2*??))
end

# Given a mean relative velocity u, temperature T and parameters for proposal distributions ??_vg, ??_vg, ??_??, uses rejection sampling to draw relative speeds v_g and angles ?? from the relative velocity. M describes the threshold for accepting a sample. M should be higher if the proposal distribution is farther from the correct distribution.
function sample(u, T, ??_vg, ??_vg, ??_??, M=2.0)
    if T < 1E-2
        return (u, 0.0)
    end
    v_g = 0.0
    ?? = 0.0
    bessel = 0.0
    i = 0
    imax = 50*M
    while true
        y = abs(??_vg + ??_vg * Random.randn())
        bessel = SpecialFunctions.besseli(0, min(MASS_BUFFER_GAS*u*y/(kB*T), 10))
        f_y = exp(-MASS_BUFFER_GAS*(u^2+y^2)/(2*kB*T)) * y * bessel * MASS_BUFFER_GAS / (kB*T)
        r = f_y/(M*g(y, ??_vg, ??_vg))
        if Random.rand() < r
            v_g = y
            break
        end
        if i > imax
            println(stderr, "Maximum iterations exceeded in sampling v_g for u $u, T $T.")
            v_g = ??_vg
            break
        end
        i += 1
    end
    i = 0
    while true
        y = abs(??_?? * Random.randn())
        f_y = exp(MASS_BUFFER_GAS * u * v_g * cos(y) / (kB*T)) / (pi * bessel)
        r = f_y/(2*M*g(y, 0, ??_??))
        if Random.rand() < r && y < ??
            ?? = y
            break
        end
        if i > imax
            println(stderr, "Maximum iterations exceeded in sampling ?? for u $u, T $T.")
            v_g = ??_vg
            break
        end
        i += 1
    end
    return v_g, ??
end

# Given temperature, mean relative velocity, and a lookup table, samples collision velocities
function sample(u, T, table, M=2.0)
    i_T = max(1,min(round(Int64, (T - table.Tmin) / table.Tstep), table.nT))
    i_U = max(1,min(round(Int64, (u - table.Umin) / table.Ustep), table.nU))
    p = table.table[i_T, i_U]
    return sample(max(table.Umin,min(u, table.Umax)), max(table.Tmin,min(T, table.Tmax)), p.??_vg, 1.5*p.??_vg, 3*p.??_??, M)
end

# Generates a lookup table of means and standard deviations for Gaussian proposal distributions for rejection sampling.
function generate_lookup_table(Tmin, Tstep, Tmax, Umin, Ustep, Umax, nsamples=100, Msample=20)
    Ts = Tmin:Tstep:Tmax
    Us = Umin:Ustep:Umax
    table = LookupTable(Tmin, Tstep, Tmax, length(Ts), Umin, Ustep, Umax, length(Us), Matrix{SampleParams}(undef, length(Ts), length(Us)))
    for (i, T) in enumerate(Ts)
        for (j, U) in enumerate(Us)
            ??_vg = 1.5*sqrt(8*kB*(T+0.2)/(??*MASS_BUFFER_GAS))
            ??_?? = 1.5*pi*??_vg/(??_vg+U)
            ??_vg = U + ??_vg
            vg_samples = zeros(nsamples)
            ??_samples = zeros(nsamples)
            for i in 1:nsamples
                vg_samples[i], ??_samples[i] = sample(U, T, ??_vg, ??_vg, ??_??, Msample)
            end
            table.table[i,j] = SampleParams(mean(vg_samples), std(vg_samples), std(??_samples))
        end
    end
    return table
end

"""
    collide!(v, vgx, vgy, vgz, T)

Accepts as input the velocity of a particle v, the mean velocity of a buffer gas atom vgx, vgy, vgz, and the buffer gas temperature T. Computes the velocity of the particle after they undergo a collision, treating the particles as hard spheres and assuming a random scattering parameter and buffer gas atom velocity (assuming the particles are moving slower than the buffer gas atoms). Follows Appendices B and C of Boyd 2017. Note that v and vg are modified.
"""
@inline function collide!(v, vg, T, table)
    u = sqrt((v[1]-vg[1])^2+(v[2]-vg[2])^2+(v[3]-vg[3])^2)
    vgmag, ?? = sample(u, T, table)
    if u < 1E-3
        vgdir = LinearAlgebra.normalize(Random.rand(3) .- 0.5)
    else
        vgdir = (vg - v) ./ u
    end
    vrand = LinearAlgebra.normalize(Random.rand(3) .- 0.5)
    vperp = LinearAlgebra.normalize(vrand .- dot(vrand, vgdir) .* vgdir)
    vg = v .+ vgmag .* (cos(??) .* vgdir .+ sin(??) .* vperp)
    cos?? = 2*Random.rand() - 1
    sin?? = sqrt(1 - cos??^2)
    ?? = 2 * ?? * Random.rand()
    g = sqrt((v[1] - vg[1])^2 + (v[2] - vg[2])^2 + (v[3] - vg[3])^2)
    v[1] = MASS_PARTICLE * v[1] + MASS_BUFFER_GAS * (vg[1] + g * cos??)
    v[2] = MASS_PARTICLE * v[2] + MASS_BUFFER_GAS * (vg[2] + g * sin?? * cos(??))
    v[3] = MASS_PARTICLE * v[3] + MASS_BUFFER_GAS * (vg[3] + g * sin?? * sin(??))
    v .= v ./ (MASS_PARTICLE + MASS_BUFFER_GAS)
end

"""
    freePropagate!(xnext, x, v, d, ??)

Updates xnext by propagating a particle at x with velocity v a distance d in a harmonic potential with frequency ??
"""
@inline function freePropagate!(xnext, x, v, t, ??)
    xnext[3] = x[3] + v[3]*t
    if ?? != 0
        pm = sign(??)
        ?? = abs(??)
        if pm > 0
            sint = sin(sqrt(2.0)*??*t)
            cost = cos(sqrt(2.0)*??*t)
            xnext[1] = x[1]*cost + v[1]*sint/(sqrt(2.0)*??)
            xnext[2] = x[2]*cost + v[2]*sint/(sqrt(2.0)*??)
            v[1] = v[1]*cost-2*x[1]*??*sint
            v[2] = v[2]*cost-2*x[2]*??*sint
        else
            sint = sinh(sqrt(2.0)*??*t)
            cost = cosh(sqrt(2.0)*??*t)
            xnext[1] = x[1]*cost + v[1]*sint/(sqrt(2.0)*??)
            xnext[2] = x[2]*cost + v[2]*sint/(sqrt(2.0)*??)
            v[1] = v[1]*cost+2*x[1]*??*sint
            v[2] = v[2]*cost+2*x[2]*??*sint
        end
    else
        xnext[1] = x[1] + v[1]*t
        xnext[2] = x[2] + v[2]*t
    end
end

# Propagates a particle to its next collision by updating xnext. Assumes starting position x, starting velocity v, a step distance of d, and a trap of frequency ?? between zmin and zmax.
@inline function freePropagate!(xnext, x, v, d, ??, zmin, zmax)
    vmag = sqrt(v[1]^2+v[2]^2+v[3]^2)
    if vmag < 1E-6
        return
    end
    t = d/vmag
    x3next = x[3]+v[3]*t
    if x[3] > zmax && x3next < zmax
        t1 = (x[3] - zmax)/v[3]
        freePropagate!(xnext, x, v, t1, 0)
        xnext[3] = zmax
        d -= sqrt((x[1]-xnext[1])^2+(x[2]-xnext[2])^2+(x[3]-xnext[3])^2)
        return freePropagate!(xnext, deepcopy(xnext), v, d, ??, zmin, zmax)
    elseif x[3] < zmax && x3next > zmax
        t1 = (zmax - x[3])/v[3]
        freePropagate!(xnext, x, v, t1, ??)
        xnext[3] = zmax
        d -= sqrt((x[1]-xnext[1])^2+(x[2]-xnext[2])^2+(x[3]-xnext[3])^2)
        return freePropagate!(xnext, deepcopy(xnext), v, d, 0, zmin, zmax)
    elseif x[3] > zmin && x3next < zmin
        t1 = (x[3] - zmin)/v[3]
        freePropagate!(xnext, x, v, t1, 0)
        xnext[3] = zmin
        d -= sqrt((x[1]-xnext[1])^2+(x[2]-xnext[2])^2+(x[3]-xnext[3])^2)
        return freePropagate!(xnext, deepcopy(xnext), v, d, ??, zmin, zmax)
    elseif x[3] < zmin && x3next > zmin
        t1 = (zmin - x[3])/v[3]
        freePropagate!(xnext, x, v, t1, ??)
        xnext[3] = zmin
        d -= sqrt((x[1]-xnext[1])^2+(x[2]-xnext[2])^2+(x[3]-xnext[3])^2)
        return freePropagate!(xnext, deepcopy(xnext), v, d, 0, zmin, zmax)
    end
    if zmin < x[3] < zmax
        return freePropagate!(xnext, x, v, t, ??)
    else
        return freePropagate!(xnext, x, v, t, 0)
    end
end

"""
    freePath(vrel, T, ??)

Accepts as input the velocity of a particle relative to a buffer gas atom v, the buffer gas temperature T and the buffer gas density ??. Draws a distance the particle travels before it hits a buffer gas atom from an exponential distribution, accounting for a velocity-dependent mean free path. Note that this assumes that the gas properties don't change significantly over a mean free path.
"""
@inline function freePath(v, vrel, T, ??)
    ?? = sqrt(v[1]^2 + v[2]^2 + v[3]^2)/(??*??_BUFFER_GAS_PARTICLE*sqrt(8*kB*T/(MASS_BUFFER_GAS*pi) + vrel^2))
    return min(-log(Random.rand()) * ??, 1000.0)
end

"""
    getIntersection(x1, x2, y2, x3, y3, x4, y4)

Returns whether the line segments ((x1, y1), (x2, y2)) and ((x3, y3), (x4, y4)) intersect. See "Faster Line Segment Intersection" from Graphics Gems III ed. David Kirk.
"""
@inline function getIntersection(x1, y1, x2, y2, x3, y3, x4, y4)
    denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    num = x4*(y1 - y3) + x1*(y3-y4) + x3*(y4-y1)
    if denom > 0
        if num < 0 || num > denom
            return false
        end
        num = x3*(y2 - y1) + x2*(y1 - y3) + x1*(y3-y2)
        if num < 0 || num > denom
            return false
        end
    else
        if num > 0 || num < denom
            return false
        end
        num = x3*(y2 - y1) + x2*(y1 - y3) + x1*(y3-y2)
        if num > 0 || num < denom
            return false
        end
    end
    return true
end


"""
    propagate(xinit, vin, interp!, getCollision, omega=0.0)

Accepts as input the position of a particle xinit, its velocity v, the function interp!, which takes as input a position and a vector and updates the vector to describe the gas [x, y, vgx, vgy, vgz, T, ??], and the function getCollision(x1, x2), which returns whether if the segment from x1 to x2 intersects geometry. Computes the path of the particle until it getCollision returns true. Returns a vector of simulation results with elements x, y, z, xnext, ynext, znext, vx, vy, vz, collides, time.
"""
@inline function propagate(xinit, vin, interp!, getCollision, table, ??=0.0, zmin=-Inf, zmax=Inf, pflip=0.0, stats=nothing)
    x = deepcopy(xinit)
    props = zeros(8) # x, y, vgx, vgy, vgz, T, ??, dmin
    interp!(props, x)
    xnext = deepcopy(x)
    v = deepcopy(vin)
    time = 0.0
    collides = 0
    
    # If nearly stationary, provide a first collision
    if LinearAlgebra.norm(v) < 1E-6
        collide!(v, view(props, 3:5), props[6], table)
        collides += 1
    end

    # Randomize the spin
    if rand() < 0.5
        ?? = -??
    end

    while true
        interp!(props, x)
        vrel = sqrt((v[1] - props[3])^2 + (v[2] - props[4])^2 + (v[3] - props[5])^2)
        dist = freePath(v, vrel, props[6], props[7])
        freePropagate!(xnext, x, v, dist, ??, zmin, zmax)
        if getCollision(x, xnext) != 0
            return (x[1], x[2], x[3], xnext[1], xnext[2], xnext[3], v[1], v[2], v[3], collides, time)
        else
            time += dist / LinearAlgebra.norm(v)
            collides += 1
        end
        if !isnothing(stats)
            updateStats!(stats, x, v, time, collides, dist)
        end
        x .= xnext
        collide!(v, view(props, 3:5), props[6], table)
        if rand() < pflip
            ?? = -??
        end
    end
end

# Initializes a variable to track the number of interpolation lookups performed
interps = 0

"""
    SimulateParticles(geomFile, gridFile, nParticles, generateParticle)

    Runs nParticles simulations using the SPARTA outputs with paths geomFile and gridFile to define the surfaces and buffer gas properties. Generates each particle with position and velocity returned by generateParticle. Returns a nParticles by 11 matrix of simulation results, with columns x, y, z, xnext, ynext, znext, vx, vy, vz, collides, time.
"""
function SimulateParticles(
    geomFile, 
    gridFile, 
    nParticles,
    generateParticle,
    print_stuff=true,
    ??=0.0,
    zmin=-Inf,
    zmax=Inf,
    pflip=0.0,
    saveall=0,
    savestats=nothing,
    saveexitstats=nothing,
    rbins=100,
    zbins=100
    )

    bounds = Matrix(CSV.read(geomFile, DataFrame, header = ["min","max"], skipto=6, limit=2,ignorerepeated=true,delim=' '))
    geom = Matrix(CSV.read(geomFile, DataFrame, header=["ID","x1","y1","x2","y2"],skipto=10, ignorerepeated=true,delim=' '))
    griddf = CSV.read(gridFile, DataFrame, header=["x","y","T","??","??m","vx","vy","vz"],skipto=10,ignorerepeated=true,delim=' ')

    # Reorder columns and only include grid cells with data
    DataFrames.select!(griddf, [:x, :y, :vx, :vy, :vz, :T, :??])
    griddf = griddf[griddf.T .> 0, :]
    griddf[!, :dmin] .= 0
    grids = Matrix(griddf)

    # Make a tree for efficient nearest neighbor search
    kdtree = KDTree(transpose(Matrix(grids[:,1:2])); leafsize=10)

    # For each point, find the 100 nearest neighbors and compute the distance of the closest point at which any of the parameters varies by more than 20%. Add that distance as a column to grid. This is used to reduce the number of nearest neighbor searches required.

    err = 0.2
    for i in 1:size(grids)[1]
        idxs, dists = knn(kdtree, grids[i,[1,2]], 100, true)
        for (j, idx) in enumerate(idxs)
            for k in [3,4,5,6,7]
                if !(err*grids[i,k] < grids[idx,k] < (1+err)*grids[i,k])
                    grids[i, 8] = dists[j]
                    break
                end
            end
        end
    end

    @printf(stderr, "Mean dmin: %f\n", sum(grids[:,8]/size(grids)[1]))

    # Set up the lookup table for sampling collision velocities
    Tmin = minimum(griddf.T)
    Tmax = maximum(griddf.T)
    Tstep = (Tmax - Tmin) / 20
    Umin = 0.0
    Umax = 1.5*maximum(sqrt.(griddf.vx.^2 .+ griddf.vy.^2))
    Ustep = (Umax - Umin) / 20
    table = generate_lookup_table(Tmin, Tstep, Tmax, Umin, Ustep, Umax)

    """
        interpolate!(props, x)
    
    Updates the gas properties props with the data from point x.
    """
    @inline function interpolate!(props, x)
        # props: x, y, vgx, vgy, vgz, T, ??, dmin
        if sqrt((x[3] - props[1])^2 + (sqrt(x[1]^2 + x[2]^2) - props[2])^2) > props[8]
            global interps
            interps += 1
            interp = view(grids, knn(kdtree, [x[3], sqrt(x[1]^2 + x[2]^2)], 1)[1][1], :)
            props[1] = interp[1]            # x 
            props[2] = interp[2]            # y
            ?? = atan(x[2],x[1])
            props[3] = interp[4] * cos(??)   # vgx
            props[4] = interp[4] * sin(??)   # vgy
            props[5] = interp[3]            # vgz
            props[6] = interp[6]            # T
            props[7] = interp[7]            # ??
            props[8] = interp[8]
        end
    end

    """
        getCollision(x1, x2)

    Checks whether the line between x1 and x2 intersects geometry or the boundary of the simulation region. Returns 0 if no collision, 1 if the particle collides with geometry, or 2 if the particle leaves the simulation bounds
    """
    @inline function getCollision(x1, x2)
        r1 = sqrt(x1[1]^2 + x1[2]^2)
        r2 = sqrt(x2[1]^2 + x2[2]^2)
        for i in 1:size(geom)[1]
            if getIntersection(geom[i,2],geom[i,3],geom[i,4],geom[i,5],x1[3],r1,x2[3],r2)
                return 1
            end
        end
        if x2[3] < bounds[1,1] || x2[3] > bounds[1,2] || r2 > bounds[2,2]
            return 2
        end
        return 0
    end

    # Runs one simulation to check the length of the output array
    output_dim = length(propagate(zeros(3), zeros(3), interpolate!, (x,y)->true, table))
    outputs = zeros(nParticles, output_dim)

    # Initializes statistics arrays
    if !isnothing(savestats)
        allstats = StatsArray(bounds[2,1], bounds[2,2], rbins, bounds[1,1], bounds[1,2], zbins)
    end
    if !isnothing(saveexitstats)
        boundstats = StatsArray(bounds[2,1], bounds[2,2], rbins, bounds[1,1], bounds[1,2], zbins)
    end
    
    Threads.@threads for i in 1:nParticles
        stats = nothing
        if !isnothing(saveexitstats) || !isnothing(savestats)
            stats = StatsArray(bounds[2,1], bounds[2,2], rbins, bounds[1,1], bounds[1,2], zbins)
        end
        xpart, vpart = generateParticle()
        outputs[i,:] .= propagate(xpart, vpart, interpolate!, getCollision, table, ??, zmin, zmax, pflip, stats)
        colltype = getCollision(outputs[i,[1,2,3]], outputs[i,[4,5,6]])
        if !isnothing(savestats)
            merge!(allstats, stats)
        end
        if colltype == 2 && !isnothing(saveexitstats)
            merge!(boundstats, stats)
        end
        if print_stuff && (saveall != 0 || colltype == 2)
            println(outputFile, @sprintf("%d %e %e %e %e %e %e %e %e %e %d %e", i, 
            outputs[i,1], outputs[i,2], outputs[i,3], outputs[i,4], outputs[i,5], outputs[i,6], outputs[i,7], outputs[i,8], outputs[i,9], outputs[i,10], outputs[i,11]))
        end
    end
    
    return outputs, boundstats, allstats
end

"""
    main()

The main function starts a particle simulation based on the command line arguments, printing outputs to stdout and timing information to stderr.
"""
function main(args)

    nParticles = args["n"]

    println(outputFile, "idx x y z xnext ynext znext vx vy vz collides time")

    # Define particle generation
    boltzmann = sqrt(kB*args["T"]/MASS_PARTICLE)
    generateParticle() = (
        [args["r"], 0.0, args["z"]],
        [args["vr"] + Random.randn() * boltzmann, Random.randn() * boltzmann, args["vz"] + Random.randn() * boltzmann])

    # Set simulation parameters and run simulation
    nthreads = Threads.nthreads()
    @printf(stderr, "Threads: %d\n", nthreads)
    start = time()
    outputs, boundstats, allstats = SimulateParticles(
        args["geom"],
        args["flow"],
        nParticles,
        generateParticle,
        true,
        args["omega"],
        args["zmin"],
        args["zmax"],
        args["pflip"],
        args["saveall"],
        !isnothing(args["stats"]),
        !isnothing(args["exitstats"]))
    runtime = time() - start
    if !isnothing(args["stats"])
        CSV.write(args["stats"], convert(DataFrame, allstats))
    end
    if !isnothing(args["exitstats"])
        CSV.write(args["exitstats"], convert(DataFrame, boundstats))
    end

    # Compute and display timing statistics
    @printf(stderr, "Time: %.3e\n",runtime)
    @printf(stderr, "Time per particle: %.3e\n", runtime/nParticles)
    @printf(stderr, "Time per collision: %.3e\n", runtime/sum(outputs[:,10]))
    @printf(stderr, "Interpolates: %.3e\n",interps)
    @printf(stderr, "Collides: %.3e\n",sum(outputs[:,10]))

    return allstats
end

function runParticleTracing(geom, flow; n=10000, z=0.035, r=0.0, vz=0.0, vr=0.0, T=0.0, m=4.0, M=191.0, sigma=130E-20, omega=0.0, zmin=-Inf, zmax=Inf, pflip=0.0, saveall=0, stats=nothing, exitstats=nothing, particlesoutput=stdout)
    
    # Set the arguments
    
    args["geom"] = geom
    args["flow"] = flow
    args["n"] = n
    args["z"] = z
    args["r"] = r
    args["vz"] = vz
    args["vr"] = vr
    args["T"] = T
    args["m"] = m
    args["M"] = M
    args["sigma"] = sigma
    args["omega"] = omega
    args["zmin"] = zmin
    args["zmax"] = zmax
    args["pflip"] = pflip
    args["saveall"] = saveall
    args["stats"] = stats
    args["exitstats"] = exitstats

    

    # Recalculate the constants

    global MASS_PARTICLE = args["M"] # AMU
    global MASS_BUFFER_GAS = args["m"] # AMU
    global MASS_REDUCED = MASS_PARTICLE * MASS_BUFFER_GAS /
        (MASS_PARTICLE + MASS_BUFFER_GAS) # AMU
    global kB = 8314.46 # AMU m^2 / (s^2 K)
    global ??_BUFFER_GAS_PARTICLE = args["sigma"] # m^2

    global outputFile = particlesoutput == stdout ? stdout : open(particlesoutput, "w")

    allstats = main(args)

end

end
