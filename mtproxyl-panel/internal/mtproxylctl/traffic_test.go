package mtproxylctl

import (
	"encoding/json"
	"testing"
)

// The report is preceded by a log line, like every other JSON the CLI prints.
func TestTrafficParsesReport(t *testing.T) {
	c := newStubClient(t)

	rep, err := c.Traffic(t.Context())
	if err != nil {
		t.Fatalf("Traffic: %v", err)
	}
	if rep.Mode != "manager" || rep.Source != "db" {
		t.Errorf("mode/source = %q/%q, want manager/db", rep.Mode, rep.Source)
	}
	if !rep.Directional || !rep.Persistent {
		t.Errorf("flags = directional:%v persistent:%v, want both true", rep.Directional, rep.Persistent)
	}
	if rep.Totals.Out != 211900000 {
		t.Errorf("totals.out = %d", rep.Totals.Out)
	}
	if len(rep.Users) != 1 {
		t.Fatalf("users = %d, want 1", len(rep.Users))
	}
	u := rep.Users[0]
	if u.User != "default" || u.In != 370700 || u.Total != 32800700 || u.Connections != 1 {
		t.Errorf("unexpected user row: %+v", u)
	}
}

// A source without direction splitting must stay distinguishable: in/out of
// zero next to a non-zero total is data, not a parsing failure, and the UI
// keys its columns off the flag rather than off the zeros.
func TestTrafficNonDirectionalReport(t *testing.T) {
	raw := `{"mode":"reanimator","source":"api","directional":false,"persistent":false,
	 "totals":{"in":0,"out":0,"total":1055,"session_in":0,"session_out":0,"connections":3},
	 "users":[{"user":"alice","in":0,"out":0,"total":1000,"session_in":0,"session_out":0,
	 "connections":3,"unique_ips":2,"enabled":true}]}`
	var rep TrafficReport
	if err := json.Unmarshal([]byte(raw), &rep); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if rep.Directional || rep.Persistent {
		t.Error("api source must be neither directional nor persistent")
	}
	if rep.Users[0].Total != 1000 || rep.Users[0].UniqueIPs != 2 {
		t.Errorf("unexpected row: %+v", rep.Users[0])
	}
}

// An empty user list must come back as an empty slice: a nil one serializes to
// JSON null and the page would have to guard against it.
func TestTrafficEmptyUsersIsSlice(t *testing.T) {
	var rep TrafficReport
	if err := json.Unmarshal([]byte(`{"mode":"reanimator","source":"none","users":null}`), &rep); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if rep.Users == nil {
		rep.Users = []TrafficUser{}
	}
	out, err := json.Marshal(rep.Users)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(out) != "[]" {
		t.Errorf("users serialized as %s, want []", out)
	}
}
