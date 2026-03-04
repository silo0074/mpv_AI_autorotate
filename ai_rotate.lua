
-- Start the Python server automatically when mpv opens
local python_path = "/mnt/D_TOSHIBA_S300/Projects/mpv_ai_autorotate/env/bin/python3"
-- local python_path = "/usr/bin/python3" -- or your venv path
local server_script = "/mnt/D_TOSHIBA_S300/Projects/mpv_ai_autorotate/ai_listener.py"
-- local utils = require 'mp.utils'
local rotations = { [0] = 0, [1] = 90, [2] = 180, [3] = 270 }
local is_processing = false
local ai_enabled = true -- Disabled by default
local TRIGGER_KEYWORD = "%rotate" -- Matches "rotate" in filename
local current_angle = 0
local osd_timer = nil

local mp = mp
mp.set_property("osd-ass-cc", "yes")


-- Function for the persistent Rx indicator
local function OSD_display_rotation(angle)
	-- If angle is 0, we can either hide it or show R0.
	-- This shows it whenever AI is enabled.
	local ass_data = string.format("{\\an7}{\\fs5}{\\b1}{\\1c&H00FF00&}R%d", angle)

	mp.set_osd_ass(0, 0, ass_data) -- 0,0 means "use window resolution"
end


local function OSD_ai_message(text, duration_ms)
    -- Color: Green (BGR: 00 FF 00)
    -- \an8 places it at the Top Center
    -- \fs25 sets font size
    local ass_data = "{\\an8}{\\fs15}{\\b1}{\\1c&H00FF00&}[AI] " .. text

    -- Draw the text
    mp.set_osd_ass(0, 0, ass_data)

    -- Set a timer to clear it
    if osd_timer then osd_timer:kill() end
    osd_timer = mp.add_timeout(duration_ms / 1000, function()
        --mp.set_osd_ass(0, 0, "")
        -- Instead of setting to "", we restore the Rx indicator
        OSD_display_rotation(current_angle)
    end)
end


local function apply_rotation(target_angle)
	-- Clean up angles to 0-359 range
	target_angle = target_angle % 360
	-- if target_angle == 360 then
	-- 	target_angle = 0
	-- end

	if target_angle == 0 then
		mp.set_property("vf", "")
	elseif target_angle == 180 then
		-- No width/height swap needed
		-- Use hflip and vflip for 180. It is often more stable
		-- than the rotate filter on older OpenGL/Intel drivers.
		mp.set_property("vf", "hflip,vflip")
		--mp.set_property("vf", "rotate=angle=PI")
	else
		-- 90 or 270: Width/Height MUST swap
		local rad = target_angle * (math.pi / 180)
		mp.set_property("vf", string.format("rotate=angle=%f:ow=ih:oh=iw", rad))
	end

	-- Force the modern aspect ratio logic
	mp.set_property("video-aspect-override", "no")
	mp.set_property("video-aspect-mode", "container")

	-- Force update if needed (modern mpv usually does this automatically on vf change)
	-- mp.command("reconfig-video")

	current_angle = target_angle
	print("Applied rotation: " .. target_angle)
	OSD_display_rotation(target_angle)
end


-- FUNCTION TO START THE SERVER
-- Simple check to see if we should start the server
local socket_check = os.execute("test -S /tmp/mpv_ai_socket")
if socket_check ~= 0 then
    mp.msg.info("Starting Python AI Server...")
    mp.command_native_async({name = "subprocess", args = {python_path, server_script}, detach = true})
else
    mp.msg.info("AI Server already running, connecting...")
end


-- EVENT: file loaded
mp.register_event("file-loaded", function()
    local path = mp.get_property("path") -- get file path

	-- Check if file name includes the keyword
    if path:lower():find(TRIGGER_KEYWORD) then
        ai_enabled = true
		OSD_ai_message("Rotation: ACTIVE (Keyword detected)", 3000)
		print("Tag detected in filename. Starting server...")
	else
		print("[AI] No keyword found in filename. Script staying idle.")
	end

	-- Check if the video has rotation set in INI file created by SMplayer
	print("Requesting rotation for: " .. path)

	mp.command_native_async({
		name = "subprocess",
		args = { "sh", "-c",
				-- $1 refers to the path passed at the end of the args list
				"while [ ! -S /tmp/mpv_ai_socket ]; do sleep 0.1; done; " ..
				"echo -n \"PATH:$1\" | socat - UNIX-CONNECT:/tmp/mpv_ai_socket",
				"--", path
			},
		capture_stdout = true
	}, function(success, res)
		-- Trim whitespace from result
		local rotation = res.stdout:match("%d+") or "0"
		print("Received result: '" .. rotation .. "'")

		if success and rotation ~= "" and rotation ~= "0" then
			-- mp.set_property("video-rotate", rotation)
			apply_rotation(rotation)
			OSD_ai_message("Restored SMPlayer Rotation: " .. rotation .. "°", 3000)
		end
	end)
end)


-- EVENT: Shutdown - Cleanup
mp.register_event("shutdown", function()
    print("Cleaning up...")
    -- Kill the specific listener process
    os.execute("pkill -f " .. server_script)
    -- Remove the socket file so it's fresh for next time
    os.remove("/tmp/mpv_ai_socket")
    os.remove("/tmp/mpv_frame.raw")
end)


local function check_orientation()
    -- Skip if AI is disabled, if we are already processing, OR if the video is paused
    if not ai_enabled or is_processing or mp.get_property_native("pause") then
        return
    end

    -- Grab the raw frame at its native resolution (no scaling arguments supported)
    local res = mp.command_native({"screenshot-raw", "video"})

    -- Ensure we got valid data before proceeding
    if res and res.data and res.w and res.h then
        is_processing = true
        local f = io.open("/tmp/mpv_frame.raw", "wb")

        if f then
            f:write(res.data)
            f:close()

            -- Pass the native width/height to Python so it can calculate the stride
            local header = string.format("%08d%08d", res.w, res.h)
            local cmd = {
                name = "subprocess",
                args = {
                    "sh", "-c",
                    -- Added -t 1.0 (timeout) and retry logic for the socket
                    "while [ ! -S /tmp/mpv_ai_socket ]; do sleep 0.2; done; " ..
                    "socat -t 1.0 - UNIX-CONNECT:/tmp/mpv_ai_socket,shut-none"
                },
                stdin_data = header,
                capture_stdout = true
            }

            mp.command_native_async(cmd, function(success, ret, err)
                is_processing = false

                if success and ret and ret.stdout then
                    local ai_idx = tonumber(ret.stdout:match("%d+"))
                    -- If AI says 0 (dark/low confidence) or 0 (already correct), stop.
                    if not ai_idx or ai_idx == 0 then return end

                    --local current_rot = mp.get_property_number("video-rotate", 0)
                    -- Mapping AI index to the ABSOLUTE angle the video SHOULD be
                    local target_angle = rotations[ai_idx]

					print(string.format("Current rotation: %d, New rotation: %d", current_angle, target_angle))
					apply_rotation(target_angle)

                    -- ABSOLUTE CALCULATION:
                    -- We determine exactly what the '0' point should be.
                    -- If AI says it needs 270 while we are at 0, target is 270.
                    -- If AI says it needs 0 while we are at 270, target is 270.
--                     local absolute_target = (current_rot + ai_needs) % 360
--
--                     -- Check if the rotation is already "in flight"
--                     -- (mpv sometimes takes a moment to update the property)
--                     if absolute_target ~= current_rot then
--                         print(string.format("AI says move %d. Current is %d. Setting Absolute Target: %d", ai_needs, current_rot, absolute_target))
--                         mp.set_property("video-rotate", absolute_target)
--                         update_rx_indicator(absolute_target)
--                     end
                end
            end)
        else
            is_processing = false
        end
    end
end


-- Run every n seconds
mp.add_periodic_timer(4, check_orientation)


