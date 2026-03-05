
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
local rotations = { [0] = 0, [1] = 90, [2] = 180, [3] = 270 }
local is_processing = false
local ai_enabled = false -- Disabled by default
local TRIGGER_KEYWORD = "%rotate" -- Matches "rotate" in filename
local current_angle = 0
local osd_timer = nil
local last_w, last_h = 0, 0
local video_path = nil

local mp = mp
mp.set_property("osd-ass-cc", "yes")


-- Function for the persistent Rx indicator
local function OSD_display_rotation(angle)
	-- If angle is 0, we can either hide it or show R0.
	-- This shows it whenever AI is enabled.
    local ass_data = string.format("{\\an7}{\\fs5}{\\b1}{\\1c&H00FF00&}R%d", angle)
    if current_angle and ai_enabled then
        ass_data = string.format("{\\an7}{\\fs5}{\\b1}{\\1c&H00FF00&}AI%d", angle)
    end

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


-- To prevent your script from deleting SMPlayer 's filters or your own auto_crop, 
-- you should use vf add, vf pre, or vf remove instead of set_property("vf", ...).
-- However, managing rotation via vf add is messy because you have to remove the "old" 
-- rotation before adding a new one. A better way is to use filter labels.
-- mp.command vs mp.set_property
-- mp.set_property: Nukes the list. It deletes every existing filter and replaces it with your new one.
-- mp.command: Appends. It adds your filter to the end of the existing chain.

-- local function apply_rotation(target_angle)
--     print("Applying rotation: " .. target_angle)

--     -- Remove any previous rotation filters we added, without touching other filters
--     -- mp.command('vf remove @ai_rot')
    
--     if target_angle == 0 then
--         -- Do nothing (already removed)
--         mp.command('vf remove @ai_rot')

--     elseif target_angle == 180 then
--         -- Add with a label @ai_rot
--         -- Use hflip and vflip for 180. It is often more stable
--         -- than the rotate filter on older OpenGL/Intel drivers.
--         mp.command('vf add @ai_rot:hflip,vflip')
--         --mp.set_property("vf", "rotate=angle=PI")
--     else
--         -- 90 or 270: Width/Height MUST swap
--         -- local rad = target_angle * (math.pi / 180)
--         -- mp.command(string.format('vf add @ai_rot:rotate=angle=%f:ow=ih:oh=iw', rad))

--         mp.command('no-osd vf add "lavfi=[rotate=PI/2:ih:iw]"')
--     end

--     -- Force the modern aspect ratio logic
--     mp.set_property("video-aspect-override", "no")
--     mp.set_property("video-aspect-mode", "container")

--     -- Force update if needed (modern mpv usually does this automatically on vf change)
--     -- mp.command("reconfig-video")

--     current_angle = target_angle
--     print("Applied rotation: " .. target_angle)
--     OSD_display_rotation(target_angle)
-- end


local function apply_rotation(target_angle)
    -- 1. CLEANUP: Remove all possible SMPlayer rotation strings first
    -- This prevents multiple rotations from stacking on top of each other
    -- mp.command('no-osd vf remove "lavfi=[rotate=PI/2:ih:iw]"')
    -- mp.command('no-osd vf remove "lavfi=[rotate=PI:iw:ih]"')
    -- mp.command('no-osd vf remove "lavfi=[rotate=3*PI/2:ih:iw]"')

    -- 2. APPLY: Match SMPlayer's specific math strings
    if target_angle == 90 then
        mp.command('no-osd vf add "lavfi=[rotate=PI/2:ih:iw]"')
    elseif target_angle == 180 then
        mp.command('no-osd vf add "lavfi=[hflip,vflip]"')
    elseif target_angle == 270 then
        mp.command('no-osd vf add "lavfi=[rotate=3*PI/2:ih:iw]"')
    end

    -- Force the modern aspect ratio logic
    mp.set_property("video-aspect-override", "no")
    mp.set_property("video-aspect-mode", "container")

    current_angle = target_angle
    OSD_display_rotation(target_angle)
    print("Applied SMPlayer-compatible rotation: " .. target_angle)
end


local function auto_crop()
    -- Use 'pre' to ensure we look at the RAW frame before any existing crops
    -- Use 'no-osd' to keep the screen clean
    mp.command('no-osd vf pre @my_cropdetect:lavfi=[cropdetect=20/255:2]')

    mp.add_timeout(2, function()
        -- 1. Try label-specific metadata first (Most accurate)
        local metadata = mp.get_property_native("vf-metadata/my_cropdetect")

        -- 2. Fallback to general metadata if label fails
        if not metadata or not metadata["lavfi.cropdetect.w"] then
            -- video-out-params usually only shows metadata for the last filter in the chain
            metadata = mp.get_property_native("video-out-params/metadata")
        end

        -- Debugging: See what mpv is actually seeing
        if not metadata then
            print("SOCKET: Metadata is still nil. Active filters: " .. mp.get_property("vf"))
        end

        local w = metadata and tonumber(metadata["lavfi.cropdetect.w"])
        local h = metadata and tonumber(metadata["lavfi.cropdetect.h"])
        local x = metadata and metadata["lavfi.cropdetect.x"]
        local y = metadata and metadata["lavfi.cropdetect.y"]

        -- Cleanup the detector
        mp.command("no-osd vf remove @my_cropdetect")

        if w and h then
            local diff_w = math.abs(w - last_w)
            local diff_h = math.abs(h - last_h)

            -- Check for sanity (don't crop to a tiny dot) and threshold
            if w > 200 and h > 200 and (diff_w > 20 or diff_h > 20) then
                print(string.format("Crop Success: %dx%d at %d,%d", w, h, x, y))
                -- Apply/Update the display crop
                mp.command(string.format("no-osd vf pre @applied_crop:crop=%s:%s:%s:%s", w, h, x, y))
                last_w, last_h = w, h

                -- Force the modern aspect ratio logic
                mp.set_property("video-aspect-override", "no")
                mp.set_property("video-aspect-mode", "container")
            end
        else
            print("Crop Fail: Metadata found but w/h missing.")
        end
    end)
end


local function sync_with_smplayer(path)
    -- Check if the video has rotation set in INI file created by SMplayer
    print("\nRequesting ini data for: " .. path)

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
        -- "-?%d+" captures the negative sign
        local rotation = res.stdout:match("-?%d+") or "-1"
        print("Received result: '" .. rotation .. "'")

        if success and rotation ~= "" then
            -- mp.set_property("video-rotate", 0)
            -- rotate 0: clockwise and flip
            -- rotate 3: counter-clockwise and flip
            local rotations = { [-1] = 0, [1] = 90, [2] = 270, [4] = 180 }
            local degrees = rotations[tonumber(rotation)]

            if not degrees then
                return
            end

            apply_rotation(degrees)
            OSD_ai_message("Restored SMPlayer Rotation: " .. degrees .. "°", 3000)
        end
    end)
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
    video_path = mp.get_property("path") -- get file path

	-- Check if file name includes the keyword
    if video_path:lower():find(TRIGGER_KEYWORD) then
        ai_enabled = true
		OSD_ai_message("Rotation: ACTIVE (Keyword detected)", 3000)
		print("\nTag detected in filename. Starting server...")
	else
		print("\nNo keyword found in filename. Script staying idle.")
	end

    sync_with_smplayer(video_path)
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


mp.observe_property("vf", "native", function(name, value)
    local any_rotation_active = false
    
    if value then
        for _, filter in ipairs(value) do
            -- print(filter.name)
            -- print(filter.params)
            -- print(filter.params.graph)

            if filter.name:find("lavfi") then
                any_rotation_active = true
                break
            end

            -- Look for the word "rotate" anywhere in the filter name or parameters
            -- if filter.name:find("rotate") or (filter.params and filter.params.graph and filter.params.graph:find("rotate")) then
            --     any_rotation_active = true
            --     break
            -- end
        end
    end

    -- If the filter list is now empty of rotations, but our script thinks we are rotated
    if not any_rotation_active and current_angle ~= 0 then
        mp.msg.info("SMPlayer cleared rotation successfully. Syncing script state.")
        current_angle = 0
        OSD_display_rotation(0)
    end
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


local function adjust_video()
    -- auto_crop()
end


-- AI Rotation: High frequency (e.g., 5s)
mp.add_periodic_timer(5, check_orientation)

-- Video adjustment: Low frequency (e.g., 20s)
mp.add_periodic_timer(4, adjust_video)


