package history

import (
	"math"
	"testing"
)

func TestRingRetentionAndCap(t *testing.T) {
	for _, step := range []int64{5, 10, 15} {
		r := NewRing()
		for ts := int64(0); ts <= 10800; ts += step {
			r.Append("m", Point{TS: ts, V: float64(ts)})
		}
		got := r.Range("m", 0)
		want := int(7200/step) + 1
		if len(got) != want {
			t.Fatalf("step %d: len = %d, want %d", step, len(got), want)
		}
		if got[0].TS != 3600 || got[len(got)-1].TS != 10800 {
			t.Fatalf("step %d: span = [%d, %d]", step, got[0].TS, got[len(got)-1].TS)
		}
	}
	r := NewRing()
	for ts := int64(0); ts < int64(Cap)+40; ts++ {
		r.Append("m", Point{TS: ts, V: 1})
	}
	if n := len(r.Range("m", 0)); n != Cap {
		t.Fatalf("cap: len = %d, want %d", n, Cap)
	}
}

func TestRingOrderReplaceAndCopy(t *testing.T) {
	r := NewRing()
	r.Append("m", Point{TS: 30, V: 3})
	r.Append("m", Point{TS: 10, V: 1})
	r.Append("m", Point{TS: 20, V: 2})
	r.Append("m", Point{TS: 20, V: 22})
	r.Append("m", Point{TS: 10 - 7200, V: 9})
	r.Append("m", Point{TS: 5, V: math.NaN()})
	r.Append("m", Point{TS: 6, V: math.Inf(1)})
	got := r.Range("m", 0)
	if len(got) != 3 || got[0].TS != 10 || got[1].V != 22 || got[2].TS != 30 {
		t.Fatalf("points = %+v", got)
	}
	got[0].V = 100
	if again := r.Range("m", 0); again[0].V != 1 {
		t.Fatalf("Range returned a shared slice")
	}
	if from := r.Range("m", 20); len(from) != 2 || from[0].TS != 20 {
		t.Fatalf("Range(20) = %+v", from)
	}
	if p, ok := r.Newest("m"); !ok || p.TS != 30 {
		t.Fatalf("Newest = %+v %v", p, ok)
	}
	if _, ok := r.Newest("none"); ok {
		t.Fatalf("Newest on empty series")
	}
}
