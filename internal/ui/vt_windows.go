//go:build windows

package ui

import (
	"os"
	"syscall"
	"unsafe"
)

var (
	kernel32           = syscall.NewLazyDLL("kernel32.dll")
	procGetConsoleMode = kernel32.NewProc("GetConsoleMode")
	procSetConsoleMode = kernel32.NewProc("SetConsoleMode")
)

const enableVirtualTerminalProcessing = 0x0004

// enableVT turns on ANSI escape processing for f's console. Windows Terminal
// ships with it on; legacy conhost needs the mode bit set. Returns whether
// escapes are safe to emit; false means the caller must stay plain.
func enableVT(f *os.File) bool {
	h := f.Fd()
	var mode uint32
	ok, _, _ := procGetConsoleMode.Call(h, uintptr(unsafe.Pointer(&mode)))
	if ok == 0 {
		return false
	}
	if mode&enableVirtualTerminalProcessing != 0 {
		return true
	}
	ok, _, _ = procSetConsoleMode.Call(h, uintptr(mode|enableVirtualTerminalProcessing))
	return ok != 0
}
