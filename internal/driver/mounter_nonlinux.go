//go:build !linux

package driver

import "errors"

const mountFlagReadOnly = 0

var errLinuxOnly = errors.New("mount operations are only supported on linux")

func mountVolume(_, _, _ string, _ uintptr, _ string) error {
	return errLinuxOnly
}

func unmountVolume(_ string) error {
	return errLinuxOnly
}
