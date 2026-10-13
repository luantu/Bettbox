//go:build !windows

package sing_tun

import (
	"errors"
	"os"
	"testing"

	"golang.org/x/sys/unix"
)

func TestCloseUnadoptedFileDescriptorOnStartupError(t *testing.T) {
	file, err := os.Open("/dev/null")
	if err != nil {
		t.Fatal(err)
	}
	fd, err := unix.Dup(int(file.Fd()))
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}

	closeUnadoptedFileDescriptor(fd, false, errors.New("startup failed"))
	if _, err = unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); !errors.Is(err, unix.EBADF) {
		_ = unix.Close(fd)
		t.Fatalf("unadopted descriptor remains open: %v", err)
	}
}

func TestKeepAdoptedFileDescriptorForListener(t *testing.T) {
	file, err := os.Open("/dev/null")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	fd := int(file.Fd())

	closeUnadoptedFileDescriptor(fd, true, errors.New("later startup failed"))
	if _, err = unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
		t.Fatalf("adopted descriptor was closed outside its listener: %v", err)
	}
}
