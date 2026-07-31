package ws

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

func removeProtocol(rawURL string) (string, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return "", err
	}
	return parsed.Host, nil
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true
		}
		host := r.Host
		if fwdHost := r.Header.Get("X-Forwarded-Host"); fwdHost != "" {
			host = fwdHost
		}

		origin, _ = removeProtocol(origin)

		return origin == host
	},
}

// ClientMessage is sent by the browser to subscribe to endpoints.
type ClientMessage struct {
	Type      string   `json:"type"`                // "subscribe"
	Endpoints []string `json:"endpoints,omitempty"` // e.g. ["/v1/health", "/v1/stats/summary"]
	Interval  int      `json:"interval,omitempty"`  // poll interval in seconds (default 5)
}

// ServerMessage is pushed to the browser with fresh data.
type ServerMessage struct {
	Type      string      `json:"type"` // "data" or "error"
	Endpoint  string      `json:"endpoint"`
	Data      interface{} `json:"data,omitempty"`
	Error     string      `json:"error,omitempty"`
	Timestamp int64       `json:"timestamp"`
}

// Handler manages WebSocket connections. It polls Telemt API server-side
// and pushes results to the connected client.
type Handler struct {
	telemtURL  string
	authHeader string
	client     *http.Client
}

func NewHandler(telemtURL, authHeader string) *Handler {
	return &Handler{
		telemtURL:  telemtURL,
		authHeader: authHeader,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws upgrade error: %v", err)
		return
	}
	defer conn.Close()

	var (
		mu        sync.Mutex
		stopCh    = make(chan struct{})
		cancelMap = make(map[string]chan struct{})
	)

	// Writer helper (thread-safe)
	send := func(msg ServerMessage) {
		mu.Lock()
		defer mu.Unlock()
		msg.Timestamp = time.Now().UnixMilli()
		_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if err := conn.WriteJSON(msg); err != nil {
			log.Printf("ws write error: %v", err)
		}
	}

	// Poll a single Telemt endpoint and push results
	pollEndpoint := func(endpoint string, interval time.Duration, stop chan struct{}) {
		// Fetch immediately on subscribe
		h.fetchAndSend(endpoint, send)

		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				h.fetchAndSend(endpoint, send)
			case <-stop:
				return
			case <-stopCh:
				return
			}
		}
	}

	// Stop all pollers
	stopAll := func() {
		for _, ch := range cancelMap {
			close(ch)
		}
		cancelMap = make(map[string]chan struct{})
	}

	// Read messages from client
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			break
		}

		var msg ClientMessage
		if err := json.Unmarshal(raw, &msg); err != nil {
			continue
		}

		if msg.Type == "subscribe" {
			// Stop existing pollers and start new ones
			mu.Lock()
			stopAll()
			mu.Unlock()

			interval := time.Duration(msg.Interval) * time.Second
			if interval < 2*time.Second {
				interval = 5 * time.Second
			}
			if interval > 60*time.Second {
				interval = 60 * time.Second
			}

			for _, ep := range msg.Endpoints {
				stop := make(chan struct{})
				mu.Lock()
				cancelMap[ep] = stop
				mu.Unlock()
				go pollEndpoint(ep, interval, stop)
			}
		}
	}

	close(stopCh)
}

func (h *Handler) fetchAndSend(endpoint string, send func(ServerMessage)) {
	req, err := http.NewRequest("GET", h.telemtURL+endpoint, nil)
	if err != nil {
		send(ServerMessage{Type: "error", Endpoint: endpoint, Error: err.Error()})
		return
	}
	if h.authHeader != "" {
		req.Header.Set("Authorization", h.authHeader)
	}

	resp, err := h.client.Do(req)
	if err != nil {
		send(ServerMessage{Type: "error", Endpoint: endpoint, Error: "telemt unreachable"})
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		send(ServerMessage{Type: "error", Endpoint: endpoint, Error: err.Error()})
		return
	}

	// Parse the Telemt response envelope { ok, data, error: {code, message} }
	var envelope struct {
		OK   bool            `json:"ok"`
		Data json.RawMessage `json:"data"`
		Err  *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		send(ServerMessage{Type: "error", Endpoint: endpoint, Error: "invalid response"})
		return
	}

	if !envelope.OK {
		errMsg := "telemt returned error"
		if envelope.Err != nil {
			switch {
			case envelope.Err.Code != "" && envelope.Err.Message != "":
				errMsg = envelope.Err.Code + ": " + envelope.Err.Message
			case envelope.Err.Message != "":
				errMsg = envelope.Err.Message
			case envelope.Err.Code != "":
				errMsg = envelope.Err.Code
			}
		}
		send(ServerMessage{Type: "error", Endpoint: endpoint, Error: errMsg})
		return
	}

	// Send raw data to avoid double-encoding
	var data interface{}
	_ = json.Unmarshal(envelope.Data, &data)
	send(ServerMessage{Type: "data", Endpoint: endpoint, Data: data})
}
