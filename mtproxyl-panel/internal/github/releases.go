package github

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"time"
)

const (
	DefaultMaxNewerReleases = 10
	DefaultMaxOlderReleases = 10
)

// ReleaseLimits controls how many releases to include in each direction.
type ReleaseLimits struct {
	MaxNewer int
	MaxOlder int
}

// FetchReleases fetches releases from GitHub and returns filtered, sorted results.
// token is optional: when non-empty it is sent as "Bearer <token>" to raise the rate limit.
func FetchReleases(owner, repo, currentVersion string, match AssetMatcher, limits ReleaseLimits, token string) (*ReleasesResult, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases?per_page=30", owner, repo)

	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch releases: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("github API returned %d", resp.StatusCode)
	}

	var releases []GitHubRelease
	if err := json.NewDecoder(resp.Body).Decode(&releases); err != nil {
		return nil, fmt.Errorf("decode releases: %w", err)
	}

	result := buildReleasesResult(releases, currentVersion, match, limits)
	return result, nil
}

// FetchRelease fetches a single release by tag name.
// token is optional: when non-empty it is sent as "Bearer <token>" to raise the rate limit.
func FetchRelease(owner, repo, tag string, match AssetMatcher, token string) (*ReleaseInfo, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases/tags/%s", owner, repo, tag)

	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch release %s: %w", tag, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("github API returned %d for tag %s", resp.StatusCode, tag)
	}

	var release GitHubRelease
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return nil, fmt.Errorf("decode release: %w", err)
	}

	bin, checksum := match(release.Assets)
	if bin == nil {
		return nil, fmt.Errorf("no matching asset found for tag %s", tag)
	}

	info := toReleaseInfo(release, bin, checksum, "", false)
	return &info, nil
}

// buildReleasesResult filters, sorts, and splits releases into newer + older.
func buildReleasesResult(releases []GitHubRelease, currentVersion string, match AssetMatcher, limits ReleaseLimits) *ReleasesResult {
	type scored struct {
		info ReleaseInfo
		cmp  int // comparison to current: 1=newer, -1=older
	}

	var items []scored

	for _, r := range releases {
		if r.Draft {
			continue
		}

		bin, checksum := match(r.Assets)
		if bin == nil {
			continue
		}

		cmp := CompareVersions(r.TagName, currentVersion)
		if cmp == 0 {
			continue // skip current version
		}

		isDowngrade := cmp < 0
		info := toReleaseInfo(r, bin, checksum, currentVersion, isDowngrade)
		items = append(items, scored{info: info, cmp: cmp})
	}

	// Sort by semver descending
	sort.Slice(items, func(i, j int) bool {
		return CompareVersions(items[i].info.Version, items[j].info.Version) > 0
	})

	// Split: up to MaxNewer newer + up to MaxOlder older
	var result []ReleaseInfo
	newerCount, olderCount := 0, 0
	for _, item := range items {
		if item.cmp > 0 {
			if limits.MaxNewer <= 0 || newerCount < limits.MaxNewer {
				result = append(result, item.info)
				newerCount++
			}
		} else {
			if limits.MaxOlder <= 0 || olderCount < limits.MaxOlder {
				result = append(result, item.info)
				olderCount++
			}
		}
	}

	return &ReleasesResult{
		CurrentVersion: currentVersion,
		Releases:       result,
	}
}

func toReleaseInfo(r GitHubRelease, bin, checksum *GitHubAsset, currentVersion string, isDowngrade bool) ReleaseInfo {
	info := ReleaseInfo{
		Version:     r.TagName,
		Name:        r.Name,
		Changelog:   r.Body,
		PublishedAt: r.PublishedAt.Format(time.RFC3339),
		HTMLURL:     r.HTMLURL,
		Prerelease:  r.Prerelease,
		IsDowngrade: isDowngrade,
		AssetURL:    bin.BrowserDownloadURL,
		AssetSize:   bin.Size,
	}
	if checksum != nil {
		info.ChecksumURL = checksum.BrowserDownloadURL
	}
	return info
}
