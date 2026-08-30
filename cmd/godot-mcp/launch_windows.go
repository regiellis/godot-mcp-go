//go:build windows

package main

import "syscall"

// detachedProcess is CreateProcess's DETACHED_PROCESS flag: the child gets no
// console of its own and does not attach to ours, so nothing the editor prints
// can reach (and corrupt) the caller's terminal. Its output goes to the log file
// the parent hands it.
const detachedProcess = 0x00000008

// detachedAttr severs the child from this process group as well, so a Ctrl+C in
// the launching shell never reaches the editor we just started.
func detachedAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | detachedProcess,
	}
}
