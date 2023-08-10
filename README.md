# About

This plugin allows mpv to stream magnet links (and any other torrent
identifier [btfs](https://github.com/johang/btfs) handles) directly. It
will automatically remove videos after they are finished playing.

This script will detect `magnet:` links and torrent
files/urls ending in `torrent` passed to mpv by default.

One reason you might want to use this script over calling the included
`btplay -p mpv` is that you can start mpv with a playlist of multiple
magnet links or add magnet links to the playlist of an already open mpv
window (e.g. using one of the scripts that allow appending a link from
the clipboard to the playlist).

# Requirements

- btfs
- btfsstat
- file --brief --mime-type
- umount
- rmdir
- mkdir -p
- sleep

# Advantages Over Peerflix and Webtorrent

Peerflix and Webtorrent are both written in javascript and have to be
installed using npm or external repos. Btfs on the other hand is in both
the default debian and default arch repos. Makes setup a lot easier and
quicker. Btfs is also a lot simpler and cleaner implementation of a
bittorrent filesystem protocol utilizing the FUSE subsystem.

Btfs makes the lua script a lot simpler in implementation than the
Peerflix and Webtorrent of the past.
