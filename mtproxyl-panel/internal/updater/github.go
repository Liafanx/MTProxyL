package updater

import (
	"net/http"
	"runtime"
	"strings"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/github"
	"github.com/Liafanx/mtproxyl-panel/internal/sysutil"
)

var httpClient = &http.Client{Timeout: 30 * time.Second}
var downloadClient = &http.Client{Timeout: 5 * time.Minute}

func archString() string {
	if runtime.GOARCH == "arm64" {
		return "aarch64"
	}
	return "x86_64"
}

// binaryPath is set externally to allow variant auto-detection against the installed binary.
var detectedVariant string

// SetBinaryPathForDetection sets the binary path used for libc variant detection.
// Must be called before AssetName() is used.
func SetBinaryPathForDetection(path string) {
	detectedVariant = sysutil.DetectVariant(path)
}

// Variant returns the detected libc variant ("musl" or "gnu").
func Variant() string {
	if detectedVariant != "" {
		return detectedVariant
	}
	return "musl" // safe default
}

// AssetName returns the expected binary asset filename for this architecture and libc variant.
func AssetName() string {
	return "telemt-" + archString() + "-linux-" + Variant() + ".tar.gz"
}

// NewAssetMatcher finds Telemt binary and checksum assets. Checksum matching is
// flexible: any .sha256 starting with the binary's name prefix, so both
// "...-gnu.sha256" and "...-gnu.tar.gz.sha256" are covered.
func NewAssetMatcher() github.AssetMatcher {
	binaryName := AssetName()
	prefix := strings.TrimSuffix(binaryName, ".tar.gz")
	return func(assets []github.GitHubAsset) (*github.GitHubAsset, *github.GitHubAsset) {
		var bin, sum *github.GitHubAsset
		for i := range assets {
			if assets[i].Name == binaryName {
				bin = &assets[i]
			}
			if sum == nil && strings.HasPrefix(assets[i].Name, prefix) && strings.HasSuffix(assets[i].Name, ".sha256") {
				sum = &assets[i]
			}
		}
		return bin, sum
	}
}

// splitOwnerRepo splits "owner/repo" into owner and repo parts.
func splitOwnerRepo(repo string) (string, string) {
	parts := strings.SplitN(repo, "/", 2)
	if len(parts) != 2 {
		return "", repo
	}
	return parts[0], parts[1]
}
