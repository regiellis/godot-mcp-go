//go:build windows

package client

import "syscall"

// stillActive is GetExitCodeProcess's sentinel for a running process (STILL_ACTIVE).
const stillActive = 259

// pidAlive reports whether the given process id is a live process. On Windows a
// dead pid's exit code is anything but STILL_ACTIVE; OpenProcess fails outright
// once the pid is fully reaped.
func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	h, err := syscall.OpenProcess(syscall.PROCESS_QUERY_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(h)
	var code uint32
	if err := syscall.GetExitCodeProcess(h, &code); err != nil {
		return false
	}
	return code == stillActive
}
