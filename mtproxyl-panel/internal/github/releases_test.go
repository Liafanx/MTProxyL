package github

import (
	"testing"
	"time"
)

func testMatcher(assets []GitHubAsset) (*GitHubAsset, *GitHubAsset) {
	var bin, sum *GitHubAsset
	for i := range assets {
		if assets[i].Name == "app.tar.gz" {
			bin = &assets[i]
		}
		if assets[i].Name == "app.sha256" {
			sum = &assets[i]
		}
	}
	return bin, sum
}

func makeRelease(tag string, prerelease bool, draft bool, hasAsset bool) GitHubRelease {
	var assets []GitHubAsset
	if hasAsset {
		assets = []GitHubAsset{
			{Name: "app.tar.gz", Size: 1000, BrowserDownloadURL: "https://example.com/" + tag + "/app.tar.gz"},
			{Name: "app.sha256", Size: 64, BrowserDownloadURL: "https://example.com/" + tag + "/app.sha256"},
		}
	}
	return GitHubRelease{
		TagName:     tag,
		Name:        "Release " + tag,
		Body:        "Changelog for " + tag,
		HTMLURL:     "https://github.com/test/repo/releases/tag/" + tag,
		PublishedAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		Prerelease:  prerelease,
		Draft:       draft,
		Assets:      assets,
	}
}

func TestBuildReleasesResult(t *testing.T) {
	releases := []GitHubRelease{
		makeRelease("v1.5.0", false, false, true),
		makeRelease("v1.4.0-rc1", true, false, true),
		makeRelease("v1.3.0", false, false, true),
		makeRelease("v1.2.0", false, false, true), // current
		makeRelease("v1.1.0", false, false, true),
		makeRelease("v1.0.0", false, false, true),
		makeRelease("v0.9.0", false, false, true),
		makeRelease("v0.8.0", false, false, true),
		makeRelease("v0.7.0", false, false, true),
		makeRelease("v0.6.0", false, false, true), // 8th older — should be excluded (limit 5)
	}

	result := buildReleasesResult(releases, "v1.2.0", testMatcher, ReleaseLimits{MaxNewer: 10, MaxOlder: 5})

	// Should include: v1.5.0, v1.4.0-rc1, v1.3.0 (newer) + v1.1.0, v1.0.0, v0.9.0, v0.8.0, v0.7.0 (5 older)
	// Excludes: v1.2.0 (current), v0.6.0 (beyond 5 older limit)
	if len(result.Releases) != 8 {
		t.Fatalf("expected 8 releases, got %d", len(result.Releases))
	}

	// Check order: newest first
	if result.Releases[0].Version != "v1.5.0" {
		t.Errorf("first release should be v1.5.0, got %s", result.Releases[0].Version)
	}

	// Check pre-release flag
	if !result.Releases[1].Prerelease {
		t.Error("v1.4.0-rc1 should be marked as prerelease")
	}

	// Check downgrade flags
	for _, r := range result.Releases {
		isOlder := CompareVersions(r.Version, "v1.2.0") < 0
		if r.IsDowngrade != isOlder {
			t.Errorf("release %s: IsDowngrade=%v, expected %v", r.Version, r.IsDowngrade, isOlder)
		}
	}

	if result.CurrentVersion != "v1.2.0" {
		t.Errorf("CurrentVersion = %q, want %q", result.CurrentVersion, "v1.2.0")
	}
}

func TestBuildReleasesResult_FiltersDraftsAndMissingAssets(t *testing.T) {
	releases := []GitHubRelease{
		makeRelease("v2.0.0", false, true, true),   // draft — excluded
		makeRelease("v1.5.0", false, false, false), // no asset — excluded
		makeRelease("v1.4.0", false, false, true),  // valid
	}

	result := buildReleasesResult(releases, "v1.0.0", testMatcher, ReleaseLimits{MaxNewer: 10, MaxOlder: 10})

	if len(result.Releases) != 1 {
		t.Fatalf("expected 1 release, got %d", len(result.Releases))
	}
	if result.Releases[0].Version != "v1.4.0" {
		t.Errorf("expected v1.4.0, got %s", result.Releases[0].Version)
	}
}
