#!/bin/sh
# Only the host's POSIX shell is used here; all launcher utilities are bundled.
case $0 in
  */*) directory=${0%/*} ;;
  *) directory=. ;;
esac
directory=$(CDPATH='' cd -- "$directory" && pwd)
exec "$directory/busybox" sh "$directory/launch" "$@"
