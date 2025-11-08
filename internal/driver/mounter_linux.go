//go:build linux

package driver

import "golang.org/x/sys/unix"

const mountFlagReadOnly = unix.MS_RDONLY

func mountVolume(source, target, fstype string, flags uintptr, data string) error {
	return unix.Mount(source, target, fstype, flags, data)
}

func unmountVolume(target string) error {
	return unix.Unmount(target, 0)
}
