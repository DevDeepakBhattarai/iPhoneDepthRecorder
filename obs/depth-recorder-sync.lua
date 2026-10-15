obs = obslua

auto_render = true
wrapper = ""

function script_description()
    return [[Depth Recorder / OBS Sync

Starts and stops the iPhone recorder with OBS, records precise OBS clock anchors, then pulls the finished phone take over USB. Full-quality video stays on the iPhone during capture; this integration sends only control/timing data.]]
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "auto_render", true)
end

function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_bool(props, "auto_render", "Automatically render LiDAR cinematic DOF after transfer")
    return props
end

function script_update(settings)
    auto_render = obs.obs_data_get_bool(settings, "auto_render")
end

local function winquote(s)
    if s == nil then return "" end
    return tostring(s):gsub('"', '""')
end

local function dispatch_event(name, output_path)
    if wrapper == nil or wrapper == "" then
        obs.script_log(obs.LOG_WARNING, "Depth Recorder wrapper path is not configured")
        return
    end
    local mono = obs.os_gettime_ns()
    local render = auto_render and "1" or "0"
    local path = winquote(output_path or "")
    local cmd = 'cmd.exe /d /c start "" /b "' .. wrapper .. '" ' .. name .. ' ' .. tostring(mono) .. ' "' .. path .. '" ' .. render
    local ok = os.execute(cmd)
    if ok == nil then
        obs.script_log(obs.LOG_WARNING, "Depth Recorder helper could not be launched for " .. name)
    end
end

function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTING then
        dispatch_event("starting", "")
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        dispatch_event("started", "")
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPING then
        dispatch_event("stopping", "")
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        local path = obs.obs_frontend_get_last_recording()
        dispatch_event("stopped", path or "")
    end
end

function script_load(settings)
    script_update(settings)
    wrapper = script_path() .. "obs-depthrecorder-event.cmd"
    obs.obs_frontend_add_event_callback(on_event)
    dispatch_event("preflight", "")
    obs.script_log(obs.LOG_INFO, "Depth Recorder OBS sync loaded")
end

function script_unload()
    obs.obs_frontend_remove_event_callback(on_event)
end
