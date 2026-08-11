//go:build !windows

package ui

import "os"

// enableVT is a no-op off Windows: any Unix terminal that reaches this point
// (a char device, not TERM=dumb) processes ANSI escapes natively.
func enableVT(*os.File) bool { return true }
