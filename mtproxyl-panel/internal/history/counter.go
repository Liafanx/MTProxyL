package history

// counter превращает монотонный счётчик движка в накопленный итог панели,
// переживающий рестарты движка: падение uptime или счётчика — новая база.
type counter struct {
	seen       bool
	prevRaw    uint64
	prevUptime float64
	total      float64
}

func (c *counter) observe(raw uint64, uptime float64) float64 {
	switch {
	case !c.seen:
		c.seen = true
	case uptime < c.prevUptime || raw < c.prevRaw:
		c.total += float64(raw)
	default:
		c.total += float64(raw - c.prevRaw)
	}
	c.prevRaw = raw
	c.prevUptime = uptime
	return c.total
}
