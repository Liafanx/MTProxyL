package telemt_config

import (
	"encoding/json"
	"testing"
)

// Панель заполняет редактор действующей конфигурацией движка — со всеми
// заводскими значениями. Отправлять их обратно нельзя: они запишутся в файл
// явно и перестанут следовать за обновлениями движка.
func TestChangedSectionsSendsOnlyEdited(t *testing.T) {
	current := map[string]interface{}{
		"server":     map[string]interface{}{"port": 443, "listen_backlog": 1024},
		"censorship": map[string]interface{}{"mask": true, "fake_cert_len": 2048},
		"timeouts":   map[string]interface{}{"client_ack": 90},
	}
	submitted := map[string]interface{}{
		"server":     map[string]interface{}{"port": 443, "listen_backlog": 1024},
		"censorship": map[string]interface{}{"mask": true, "fake_cert_len": 4096}, // правка
		"timeouts":   map[string]interface{}{"client_ack": 90},
	}

	got := ChangedSections(submitted, current)
	if len(got) != 1 {
		t.Fatalf("отправляется секций: %d, ожидалась одна (%v)", len(got), keys(got))
	}
	if _, ok := got["censorship"]; !ok {
		t.Fatalf("изменённая секция не попала в патч: %v", keys(got))
	}
}

// Числа приходят из API как json.Number, а из парсера TOML как int64 —
// нетронутая секция не должна выглядеть изменённой из-за типа.
func TestChangedSectionsIgnoresNumericTypeDifference(t *testing.T) {
	var n json.Number = "443"
	current := map[string]interface{}{"server": map[string]interface{}{"port": n}}
	submitted := map[string]interface{}{"server": map[string]interface{}{"port": int64(443)}}

	if got := ChangedSections(submitted, current); len(got) != 0 {
		t.Fatalf("секция без правок попала в патч: %v", got)
	}
}

func TestChangedSectionsKeepsNewSection(t *testing.T) {
	current := map[string]interface{}{"server": map[string]interface{}{"port": 443}}
	submitted := map[string]interface{}{
		"server":     map[string]interface{}{"port": 443},
		"server.api": map[string]interface{}{"enabled": true},
	}
	got := ChangedSections(submitted, current)
	if len(got) != 1 || got["server.api"] == nil {
		t.Fatalf("новая секция должна отправляться: %v", keys(got))
	}
}

// Ничего не поменяли — патч пустой, и запрос вообще не нужен.
func TestChangedSectionsEmptyWhenNothingEdited(t *testing.T) {
	m := map[string]interface{}{"a": map[string]interface{}{"x": 1}}
	if got := ChangedSections(m, m); len(got) != 0 {
		t.Fatalf("ожидался пустой патч, получено %v", got)
	}
}

// Удаление ключа внутри секции — это правка, секцию надо отправить.
func TestChangedSectionsDetectsRemovedKey(t *testing.T) {
	current := map[string]interface{}{"s": map[string]interface{}{"a": 1, "b": 2}}
	submitted := map[string]interface{}{"s": map[string]interface{}{"a": 1}}
	if got := ChangedSections(submitted, current); len(got) != 1 {
		t.Fatalf("удаление ключа не замечено: %v", got)
	}
}

func keys(m map[string]interface{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
