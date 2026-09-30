-- Stronger Aim Assist
-- 1.0.0

local NAME, VERSION = "Stronger Aim Assist", "1.0.0"
local CONFIG = "stronger_aim_assist.json"
local SUPPORTER = "app.cPlayerSubWeaponSupporter"
local CAMERA = "app.mcCam_AimSupport"
local INPUT = "app.mcCam_GameCameraInputRotate"
local specs = {
    { key = "strength", label = "Slowdown strength", default = 5, min = 1, max = 10 },
    { key = "radius", label = "Assist area / aiming FOV", default = 10, min = 1, max = 10 },
    { key = "threshold", label = "Stick breakaway threshold", default = 0.75, min = 0.1, max = 1 },
    { key = "mouse_floor", label = "Minimum mouse speed while assisted", default = 0.4, min = 0.25, max = 1 },
    { key = "near", label = "Minimum target distance", default = 0, min = 0, max = 1 },
    { key = "switch_threshold", label = "Mouse movement to release target", default = 4.05, min = 0.1, max = 100, format = "%.2f" },
    { key = "switch_delay", label = "Reacquire after quiet mouse input", default = 0.12, min = 0.05, max = 1, format = "%.2f s" },
}
local active, failure, save_error = {}, nil, nil
local frames, camera_states, status_owners = 0, {}, {}
local released = false
local release_until = 0
local diagnostic = { version = VERSION, hooks = {}, values = {}, assisted_frames = 0, mouse_frames = 0 }

local function finite(v)
    return type(v) == "number" and v == v and math.abs(v) < math.huge
end

local function close(a, b)
    return finite(a) and finite(b) and math.abs(a - b) <= math.max(1, math.abs(b)) * 1e-6
end

local function normalize(v)
    local out = {
        enabled = v.enabled ~= false,
        mouse = v.mouse ~= false,
        no_snap = v.no_snap ~= false,
        auto_aim = v.auto_aim ~= false,
        mouse_switch = v.mouse_switch ~= false,
        head_priority = v.head_priority ~= false,
        force_native = v.force_native ~= false,
        schema = 3,
    }
    for _, s in ipairs(specs) do
        out[s.key] = finite(v[s.key]) and math.max(s.min, math.min(s.max, v[s.key])) or s.default
    end
    return out
end

local ok, saved = pcall(json.load_file, CONFIG)
local options = normalize(ok and type(saved) == "table" and saved or {})

local function is_released()
    return released or (options.auto_aim and options.mouse_switch and os.clock() < release_until)
end

local function sample_switch_input(object)
    if not options.auto_aim or not options.mouse_switch or released then
        release_until = 0
        return
    end
    local success, err = pcall(function()
        if not object:call("checkAim") then
            release_until = 0
            return
        end
        -- Read the actual mouse movement, before slowdown or aim correction gets involved
        local delta = object:call("getMouseInputVec")
        assert(delta and finite(delta.x) and finite(delta.y), "Mouse movement unavailable")
        local magnitude = math.sqrt(delta.x * delta.x + delta.y * delta.y)
        diagnostic.mouse_movement = magnitude
        local now = os.clock()
        local limit = now < release_until and options.switch_threshold * 0.25 or options.switch_threshold
        if magnitude >= limit then
            if now >= release_until then
                diagnostic.mouse_releases = (diagnostic.mouse_releases or 0) + 1
            end
            release_until = now + options.switch_delay
        end
    end)
    diagnostic.switch_error = not success and tostring(err) or nil
end

local function save()
    local success, result = pcall(json.dump_file, CONFIG, options)
    save_error = (not success or result == false) and "Could not save settings." or nil
end

local function save_diagnostic()
    diagnostic.options = options
    diagnostic.failure = failure
    pcall(json.dump_file, "stronger_aim_assist_status.json", diagnostic)
end

local function restore(tx)
    if not tx.written then
        return
    end
    local success, err = pcall(function()
        if close(tx.object:get_field(tx.field), tx.applied) then
            tx.object:set_field(tx.field, tx.original)
        end
    end)
    if not success then
        failure = "Restore failed: " .. tostring(err)
        log.error("[" .. NAME .. "] " .. failure)
    end
end

local function leave(ctx)
    if ctx.order then
        local success, err = pcall(function()
            local order = ctx.order
            if order.list:call("get_Count") ~= order.count then
                return
            end
            for _, slot in ipairs(order.written) do
                local current = order.list:call("get_Item", slot.index)
                if current and current:get_address() == slot.applied:get_address() then
                    order.list:call("set_Item", slot.index, slot.original)
                end
            end
        end)
        if not success then
            failure = "Target order restore failed: " .. tostring(err)
            log.error("[" .. NAME .. "] " .. failure)
        end
    end
    for i = #ctx, 1, - 1 do
        local tx = ctx[i]
        tx.depth = tx.depth - 1
        if tx.depth == 0 then
            restore(tx)
            active[tx.key] = nil
        end
    end
end

local function patch(ctx, object, field, transform)
    local key = tostring(object:get_address()) .. ":" .. field
    if ctx[key] then
        return
    end
    ctx[key] = true
    local tx = active[key]
    if tx then
        tx.depth = tx.depth + 1
        ctx[#ctx + 1] = tx
        return
    end
    local original = object:get_field(field)
    assert(finite(original) and original >= 0, "Invalid native value: " .. field)
    local applied = transform(original)
    assert(finite(applied) and applied >= 0, "Invalid requested value: " .. field)
    tx = { key = key, object = object, field = field, original = original, applied = applied, depth = 1 }
    active[key] = tx
    ctx[#ctx + 1] = tx
    if not close(original, applied) then
        tx.written = true
        object:set_field(field, applied)
    end
    diagnostic.values[field] = { original = original, requested = applied, readback = object:get_field(field) }
end

local function typed(object, name)
    return object and object:get_type_definition():get_full_name() == name
end

local function camera_parameters()
    local manager = sdk.get_managed_singleton("app.CameraManager")
    if not manager then
        return nil
    end
    local setting = manager:get_field("_Setting")
    local game = setting and setting:get_field("_GameCameraParam")
    local param = game and game:get_field("_OperateOptionBuildParam")
    if typed(param, "app.cCameraOperateOptionBuildParam") then
        return param
    end
end

local function order_targets(ctx, owner, list, count)
    local camera = owner and owner:call("get_Camera")
    assert(camera, "Target ordering: camera unavailable")
    local eye, forward = camera:call("get_EyePos"), camera:call("get_Forward")
    local function vector(v)
        return v and finite(v.x) and finite(v.y) and finite(v.z)
    end
    assert(vector(eye) and vector(forward), "Target ordering: invalid camera direction")
    assert(forward.x * forward.x + forward.y * forward.y + forward.z * forward.z > 1e-10, "Target ordering: zero camera direction")
    local ranked, original, groups = {}, {}, {}
    local heads = 0
    for i = 0, count - 1 do
        local request = list:call("get_Item", i)
        original[i + 1] = request
        local score =  - math.huge
        local success, pos = pcall(function() return request:call("getAimPos") end)
        if success and vector(pos) then
            local x, y, z = pos.x - eye.x, pos.y - eye.y, pos.z - eye.z
            local distance2 = x * x + y * y + z * z
            if distance2 > 1e-10 then
                score = (x * forward.x + y * forward.y + z * forward.z) / math.sqrt(distance2)
            end
        end
        local group_key = "request:" .. i
        local head = false
        pcall(function()
            local target = request:get_field("_TargetObject")
            if not target then
                return
            end
            group_key = tostring(target:get_address())
            if not options.head_priority then
                return
            end
            local setting = request:get_field("_AimTargetSetting")
            if not setting or setting:get_field("_UseChain") == true then
                return
            end
            local hash = setting:get_field("_Joint")
            hash = hash and hash:get_field("_Hash")
            if not finite(hash) then
                return
            end
            local transform = target:call("get_Transform")
            local joint = transform and transform:call("getJointByHash", hash)
            if not joint or not joint:call("get_Valid") then
                return
            end
            local name = joint:call("get_Name")
            if type(name) == "string" then
                head = score > 0 and (name:lower():find("head", 1, true) ~= nil or name:lower():find("skull", 1, true) ~= nil)
                if head then
                    heads = heads + 1
                end
            end
        end)
        local group = groups[group_key]
        if not group then
            group = { score = score, index = i }
            groups[group_key] = group
        end
        group.score = math.max(group.score, score)
        ranked[#ranked + 1] = { request = request, score = score, index = i, group = group, head = head }
    end
    table.sort(ranked, function(a, b)
        if options.head_priority then
            if a.group ~= b.group then
                if a.group.score == b.group.score then
                    return a.group.index < b.group.index
                end
                return a.group.score > b.group.score
            end
            if a.head ~= b.head then
                return a.head
            end
        end
        if a.score == b.score then
            return a.index < b.index
        end
        return a.score > b.score
    end)
    ctx.order = { list = list, count = count, written = {} }
    for i, item in ipairs(ranked) do
        if item.index ~= i - 1 then
            local slot = { index = i - 1, original = original[i], applied = item.request }
            ctx.order.written[#ctx.order.written + 1] = slot
            list:call("set_Item", slot.index, slot.applied)
        end
    end
    diagnostic.target_order = "closest to crosshair"
    diagnostic.first_candidate = ranked[1].index
    diagnostic.head_candidates = heads
end

local function install(type_name, method_name, receiver_name, before, after)
    local td = assert(sdk.find_type_definition(type_name), "Missing type: " .. type_name)
    local method = assert(td:get_method(method_name), "Missing hook: " .. method_name)
    local report = { calls = 0, valid = 0, skipped = 0 }
    diagnostic.hooks[type_name .. "." .. method_name] = report
    pcall(function() report.address = tostring(sdk.to_int64(method:get_function())) end)
    sdk.hook(method, function(args)
        local storage = thread.get_hook_storage()
        storage.stronger_aim_assist = nil
        report.calls = report.calls + 1
        if failure or not options.enabled then
            return sdk.PreHookResult.CALL_ORIGINAL
        end
        local valid, object = pcall(function()
            local obj = sdk.to_managed_object(args[2])
            if typed(obj, receiver_name) then
                return obj
            end
        end)
        if not valid or not object then
            report.skipped = report.skipped + 1
            return sdk.PreHookResult.CALL_ORIGINAL
        end
        local ctx = { object = object }
        storage.stronger_aim_assist = ctx
        local success, err = pcall(before, ctx, object, report, args)
        if not success then
            leave(ctx)
            storage.stronger_aim_assist = nil
            failure = tostring(err)
            log.error("[" .. NAME .. "] " .. failure)
        else report.valid = report.valid + 1 end
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local storage = thread.get_hook_storage()
        local ctx = storage.stronger_aim_assist
        storage.stronger_aim_assist = nil
        if ctx then
            if after and options.enabled and not failure then
                local success, err = pcall(after, ctx, ctx.object, report, retval)
                if not success then
                    failure = tostring(err)
                    log.error("[" .. NAME .. "] " .. failure)
                end
            end
            leave(ctx)
        end
        return retval
    end)
end

local function initialize()
    local option_type = assert(sdk.find_type_definition("app.savedata.cOptionParam"), "Missing native options")
    local option_getter = assert(option_type:get_method("getOptionValue(app.Option.ITEM)") or option_type:get_method("getOptionValue"), "Missing native option getter")
    sdk.hook(option_getter, function(args)
        local storage = thread.get_hook_storage()
        storage.saa_native_assist = false
        if options.enabled and options.force_native and not failure then
            local success, match = pcall(function()
                return sdk.to_int64(args[3]) == 70 and typed(sdk.to_managed_object(args[2]), "app.savedata.cOptionParam")
            end)
            storage.saa_native_assist = success and match
        end
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        if thread.get_hook_storage().saa_native_assist then
            diagnostic.native_override_calls = (diagnostic.native_override_calls or 0) + 1
            return sdk.to_ptr(0)
        end
        return retval
    end)
    install(SUPPORTER, "updateAimSupport", SUPPORTER, function(ctx, object)
        local param = object:get_field("_Param")
        if not typed(param, "app.user_data.PlayerSubWeaponParam") then
            return
        end
        patch(ctx, param, "_SubWeaponBow_AimSupport_DistMin", function(v) return v * options.near end)
    end)
    install(CAMERA, "updateMain", CAMERA, function(ctx, object, report)
        local owner = object:get_field("_OwnerController")
        ctx.owner = owner and tostring(owner:get_address())
        report.targets = 0
        local list = object:get_field("_AimRequestList")
        if not list then
            return
        end
        local count = list:call("get_Count")
        if not finite(count) or count <= 0 then
            return
        end
        assert(count <= 4096, "Unexpected target request count")
        ctx.had_targets = true
        report.targets = count
        if options.auto_aim and not is_released() and count > 1 then
            order_targets(ctx, owner, list, count)
        end
        local param = camera_parameters()
        if param then patch(ctx, param, "_AimSupportThreshold", function(v) return math.min(1, v * options.threshold) end) end
        for i = 0, count - 1 do
            local request = list:call("get_Item", i)
            local setting = request and request:get_field("_AimTargetSetting")
            if typed(setting, "app.mcCam_AimSupport.cAimTargetSetting") then
                patch(ctx, setting, "_Range", function(v) return v * options.radius end)
            end
        end
        if is_released() then object:set_field("_InRange", true)
        elseif options.auto_aim then
            object:set_field("_InRange", false)
            diagnostic.reacquire_requests = (diagnostic.reacquire_requests or 0) + 1
        elseif options.no_snap then object:set_field("_InRange", true) end
    end, function(ctx, object, report, retval)
        local evaluated = ctx.had_targets and sdk.to_int64(retval) == 0
        report.in_range = not is_released() and evaluated and object:get_field("_InRange") == true or false
        if not report.in_range then
            object:set_field("_InRange", false)
        end
        if ctx.owner then
            camera_states[ctx.owner] = { frame = frames, valid = report.in_range }
        end
    end)

    install("app.mcCam_InputRotate", "updateOperatorStatus", INPUT, function(ctx, object)
        sample_switch_input(object)
        local owner = object:get_field("_OwnerController")
        local status = object:get_field("_Status")
        if owner and status then
            status_owners[tostring(status:get_address())] = { owner = tostring(owner:get_address()), frame = frames }
        end
        local param = camera_parameters()
        if param then patch(ctx, param, "_AimSupportRate", function(v) return is_released() and 1 or v / options.strength end) end
    end)
    -- Restore mouse speed after the game copies it, or repeated scaling will freeze the camera.
    install("app.cCameraOperateCalculator", "applyUpdateStatus", "app.cCameraOperateCalculator", function(ctx, _, report, args)
        local status = sdk.to_managed_object(args[3])
        if not typed(status, "app.cCameraOperateOptionUpdateStatus") then
            return
        end
        report.assisting = false
        if is_released() then
            return
        end
        if not status or status:get_field("IsAim") ~= true then
            report.assisting = false
            return
        end
        local binding = status_owners[tostring(status:get_address())]
        local target = binding and camera_states[binding.owner]
        if not binding or frames - binding.frame > 1 or not target or not target.valid or frames - target.frame > 1 then
            return
        end
        local rate = status:get_field("PadSpeedVariableRate")
        if not rate or not finite(rate.x) or not finite(rate.y) then
            return
        end
        local factor = math.min(rate.x, rate.y)
        report.assisting = factor >= 0 and factor < 0.9999
        if not report.assisting then
            return
        end
        diagnostic.assisted_frames = diagnostic.assisted_frames + 1
        report.rate = factor
        if options.mouse then
            patch(ctx, status, "MouseSpeedVariableRate", function(v) return v * math.max(options.mouse_floor, factor) end)
            diagnostic.mouse_frames = diagnostic.mouse_frames + 1
            diagnostic.mouse_rate = status:get_field("MouseSpeedVariableRate")
        end
    end)
end

local success, err = pcall(initialize)
if not success then failure = tostring(err); log.error("[" .. NAME .. "] " .. failure)
else log.info("[" .. NAME .. "] Loaded " .. VERSION) end
save_diagnostic()

re.on_frame(function()
    frames = frames + 1
    -- panic key (Alt) to release aim if the key check fails so the reticle doesn't get stuck
    local key_ok, held = pcall(function() return reframework:is_key_down(0x12) or reframework:is_drawing_ui() end)
    released = not key_ok or held == true
    diagnostic.released = is_released()
    for k, v in pairs(camera_states) do if frames - v.frame > 2 then camera_states[k] = nil end end
    for k, v in pairs(status_owners) do if frames - v.frame > 2 then status_owners[k] = nil end end
    if frames%600 == 0 then
        save_diagnostic()
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node(NAME) then
        return
    end
    local changed, value = imgui.checkbox("Enabled##saa", options.enabled)
    if changed then
        options.enabled = value
        save()
    end
    imgui.text("Hold Alt to release assistance and switch targets.")
    if failure then
        imgui.text("Disabled: " .. failure)
    end
    if save_error then
        imgui.text(save_error)
    end
    imgui.tree_pop()
end)

re.on_script_reset(function()
    for _, tx in pairs(active) do restore(tx) end
    active = {}
end)
