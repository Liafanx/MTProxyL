package tgbot

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestNormalizeCommand(t *testing.T) {
	cases := map[string]string{
		"/status":          cmdStatus,
		"/status@some_bot": cmdStatus,
		"  /check  ":       cmdCheck,
		"/MUTE":            cmdMute,
		btnStatus:          cmdStatus,
		btnCheck:           cmdCheck,
		btnMute:            cmdMute,
		"просто текст":     "просто текст",
	}
	for in, want := range cases {
		if got := normalizeCommand(in); got != want {
			t.Errorf("normalizeCommand(%q) = %q, want %q", in, got, want)
		}
	}
}

// Кнопки клавиатуры шлют обычный текст — он обязан приводиться к той же
// команде, иначе клавиатура окажется бесполезной.
func TestKeyboardButtonsMapToCommands(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{MessageID: 77})

	b.handleMessage(context.Background(), b.client, 555, &Message{Text: btnStatus, Chat: Chat{ID: 555}})

	select {
	case <-b.redraw:
	default:
		t.Errorf("кнопка «Статус» не попросила перерисовать сообщение: %v", rec.methods())
	}
}

func TestStartInstallsKeyboardForAdmin(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})

	b.handleMessage(context.Background(), b.client, 555, &Message{Text: cmdStart, Chat: Chat{ID: 555}})

	send := rec.find("sendMessage")
	if send == nil {
		t.Fatalf("вызовы %v", rec.methods())
	}
	if send.Body["reply_markup"] == nil {
		t.Error("админу не выдана постоянная клавиатура")
	}
	if rec.count("setMyCommands") == 0 {
		t.Errorf("после /start команды не зарегистрированы в области чата: %v", rec.methods())
	}
}

// Постороннему ни клавиатуры, ни своего chat_id.
func TestStrangerGetsNoKeyboard(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})

	b.handleMessage(context.Background(), b.client, 555, &Message{Text: cmdStart, Chat: Chat{ID: 999}})

	send := rec.find("sendMessage")
	if send == nil {
		t.Fatalf("вызовы %v", rec.methods())
	}
	if send.Body["reply_markup"] != nil {
		t.Error("постороннему выдана клавиатура")
	}
	if text, _ := send.Body["text"].(string); !strings.Contains(text, "чужую панель") {
		t.Errorf("посторонний не получил отказ: %q", text)
	}
}

func TestStrangerCommandsAreRefused(t *testing.T) {
	for _, cmd := range []string{cmdStatus, cmdCheck, cmdMute, cmdUnmute, cmdHelp} {
		t.Run(cmd, func(t *testing.T) {
			b, rec := newTestBot(t, Deps{}, PersistedState{})

			b.handleMessage(context.Background(), b.client, 555, &Message{Text: cmd, Chat: Chat{ID: 999}})

			send := rec.find("sendMessage")
			if send == nil {
				t.Fatalf("вызовы %v", rec.methods())
			}
			if text, _ := send.Body["text"].(string); !strings.Contains(text, "чужую панель") {
				t.Errorf("посторонний выполнил %s: %q", cmd, text)
			}
		})
	}
}

func TestHelpExplainsBothDirections(t *testing.T) {
	out := RenderHelp()
	for _, want := range []string{"вход:", "выход:", "Писатели", "/mute"} {
		if !strings.Contains(out, want) {
			t.Errorf("в справке нет %q", want)
		}
	}
}

// ── Пауза ───────────────────────────────────────────────────────────────────

func TestMuteSetsWindowAndPersists(t *testing.T) {
	var saved []PersistedState
	b, rec := newTestBot(t, Deps{Persist: func(s PersistedState) error {
		saved = append(saved, s)
		return nil
	}}, PersistedState{MessageID: 77})

	b.setMute(context.Background(), b.client, 555, 30*time.Minute, false)

	if !b.state.Incidents.Muted(b.now()) {
		t.Error("пауза не включилась")
	}
	if len(saved) == 0 || !saved[0].Incidents.Muted(b.now()) {
		t.Error("пауза не сохранена — перезапуск панели снова включил бы сирену")
	}
	if send := rec.find("sendMessage"); send == nil {
		t.Errorf("о паузе не сообщили: %v", rec.methods())
	}
}

// Снятие паузы при живой аварии обязано об этом сказать: иначе человек снимает
// паузу и остаётся в уверенности, что всё хорошо.
func TestUnmuteWarnsAboutOngoingIncident(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{
		MessageID: 77,
		Incidents: Incidents{
			MuteForever: true,
			Uplink:      IncidentState{Active: true},
		},
	})

	b.setMute(context.Background(), b.client, 555, 0, false)

	send := rec.find("sendMessage")
	if send == nil {
		t.Fatalf("вызовы %v", rec.methods())
	}
	text, _ := send.Body["text"].(string)
	if !strings.Contains(text, "всё ещё продолжается") {
		t.Errorf("не предупредили о продолжающейся аварии: %q", text)
	}
}

func TestUnmuteWithoutIncidentIsCalm(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{MessageID: 77, Incidents: Incidents{MuteForever: true}})

	b.setMute(context.Background(), b.client, 555, 0, false)

	text, _ := rec.find("sendMessage").Body["text"].(string)
	if strings.Contains(text, "всё ещё продолжается") {
		t.Errorf("предупреждение об аварии без аварии: %q", text)
	}
	if b.state.Incidents.Muted(b.now()) {
		t.Error("пауза не снялась")
	}
}

// Истёкшая пауза при живой аварии будит: пауза кончилась, а проблема нет.
func TestExpiredMuteWithLiveIncidentBecomesLoud(t *testing.T) {
	fixed := time.Date(2026, 8, 11, 17, 30, 0, 0, time.UTC)
	b, rec := newTestBot(t, Deps{}, PersistedState{
		MessageID: 77,
		Incidents: Incidents{
			MutedUntil: fixed.Add(-time.Minute),
			Uplink:     IncidentState{Active: true, Since: fixed.Add(-time.Hour), LastNotify: fixed.Add(-time.Hour)},
		},
	})

	b.absorbUplink(uplinkDown())
	b.evaluateAndDeliver(context.Background())

	if rec.count("sendMessage") == 0 {
		t.Errorf("после истечения паузы авария осталась беззвучной: %v", rec.methods())
	}
	if b.state.Incidents.Muted(b.now()) {
		t.Error("истёкшая пауза не снялась")
	}
}

func TestMuteCallbacksSetExpectedWindows(t *testing.T) {
	cases := []struct {
		data    string
		forever bool
	}{
		{callbackMute30, false},
		{callbackMute2h, false},
		{callbackMuteOn, true},
	}
	for _, tc := range cases {
		t.Run(tc.data, func(t *testing.T) {
			b, _ := newTestBot(t, Deps{}, PersistedState{MessageID: 77})

			b.handleCallback(context.Background(), b.client, 555, &CallbackQuery{
				ID: "q", From: User{ID: 555}, Data: tc.data,
			})

			inc := b.state.Incidents
			if !inc.Muted(b.now()) {
				t.Fatal("пауза не включилась")
			}
			if inc.MuteForever != tc.forever {
				t.Errorf("MuteForever = %v, want %v", inc.MuteForever, tc.forever)
			}
		})
	}
}
