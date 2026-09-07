//go:build !windows

package main

import "syscall"

// detachedAttr puts the editor in its own session, so it outlives this CLI and
// no signal sent to the launching shell's job reaches it.
func detachedAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setsid: true}
}
