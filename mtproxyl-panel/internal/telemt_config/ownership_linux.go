package telemt_config

import (
	"os"
	"syscall"
)

func preserveFileOwnership(path string, origStat os.FileInfo) error {
	if err := os.Chmod(path, origStat.Mode().Perm()); err != nil {
		return err
	}
	if sys, ok := origStat.Sys().(*syscall.Stat_t); ok {
		if err := os.Chown(path, int(sys.Uid), int(sys.Gid)); err != nil {
			return err
		}
	}
	return nil
}
