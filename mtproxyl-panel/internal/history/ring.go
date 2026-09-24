// Package history копит короткую историю метрик telemt в памяти панели.
package history

import (
	"math"
	"sort"
	"sync"
	"time"
)

// Retention — глубина живой истории; Cap — предел точек на серию при шаге 5 с.
const (
	Retention = 2 * time.Hour
	Cap       = int(Retention/(5*time.Second)) + 1
)

type Point struct {
	TS int64   `json:"ts"`
	V  float64 `json:"v"`
}

type Ring struct {
	mu     sync.RWMutex
	series map[string][]Point
}

func NewRing() *Ring {
	return &Ring{series: make(map[string][]Point)}
}

func (r *Ring) Retention() time.Duration { return Retention }

// Append вставляет точку по времени; дубликат TS заменяется, старые
// и лишние точки отбрасываются.
func (r *Ring) Append(name string, p Point) {
	if name == "" || math.IsNaN(p.V) || math.IsInf(p.V, 0) {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	points := r.series[name]
	newest := p.TS
	if n := len(points); n > 0 && points[n-1].TS > newest {
		newest = points[n-1].TS
	}
	cutoff := newest - int64(Retention/time.Second)
	if p.TS < cutoff {
		return
	}
	i := sort.Search(len(points), func(i int) bool { return points[i].TS >= p.TS })
	if i < len(points) && points[i].TS == p.TS {
		points[i] = p
	} else {
		points = append(points, Point{})
		copy(points[i+1:], points[i:])
		points[i] = p
	}
	start := sort.Search(len(points), func(i int) bool { return points[i].TS >= cutoff })
	if over := len(points) - Cap; over > start {
		start = over
	}
	if start > 0 {
		points = append([]Point(nil), points[start:]...)
	}
	r.series[name] = points
}

// Range возвращает копию точек серии с TS >= fromTS, от старых к новым.
func (r *Ring) Range(name string, fromTS int64) []Point {
	r.mu.RLock()
	defer r.mu.RUnlock()
	points := r.series[name]
	i := sort.Search(len(points), func(i int) bool { return points[i].TS >= fromTS })
	out := make([]Point, len(points)-i)
	copy(out, points[i:])
	return out
}

func (r *Ring) Newest(name string) (Point, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	points := r.series[name]
	if len(points) == 0 {
		return Point{}, false
	}
	return points[len(points)-1], true
}
