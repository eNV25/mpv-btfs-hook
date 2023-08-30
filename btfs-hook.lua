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
	mp.command_native({
		name = "subprocess",
		detach = true,
		playback_only = false,
		args = { "sh", "-c", [[ sleep 1; umount "$1"; rmdir "$1" ]], "sh", mountpoint },
	})
end

local do_mount = function(url, mountpoint)
	mp.command_native({ name = "subprocess", args = { "mkdir", "-p", mountpoint } })

	if not is_mounted(mountpoint) then
		local args = { "btfs" }
		for _, v in ipairs(BTFS_ARGS) do
			table.insert(args, v)
		end
		table.insert(args, url)
		table.insert(args, mountpoint)
		mp.command_native({ name = "subprocess", args = args })
	end

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

local btfs_hook = function(url, dirname)
	msg.verbose("using url " .. url)
	local mountpoint = MOUNT_DIR .. "/" .. dirname
	msg.verbose("using mountpoint " .. mountpoint)
	if not do_mount(url, mountpoint) then
		msg.error("mount failed!")
		return
	end
	mp.set_property("stream-open-filename", mountpoint)
end

mp.add_hook("on_load", 9, function()
	local url = mp.get_property("stream-open-filename")
	local dirname = url:match("^magnet:.*[?&]xt=urn:bt[im]h:(%w*)&?")
	if not dirname then
		return
	end
	btfs_hook(url, dirname)
end)

mp.add_hook("on_load_fail", 9, function()
	local url = mp.get_property("stream-open-filename")
	local dirname = url:match("^.*%.torrent$") and url:gsub('[<>:"/\\|?*]', "⧸")
	if not dirname then
		return
	end
	btfs_hook(url, dirname)
end)

mp.register_event("shutdown", function()
	for url, mountpoint in pairs(mounted_points) do
		do_unmount(url, mountpoint)
	end
end)
