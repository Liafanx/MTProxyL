//go:build !linux

package telemt_config

import "os"

func preserveFileOwnership(path string, origStat os.FileInfo) error {
	return os.Chmod(path, origStat.Mode().Perm())
}
