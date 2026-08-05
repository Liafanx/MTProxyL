package github

import (
	"fmt"
	"strconv"
	"strings"
)

// ParseVersion parses a version string like "v1.2.3", "1.2.3", or "v1.2.3-rc1".
// Returns major, minor, patch, pre-release suffix, and error.
func ParseVersion(s string) (major, minor, patch int, pre string, err error) {
	if s == "" {
		return 0, 0, 0, "", fmt.Errorf("empty version string")
	}
	s = strings.TrimPrefix(s, "v")

	// Split off pre-release suffix
	if idx := strings.IndexByte(s, '-'); idx >= 0 {
		pre = s[idx+1:]
		s = s[:idx]
	}

	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return 0, 0, 0, "", fmt.Errorf("invalid version format: %q", s)
	}

	major, err = strconv.Atoi(parts[0])
	if err != nil {
		return 0, 0, 0, "", fmt.Errorf("invalid major version: %w", err)
	}
	minor, err = strconv.Atoi(parts[1])
	if err != nil {
		return 0, 0, 0, "", fmt.Errorf("invalid minor version: %w", err)
	}
	patch, err = strconv.Atoi(parts[2])
	if err != nil {
		return 0, 0, 0, "", fmt.Errorf("invalid patch version: %w", err)
	}

	return major, minor, patch, pre, nil
}

// CompareVersions compares two version strings.
// Returns -1 if a < b, 0 if a == b, 1 if a > b.
func CompareVersions(a, b string) int {
	aMaj, aMin, aPat, aPre, aErr := ParseVersion(a)
	bMaj, bMin, bPat, bPre, bErr := ParseVersion(b)

	// Unparseable versions sort last
	if aErr != nil && bErr != nil {
		return 0
	}
	if aErr != nil {
		return -1
	}
	if bErr != nil {
		return 1
	}

	if aMaj != bMaj {
		return cmpInt(aMaj, bMaj)
	}
	if aMin != bMin {
		return cmpInt(aMin, bMin)
	}
	if aPat != bPat {
		return cmpInt(aPat, bPat)
	}

	// Both have no pre-release: equal
	if aPre == "" && bPre == "" {
		return 0
	}
	// Release > pre-release
	if aPre == "" {
		return 1
	}
	if bPre == "" {
		return -1
	}
	// Both pre-release: lexicographic
	if aPre < bPre {
		return -1
	}
	if aPre > bPre {
		return 1
	}
	return 0
}

func cmpInt(a, b int) int {
	if a < b {
		return -1
	}
	return 1
}
