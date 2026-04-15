
-------------------------------- NOTES ------------------------------------------------------
-- SMplayer 25+ is buggy. After cropping or applying rotation, the aspect ratio will be wrong.
-- Use version 24.5
-- Update: version 25.6.0 (revision 10403) works.

-- INSTALLING MODULES:
-- # 1. Create the venv (without system site packages for total isolation)
-- python3 -m venv env

-- # 2. Activate it
-- source env/bin/activate

-- # 3. Install everything from the file
-- pip install -r requirements.txt

-- INSTALL and INITIALIZE git-lfs
-- sudo pacman -S git-lfs
-- git lfs install

-- DEBUGGING:
-- mpv --geometry=100%x100% --no-keepaspect-window --scripts=/path_to/mpv_ai_autorotate/ai_rotate.lua video.mkv
---------------------------------------------------------------------------------------------
APP_VERSION = "1.0.2"
APP_NAME = "mpv AI Auto-Rotate"

-- Check if we are in a venv, otherwise use system python
local python_path = "/mnt/D_TOSHIBA_S300/Projects/mpv_ai_autorotate/env/bin/python3"
local f = io.open(python_path, "r")
if f then 
    f:close() 
else 
    python_path = "python3" -- Fallback to system python
end

print("DEBUG: Using Python path: " .. python_path)

-- Start the Python server automatically when mpv opens
-- local python_path = "/usr/bin/python3" -- or your venv path
local server_script = "/mnt/D_TOSHIBA_S300/Projects/mpv_ai_autorotate/ai_listener.py"
local rotations = { [0] = 0, [1] = 90, [2] = 180, [3] = 270 }
local TRIGGER_KEYWORD = "rotate" -- Matches "rotate" in filename
local current_angle = 0
local osd_timer = nil
local last_w, last_h = 0, 0
local video_path = nil
local is_processing = false
local pause_history = {}
local ai_enabled = false
local cropping_active = false
local ini_rotation = false

local mp = mp
local utils = require 'mp.utils'
-- mp.set_property("osd-ass-cc", "yes")

local pid = utils.getpid()
local temp_frame = "/tmp/mpv_frame_" .. pid .. ".raw"
local socket_check = os.execute("test -S /tmp/mpv_ai_socket")


local function OSD_display_filters()
    -- Determine the top line (AI vs R)
    local status_text = "R"

    if ai_enabled then
        status_text = "AI"
    end

    local ass_data = string.format("{\\an7}{\\fs5}{\\b1}{\\1c&H00FF00&}%s%d", status_text, current_angle)

    -- Check if Cropping is active
    -- We look for the label '@applied_crop' in the current 
    -- filter list also in case SMplayer clears it
    local vf_table = mp.get_property_native("vf")
    cropping_active = false

    if vf_table then
        for _, filter in ipairs(vf_table) do
            if filter.label == "applied_crop" then
                cropping_active = true
                print("DEBUG: applied_crop filter label found")
                break
            end
        end
    end

    -- If cropping is active, append CR on a new line (\N)
    if cropping_active then
        -- \N is the standard ASS tag for a forced line break
        ass_data = ass_data .. "\\NCR"
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
        OSD_display_filters()
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
    -- If the angle hasn't changed, exit immediately to prevent flashing
    if target_angle == current_angle then return end

    -- 1. CLEANUP: Remove all possible SMPlayer rotation strings first
    -- This prevents multiple rotations from stacking on top of each other
    mp.command('no-osd vf remove "lavfi=[rotate=PI/2:ih:iw]"')
    mp.command('no-osd vf remove "lavfi=[hflip,vflip]"')
    mp.command('no-osd vf remove "lavfi=[rotate=3*PI/2:ih:iw]"')

    -- 2. APPLY: Match SMPlayer's specific math strings
    if target_angle == 90 then
        mp.command('no-osd vf add "lavfi=[rotate=PI/2:ih:iw]"')
    elseif target_angle == 180 then
        mp.command('no-osd vf add "lavfi=[hflip,vflip]"')
    elseif target_angle == 270 then
        mp.command('no-osd vf add "lavfi=[rotate=3*PI/2:ih:iw]"')
    end

    mp.set_property("video-aspect-override", "no")
    mp.set_property("video-aspect-mode", "container")

    -- 3. THE "KICK": Force SMPlayer/mpv to recalculate window geometry
    -- We set override to "no" to ensure we aren't fighting a previous manual setting
    -- mp.set_property("video-aspect-override", "no")

    -- -- The toggle trick that actually fixes the SMPlayer 25 bug
    -- mp.set_property_bool("keepaspect", false)
    -- mp.add_timeout(0.2, function()
    --     mp.set_property_bool("keepaspect", true)
    --     -- Optional: ensure OSD updates to show the correct state
    --     mp.set_property("video-aspect-mode", "container")
    -- end)

    current_angle = target_angle
    OSD_display_filters()
    print("Applied SMPlayer-compatible rotation: " .. target_angle)
end


local function auto_crop()
    -- Get the ORIGINAL container dimensions (ignore current filters)
    local video_w = mp.get_property_number("video-params/w")
    local video_h = mp.get_property_number("video-params/h")

    -- -- If the video is rotated 90/270, we must swap our reference width/height
    -- if current_angle == 90 or current_angle == 270 then
    --     video_w, video_h = video_h, video_w
    -- end

    -- Use 'pre' to ensure we look at the RAW frame before any existing crops
    -- Use 'no-osd' to keep the screen clean
    -- In cropdetect=limit:round:reset, the first value (limit) is the intensity threshold. 
    -- 5 is extremely low; digital noise in a "black" bar often exceeds this, causing the filter 
    -- to think the bar is part of the actual image.
    mp.command('no-osd vf pre @my_cropdetect:lavfi=[cropdetect=16/255:2]')

    mp.add_timeout(0.2, function()
        print("---------------------------------")

        -- Try label-specific metadata first (Most accurate)
        local metadata = mp.get_property_native("vf-metadata/my_cropdetect")

        -- Fallback to general metadata if label fails
        if not metadata or not metadata["lavfi.cropdetect.w"] then
            -- video-out-params usually only shows metadata for the last filter in the chain
            metadata = mp.get_property_native("video-out-params/metadata")
        end

        -- Debugging: See what mpv is actually seeing
        if not metadata then
            print("Metadata is still nil. Active filters: " .. mp.get_property("vf"))
        end

        local w = metadata and tonumber(metadata["lavfi.cropdetect.w"])
        local h = metadata and tonumber(metadata["lavfi.cropdetect.h"])
        local x = metadata and tonumber(metadata["lavfi.cropdetect.x"])
        local y = metadata and tonumber(metadata["lavfi.cropdetect.y"])

        -- Cleanup the detector
        mp.command("no-osd vf remove @my_cropdetect")
        cropping_active = false

        if w and h then
            print("DEBUG: Detected W: " .. w .. " vs Video W: " .. video_w)
            print("DEBUG: Detected H: " .. h .. " vs Video H: " .. video_h)

            -- Check if crop is essentially the full container size (margin of 10px)
            local is_full_frame = math.abs(w - video_w) < 10 and math.abs(h - video_h) < 10

            if is_full_frame then
                print("DEBUG: auto crop is_full_frame")

                if last_w ~= 0 then
                    print("Video is full frame. Removing crop.")
                    mp.command("no-osd vf remove @applied_crop")
                    last_w, last_h = 0, 0
                    OSD_display_filters()
                end
            else
                -- Only apply if the change is significant to avoid flickering
                local diff_w = math.abs(w - last_w)
                local diff_h = math.abs(h - last_h)

                print("DEBUG: auto crop diff_w: " .. diff_w)
                print("DEBUG: auto crop diff_h: " .. diff_h)

                if diff_w > 20 or diff_h > 20 then
                    print(string.format("Crop Applied: %dx%d at %d,%d", w, h, x, y))
                    mp.command(string.format("no-osd vf pre @applied_crop:crop=%s:%s:%s:%s", w, h, x, y))
                    last_w, last_h = w, h
                    cropping_active = true
                    OSD_display_filters()
                end
            end

            -- local diff_w = math.abs(w - last_w)
            -- local diff_h = math.abs(h - last_h)

            -- Check for sanity (don't crop to a tiny dot) and threshold
            -- if not is_full_frame and (diff_w > 20 or diff_h > 20) then
            -- -- if w > 200 and h > 200 and (diff_w > 20 or diff_h > 20) then
            --     -- Apply/Update the display crop
            --     mp.command(string.format("no-osd vf pre @applied_crop:crop=%s:%s:%s:%s", w, h, x, y))
            --     last_w, last_h = w, h
                
            --     -- Force the modern aspect ratio logic
            --     mp.set_property("video-aspect-override", "no")
            --     mp.set_property("video-aspect-mode", "container")
                
            --     cropping_active = true
            --     OSD_display_filters()
            --     print(string.format("Crop Applied: %dx%d at %d,%d", w, h, x, y))

            -- elseif is_full_frame then
            --     -- If it's a full frame, remove existing crop if there was one
            --     if last_w ~= 0 then
            --        print("Video is full frame. Removing crop.")
            --        mp.command("no-osd vf remove @applied_crop")
            --        last_w, last_h = 0, 0
            --        OSD_display_filters()
            --     end
            -- end
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
            local rotations_smplayer = { [-1] = 0, [1] = 90, [2] = 270, [4] = 180 }
            local degrees = rotations_smplayer[tonumber(rotation)]

            if not degrees or degrees == 0 then
                return
            end

            ini_rotation = true
            apply_rotation(degrees)
            OSD_ai_message("Restored SMPlayer Rotation: " .. degrees .. "°", 3000)
        end
    end)
end


local function has_trigger(path, keyword)
    local p = path:lower()
    local k = keyword:lower() -- keyword would be "%rotate"

    -- We must escape the % in the keyword for the find command
    local escaped_k = k:gsub("%%", "%%%%")
    local start_idx, end_idx = p:find(escaped_k)

    if start_idx then
        -- Character immediately after the keyword
        local next_char = p:sub(end_idx + 1, end_idx + 1)

        -- Boundary check: Is it a space, comma, closing bracket, or end of string?
        local valid_boundaries = { [" "] = true, [","] = true, ["]"] = true, [""] = true, ["."] = true }

        if valid_boundaries[next_char] then
            return true
        end
    end
    return false
end


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
        OSD_display_filters()
    end
end)


mp.observe_property("pause", "bool", function(name, paused)
    local now = mp.get_time()
    table.insert(pause_history, now)

    print("DEBUG: pause detected: " .. now)

    -- Keep only timestamps from the last 5 seconds
    while #pause_history > 0 and now - pause_history[1] > 5 do
        table.remove(pause_history, 1)
    end

    -- If we detect 3 toggles (state changes) in the window
    if #pause_history >= 6 then
        print("DEBUG: AI rotation toggled using pause gesture")
        ai_enabled = not ai_enabled
        local status = ai_enabled and "ENABLED" or "DISABLED"
        OSD_ai_message("AI Mode: " .. status, 3000)
        pause_history = {} -- Reset history to prevent immediate re-trigger
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
        local f = io.open(temp_frame, "wb")

        if f then
            f:write(res.data)
            f:close()
            print("---------------------------------")
            print("Sending frame")

            -- Pass the native width/height to Python so it can calculate the stride
            -- 8 bytes width, 8 bytes height, then the filename
            local header = string.format("%08d%08d%s", res.w, res.h, temp_frame)
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
    if mp.get_property_native("pause") then
        return
    end

    auto_crop()
end


-- FUNCTION TO START THE SERVER
-- Simple check to see if we should start the server
print("Starting '" .. APP_NAME .. "' version " .. APP_VERSION)
if socket_check ~= 0 then
    print("Starting Python AI Server...")
    mp.command_native_async({ name = "subprocess", args = { python_path, server_script }, detach = true })
else
    print("AI Server already running, connecting...")
end


-- EVENT: file loaded
mp.register_event("file-loaded", function()
    video_path = mp.get_property("path") -- get file path

    if has_trigger(video_path, TRIGGER_KEYWORD) then
        ai_enabled = true
        OSD_ai_message("Rotation ACTIVE (Keyword detected)", 3000)
        print("Rotation ACTIVE (Keyword detected)")
    else
        print("No keyword found in filename.")
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
    os.remove(temp_frame)
end)


-- AI Rotation: High frequency (e.g., 5s)
mp.add_periodic_timer(5, check_orientation)

-- Video adjustment: Low frequency (e.g., 20s)
mp.add_periodic_timer(5, adjust_video)
