local utils = require "mp.utils"
local msg = require "mp.msg"
local options = require "mp.options"

local ON_WINDOWS = (package.config:sub(1,1) ~= "/")

local has_ffi, ffi = pcall(require, "ffi")
if has_ffi and ON_WINDOWS then
    ffi.cdef[[
        void* _wfopen(const wchar_t* filename, const wchar_t* mode);
        size_t fread(void* ptr, size_t size, size_t nmemb, void* stream);
        size_t fwrite(const void* ptr, size_t size, size_t nmemb, void* stream);
        int fclose(void* stream);
        long ftell(void* stream);
        int fseek(void* stream, long offset, int origin);
        int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
        int CreateHardLinkW(const wchar_t* lpFileName, const wchar_t* lpExistingFileName, void* lpSecurityAttributes);
        unsigned long GetFileAttributesW(const wchar_t* lpFileName);
        int CreateDirectoryW(const wchar_t* lpPathName, void* lpSecurityAttributes);
        int DeleteFileW(const wchar_t* lpFileName);
    ]]
end

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
    auto_fonts = true,
    font_index_path = "",
    temp_fonts_dir = "",
}


function append_table(lhs, rhs)
    for i = 1,#rhs do
        lhs[#lhs+1] = rhs[i]
    end
    return lhs
end

local function utf8_to_wide(str)
    if not (has_ffi and ON_WINDOWS and str) then return nil end
    local CP_UTF8 = 65001
    local len = ffi.C.MultiByteToWideChar(CP_UTF8, 0, str, #str, nil, 0)
    local wstr = ffi.new("wchar_t[?]", len + 1)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, str, #str, wstr, len)
    wstr[len] = 0
    return wstr
end

local function read_file_content(path)
    if has_ffi and ON_WINDOWS then
        local wpath = utf8_to_wide(path)
        local wmode = utf8_to_wide("rb")
        if wpath and wmode then
            local fp = ffi.C._wfopen(wpath, wmode)
            if fp ~= nil then
                ffi.C.fseek(fp, 0, 2)
                local size = tonumber(ffi.C.ftell(fp))
                ffi.C.fseek(fp, 0, 0)
                local buf = ffi.new("char[?]", size)
                local read_bytes = tonumber(ffi.C.fread(buf, 1, size, fp))
                ffi.C.fclose(fp)
                return ffi.string(buf, read_bytes)
            end
        end
    end
    local f = io.open(path, "rb")
    if f then
        local c = f:read("*a")
        f:close()
        return c
    end
    return nil
end

function file_exists(name)
    if not name or name == "" then return false end
    if has_ffi and ON_WINDOWS then
        local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
        local wpath = utf8_to_wide(name)
        if wpath then
            local attr = ffi.C.GetFileAttributesW(wpath)
            if attr ~= INVALID_FILE_ATTRIBUTES then
                return true
            end
        end
    end
    local f = io.open(name, "r")
    if f ~= nil then
        io.close(f)
        return true
    else
        return false
    end
end

local function unescape_xml(str)
    if not str then return "" end
    str = string.gsub(str, "&amp;", "&")
    str = string.gsub(str, "&lt;", "<")
    str = string.gsub(str, "&gt;", ">")
    str = string.gsub(str, "&quot;", "\"")
    str = string.gsub(str, "&apos;", "'")
    return str
end

local function trim_str(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function parse_ass_fonts(content)
    if not content or content == "" then return {} end
    local fonts = {}
    for line in string.gmatch(content, "[^\r\n]+") do
        local style_line = string.match(line, "^%s*Style:%s*(.*)$")
        if style_line then
            local parts = {}
            for part in string.gmatch(style_line .. ",", "([^,]*),") do
                parts[#parts + 1] = part
            end
            if #parts >= 2 then
                local fontname = trim_str(parts[2])
                if fontname:sub(1, 1) == "@" then
                    fontname = fontname:sub(2)
                end
                if fontname ~= "" then
                    fonts[fontname] = true
                end
            end
        end
        for fn in string.gmatch(line, "\\fn([^\\}]+)") do
            local fontname = trim_str(fn)
            if fontname:sub(1, 1) == "@" then
                fontname = fontname:sub(2)
            end
            if fontname ~= "" then
                fonts[fontname] = true
            end
        end
    end
    return fonts
end

local g_font_index_cache = nil
local g_font_index_path_cached = nil

local function get_font_index_content(index_path)
    if not file_exists(index_path) then return nil end
    if g_font_index_cache and g_font_index_path_cached == index_path then
        return g_font_index_cache
    end
    local content = read_file_content(index_path)
    if content then
        g_font_index_cache = content
        g_font_index_path_cached = index_path
    end
    return content
end

local function find_font_paths_in_index(index_content, fonts)
    local matched_paths = {}
    local lower_index_content = nil
    for font_name, _ in pairs(fonts) do
        local target = ">" .. font_name .. "<"
        local pos = string.find(index_content, target, 1, true)
        if not pos then
            if not lower_index_content then
                lower_index_content = string.lower(index_content)
            end
            pos = string.find(lower_index_content, string.lower(target), 1, true)
        end
        if pos then
            local chunk_start = math.max(1, pos - 2000)
            local sub_str = string.sub(index_content, chunk_start, pos)
            local tag = '<FontFace path="'
            local last_pos = nil
            local s_from = 1
            while true do
                local p = string.find(sub_str, tag, s_from, true)
                if not p then break end
                last_pos = chunk_start + p - 1
                s_from = p + #tag
            end
            if last_pos then
                local start_p = last_pos + #tag
                local end_p = string.find(index_content, '"', start_p, true)
                if end_p then
                    local raw_path = string.sub(index_content, start_p, end_p - 1)
                    local path = unescape_xml(raw_path)
                    if file_exists(path) then
                        matched_paths[path] = true
                    end
                end
            end
        end
    end
    return matched_paths
end

local function ensure_dir(dir_path)
    if has_ffi and ON_WINDOWS then
        local wdir = utf8_to_wide(dir_path)
        if wdir then ffi.C.CreateDirectoryW(wdir, nil) end
    else
        os.execute('mkdir "' .. dir_path .. '" 2>nul')
    end
end

local function delete_file(path)
    if has_ffi and ON_WINDOWS then
        local wpath = utf8_to_wide(path)
        if wpath then ffi.C.DeleteFileW(wpath) end
    else
        os.remove(path)
    end
end

local function link_or_copy_font(src_path, dst_path)
    delete_file(dst_path)
    if has_ffi and ON_WINDOWS then
        local wsrc = utf8_to_wide(src_path)
        local wdst = utf8_to_wide(dst_path)
        if wsrc and wdst and ffi.C.CreateHardLinkW(wdst, wsrc, nil) ~= 0 then
            return true
        end
    end
    local data = read_file_content(src_path)
    if not data then return false end
    if has_ffi and ON_WINDOWS then
        local wdst = utf8_to_wide(dst_path)
        local wmode = utf8_to_wide("wb")
        if wdst and wmode then
            local fp = ffi.C._wfopen(wdst, wmode)
            if fp ~= nil then
                local written = tonumber(ffi.C.fwrite(data, 1, #data, fp))
                ffi.C.fclose(fp)
                return written == #data
            end
        end
    end
    local f = io.open(dst_path, "wb")
    if f then
        f:write(data)
        f:close()
        return true
    end
    return false
end

local function get_sub_fontsdir_opt(sub_file_or_video, track_idx_or_nil, enc_settings)
    if not enc_settings.auto_fonts then return "" end
    local index_path = enc_settings.font_index_path
    if not index_path or index_path == "" then
        return ""
    end
    index_path = mp.command_native({"expand-path", index_path}) or index_path
    if not file_exists(index_path) then
        return ""
    end

    local ass_content = nil
    if track_idx_or_nil == nil then
        ass_content = read_file_content(sub_file_or_video)
    else
        local temp_sub = utils.join_path(os.getenv("TEMP") or ".", "mpv_encode_temp_sub.ass")
        local extract_args = {
            enc_settings.ffmpeg_command,
            "-loglevel", "panic", "-y",
            "-i", sub_file_or_video,
            "-map", string.format("0:%d", track_idx_or_nil),
            "-c:s", "copy",
            temp_sub
        }
        local res = utils.subprocess({ args = extract_args, cancellable = false })
        if res.status == 0 and file_exists(temp_sub) then
            ass_content = read_file_content(temp_sub)
            delete_file(temp_sub)
        end
    end

    if not ass_content or ass_content == "" then return "" end

    local fonts = parse_ass_fonts(ass_content)
    local has_any_font = false
    for _ in pairs(fonts) do
        has_any_font = true
        break
    end
    if not has_any_font then return "" end

    local index_content = get_font_index_content(index_path)
    if not index_content then return "" end

    local matched_paths = find_font_paths_in_index(index_content, fonts)
    local has_matched = false
    for _ in pairs(matched_paths) do
        has_matched = true
        break
    end
    if not has_matched then return "" end

    local temp_dir = enc_settings.temp_fonts_dir
    if not temp_dir or temp_dir == "" then
        temp_dir = utils.join_path(os.getenv("TEMP") or ".", "mpv_encode_fonts")
    end
    ensure_dir(temp_dir)

    for src_path, _ in pairs(matched_paths) do
        local _, filename = utils.split_path(src_path)
        local dst_path = utils.join_path(temp_dir, filename)
        link_or_copy_font(src_path, dst_path)
    end

    local escaped_dir = string.gsub(string.gsub(temp_dir, "\\", "/"), ":", "\\:")
    return ":fontsdir='" .. escaped_dir .. "'"
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
    local raw_sub_ex_filename
    local sub_in
    while i < tracks_count do
        track_type = mp.get_property(string.format("track-list/%d/type", i))
        local track_index = mp.get_property_number(string.format("track-list/%d/id", i))
        local track_selected = mp.get_property(string.format("track-list/%d/selected", i))
        local track_external = mp.get_property(string.format("track-list/%d/external", i))
        local track_external_filename = mp.get_property(string.format("track-list/%d/external-filename", i))
        if track_type == "sub" and track_selected == "yes" then
            if track_external == "yes" then
                raw_sub_ex_filename = track_external_filename
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
    local fontsdir_opt = ""
    if sub_ex_on then
        fontsdir_opt = get_sub_fontsdir_opt(raw_sub_ex_filename, nil, settings)
        args_sub_ex = "subtitles='" .. sub_ex .. "'" .. fontsdir_opt .. ",setpts=PTS+" .. from .. "/TB"
    elseif sub_in_on then
        fontsdir_opt = get_sub_fontsdir_opt(path, sub_in, settings)
        args_sub_in = "subtitles='" .. sub_in_path .. ":si=" .. sub_in .. "'" .. fontsdir_opt .. ",setpts=PTS+" .. from .. "/TB"
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
