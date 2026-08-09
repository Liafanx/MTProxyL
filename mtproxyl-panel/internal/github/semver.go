package github

import (
	"fmt"
	"regexp"
	"strconv"
)

// versionSuffixPattern matches a semver "X.Y.Z" (optionally "-pre") at the end
// of a string: release tags carry a prefix like "mtproxyl-panel-v1.0.1", which
// TrimPrefix(s, "v") would fail to parse and sort as older than anything.
var versionSuffixPattern = regexp.MustCompile(`(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.]+))?$`)

// ParseVersion parses a version string like "v1.2.3", "1.2.3", "v1.2.3-rc1",
// or a prefixed tag like "mtproxyl-panel-v1.2.3".
// Returns major, minor, patch, pre-release suffix, and error.
func ParseVersion(s string) (major, minor, patch int, pre string, err error) {
	if s == "" {
		return 0, 0, 0, "", fmt.Errorf("empty version string")
	}

	m := versionSuffixPattern.FindStringSubmatch(s)
	if m == nil {
		return 0, 0, 0, "", fmt.Errorf("invalid version format: %q", s)
	}

	major, err = strconv.Atoi(m[1])
	if err != nil {
		return 0, 0, 0, "", fmt.Errorf("invalid major version: %w", err)
	}
	minor, err = strconv.Atoi(m[2])
	if err != nil {
		return 0, 0, 0, "", fmt.Errorf("invalid minor version: %w", err)
	}
	patch, err = strconv.Atoi(m[3])
	if err != nil {
		return 0, 0, 0, "", fmt.Errorf("invalid patch version: %w", err)
	}

	return major, minor, patch, m[4], nil
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
