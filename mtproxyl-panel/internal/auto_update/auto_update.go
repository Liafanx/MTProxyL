package auto_update

import (
	"log"
	"sync"
	"time"
)

// CheckResult is the common result from checking for updates.
type CheckResult struct {
	CurrentVersion  string `json:"current_version"`
	LatestVersion   string `json:"latest_version"`
	UpdateAvailable bool   `json:"update_available"`
	ReleaseName     string `json:"release_name"`
	ReleaseURL      string `json:"release_url"`
	PublishedAt     string `json:"published_at,omitempty"`
	Changelog       string `json:"changelog,omitempty"`
}

// ComponentConfig holds auto-update settings for one component.
type ComponentConfig struct {
	Enabled       bool   `json:"enabled"`
	CheckInterval string `json:"check_interval"` // Go duration string, e.g. "1h", "30m"
	AutoApply     bool   `json:"auto_apply"`
}

// ParsedInterval returns the parsed duration, clamped to 5m minimum.
func (c ComponentConfig) ParsedInterval() time.Duration {
	if c.CheckInterval == "" {
		return 1 * time.Hour
	}
	d, err := time.ParseDuration(c.CheckInterval)
	if err != nil || d < 5*time.Minute {
		return 1 * time.Hour
	}
	return d
}

// ComponentState tracks the runtime state for one component.
type ComponentState struct {
	Config      ComponentConfig `json:"config"`
	LastCheck   *CheckResult    `json:"last_check,omitempty"`
	LastCheckAt string          `json:"last_check_at,omitempty"` // RFC3339
}

// Component defines a updatable component via functions.
type Component struct {
	CheckFn func() (*CheckResult, error)
	ApplyFn func(version string) error
}

// Status is the API response for GET /api/auto-update/status.
type Status struct {
	Panel  ComponentState `json:"panel"`
	Telemt ComponentState `json:"telemt"`
}

// UpdateConfigRequest is the API request for PUT /api/auto-update/config.
type UpdateConfigRequest struct {
	Panel  ComponentConfig `json:"panel"`
	Telemt ComponentConfig `json:"telemt"`
}

// componentRunner manages one component's auto-update ticker.
type componentRunner struct {
	name   string
	cfg    ComponentConfig
	state  ComponentState
	check  func() (*CheckResult, error)
	apply  func(version string) error
	mu     sync.Mutex
	stopCh chan struct{}
}

// Manager manages auto-update tickers for panel and telemt.
type Manager struct {
	mu         sync.Mutex
	components map[string]*componentRunner
}

// New creates a new auto-update manager.
func New() *Manager {
	return &Manager{
		components: make(map[string]*componentRunner),
	}
}

// Register adds a component to the manager and starts its ticker if enabled.
func (m *Manager) Register(name string, comp Component, cfg ComponentConfig) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if existing, ok := m.components[name]; ok {
		existing.stop()
		delete(m.components, name)
	}

	cr := &componentRunner{
		name:  name,
		cfg:   cfg,
		check: comp.CheckFn,
		apply: comp.ApplyFn,
		state: ComponentState{Config: cfg},
	}
	m.components[name] = cr

	if cfg.Enabled {
		cr.start()
	}
}

// UpdateConfig updates settings for a component and restarts its ticker.
func (m *Manager) UpdateConfig(name string, cfg ComponentConfig) {
	m.mu.Lock()
	cr, ok := m.components[name]
	m.mu.Unlock()
	if !ok {
		return
	}

	cr.mu.Lock()
	cr.cfg = cfg
	cr.state.Config = cfg
	cr.mu.Unlock()

	cr.stop()
	if cfg.Enabled {
		cr.start()
	}
}

// GetStatus returns the current state of all components.
func (m *Manager) GetStatus() Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := Status{}
	if cr, ok := m.components["panel"]; ok {
		cr.mu.Lock()
		s.Panel = cr.state
		cr.mu.Unlock()
	}
	if cr, ok := m.components["telemt"]; ok {
		cr.mu.Lock()
		s.Telemt = cr.state
		cr.mu.Unlock()
	}
	return s
}

// StopAll stops all component tickers.
func (m *Manager) StopAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for name, cr := range m.components {
		cr.stop()
		delete(m.components, name)
	}
}

func (cr *componentRunner) start() {
	cr.mu.Lock()
	defer cr.mu.Unlock()

	cr.stopCh = make(chan struct{})
	interval := cr.cfg.ParsedInterval()

	log.Printf("[auto_update:%s] started (interval=%v, auto_apply=%v)", cr.name, interval, cr.cfg.AutoApply)

	go func() {
		cr.tick() // first check immediately

		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				cr.tick()
			case <-cr.stopCh:
				return
			}
		}
	}()
}

func (cr *componentRunner) stop() {
	cr.mu.Lock()
	defer cr.mu.Unlock()
	if cr.stopCh != nil {
		close(cr.stopCh)
		cr.stopCh = nil
		log.Printf("[auto_update:%s] stopped", cr.name)
	}
}

func (cr *componentRunner) tick() {
	cr.mu.Lock()
	cfg := cr.cfg
	cr.mu.Unlock()

	result, err := cr.check()
	now := time.Now().Format(time.RFC3339)

	cr.mu.Lock()
	defer cr.mu.Unlock()

	if err != nil {
		log.Printf("[auto_update:%s] check failed: %s", cr.name, err)
		cr.state.LastCheck = nil
		cr.state.LastCheckAt = now
		return
	}

	cr.state.LastCheck = result
	cr.state.LastCheckAt = now
	log.Printf("[auto_update:%s] current=%s latest=%s update=%v",
		cr.name, result.CurrentVersion, result.LatestVersion, result.UpdateAvailable)

	if cfg.AutoApply && result.UpdateAvailable {
		log.Printf("[auto_update:%s] auto-applying %s", cr.name, result.LatestVersion)
		if applyErr := cr.apply(""); applyErr != nil {
			log.Printf("[auto_update:%s] auto-apply failed: %s", cr.name, applyErr)
		}
	}
}
