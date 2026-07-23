//go:build !windows

package client

import (
	"os"
	"syscall"
)

// pidAlive reports whether the given process id is a live process. Signal 0 is
// the POSIX existence check: it delivers nothing but still errors (ESRCH) when
// no such process exists.
func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}
