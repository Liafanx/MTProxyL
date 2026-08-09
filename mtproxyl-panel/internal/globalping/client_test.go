package globalping

import "testing"

func TestBuildMeasurementRequestTargetsRussianEyeballProbes(t *testing.T) {
	req := BuildMeasurementRequest("1.2.3.4", 8443, "microsoft.com", 20)

	if req.Target != "1.2.3.4" {
		t.Errorf("Target = %q, want 1.2.3.4", req.Target)
	}
	if req.MeasurementOptions.Port != 8443 {
		t.Errorf("Port = %d, want 8443", req.MeasurementOptions.Port)
	}
	if req.MeasurementOptions.Protocol != "HTTPS" {
		t.Errorf("Protocol = %q, want HTTPS", req.MeasurementOptions.Protocol)
	}
	if req.MeasurementOptions.Request.Host != "microsoft.com" {
		t.Errorf("Request.Host (SNI) = %q, want microsoft.com", req.MeasurementOptions.Request.Host)
	}
	if req.Limit != 20 {
		t.Errorf("Limit = %d, want 20", req.Limit)
	}
	if len(req.Locations) != 1 || req.Locations[0].Country != "RU" {
		t.Fatalf("Locations = %+v, want a single RU location", req.Locations)
	}
	if len(req.Locations[0].Tags) != 1 || req.Locations[0].Tags[0] != eyeballTag {
		t.Errorf("Locations[0].Tags = %v, want [%s]", req.Locations[0].Tags, eyeballTag)
	}
}

func TestBuildMeasurementRequestWithoutSNI(t *testing.T) {
	req := BuildMeasurementRequest("example.com", 443, "", 20)
	if req.MeasurementOptions.Request.Host != "" {
		t.Errorf("Request.Host = %q, want empty when no FakeTLS domain is set", req.MeasurementOptions.Request.Host)
	}
}

func TestAnalyzeMeasurementMixedResults(t *testing.T) {
	m := &Measurement{
		ID:     "test-123",
		Status: "finished",
		Target: "example.com",
		Results: []ProbeResult{
			{Probe: Probe{City: "Moscow", Country: "RU"}, Result: Result{Status: "finished", TLS: &TLSInfo{Authorized: true}}},
			{Probe: Probe{City: "SPB", Country: "RU"}, Result: Result{Status: "finished", TLS: &TLSInfo{Authorized: true}}},
			{Probe: Probe{City: "Kazan", Country: "RU"}, Result: Result{Status: "failed", RawOutput: "connection refused"}},
		},
	}

	result := AnalyzeMeasurement(m)

	if result.TotalProbes != 3 {
		t.Errorf("TotalProbes = %d, want 3", result.TotalProbes)
	}
	if result.SuccessProbes != 2 {
		t.Errorf("SuccessProbes = %d, want 2", result.SuccessProbes)
	}
	if result.Percentage < 66 || result.Percentage > 67 {
		t.Errorf("Percentage = %.2f, want ~66.67", result.Percentage)
	}
	if result.Level != LevelYellow {
		t.Errorf("Level = %s, want yellow", result.Level)
	}
	if result.Probes[2].TLSSuccess {
		t.Error("failed probe must not count as TLS success")
	}
	if result.Probes[2].Error == "" {
		t.Error("failed probe should carry an error message")
	}
}

// A probe that finished without a TLS certificate is a failure: the TCP
// connect succeeded but the handshake didn't, which is exactly the "port
// open, filtered mid-handshake" case this check exists to catch.
func TestAnalyzeMeasurementFinishedWithoutTLSCountsAsFailure(t *testing.T) {
	m := &Measurement{
		Results: []ProbeResult{
			{Probe: Probe{City: "Moscow"}, Result: Result{Status: "finished", TLS: nil}},
		},
	}

	result := AnalyzeMeasurement(m)

	if result.SuccessProbes != 0 {
		t.Errorf("SuccessProbes = %d, want 0 (finished without TLS is a failure)", result.SuccessProbes)
	}
	if result.Level != LevelRed {
		t.Errorf("Level = %s, want red", result.Level)
	}
}

func TestAnalyzeMeasurementAllSuccessIsGreen(t *testing.T) {
	m := &Measurement{
		Results: []ProbeResult{
			{Result: Result{Status: "finished", TLS: &TLSInfo{}}},
			{Result: Result{Status: "finished", TLS: &TLSInfo{}}},
		},
	}

	result := AnalyzeMeasurement(m)

	if result.Percentage != 100 {
		t.Errorf("Percentage = %.2f, want 100", result.Percentage)
	}
	if result.Level != LevelGreen {
		t.Errorf("Level = %s, want green", result.Level)
	}
}
