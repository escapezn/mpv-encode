local utils = require "mp.utils"
local msg = require "mp.msg"
local options = require "mp.options"

local ON_WINDOWS = (package.config:sub(1,1) ~= "/")

local start_timestamp = nil
local profile_start = ""

-- implementation detail of the osd message
local timer = nil
local timer_duration = 2

local settings = {
    detached = true,
    container = "",
    only_active_tracks = false,
    preserve_filters = true,
    append_filter = "",
    codec = "-an -sn -c:v libvpx -crf 10 -b:v 1000k",
    output_format = "$f_$n.webm",
    output_directory = "",
    ffmpeg_command = "ffmpeg",
    print = true,
    nomap = false,
    gif = false,
    gif_fps = 10,
    gif_scale = "",
    gif_palettegen = "",
    gif_paletteuse = "",
    fonthelper_inject = true,
    fonthelper_daemon = "",
}

local has_ffi, ffi = pcall(require, "ffi")
if has_ffi and ON_WINDOWS then
    pcall(ffi.cdef, [[
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned short WORD;
        typedef unsigned char BYTE;
        typedef const wchar_t* LPCWSTR;
        typedef wchar_t* LPWSTR;
        typedef void* LPVOID;

        typedef struct _STARTUPINFOW {
            DWORD   cb;
            LPWSTR  lpReserved;
            LPWSTR  lpDesktop;
            LPWSTR  lpTitle;
            DWORD   dwX;
            DWORD   dwY;
            DWORD   dwXSize;
            DWORD   dwYSize;
            DWORD   dwXCountChars;
            DWORD   dwYCountChars;
            DWORD   dwFillAttribute;
            DWORD   dwFlags;
            WORD    wShowWindow;
            WORD    cbReserved2;
            BYTE*   lpReserved2;
            HANDLE  hStdInput;
            HANDLE  hStdOutput;
            HANDLE  hStdError;
        } STARTUPINFOW, *LPSTARTUPINFOW;

        typedef struct _PROCESS_INFORMATION {
            HANDLE hProcess;
            HANDLE hThread;
            DWORD  dwProcessId;
            DWORD  dwThreadId;
        } PROCESS_INFORMATION, *LPPROCESS_INFORMATION;

        int MultiByteToWideChar(
            unsigned int CodePage,
            DWORD        dwFlags,
            const char*  lpMultiByteStr,
            int          cbMultiByte,
            LPWSTR       lpWideCharStr,
            int          cchWideChar
        );

        BOOL CreateProcessW(
            LPCWSTR lpApplicationName,
            LPWSTR lpCommandLine,
            void* lpProcessAttributes,
            void* lpThreadAttributes,
            BOOL bInheritHandles,
            DWORD dwCreationFlags,
            void* lpEnvironment,
            LPCWSTR lpCurrentDirectory,
            LPSTARTUPINFOW lpStartupInfo,
            LPPROCESS_INFORMATION lpProcessInformation
        );
        DWORD ResumeThread(HANDLE hThread);
        DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
        BOOL GetExitCodeProcess(HANDLE hProcess, DWORD* lpExitCode);
        BOOL CloseHandle(HANDLE hObject);
    ]])
end


function append_table(lhs, rhs)
    for i = 1,#rhs do
        lhs[#lhs+1] = rhs[i]
    end
    return lhs
end

function file_exists(name)
    if not name or name == "" then return false end
    local info = utils.file_info(name)
    if info then return not info.is_dir end
    local f = io.open(name, "r")
    if f ~= nil then
        io.close(f)
        return true
    else
        return false
    end
end

local function utf8_to_wide(str)
    if not str or not has_ffi then return nil end
    local len = ffi.C.MultiByteToWideChar(65001, 0, str, #str, nil, 0)
    if len <= 0 then return nil end
    local wstr = ffi.new("wchar_t[?]", len + 1)
    ffi.C.MultiByteToWideChar(65001, 0, str, #str, wstr, len)
    wstr[len] = 0
    return wstr
end

local function quote_windows_arg(arg)
    if arg == "" then return '""' end
    if not string.find(arg, '[ \t\n\v"]') then
        return arg
    end
    local result = '"'
    local bs_count = 0
    for i = 1, #arg do
        local c = string.sub(arg, i, i)
        if c == '\\' then
            bs_count = bs_count + 1
        elseif c == '"' then
            result = result .. string.rep('\\', bs_count * 2 + 1) .. '"'
            bs_count = 0
        else
            if bs_count > 0 then
                result = result .. string.rep('\\', bs_count)
                bs_count = 0
            end
            result = result .. c
        end
    end
    if bs_count > 0 then
        result = result .. string.rep('\\', bs_count * 2)
    end
    result = result .. '"'
    return result
end

local function build_windows_cmdline(args)
    local parts = {}
    for i = 1, #args do
        parts[i] = quote_windows_arg(args[i])
    end
    return table.concat(parts, " ")
end

local function resolve_fonthelper_daemon(custom_path)
    if custom_path and custom_path ~= "" and file_exists(custom_path) then
        return custom_path
    end

    local sfh_opts = { daemon_path = "" }
    options.read_options(sfh_opts, "subtitle_font_helper")
    if sfh_opts.daemon_path ~= "" and file_exists(sfh_opts.daemon_path) then
        return sfh_opts.daemon_path
    end

    local candidates = {
        mp.command_native({"expand-path", "~~/scripts/subtitle-font-helper/SubtitleFontAutoLoaderDaemon.exe"}),
        mp.command_native({"expand-path", "~~/scripts/SubtitleFontHelper/SubtitleFontAutoLoaderDaemon.exe"}),
    }
    local script_dir = mp.get_script_directory()
    if script_dir then
        table.insert(candidates, utils.join_path(script_dir, "SubtitleFontAutoLoaderDaemon.exe"))
        table.insert(candidates, utils.join_path(script_dir, "../subtitle-font-helper/SubtitleFontAutoLoaderDaemon.exe"))
        table.insert(candidates, utils.join_path(script_dir, "../SubtitleFontHelper/SubtitleFontAutoLoaderDaemon.exe"))
        table.insert(candidates, utils.join_path(script_dir, "subtitle-font-helper/SubtitleFontAutoLoaderDaemon.exe"))
        table.insert(candidates, utils.join_path(script_dir, "SubtitleFontHelper/SubtitleFontAutoLoaderDaemon.exe"))
    end
    for _, path in ipairs(candidates) do
        if path and path ~= "" and file_exists(path) then
            return path
        end
    end
    return nil
end

local function execute_with_fonthelper(args, settings)
    if not (ON_WINDOWS and has_ffi and settings.fonthelper_inject) then
        return false
    end

    local daemon_path = resolve_fonthelper_daemon(settings.fonthelper_daemon)
    if not daemon_path then
        return false
    end

    local cmdline_str = build_windows_cmdline(args)
    local wcmdline = utf8_to_wide(cmdline_str)
    if not wcmdline then
        return false
    end

    local si = ffi.new("STARTUPINFOW")
    si.cb = ffi.sizeof(si)
    local STARTF_USESHOWWINDOW = 0x00000001
    local SW_HIDE = 0
    si.dwFlags = STARTF_USESHOWWINDOW
    si.wShowWindow = SW_HIDE

    local pi = ffi.new("PROCESS_INFORMATION")

    local CREATE_SUSPENDED = 0x00000004
    local CREATE_NO_WINDOW = 0x08000000
    local creation_flags = CREATE_SUSPENDED + CREATE_NO_WINDOW
    local ok = ffi.C.CreateProcessW(
        nil,
        wcmdline,
        nil,
        nil,
        0,
        creation_flags,
        nil,
        nil,
        si,
        pi
    )

    if ok == 0 then
        msg.warn("Failed to create suspended FFmpeg process via Win32 API")
        return false
    end

    local pid = tonumber(pi.dwProcessId)
    msg.info(string.format("FFmpeg created suspended (PID: %d), injecting FontHelper...", pid))

    -- Perform injection
    local inject_args = {
        daemon_path,
        "-inject", tostring(pid),
        "-no-monitor"
    }
    local inject_res = utils.subprocess({ args = inject_args, max_size = 0, cancellable = false })
    if inject_res.status ~= 0 then
        msg.warn(string.format("FontHelper injection returned non-zero status: %d", inject_res.status))
    else
        msg.info(string.format("FontHelper injected successfully into FFmpeg (PID: %d)", pid))
    end

    -- Resume FFmpeg main thread
    ffi.C.ResumeThread(pi.hThread)

    if settings.detached then
        ffi.C.CloseHandle(pi.hThread)
        ffi.C.CloseHandle(pi.hProcess)
        return true
    else
        local screenx, screeny, aspect = mp.get_osd_size()
        mp.set_osd_ass(screenx, screeny, "{\\an9}● ")

        local INFINITE = 0xFFFFFFFF
        ffi.C.WaitForSingleObject(pi.hProcess, INFINITE)

        local exit_code = ffi.new("DWORD[1]")
        ffi.C.GetExitCodeProcess(pi.hProcess, exit_code)

        ffi.C.CloseHandle(pi.hThread)
        ffi.C.CloseHandle(pi.hProcess)

        mp.set_osd_ass(screenx, screeny, "")
        if exit_code[0] == 0 then
            mp.osd_message("Finished encoding succesfully")
        else
            mp.osd_message("Failed to encode, check the log")
        end
        return true
    end
end

function get_extension(path)
    local candidate = string.match(path, "%.([^.]+)$")
    if candidate then
        for _, ext in ipairs({ "mkv", "webm", "mp4", "avi" }) do
            if candidate == ext then
                return candidate
            end
        end
    end
    return "mkv"
end

function get_output_string(dir, format, input, extension, title, from, to, profile)
    local res = utils.readdir(dir)
    if not res then
        return nil
    end
    local files = {}
    for _, f in ipairs(res) do
        files[f] = true
    end
    local output = format
    output = string.gsub(output, "$f", function() return input end)
    output = string.gsub(output, "$t", function() return title end)
    output = string.gsub(output, "$s", function() return seconds_to_time_string(from, true) end)
    output = string.gsub(output, "$e", function() return seconds_to_time_string(to, true) end)
    output = string.gsub(output, "$d", function() return seconds_to_time_string(to-from, true) end)
    if (track_type == "sub" and settings.only_active_tracks == false) or (track_type == "sub" and settings.only_active_tracks == true and sub_visiable == true) then
        output = string.gsub(output, "$x", "mkv")
    else
        output = string.gsub(output, "$x", function() return extension end)
    end
    -- output = string.gsub(output, "$x", function() return extension end)
    output = string.gsub(output, "$x", function() return extension end)
    output = string.gsub(output, "$p", function() return profile end)
    if ON_WINDOWS then
        output = string.gsub(output, "[/\\|<>?:\"*]", "_")
    end
    if not string.find(output, "$n") then
        return files[output] and nil or output
    end
    local i = 1
    while true do
        local potential_name = string.gsub(output, "$n", tostring(i))
        if not files[potential_name] then
            return potential_name
        end
        i = i + 1
    end
end

function get_video_filters()
    local filters = {}
    for _, vf in ipairs(mp.get_property_native("vf")) do
        local name = vf["name"]
        name = string.gsub(name, '^lavfi%-', '')
        local filter
        if name == "crop" then
            local p = vf["params"]
            filter = string.format("crop=%d:%d:%d:%d", p.w, p.h, p.x, p.y)
        elseif name == "mirror" then
            filter = "hflip"
        elseif name == "flip" then
            filter = "vflip"
        elseif name == "rotate" then
            local rotation = vf["params"]["angle"]
            -- rotate is NOT the filter we want here
            if rotation == "90" then
                filter = "transpose=clock"
            elseif rotation == "180" then
                filter = "transpose=clock,transpose=clock"
            elseif rotation == "270" then
                filter = "transpose=cclock"
            end
        end
        filters[#filters + 1] = filter
    end
    return filters
end

function get_input_info(default_path, only_active)
    local accepted
    if not settings.nomap then
        accepted = {
            video = true,
            audio = not mp.get_property_bool("mute"),
            sub = mp.get_property_bool("sub-visibility")
        }
    else accepted = {
            video = true,
            audio = false,
            sub = false
        }
    end
    local ret = {}
    for _, track in ipairs(mp.get_property_native("track-list")) do
        local track_path = track["external-filename"] or default_path
        if not only_active or (track["selected"] and accepted[track["type"]]) then
            local tracks = ret[track_path]
            if not tracks then
                ret[track_path] = { track["ff-index"] }
            else
                tracks[#tracks + 1] = track["ff-index"]
            end
        end
    end
    return ret
end

function seconds_to_time_string(seconds, full)
    local ret = string.format("%02d:%02d.%03d"
        , math.floor(seconds / 60) % 60
        , math.floor(seconds) % 60
        , seconds * 1000 % 1000
    )
    if full or seconds > 3600 then
        ret = string.format("%d:%s", math.floor(seconds / 3600), ret)
    end
    return ret
end

function start_encoding(from, to, settings)
    local args = {
        settings.ffmpeg_command,
        "-loglevel", "panic", "-hide_banner",
    }
    local append_args = function(table) args = append_table(args, table) end

    local path = mp.get_property("path")
    local is_stream = not file_exists(path)
    if is_stream then
        path = mp.get_property("stream-path")
    end

    local track_args = {}
    local start = seconds_to_time_string(from, false)
    local input_index = 0
    local sub_in_path
    for input_path, tracks in pairs(get_input_info(path, settings.only_active_tracks)) do
        sub_in_path = string.gsub(string.gsub(input_path, "\\", "\\\\"), ":", "\\:")
        append_args({
            "-ss", start,
            "-t", string.format("%.3f", to-from),
            "-i", input_path,
        })
        if settings.only_active_tracks then
            for _, track_index in ipairs(tracks) do
            track_args = append_table(track_args, { "-map", string.format("%d:%d", input_index, track_index)})
            end
        else
            track_args = append_table(track_args, { "-map", tostring(input_index)})
        end
        input_index = input_index + 1
    end

    sub_visiable = mp.get_property_bool("sub-visibility")
    track_type = nil

    local i = 0
    local tracks_count = mp.get_property_number("track-list/count")
    local sub_ex
    local sub_in
    while i < tracks_count do
        track_type = mp.get_property(string.format("track-list/%d/type", i))
        local track_index = mp.get_property_number(string.format("track-list/%d/id", i))
        local track_selected = mp.get_property(string.format("track-list/%d/selected", i))
        local track_external = mp.get_property(string.format("track-list/%d/external", i))
        local track_external_filename = mp.get_property(string.format("track-list/%d/external-filename", i))
        if track_type == "sub" and track_selected == "yes" then
            if track_external == "yes" then
                sub_ex = string.gsub(string.gsub(track_external_filename, "\\", "\\\\"), ":", "\\:")
            else
                sub_in = track_index - 1
            end
            break
        else
            i = i + 1
        end
    end

    local args_sub_ex
    local args_sub_in
    local sub_ex_on = (sub_visiable == true and sub_ex)
    local sub_in_on = (sub_visiable == true and sub_in)
    if sub_ex_on then
        args_sub_ex = "subtitles='" .. sub_ex .. "',setpts=PTS+" .. from .. "/TB"
    elseif sub_in_on then
        args_sub_in = "subtitles='" .. sub_in_path .. ":si=" .. sub_in .. "',setpts=PTS+" .. from .. "/TB"
    else
    end

    if settings.gif then
        local gif_args_vf = "[0:v]fps=" .. settings.gif_fps .. ",scale=" .. settings.gif_scale
        local gif_args_palette = settings.gif_palettegen .. settings.gif_paletteuse
        if sub_ex_on then
            append_args({
                "-copyts",
                "-filter_complex", gif_args_vf .. "," .. args_sub_ex .. gif_args_palette,
            })
        elseif sub_in_on then
            append_args({
                "-copyts",
                "-filter_complex", gif_args_vf .. "," .. args_sub_in .. gif_args_palette,
            })
        else
            append_args({
                "-filter_complex", gif_args_vf .. gif_args_palette,
            })
        end
    elseif settings.nomap then
        if sub_ex_on then
            append_args({
                "-copyts",
                "-vf", args_sub_ex,
            })
        elseif sub_in_on then
            append_args({
                "-copyts",
                "-vf", args_sub_in,
            })
        else
        end
    else
        append_args(track_args)
    end

    -- apply some of the video filters currently in the chain
    local filters = {}
    if settings.preserve_filters then
        filters = get_video_filters()
    end
    if settings.append_filter ~= "" then
        filters[#filters + 1] = settings.append_filter
    end
    if #filters > 0 then
        append_args({ "-filter:v", table.concat(filters, ",") })
    end

    -- split the user-passed settings on whitespace
    for token in string.gmatch(settings.codec, "[^%s]+") do
        args[#args + 1] = token
    end
    if settings.profile == "encode_slice" and track_type == "sub" then
        append_args({ "-disposition:s:0", "default" })
    end
    -- path of the output
    local output_directory = settings.output_directory
    if output_directory == "" then
        if is_stream then
            output_directory = "."
        else
            output_directory, _ = utils.split_path(path)
        end
    else
        output_directory = string.gsub(output_directory, "^~", os.getenv("HOME") or "~")
    end
    local input_name = mp.get_property("filename/no-ext") or "encode"
    local title = mp.get_property("media-title")
    local extension = get_extension(path)
    local output_name = get_output_string(output_directory, settings.output_format, input_name, extension, title, from, to, settings.profile)
    if not output_name then
        mp.osd_message("Invalid path " .. output_directory)
        return
    end
    args[#args + 1] = utils.join_path(output_directory, output_name)

    if settings.print then
        local o = ""
        -- fuck this is ugly
        for i = 1, #args do
            local fmt = ""
            if i == 1 then
                fmt = "%s%s"
            elseif i >= 2 and i <= 4 then
                fmt = "%s"
            elseif args[i-1] == "-i" or i == #args or args[i-1] == "-filter:v" then
                fmt = "%s '%s'"
            else
                fmt = "%s %s"
            end
            o = string.format(fmt, o, args[i])
        end
        print(o)
    end
    local handled = execute_with_fonthelper(args, settings)
    if not handled then
        if settings.detached then
            utils.subprocess_detached({ args = args })
        else
            local screenx, screeny, aspect = mp.get_osd_size()
            mp.set_osd_ass(screenx, screeny, "{\\an9}● ")
            local res = utils.subprocess({ args = args, max_size = 0, cancellable = false })
            mp.set_osd_ass(screenx, screeny, "")
            if res.status == 0 then
                mp.osd_message("Finished encoding succesfully")
            else
                mp.osd_message("Failed to encode, check the log")
            end
        end
    end
end

function clear_timestamp()
    timer:kill()
    start_timestamp = nil
    profile_start = ""
    mp.remove_key_binding("encode-ESC")
    mp.remove_key_binding("encode-ENTER")
    mp.osd_message("", 0)
end

function set_timestamp(profile)
    if not mp.get_property("path") then
        mp.osd_message("No file currently playing")
        return
    end
    if not mp.get_property_bool("seekable") then
        mp.osd_message("Cannot encode non-seekable media")
        return
    end

    if not start_timestamp or profile ~= profile_start then
        profile_start = profile
        start_timestamp = mp.get_property_number("time-pos")
        local msg = function()
            mp.osd_message(
                string.format("encode [%s]: waiting for end timestamp", profile or "default"),
                timer_duration
            )
        end
        msg()
        timer = mp.add_periodic_timer(timer_duration, msg)
        mp.add_forced_key_binding("ESC", "encode-ESC", clear_timestamp)
        mp.add_forced_key_binding("ENTER", "encode-ENTER", function() set_timestamp(profile) end)
    else
        local from = start_timestamp
        local to = mp.get_property_number("time-pos")
        if to <= from then
            mp.osd_message("Second timestamp cannot be before the first", timer_duration)
            timer:kill()
            timer:resume()
            return
        end
        clear_timestamp()
        mp.osd_message(string.format("Encoding from %s to %s"
            , seconds_to_time_string(from, false)
            , seconds_to_time_string(to, false)
        ), timer_duration)
        -- include the current frame into the extract
        local fps = mp.get_property_number("container-fps") or 30
        to = to + 1 / fps / 2
        if profile then
            options.read_options(settings, profile)
            if settings.container ~= "" then
                msg.warn("The 'container' setting is deprecated, use 'output_format' now")
                settings.output_format = settings.output_format .. "." .. settings.container
            end
            settings.profile = profile
        else
            settings.profile = "default"
        end
        start_encoding(from, to, settings)
    end
end

mp.add_key_binding(nil, "set-timestamp", set_timestamp)
