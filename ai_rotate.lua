
-- Optimization: Since the AI is seeing the filtered frames, the Letterboxing logic 
-- in ai_listener.py is now even more important. When you rotate a 16:9 video 90 degrees, 
-- it becomes a thin 9:16 vertical sliver. The letterboxing ensures the AI still sees 
-- that thin sliver centered in a 384x384 square, rather than a distorted, stretched version.

-- Case A: The AI sees the video is sideways (90°) and your current rotation is 0. 
-- It applies 90. The video looks correct. The next frame the AI sees is upright (IDX 0), so it stays at 90.

-- Case B (The Flip): The person flips the camera while you are already at 90°. 
-- The AI now sees a new sideways image. It sends IDX 1 (90°). The script adds 90 to your current 90, 
-- moving you to 180°. The video is now corrected again.

-- mpv --geometry=100%x100% --no-keepaspect-window --scripts=/path_to/mpv_ai_autorotate/ai_rotate.lua video.mkv

-- Start the Python server automatically when mpv opens
local python_path = "/mnt/D_TOSHIBA_S300/Projects/mpv_ai_autorotate/env/bin/python3"
-- local python_path = "/usr/bin/python3" -- or your venv path
local server_script = "/mnt/D_TOSHIBA_S300/Projects/mpv_ai_autorotate/ai_listener.py"
-- local utils = require 'mp.utils'
local rotations = { [0] = 0, [1] = 90, [2] = 180, [3] = 270 }
local is_processing = false
local ai_enabled = false -- Disabled by default
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
    print("Applying rotation: " .. target_angle)
    if not target_angle then
        return
    end
	-- Clean up angles to 0-360 range
	target_angle = target_angle % 360
    print("Applying rotation mod: " .. target_angle)

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
    print("Starting Python AI Server...")
    mp.command_native_async({name = "subprocess", args = {python_path, server_script}, detach = true})
else
    print("AI Server already running, connecting...")
end


-- EVENT: file loaded
mp.register_event("file-loaded", function()
    local path = mp.get_property("path") -- get file path

	-- Check if file name includes the keyword
    if path:lower():find(TRIGGER_KEYWORD) then
        ai_enabled = true
		OSD_ai_message("Rotation: ACTIVE (Keyword detected)", 3000)
		print("\nTag detected in filename. Starting server...")
	else
		print("\nNo keyword found in filename. Script staying idle.")
	end

	-- Check if the video has rotation set in INI file created by SMplayer
	print("\nRequesting rotation for: " .. path)

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
        -- print("Orientation check skipped")
        return
    end

    -- Grab the raw frame at its native resolution (no scaling arguments supported)
    -- "video": you are telling mpv to capture the frame exactly as 
    -- it comes out of the video decoder, but before most user-applied filters 
    -- (like video-rotate or vf) are applied.
    -- "window": Captures exactly what you see on your monitor 
    -- (includes OSD, subtitles, and all rotations/filters)
    -- "subtitles": Captures the video plus subtitles, but usually before color management.
    -- Even though screenshot-raw "video" is documented to capture frames from the decoder, 
    -- when you apply a rotation filter via vf, some hardware drivers or mpv configurations 
    -- feed those filtered frames back into the capture buffer.
    local res = mp.command_native({"screenshot-raw", "video"})

    -- Ensure we got valid data before proceeding
    if res and res.data and res.w and res.h then
        is_processing = true
        local f = io.open("/tmp/mpv_frame.raw", "wb")

        if f then
            f:write(res.data)
            f:close()
            print("---------------------------------")
            print("Sending frame")

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
                    -- We map the AI result (0,1,2,3) to (0, 90, 180, 270)
                    local adjustment = rotations[ai_idx]

                    -- Relative or absolute rotation
                    -- If the model send the correction even after the filter is applied use absolute.
                    -- If the model sends 0 after orientation has been corrected, use relative.

                    -- CALCULATE RELATIVE CHANGE:
                    -- We add the AI's requested turn to our current position
                    local new_angle = (current_angle + adjustment) % 360

                    print(string.format("Received rotation: %d, current rotation: %d", adjustment, current_angle))
                    print("New rotation: " .. new_angle)

                    if new_angle ~= current_angle then
                        apply_rotation(new_angle)
                    end
                end
            end)
        else
            is_processing = false
        end
    end
end


-- Run every n seconds
mp.add_periodic_timer(5, check_orientation)


