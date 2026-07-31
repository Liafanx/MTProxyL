package logs

import (
	"reflect"
	"testing"
)

func TestNormalizeSince(t *testing.T) {
	tests := map[string]string{
		"":      "1h",
		"bad":   "1h",
		"1h":    "1h",
		"2h":    "2h",
		"12h":   "12h",
		"24h":   "24h",
		"7d":    "7d",
		"all":   "all",
		"--bad": "1h",
	}

	for input, want := range tests {
		if got := NormalizeSince(input); got != want {
			t.Fatalf("NormalizeSince(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestJournalctlArgsIncludeSince(t *testing.T) {
	got := journalctlArgs("telemt", false, 200, LogOptions{Since: "12h"})
	want := []string{"-u", "telemt", "-n", "200", "--since", "-12 hours", "--no-pager", "-o", "short-iso"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("journalctlArgs() = %#v, want %#v", got, want)
	}
}

func TestJournalctlArgsSkipSinceForAll(t *testing.T) {
	got := journalctlArgs("telemt", true, 0, LogOptions{Since: "all"})
	want := []string{"-u", "telemt", "-f", "--no-pager", "-o", "short-iso"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("journalctlArgs() = %#v, want %#v", got, want)
	}
}

func TestDockerLogArgsIncludeSince(t *testing.T) {
	got := dockerLogArgs("telemt", false, 200, LogOptions{Since: "7d"})
	want := []string{"logs", "--tail", "200", "--since", "168h", "--timestamps", "telemt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("dockerLogArgs() = %#v, want %#v", got, want)
	}
}

func TestDockerLogArgsSkipSinceForAll(t *testing.T) {
	got := dockerLogArgs("telemt", true, 0, LogOptions{Since: "all"})
	want := []string{"logs", "-f", "--timestamps", "telemt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("dockerLogArgs() = %#v, want %#v", got, want)
	}
}
