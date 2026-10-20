package mtproxylctl

import (
	"encoding/json"
	"testing"
)

func TestNftStatusServerIPs(t *testing.T) {
	var st NftStatus
	raw := `{"nft":{"enabled":true,"mode":"smart","service_active":true},"meko_opt":{"applied":false},` +
		`"server_ips":{"server_ips":"all","selected":["203.0.113.10","203.0.113.11"],"detected":["203.0.113.10"],` +
		`"listen_port":443,"nft":"SERVER_IPS: { 203.0.113.10, 203.0.113.11 }","zapret2":"не установлен","links_host":""},"params":[]}`
	if err := json.Unmarshal([]byte(raw), &st); err != nil {
		t.Fatal(err)
	}
	if st.ServerIPs == nil || st.ServerIPs.ServerIPs != "all" || len(st.ServerIPs.Selected) != 2 || st.ServerIPs.ListenPort != 443 {
		t.Fatalf("server_ips = %+v", st.ServerIPs)
	}
	// MTProxyL до 1.7.8 блока не отдаёт — поле пустое, а не ошибка.
	var old NftStatus
	if err := json.Unmarshal([]byte(`{"nft":{"enabled":false},"params":[]}`), &old); err != nil || old.ServerIPs != nil {
		t.Fatalf("old status: %v %+v", err, old.ServerIPs)
	}
}
