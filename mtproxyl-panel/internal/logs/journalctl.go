package logs

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
)

type journalctlSource struct {
	serviceName string
	mu          sync.RWMutex
	useSudo     bool
}

func newJournalctlSource(serviceName string) (*journalctlSource, error) {
	if serviceName == "" {
		return nil, fmt.Errorf("service_name is required for journalctl log source")
	}
	if !HasJournalctl() {
		return nil, fmt.Errorf("journalctl not found")
	}
	return &journalctlSource{serviceName: serviceName}, nil
}

func (s *journalctlSource) Name() string { return "journalctl" }

func (s *journalctlSource) shouldUseSudo() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.useSudo
}

func (s *journalctlSource) markUseSudo() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.useSudo = true
}

func journalctlArgs(serviceName string, follow bool, n int, opts LogOptions) []string {
	args := []string{"-u", serviceName}
	if follow {
		args = append(args, "-f")
	} else {
		args = append(args, "-n", fmt.Sprintf("%d", ClampLines(n)))
	}
	if since := journalctlSinceArg(opts.Since); since != "" {
		args = append(args, "--since", since)
	}
	args = append(args, "--no-pager", "-o", "short-iso")
	return args
}

func journalctlCommand(ctx context.Context, args []string, withSudo bool) *exec.Cmd {
	if withSudo {
		return exec.CommandContext(ctx, "sudo", append([]string{"-n", "journalctl"}, args...)...)
	}
	return exec.CommandContext(ctx, "journalctl", args...)
}

// deniedJournalOutput reports whether journalctl refused to show the unit's
// records for lack of privileges.
//
// It does not fail in that case: an unprivileged caller gets its own records
// (usually none), exit status 0 and a note on stderr. Without this check the
// panel treats that as an empty-but-working journal and never falls back to
// sudo — the engine's log page stays blank with no explanation.
func deniedJournalOutput(out []byte) bool {
	return strings.Contains(string(out), "No journal files were opened due to insufficient permissions")
}

func (s *journalctlSource) Tail(ctx context.Context, n int, opts LogOptions) ([]string, error) {
	n = ClampLines(n)
	args := journalctlArgs(s.serviceName, false, n, opts)
	out, err := journalctlCommand(ctx, args, s.shouldUseSudo()).CombinedOutput()
	if err == nil && !s.shouldUseSudo() && deniedJournalOutput(out) {
		if sudoOut, sudoErr := journalctlCommand(ctx, args, true).CombinedOutput(); sudoErr == nil {
			s.markUseSudo()
			out = sudoOut
		}
	}
	if err != nil {
		sudoOut, sudoErr := journalctlCommand(ctx, args, true).CombinedOutput()
		if sudoErr != nil {
			return nil, fmt.Errorf(
				"journalctl tail failed: %s; sudo fallback failed: %s (%w). Configure journal access or passwordless sudo for journalctl",
				strings.TrimSpace(string(out)),
				strings.TrimSpace(string(sudoOut)),
				sudoErr,
			)
		}
		s.markUseSudo()
		out = sudoOut
	}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return []string{}, nil
	}
	return lines, nil
}

func startJournalctlStream(ctx context.Context, args []string, withSudo bool) (*exec.Cmd, io.ReadCloser, io.ReadCloser, error) {
	cmd := journalctlCommand(ctx, args, withSudo)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, nil, fmt.Errorf("journalctl pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, nil, nil, fmt.Errorf("journalctl stderr pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, nil, nil, err
	}
	return cmd, stdout, stderr, nil
}

// probeSudoNeeded decides up front whether this stream has to go through sudo.
//
// Start() succeeding says nothing about access: without the privileges to read
// the unit, `journalctl -f` does not follow anything — it prints the hint about
// insufficient permissions and exits straight away. The stream then closes on
// its own a moment later, which the UI reports as "Log stream ended
// unexpectedly". A cheap non-follow probe answers the question before the
// stream starts, so the fallback happens where it still helps.
func (s *journalctlSource) probeSudoNeeded(ctx context.Context) {
	if s.shouldUseSudo() {
		return
	}
	// Форма аргументов повторяет journalctlArgs: правила sudoers пишутся под
	// неё дословно, и проба с любым другим набором просто не найдёт своего
	// правила — sudo ответит "a password is required".
	probe := []string{"-u", s.serviceName, "-n", "0", "--no-pager", "-o", "short-iso"}
	out, err := journalctlCommand(ctx, probe, false).CombinedOutput()
	if err == nil && !deniedJournalOutput(out) {
		return
	}
	if _, sudoErr := journalctlCommand(ctx, probe, true).CombinedOutput(); sudoErr == nil {
		s.markUseSudo()
	}
}

func (s *journalctlSource) Stream(ctx context.Context, opts LogOptions) (<-chan string, error) {
	s.probeSudoNeeded(ctx)
	args := journalctlArgs(s.serviceName, true, 0, opts)
	cmd, stdout, stderr, err := startJournalctlStream(ctx, args, s.shouldUseSudo())
	if err != nil {
		cmd, stdout, stderr, err = startJournalctlStream(ctx, args, true)
		if err != nil {
			return nil, fmt.Errorf("journalctl start failed, sudo fallback failed: %w. Configure journal access or passwordless sudo for journalctl", err)
		}
		s.markUseSudo()
	}

	ch := make(chan string, 64)
	go func() {
		defer cmd.Wait()
		emit := func(line string) bool {
			select {
			case ch <- line:
				return true
			case <-ctx.Done():
				return false
			}
		}

		var wg sync.WaitGroup
		scanPipe := func(r io.Reader) {
			defer wg.Done()
			scanner := bufio.NewScanner(r)
			for scanner.Scan() {
				if !emit(scanner.Text()) {
					return
				}
			}
		}

		wg.Add(2)
		go scanPipe(stderr)
		go scanPipe(stdout)
		wg.Wait()
		close(ch)
	}()

	return ch, nil
}
