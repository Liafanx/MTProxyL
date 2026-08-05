package github

import "testing"

func TestParseVersion(t *testing.T) {
	tests := []struct {
		input               string
		major, minor, patch int
		pre                 string
		wantErr             bool
	}{
		{"v1.2.3", 1, 2, 3, "", false},
		{"1.2.3", 1, 2, 3, "", false},
		{"v3.3.10", 3, 3, 10, "", false},
		{"3.3.10", 3, 3, 10, "", false},
		{"v1.0.0-rc1", 1, 0, 0, "rc1", false},
		{"v2.1.0-beta.2", 2, 1, 0, "beta.2", false},
		{"", 0, 0, 0, "", true},
		{"invalid", 0, 0, 0, "", true},
		{"v1.2", 0, 0, 0, "", true},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			maj, min, pat, pre, err := ParseVersion(tt.input)
			if (err != nil) != tt.wantErr {
				t.Fatalf("ParseVersion(%q) error = %v, wantErr %v", tt.input, err, tt.wantErr)
			}
			if err != nil {
				return
			}
			if maj != tt.major || min != tt.minor || pat != tt.patch || pre != tt.pre {
				t.Errorf("ParseVersion(%q) = (%d,%d,%d,%q), want (%d,%d,%d,%q)",
					tt.input, maj, min, pat, pre, tt.major, tt.minor, tt.patch, tt.pre)
			}
		})
	}
}

func TestCompareVersions(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		{"v1.0.0", "v1.0.0", 0},
		{"v1.0.1", "v1.0.0", 1},
		{"v1.0.0", "v1.0.1", -1},
		{"v2.0.0", "v1.9.9", 1},
		{"v1.2.0", "v1.1.9", 1},
		{"3.3.10", "v3.3.9", 1},         // bare vs prefixed
		{"v1.0.0", "v1.0.0-rc1", 1},     // release > pre-release
		{"v1.0.0-rc1", "v1.0.0", -1},    // pre-release < release
		{"v1.0.0-rc2", "v1.0.0-rc1", 1}, // pre-release lexicographic
	}
	for _, tt := range tests {
		t.Run(tt.a+"_vs_"+tt.b, func(t *testing.T) {
			got := CompareVersions(tt.a, tt.b)
			if got != tt.want {
				t.Errorf("CompareVersions(%q, %q) = %d, want %d", tt.a, tt.b, got, tt.want)
			}
		})
	}
}
