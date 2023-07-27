--[[

script to make mpv play torrents/magnets directly using btfs

original script: https://gist.github.com/huglovefan/4c68bc40661b6701ca5fc6ce1157f192

requires:
- linux
- btfs
- xterm (optional)

usage:
- open a magnet link or torrent url using mpv and it should Just Work
- urls must end with ".torrent" to be detected by this

]]

-- see "btfs --help"
local btfs_args = {
	-- temporary directory to store downloaded data
	-- '--data-directory=', Using xdg by default
	-- you may want to make sure this is on a real filesystem and not tmpfs
	-- otherwise it might fill your ram when watching a big enough file

	-- these are in kB/s
	--'--max-download-rate=4900',
	"--max-upload-rate=500",
}

local mountdir = "/tmp/mpvbtfs"

--------------------------------------------------------------------------------

local mp = require("mp")
local utils = require("mp.utils")

local shellquote = function(s)
	return "'" .. s:gsub("'", [['\'']]) .. "'"
end

local exec_ok = os.execute
if _VERSION == "Lua 5.1" then
	exec_ok = function(...)
		return 0 == os.execute(...)
	end
end

local MPV_MIME_TYPES = {};

(function() -- init MPV_MIME_TYPES
	-- get XDG_DATA_DIRS and add a final semicolon to make it easier to parse
	local XDG_DATA_DIRS = os.getenv("XDG_DATA_DIRS") or "/usr/share"
	if not XDG_DATA_DIRS:match(":$") then
		XDG_DATA_DIRS = XDG_DATA_DIRS .. ":"
	end
	for path in XDG_DATA_DIRS:gmatch("(.-):") do
		-- build path and make sure it is absolute
		path = utils.join_path(path, "applications/mpv.desktop")
		if not path:match("^/") then
			goto continue
		end

		-- find the first mpv.desktop in XDG_DATA_DIRS
		local f = io.open(path)
		if not f then
			goto continue
		end

		-- parse the first MimeType= line
		for line in f:lines() do
			local mime_types = line:match("^MimeType=(.*)$")
			if mime_types then
				f:close()
				if not mime_types:match(";$") then
					mime_types = mime_types .. ";"
				end
				for mime_type in mime_types:gmatch("(.-);") do
					MPV_MIME_TYPES[mime_type] = true
				end
				return
			end
		end

		f:close()

		::continue::
	end
end)()

-- list files from the mountpoint that should added to the playlist
-- TODO: implement natural order sorting
local list_files = function(mountpoint)
	local files = {}
	local dirs = { mountpoint }

	while #dirs > 0 do
		-- pop first directory
		local current = dirs[1]
		table.remove(dirs, 1)

		-- append media files
		local subfiles = utils.readdir(current, "files")
		table.sort(subfiles)
		for _, filename in ipairs(subfiles) do
			local file = utils.join_path(current, filename)

			msg.verbose("checking " .. file)

			local mime_type = mp.command_native({
						name = "subprocess",
						args = { "file", "--brief", "--mime-type", file },
						capture_stdout = true,
					}).stdout
					:match("[%S]*") -- %S: not whitespace

			if MPV_MIME_TYPES[mime_type] then
				msg.verbose("using " .. file)
				table.insert(files, file)
			end
		end

		-- append subdirectories to queue
		local subdirs = utils.readdir(current, "dirs")
		table.sort(subdirs)
		for _, dirname in ipairs(subdirs) do
			table.insert(dirs, utils.join_path(current, dirname))
		end
	end

	return files
end

--------------------------------------------------------------------------------

-- mountpoints mounted by us (will be unmounted on shutdown)
local mounted_points = {}

local do_unmount = function(mountpoint)
	os.execute([[
	mountpoint=]] .. shellquote(mountpoint) .. "\n" .. [[
	fusermount -u "$mountpoint"
	rmdir "$mountpoint"
	]])
	mounted_points[mountpoint] = nil
end

local do_mount = function(url, mountpoint)
	if type(btfs_args) == "table" then
		for i = 1, #btfs_args do
			btfs_args[i] = shellquote(btfs_args[i])
		end
		btfs_args = table.concat(btfs_args, " ")
	end
	local title = ("btfs - " .. mountpoint:match("[^/]+$"))
	if
			not exec_ok([[
	mountpoint=]] .. shellquote(mountpoint) .. "\n" .. [[
	url=]] .. shellquote(url) .. "\n" .. [[
	mkdir -p "$mountpoint" || exit 1
	{
	# if command -v xterm >/dev/null; then
	# 	exec xterm -title ]] .. shellquote(title) .. [[ -e btfs -f ]] .. btfs_args .. [[ "$url" "$mountpoint"
	# else
		exec btfs -f ]] .. btfs_args .. [[ "$url" "$mountpoint" >/dev/null 2>&1
	#fi
	} &
	pid=$!
	while true; do
		if [ ! -e /proc/$pid ]; then
			exit 1
		fi
		if mountpoint -q "$mountpoint"; then
			set -- "$mountpoint"/*
			if [ $# -gt 1 ] || [ -e "$1" ]; then
				exit 0
			fi
		fi
		command sleep 0.25 || exit 1
	done
	]])
	then
		return false
	end
	mounted_points[mountpoint] = true
	return true
end

local is_mounted = function(mountpoint)
	return exec_ok("mountpoint -q " .. shellquote(mountpoint))
end

--------------------------------------------------------------------------------

-- gets the info hash or torrent filename for use as the mount directory name
local parse_url = function(url)
	return url:match("^magnet:.*[?&]xt=urn:bt[im]h:([a-zA-Z0-9]*)&?")
			or url:gsub("[?#].*", "", 1):match("/([^/]+%.torrent)$")
end

mp.add_hook("on_load", 11, function()
	local url = mp.get_property("stream-open-filename")
	if not url then
		return
	end

	local dirname = parse_url(url)
	if not dirname then
		return
	end

	local mountpoint = (mountdir .. "/" .. dirname)
	if not is_mounted(mountpoint) then
		if not do_mount(url, mountpoint) then
			print("mount failed!")
			return
		end
	end

	local files = list_files(mountpoint)
	if #files == 0 then
		print("nothing to play!")
	elseif #files == 1 then
		mp.set_property("file-local-options/force-media-title", files[1]:match("[^/]+$"))
		mp.set_property("stream-open-filename", "file://" .. files[1])
	else
		local playlist = { "#EXTM3U" }
		for _, line in ipairs(files) do
			table.insert(playlist, "#EXTINF:0," .. line:match("[^/]+$"))
			table.insert(playlist, "file://" .. line)
		end
		mp.set_property("stream-open-filename", "memory://" .. table.concat(playlist, "\n"))
	end
end)

mp.register_event("shutdown", function()
	for mountpoint in pairs(mounted_points) do
		do_unmount(mountpoint)
	end
end)
