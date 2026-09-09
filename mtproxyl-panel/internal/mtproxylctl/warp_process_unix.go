//go:build linux || darwin || freebsd

package mtproxylctl

import (
	"os/exec"
	"syscall"
	"time"
)

func configureWarpCancellation(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
	cmd.WaitDelay = 5 * time.Second
}
