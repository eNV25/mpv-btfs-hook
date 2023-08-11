--[[

script to make mpv play torrents/magnets directly using btfs https://github.com/johang/btfs

original script: https://gist.github.com/huglovefan/4c68bc40661b6701ca5fc6ce1157f192

requires:
- btfs
- btfsstat
- file --brief --mime-type
- umount
- rmdir
- mkdir -p
- sleep

usage:
- open a magnet link or torrent url using mpv and it should Just Work
- urls must end with ".torrent" to be detected by this

]]

-- see "btfs --help"
local BTFS_ARGS = {
	-- temporary directory to store downloaded data
	-- '--data-directory=', Using xdg by default
	-- you may want to make sure this is on a real filesystem and not tmpfs
	-- otherwise it might fill your ram when watching a big enough file

	-- these are in kB/s
	--'--max-download-rate=4900',
	"--max-upload-rate=500",
}

local MOUNT_DIR = "/tmp/mpvbtfs"

--------------------------------------------------------------------------------

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

--------------------------------------------------------------------------------

-- predeclare with some common file types, for faster loading
local MPV_MEDIA_TYPES = {
	[".aiff"] = true,
	[".ape"] = true,
	[".au"] = true,
	[".flac"] = true,
	[".m4a"] = true,
	[".mka"] = true,
	[".mp3"] = true,
	[".oga"] = true,
	[".ogg"] = true,
	[".ogm"] = true,
	[".opus"] = true,
	[".wav"] = true,
	[".wma"] = true,

	[".m3u"] = true,
	[".m3u8"] = true,

	[".3g2"] = true,
	[".3gp"] = true,
	[".avi"] = true,
	[".flv"] = true,
	[".m2ts"] = true,
	[".m4v"] = true,
	[".mj2"] = true,
	[".mkv"] = true,
	[".mov"] = true,
	[".mp4"] = true,
	[".mpeg"] = true,
	[".mpg"] = true,
	[".ogv"] = true,
	[".rmvb"] = true,
	[".webm"] = true,
	[".wmv"] = true,
	[".y4m"] = true,

	[".avif"] = false,
	[".bmp"] = false,
	[".gif"] = false,
	[".j2k"] = false,
	[".jp2"] = false,
	[".jpeg"] = false,
	[".jpg"] = false,
	[".jxl"] = false,
	[".png"] = false,
	[".svg"] = false,
	[".tga"] = false,
	[".tif"] = false,
	[".tiff"] = false,
	[".webp"] = false,

	[".dfxp"] = false,
	[".html"] = false,
	[".lrc"] = false,
	[".sami"] = false,
	[".smi"] = false,
	[".srt"] = false,
	[".sub"] = false,
	[".ttml"] = false,
	[".txt"] = false,
	[".usf"] = false,
	[".vtt"] = false,
	[".xml"] = false,
}

setmetatable(MPV_MEDIA_TYPES, {
	__index = function(table, key)
		if not rawget(table, "init") and key:match("^[^/]+/[^/]+$") then
			-- init MPV_MEDIA_TYPES with supported mime types from mpv.desktop,
			-- for use with file --brief --mime-type
			(function()
				-- get XDG_DATA_DIRS and add a final colon to make it easier to parse
				local XDG_DATA_DIRS = os.getenv("XDG_DATA_DIRS") or "/usr/share"
				if not XDG_DATA_DIRS:match(":$") then
					XDG_DATA_DIRS = XDG_DATA_DIRS .. ":"
				end
				for path in XDG_DATA_DIRS:gmatch("(.-):") do
					-- build path and make sure it is absolute
					path = utils.join_path(path, "applications/mpv.desktop")
					if path:match("^/") then
						-- find the first mpv.desktop in XDG_DATA_DIRS
						local f = io.open(path)
						if f then
							-- parse the first MimeType= line
							for line in f:lines() do
								local mime_types = line:match("^MimeType=(.*)$")
								if mime_types then
									f:close()
									if not mime_types:match(";$") then
										mime_types = mime_types .. ";"
									end
									for mime_type in mime_types:gmatch("(.-);") do
										rawset(table, mime_type, true)
									end
									return
								end
							end
							f:close()
						end
					end
				end
			end)()
			rawset(table, "init", true)
		end
		return rawget(table, key)
	end,
})

-- return shortest file extension
local file_ext = function(file)
	return file:match("^.+(%.[^.][^.]-)$")
end

-- alphanum sorting for humans in Lua, copied from autoload.lua
-- http://notebook.kulchenko.com/algorithms/alphanumeric-natural-sorting-for-humans-in-lua
local alphanumsort = function(filenames)
	local padnum = function(n, d)
		return #d > 0 and ("%03d%s%.12f"):format(#n, n, tonumber(d) / (10 ^ #d)) or ("%03d%s"):format(#n, n)
	end

	local tuples = {}
	for i, f in ipairs(filenames) do
		tuples[i] = { f:lower():gsub("0*(%d+)%.?(%d*)", padnum), f }
	end
	table.sort(tuples, function(a, b)
		return a[1] == b[1] and #b[2] < #a[2] or a[1] < b[1]
	end)
	for i, tuple in ipairs(tuples) do
		filenames[i] = tuple[2]
	end
	return filenames
end

-- list files from the mountpoint that should added to the playlist
local list_files = function(mountpoint)
	local files = {}
	local dirs = { mountpoint }

	while #dirs > 0 do
		-- pop first directory
		local current = dirs[1]
		table.remove(dirs, 1)

		-- append media files, while caching file extensions for future use
		local subfiles = alphanumsort(utils.readdir(current, "files"))
		for _, filename in ipairs(subfiles) do
			local ext = file_ext(filename)
			local file = utils.join_path(current, filename)

			msg.verbose("checking " .. file)

			if ext and MPV_MEDIA_TYPES[ext] then
				table.insert(files, file)
			elseif MPV_MEDIA_TYPES[ext] == nil then
				local mime_type = mp.command_native({
							name = "subprocess",
							args = { "file", "--brief", "--mime-type", file },
							capture_stdout = true,
						}).stdout
						:match("[%S]*") -- strip whitespace

				if mime_type and MPV_MEDIA_TYPES[mime_type] then
					msg.verbose("using " .. file)

					MPV_MEDIA_TYPES[ext] = true
					table.insert(files, file)
				end
			end
		end

		-- append subdirectories to queue
		local subdirs = alphanumsort(utils.readdir(current, "dirs"))
		for _, dirname in ipairs(subdirs) do
			table.insert(dirs, utils.join_path(current, dirname))
		end
	end

	return files
end

--------------------------------------------------------------------------------

-- mountpoints mounted by us (will be unmounted on shutdown)
local mounted_points = {}

local is_mounted = function(mountpoint)
	return mp.command_native({
		name = "subprocess",
		args = { "btfsstat", mountpoint },
		capture_size = 0,
		capture_stdout = true,
		capture_stderr = true,
	}).status == 0
end

local do_unmount = function(url, mountpoint)
	mounted_points[url] = nil
	mp.command_native({ name = "subprocess", args = { "umount", mountpoint }, playback_only = false })
	mp.command_native({ name = "subprocess", args = { "rmdir", mountpoint }, playback_only = false })
end

local do_mount = function(url, mountpoint)
	mp.command_native({ name = "subprocess", args = { "mkdir", "-p", mountpoint } })

	local args = { "btfs" }
	for _, v in ipairs(BTFS_ARGS) do
		table.insert(args, v)
	end
	table.insert(args, url)
	table.insert(args, mountpoint)

	mp.command_native({ name = "subprocess", args = args })

	msg.verbose("waiting for files")

	-- wait until btfs is finished mounting, else fail
	while is_mounted(mountpoint) do
		if #utils.readdir(mountpoint) > 0 then
			msg.verbose("files found")
			mounted_points[url] = mountpoint
			return true
		end
		mp.command_native({ name = "subprocess", args = { "sleep", "0.25" } })
	end
	return false
end

--------------------------------------------------------------------------------

-- gets the info hash or torrent filename for use as the mount directory name
local parse_url = function(url)
	return url:match("^magnet:.*[?&]xt=urn:bt[im]h:(%w*)&?") or (url:match("^.*%.torrent$") and url:gsub("/", "⧸"))
end

local file_url = function(file)
	return "file://" .. file:gsub("%%", "%%25"):gsub("\r", "%%0D"):gsub("\n", "%%0A")
end

mp.add_hook("on_load", 11, function()
	local url = mp.get_property("stream-open-filename")
	if not url then
		return
	end

	msg.verbose("using url " .. url)

	local dirname = parse_url(url)
	if not dirname then
		return
	end

	local mountpoint = (MOUNT_DIR .. "/" .. dirname)

	msg.verbose("using mountpoint " .. mountpoint)

	if not is_mounted(mountpoint) then
		if not do_mount(url, mountpoint) then
			msg.error("mount failed!")
			return
		end
	end

	local files = list_files(mountpoint)
	if #files == 0 then
		msg.error("nothing to play!")
	else
		local playlist = { "#EXTM3U" }
		for _, file in ipairs(files) do
			table.insert(playlist, file_url(file))
		end
		mp.set_property("stream-open-filename", "memory://" .. table.concat(playlist, "\n"))
	end
end)

mp.register_event("shutdown", function()
	for url, mountpoint in pairs(mounted_points) do
		do_unmount(url, mountpoint)
	end
end)
