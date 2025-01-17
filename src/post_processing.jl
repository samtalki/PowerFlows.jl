function _is_available_source(x, bus::PSY.Bus)
    return PSY.get_available(x) && x.bus == bus && !isa(x, PSY.ElectricLoad)
end

"""
Calculates the From - To complex power flow (Flow injected at the bus) of branch of type
TapTransformer
"""
function flow_val(b::PSY.TapTransformer)
    !PSY.get_available(b) && return 0.0
    Y_t = PSY.get_series_admittance(b)
    c = 1 / PSY.get_tap(b)
    arc = PSY.get_arc(b)
    V_from = arc.from.magnitude * (cos(arc.from.angle) + sin(arc.from.angle) * 1im)
    V_to = arc.to.magnitude * (cos(arc.to.angle) + sin(arc.to.angle) * 1im)
    I = (V_from * Y_t * c^2) - (V_to * Y_t * c)
    flow = V_from * conj(I)
    return flow
end

"""
Calculates the From - To complex power flow (Flow injected at the bus) of branch of type
Line
"""
function flow_val(b::PSY.ACBranch)
    !PSY.get_available(b) && return 0.0
    Y_t = PSY.get_series_admittance(b)
    arc = PSY.get_arc(b)
    V_from = arc.from.magnitude * (cos(arc.from.angle) + sin(arc.from.angle) * 1im)
    V_to = arc.to.magnitude * (cos(arc.to.angle) + sin(arc.to.angle) * 1im)
    I = V_from * (Y_t + (1im * PSY.get_b(b).from)) - V_to * Y_t
    flow = V_from * conj(I)
    return flow
end

"""
Calculates the From - To complex power flow (Flow injected at the bus) of branch of type
Transformer2W
"""
function flow_val(b::PSY.Transformer2W)
    !PSY.get_available(b) && return 0.0
    Y_t = PSY.get_series_admittance(b)
    arc = PSY.get_arc(b)
    V_from = arc.from.magnitude * (cos(arc.from.angle) + sin(arc.from.angle) * 1im)
    V_to = arc.to.magnitude * (cos(arc.to.angle) + sin(arc.to.angle) * 1im)
    I = V_from * (Y_t + (1im * PSY.get_primary_shunt(b))) - V_to * Y_t
    flow = V_from * conj(I)
    return flow
end

function flow_val(b::PSY.PhaseShiftingTransformer)
    error("Systems with PhaseShiftingTransformer not supported yet")
    return
end

"""
Calculates the From - To complex power flow using external data of voltages of branch of type
TapTransformer
"""
function flow_func(b::PSY.TapTransformer, V_from::Complex{Float64}, V_to::Complex{Float64})
    !PSY.get_available(b) && return (0.0, 0.0)
    Y_t = PSY.get_series_admittance(b)
    c = 1 / PSY.get_tap(b)
    I = (V_from * Y_t * c^2) - (V_to * Y_t * c)
    flow = V_from * conj(I)
    return real(flow), imag(flow)
end

"""
Calculates the From - To complex power flow using external data of voltages of branch of type
Line
"""
function flow_func(b::PSY.ACBranch, V_from::Complex{Float64}, V_to::Complex{Float64})
    !PSY.get_available(b) && return (0.0, 0.0)
    Y_t = PSY.get_series_admittance(b)
    I = V_from * (Y_t + (1im * PSY.get_b(b).from)) - V_to * Y_t
    flow = V_from * conj(I)
    return real(flow), imag(flow)
end

"""
Calculates the From - To complex power flow using external data of voltages of branch of type
Transformer2W
"""
function flow_func(b::PSY.Transformer2W, V_from::Complex{Float64}, V_to::Complex{Float64})
    !PSY.get_available(b) && return (0.0, 0.0)
    Y_t = PSY.get_series_admittance(b)
    I = V_from * (Y_t + (1im * PSY.get_primary_shunt(b))) - V_to * Y_t
    flow = V_from * conj(I)
    return real(flow), imag(flow)
end

function flow_func(
    b::PSY.PhaseShiftingTransformer,
    V_from::Complex{Float64},
    V_to::Complex{Float64},
)
    error("Systems with PhaseShiftingTransformer not supported yet")
    return
end

"""
Updates the flow on the branches
"""
function _update_branch_flow!(sys::PSY.System)
    for b in PSY.get_components(PSY.ACBranch, sys)
        S_flow = PSY.get_available(b) ? flow_val(b) : 0.0 + 0.0im
        PSY.set_active_power_flow!(b, real(S_flow))
        PSY.set_reactive_power_flow!(b, imag(S_flow))
    end
end

"""
Obtain total load on bus b
"""
function _get_load_data(sys::PSY.System, b::PSY.Bus)
    active_power = 0.0
    reactive_power = 0.0
    for l in PSY.get_components(PSY.ElectricLoad, sys, x -> !isa(x, PSY.FixedAdmittance))
        !PSY.get_available(l) && continue
        if (l.bus == b)
            active_power += PSY.get_active_power(l)
            reactive_power += PSY.get_reactive_power(l)
        end
    end
    return active_power, reactive_power
end

function _get_fixed_admittance_power(
    sys::PSY.System,
    b::PSY.Bus,
    result::AbstractVector,
    ix::Int,
)
    active_power = 0.0
    reactive_power = 0.0
    for l in PSY.get_components(PSY.FixedAdmittance, sys)
        !PSY.get_available(l) && continue
        if (l.bus == b)
            Vm_squared =
                b.bustype == PSY.BusTypes.PQ ? result[2 * ix - 1]^2 : PSY.get_magnitude(b)^2
            active_power += Vm_squared * real(PSY.get_Y(l))
            reactive_power += Vm_squared * imag(PSY.get_Y(l))
        end
    end
    return active_power, reactive_power
end

function _power_redistribution_ref(
    sys::PSY.System,
    P_gen::Float64,
    Q_gen::Float64,
    bus::PSY.Bus,
)
    devices_ =
        PSY.get_components(PSY.StaticInjection, sys, x -> _is_available_source(x, bus))
    if length(devices_) == 1
        device = first(devices_)
        PSY.set_active_power!(device, P_gen)
        PSY.set_reactive_power!(device, Q_gen)
        return
    elseif length(devices_) > 1
        devices = sort(collect(devices_); by=x -> PSY.get_max_active_power(x))
    else
        error("No devices in bus $(PSY.get_name(bus))")
    end

    sum_basepower = sum(PSY.get_max_active_power.(devices))
    p_residual = P_gen
    units_at_limit = Vector{Int}()
    for (ix, d) in enumerate(devices)
        p_limits = PSY.get_active_power_limits(d)
        part_factor = p_limits.max / sum_basepower
        p_frac = P_gen * part_factor
        p_set_point = clamp(p_frac, p_limits.min, p_limits.max)
        if (p_frac >= p_limits.max + BOUNDS_TOLERANCE) ||
           (p_frac <= p_limits.min - BOUNDS_TOLERANCE)
            push!(units_at_limit, ix)
            @warn "Unit $(PSY.get_name(d)) set at the limit $(p_set_point). P_max = $(p_limits.max) P_min = $(p_limits.min)"
        end
        PSY.set_active_power!(d, p_set_point)
        p_residual -= p_set_point
    end

    if !isapprox(p_residual, 0.0, atol=ISAPPROX_ZERO_TOLERANCE)
        removed_power = sum(PSY.get_max_active_power.(devices[units_at_limit]))
        reallocated_p = 0.0
        it = 0
        while !isapprox(p_residual, 0.0, atol=ISAPPROX_ZERO_TOLERANCE)
            if length(devices) == length(units_at_limit) + 1
                @warn "all devices at the active Power Limit"
                break
            end
            for (ix, d) in enumerate(devices)
                ix ∈ units_at_limit && continue
                p_limits = PSY.get_active_power_limits(d)
                part_factor = p_limits.max / (sum_basepower - removed_power)
                p_frac = p_residual * part_factor
                current_p = PSY.get_active_power(d)
                p_set_point = p_frac + current_p
                if (p_set_point >= p_limits.max + BOUNDS_TOLERANCE) ||
                   (p_set_point <= p_limits.min - BOUNDS_TOLERANCE)
                    push!(units_at_limit, ix)
                    @warn "Unit $(PSY.get_name(d)) set at the limit $(p_set_point). P_max = $(p_limits.max) P_min = $(p_limits.min)"
                end
                p_set_point = clamp(p_set_point, p_limits.min, p_limits.max)
                PSY.set_active_power!(d, p_set_point)
                reallocated_p += p_frac
            end
            p_residual -= reallocated_p
            if isapprox(p_residual, 0, atol=ISAPPROX_ZERO_TOLERANCE)
                break
            end
            it += 1
            if it > 10
                break
            end
        end
        if !isapprox(p_residual, 0.0, atol=ISAPPROX_ZERO_TOLERANCE)
            remaining_unit_index = setdiff(1:length(devices), units_at_limit)
            @assert length(remaining_unit_index) == 1 remaining_unit_index
            device = devices[remaining_unit_index[1]]
            @debug "Remaining residual $q_residual, $(PSY.get_name(bus))"
            p_set_point = PSY.get_active_power(device) + p_residual
            PSY.set_active_power!(device, p_set_point)
            p_limits = PSY.get_reactive_power_limits(device)
            if (p_set_point >= p_limits.max + BOUNDS_TOLERANCE) ||
               (p_set_point <= p_limits.min - BOUNDS_TOLERANCE)
                @error "Unit $(PSY.get_name(device)) P=$(p_set_point) above limits. P_max = $(p_limits.max) P_min = $(p_limits.min)"
            end
        end
    end
    _reactive_power_redistribution_pv(sys, Q_gen, bus)
    return
end

function _reactive_power_redistribution_pv(sys::PSY.System, Q_gen::Float64, bus::PSY.Bus)
    @debug "Reactive Power Distribution $(PSY.get_name(bus))"
    devices_ =
        PSY.get_components(PSY.StaticInjection, sys, x -> _is_available_source(x, bus))

    if length(devices_) == 1
        @debug "Only one generator in the bus"
        PSY.set_reactive_power!(first(devices_), Q_gen)
        return
    elseif length(devices_) > 1
        devices = sort(collect(devices_); by=x -> PSY.get_max_reactive_power(x))
    else
        error("No devices in bus $(PSY.get_name(bus))")
    end

    total_active_power = sum(PSY.get_active_power.(devices))

    if isapprox(total_active_power, 0.0, atol=ISAPPROX_ZERO_TOLERANCE)
        @debug "Total Active Power Output at the bus is $(total_active_power). Using Unit's Base Power"
        sum_basepower = sum(PSY.get_base_power.(devices))
        for d in devices
            part_factor = PSY.get_base_power(d) / sum_basepower
            PSY.set_reactive_power!(d, Q_gen * part_factor)
        end
        return
    end

    q_residual = Q_gen
    units_at_limit = Vector{Int}()

    for (ix, d) in enumerate(devices)
        q_limits = PSY.get_reactive_power_limits(d)
        if isapprox(q_limits.max, 0.0, atol=BOUNDS_TOLERANCE) &&
           isapprox(q_limits.min, 0.0, atol=BOUNDS_TOLERANCE)
            push!(units_at_limit, ix)
            @info "Unit $(PSY.get_name(d)) has no Q control capability. Q_max = $(q_limits.max) Q_min = $(q_limits.min)"
            continue
        end

        fraction = PSY.get_active_power(d) / total_active_power

        if fraction == 0.0
            PSY.set_reactive_power!(d, 0.0)
            continue
        else
            @assert fraction > 0
        end

        q_frac = Q_gen * fraction
        q_set_point = clamp(q_frac, q_limits.min, q_limits.max)

        if (q_frac >= q_limits.max + BOUNDS_TOLERANCE) ||
           (q_frac <= q_limits.min - BOUNDS_TOLERANCE)
            push!(units_at_limit, ix)
            @warn "Unit $(PSY.get_name(d)) set at the limit $(q_set_point). Q_max = $(q_limits.max) Q_min = $(q_limits.min)"
        end

        PSY.set_reactive_power!(d, q_set_point)
        q_residual -= q_set_point

        if isapprox(q_residual, 0.0, atol=ISAPPROX_ZERO_TOLERANCE)
            break
        end
    end

    if !isapprox(q_residual, 0.0, atol=ISAPPROX_ZERO_TOLERANCE)
        it = 0
        while !isapprox(q_residual, 0.0, atol=ISAPPROX_ZERO_TOLERANCE)
            if length(devices) == length(units_at_limit) + 1
                @debug "Only one device not at the limit in Bus"
                break
            end
            removed_power = sum(PSY.get_active_power.(devices[units_at_limit]))
            reallocated_q = 0.0
            for (ix, d) in enumerate(devices)
                ix ∈ units_at_limit && continue
                q_limits = PSY.get_reactive_power_limits(d)

                if removed_power < total_active_power
                    fraction =
                        PSY.get_active_power(d) / (total_active_power - removed_power)
                elseif isapprox(removed_power, total_active_power)
                    fraction = 1
                else
                    error("Remove power can't be larger than the total active power")
                end

                if fraction == 0.0
                    continue
                else
                    PSY.InfrastructureSystems.@assert_op fraction > 0
                end

                current_q = PSY.get_reactive_power(d)
                q_frac = q_residual * fraction
                q_set_point = clamp(q_frac + current_q, q_limits.min, q_limits.max)
                reallocated_q += q_frac
                if (q_frac >= q_limits.max + BOUNDS_TOLERANCE) ||
                   (q_frac <= q_limits.min - BOUNDS_TOLERANCE)
                    push!(units_at_limit, ix)
                    @warn "Unit $(PSY.get_name(d)) set at the limit $(q_set_point). Q_max = $(q_limits.max) Q_min = $(q_limits.min)"
                end

                PSY.set_reactive_power!(d, q_set_point)
            end
            q_residual -= reallocated_q
            if isapprox(q_residual, 0, atol=ISAPPROX_ZERO_TOLERANCE)
                break
            end
            it += 1
            if it > 1
                break
            end
        end
    end

    if !isapprox(q_residual, 0.0, atol=ISAPPROX_ZERO_TOLERANCE)
        remaining_unit_index = setdiff(1:length(devices), units_at_limit)
        @assert length(remaining_unit_index) == 1 remaining_unit_index
        device = devices[remaining_unit_index[1]]
        @debug "Remaining residual $q_residual, $(PSY.get_name(bus))"
        q_set_point = PSY.get_reactive_power(device) + q_residual
        PSY.set_reactive_power!(device, q_set_point)
        q_limits = PSY.get_reactive_power_limits(device)
        if (q_set_point >= q_limits.max + BOUNDS_TOLERANCE) ||
           (q_set_point <= q_limits.min - BOUNDS_TOLERANCE)
            @error "Unit $(PSY.get_name(device)) Q=$(q_set_point) above limits. Q_max = $(q_limits.max) Q_min = $(q_limits.min)"
        end
    end

    return
end

"""
Updates system voltages and powers with power flow results
"""
function write_powerflow_solution!(sys::PSY.System, result::Vector{Float64})
    buses = enumerate(
        sort!(collect(PSY.get_components(PSY.Bus, sys)), by=x -> PSY.get_number(x)),
    )

    for (ix, bus) in buses
        if bus.bustype == PSY.BusTypes.REF
            P_gen = result[2 * ix - 1]
            Q_gen = result[2 * ix]
            _power_redistribution_ref(sys, P_gen, Q_gen, bus)
        elseif bus.bustype == PSY.BusTypes.PV
            Q_gen = result[2 * ix - 1]
            bus.angle = result[2 * ix]
            _reactive_power_redistribution_pv(sys, Q_gen, bus)
        elseif bus.bustype == PSY.BusTypes.PQ
            Vm = result[2 * ix - 1]
            θ = result[2 * ix]
            PSY.set_magnitude!(bus, Vm)
            PSY.set_angle!(bus, θ)
        end
    end

    _update_branch_flow!(sys)
    return
end

"""
Return power flow results in dictionary of dataframes.
"""
function write_results(sys::PSY.System, result::Vector{Float64})
    @info("Voltages are exported in pu. Powers are exported in MW/MVAr.")
    buses = sort!(collect(PSY.get_components(PSY.Bus, sys)), by=x -> PSY.get_number(x))
    N_BUS = length(buses)
    bus_map = Dict(buses .=> 1:N_BUS)
    sys_basepower = PSY.get_base_power(sys)
    sources = PSY.get_components(PSY.StaticInjection, sys, d -> !isa(d, PSY.ElectricLoad))
    Vm_vect = fill(0.0, N_BUS)
    θ_vect = fill(0.0, N_BUS)
    P_gen_vect = fill(0.0, N_BUS)
    Q_gen_vect = fill(0.0, N_BUS)
    P_load_vect = fill(0.0, N_BUS)
    Q_load_vect = fill(0.0, N_BUS)

    for (ix, bus) in enumerate(buses)
        P_load_vect[ix], Q_load_vect[ix] = _get_load_data(sys, bus) .* sys_basepower
        P_admittance, Q_admittance = _get_fixed_admittance_power(sys, bus, result, ix)
        P_load_vect[ix] += P_admittance
        Q_load_vect[ix] += Q_admittance
        if bus.bustype == PSY.BusTypes.REF
            Vm_vect[ix] = PSY.get_magnitude(bus)
            θ_vect[ix] = PSY.get_angle(bus)
            P_gen_vect[ix] = result[2 * ix - 1] * sys_basepower
            Q_gen_vect[ix] = result[2 * ix] * sys_basepower
        elseif bus.bustype == PSY.BusTypes.PV
            Vm_vect[ix] = PSY.get_magnitude(bus)
            θ_vect[ix] = result[2 * ix]
            for gen in sources
                !PSY.get_available(gen) && continue
                if gen.bus == bus
                    P_gen_vect[ix] += PSY.get_active_power(gen) * sys_basepower
                end
            end
            Q_gen_vect[ix] = result[2 * ix - 1] * sys_basepower
        elseif bus.bustype == PSY.BusTypes.PQ
            Vm_vect[ix] = result[2 * ix - 1]
            θ_vect[ix] = result[2 * ix]
            for gen in sources
                !PSY.get_available(gen) && continue
                if gen.bus == bus
                    P_gen_vect[ix] += PSY.get_active_power(gen) * sys_basepower
                    Q_gen_vect[ix] += PSY.get_reactive_power(gen) * sys_basepower
                end
            end
        end
    end

    branches = PSY.get_components(PSY.ACBranch, sys)
    N_BRANCH = length(branches)
    P_from_to_vect = fill(0.0, N_BRANCH)
    Q_from_to_vect = fill(0.0, N_BRANCH)
    P_to_from_vect = fill(0.0, N_BRANCH)
    Q_to_from_vect = fill(0.0, N_BRANCH)
    for (ix, b) in enumerate(branches)
        !PSY.get_available(b) && continue
        bus_f_ix = bus_map[PSY.get_arc(b).from]
        bus_t_ix = bus_map[PSY.get_arc(b).to]
        V_from = Vm_vect[bus_f_ix] * (cos(θ_vect[bus_f_ix]) + sin(θ_vect[bus_f_ix]) * 1im)
        V_to = Vm_vect[bus_t_ix] * (cos(θ_vect[bus_t_ix]) + sin(θ_vect[bus_t_ix]) * 1im)
        P_from_to_vect[ix], Q_from_to_vect[ix] = flow_func(b, V_from, V_to) .* sys_basepower
        P_to_from_vect[ix], Q_to_from_vect[ix] = flow_func(b, V_to, V_from) .* sys_basepower
    end

    bus_df = DataFrames.DataFrame(
        bus_number=PSY.get_number.(buses),
        Vm=Vm_vect,
        θ=θ_vect,
        P_gen=P_gen_vect,
        P_load=P_load_vect,
        P_net=P_gen_vect - P_load_vect,
        Q_gen=Q_gen_vect,
        Q_load=Q_load_vect,
        Q_net=Q_gen_vect - Q_load_vect,
    )

    branch_df = DataFrames.DataFrame(
        line_name=PSY.get_name.(branches),
        bus_from=PSY.get_number.(PSY.get_from.(PSY.get_arc.(branches))),
        bus_to=PSY.get_number.(PSY.get_to.(PSY.get_arc.(branches))),
        P_from_to=P_from_to_vect,
        Q_from_to=Q_from_to_vect,
        P_to_from=P_to_from_vect,
        Q_to_from=Q_to_from_vect,
        P_losses=P_from_to_vect + P_to_from_vect,
        Q_losses=Q_from_to_vect + Q_to_from_vect,
    )
    DataFrames.sort!(branch_df, [:bus_from, :bus_to])

    return Dict("bus_results" => bus_df, "flow_results" => branch_df)
end
