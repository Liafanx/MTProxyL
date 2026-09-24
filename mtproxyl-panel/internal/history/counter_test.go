package history

import "testing"

func TestCounter(t *testing.T) {
	var c counter
	if got := c.observe(100, 10); got != 0 {
		t.Fatalf("baseline = %v, want 0", got)
	}
	if got := c.observe(130, 20); got != 30 {
		t.Fatalf("delta = %v, want 30", got)
	}
	if got := c.observe(5, 1); got != 35 {
		t.Fatalf("restart = %v, want 35", got)
	}
	if got := c.observe(2, 2); got != 37 {
		t.Fatalf("regression = %v, want 37", got)
	}
}
