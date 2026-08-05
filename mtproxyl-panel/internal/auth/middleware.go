package auth

import (
	"encoding/json"
	"net/http"
)

type errorResponse struct {
	OK    bool        `json:"ok"`
	Error errorDetail `json:"error"`
}

type errorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func RequireAuth(jwtSecret []byte, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("session")
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(errorResponse{
				OK:    false,
				Error: errorDetail{Code: "unauthorized", Message: "missing session cookie"},
			})
			return
		}

		username, err := ValidateToken(cookie.Value, jwtSecret)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(errorResponse{
				OK:    false,
				Error: errorDetail{Code: "unauthorized", Message: "invalid or expired session"},
			})
			return
		}

		r.Header.Set("X-Auth-User", username)
		next.ServeHTTP(w, r)
	})
}
