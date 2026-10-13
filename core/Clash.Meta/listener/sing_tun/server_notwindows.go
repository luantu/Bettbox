//go:build !windows

package sing_tun

import (
	tun "github.com/metacubex/sing-tun"
	"golang.org/x/sys/unix"
)

func tunNew(options tun.Options) (tun.Tun, error) {
	return tun.New(options)
}

func closeUnadoptedFileDescriptor(fd int, adopted bool, startupErr error) {
	if fd > 0 && !adopted && startupErr != nil {
		_ = unix.Close(fd)
	}
}
