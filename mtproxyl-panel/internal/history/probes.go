package history

// probeClasses — отказы движка, за которыми стоит чужой трафик (пробы, сканеры,
// старые клиенты), а не сбой прокси. Список совпадает с фронтом (lib/probes.ts).
var probeClasses = map[string]bool{
	"direct_modes_disabled":             true,
	"tls_clienthello_len_out_of_bounds": true,
	"tls_clienthello_truncated":         true,
	"tls_clienthello_read_error":        true,
	"tls_handshake_bad_client":          true,
	"unknown_tls_sni":                   true,
}

func IsProbeClass(class string) bool { return probeClasses[class] }
