package panel_updater

import (
	"runtime"
	"strings"

	"github.com/Liafanx/mtproxyl-panel/internal/github"
	"github.com/Liafanx/mtproxyl-panel/internal/sysutil"
)

func archString() string {
	if runtime.GOARCH == "arm64" {
		return "aarch64"
	}
	return "x86_64"
}

var detectedVariant string

// SetBinaryPathForDetection sets the binary path used for libc variant detection.
func SetBinaryPathForDetection(path string) {
	detectedVariant = sysutil.DetectVariant(path)
}

// Variant returns the detected libc variant ("musl" or "gnu").
func Variant() string {
	if detectedVariant != "" {
		return detectedVariant
	}
	return "musl"
}

// archAssetPrefix is the libc-agnostic asset prefix for this arch, e.g.
// "mtproxyl-panel-x86_64-linux-". Any "<prefix><variant>.tar.gz" asset works
// because the panel binary is static (CGO_ENABLED=0) — the libc token is cosmetic.
func archAssetPrefix() string {
	return "mtproxyl-panel-" + archString() + "-linux-"
}

// AssetName returns the preferred asset name for the detected variant. Used for
// logging and as the preference when multiple variants are published.
func AssetName() string {
	return archAssetPrefix() + Variant() + ".tar.gz"
}

// NewAssetMatcher selects the release asset by architecture, not libc variant.
// The variant is only a preference — releases ship one static "gnu" binary,
// so updates keep working when detection falls back to "musl".
func NewAssetMatcher() github.AssetMatcher {
	preferred := AssetName()
	archPrefix := archAssetPrefix()
	return func(assets []github.GitHubAsset) (*github.GitHubAsset, *github.GitHubAsset) {
		var bin *github.GitHubAsset
		for i := range assets {
			name := assets[i].Name
			if !strings.HasPrefix(name, archPrefix) || !strings.HasSuffix(name, ".tar.gz") {
				continue
			}
			if name == preferred {
				bin = &assets[i]
				break // exact variant match wins
			}
			if bin == nil {
				bin = &assets[i] // fall back to first published variant for this arch
			}
		}
		if bin == nil {
			return nil, nil
		}

		// Match the checksum to the chosen binary (handles both "<bin>.sha256"
		// and "<bin>.tar.gz.sha256" naming).
		sumPrefix := strings.TrimSuffix(bin.Name, ".tar.gz")
		var sum *github.GitHubAsset
		for i := range assets {
			name := assets[i].Name
			if strings.HasPrefix(name, sumPrefix) && strings.HasSuffix(name, ".sha256") {
				sum = &assets[i]
				break
			}
		}
		return bin, sum
	}
}

func splitOwnerRepo(repo string) (string, string) {
	parts := strings.SplitN(repo, "/", 2)
	if len(parts) != 2 {
		return "", repo
	}
	return parts[0], parts[1]
}
