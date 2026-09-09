//go:build !linux && !darwin && !freebsd

package mtproxylctl

import "os/exec"

func configureWarpCancellation(cmd *exec.Cmd) {}
