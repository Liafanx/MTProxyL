package history

import (
	"fmt"
	"sort"
	"time"
)

// gapTolerance — допустимый разрыв между точками, иначе серия partial.
const gapTolerance int64 = 120

var ranges = map[string]time.Duration{
	"15m": 15 * time.Minute,
	"30m": 30 * time.Minute,
	"1h":  time.Hour,
	"2h":  2 * time.Hour,
}

func Ranges() []string {
	out := make([]string, 0, len(ranges))
	for k := range ranges {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return ranges[out[i]] < ranges[out[j]] })
	return out
}

type Series struct {
	Metric          string  `json:"metric"`
	Range           string  `json:"range"`
	State           string  `json:"state"`
	RequestedFrom   int64   `json:"requested_from_epoch_secs"`
	RetentionSecs   int64   `json:"retention_secs"`
	AvailableFrom   *int64  `json:"available_from_epoch_secs,omitempty"`
	SourceAvailable *bool   `json:"source_available,omitempty"`
	Points          []Point `json:"points"`
}

// Series отдаёт точки метрики за диапазон и оценку полноты.
func (r *Recorder) Series(metric, rng string, now time.Time) (Series, error) {
	window, ok := ranges[rng]
	if !ok {
		return Series{}, fmt.Errorf("unknown range %q", rng)
	}
	if !IsMetric(metric) {
		return Series{}, fmt.Errorf("unknown metric %q", metric)
	}
	nowTS := now.Unix()
	from := nowTS - int64(window/time.Second)
	retention := int64(r.ring.Retention() / time.Second)
	readFrom := from
	if floor := nowTS - retention; floor > readFrom {
		readFrom = floor
	}
	points := r.ring.Range(metric, readFrom)
	s := Series{
		Metric:        metric,
		Range:         rng,
		State:         seriesState(points, from, nowTS),
		RequestedFrom: from,
		RetentionSecs: retention,
		Points:        points,
	}
	if len(points) > 0 {
		first := points[0].TS
		s.AvailableFrom = &first
	}
	if p, ok := r.ring.Newest(MetricAvailable); ok {
		available := p.V >= 0.5 && nowTS-p.TS <= gapTolerance
		s.SourceAvailable = &available
	}
	return s, nil
}

func seriesState(points []Point, from, now int64) string {
	if len(points) == 0 {
		return "empty"
	}
	if points[0].TS > from+gapTolerance || now-points[len(points)-1].TS > gapTolerance {
		return "partial"
	}
	for i := 1; i < len(points); i++ {
		if points[i].TS-points[i-1].TS > gapTolerance {
			return "partial"
		}
	}
	return "ready"
}
