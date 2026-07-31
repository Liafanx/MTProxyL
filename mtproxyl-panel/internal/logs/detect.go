package logs

import (
	"os"
	"os/exec"
	"runtime"
)

// DetectSource determines the appropriate log source based on environment.
func DetectSource(serviceName, containerName string) (LogSource, error) {
	if containerName != "" {
		return newDockerSource(containerName)
	}
	return newJournalctlSource(serviceName)
}

// IsInsideDocker checks if the current process is running inside a Docker container.
func IsInsideDocker() bool {
	if runtime.GOOS != "linux" {
		return false
	}
	_, err := os.Stat("/.dockerenv")
	return err == nil
}

// HasDockerSocket checks if Docker socket is accessible.
func HasDockerSocket() bool {
	_, err := os.Stat("/var/run/docker.sock")
	return err == nil
}

// HasJournalctl checks if journalctl is available.
func HasJournalctl() bool {
	_, err := exec.LookPath("journalctl")
	return err == nil
}

// HasDockerCLI checks if docker CLI is available.
func HasDockerCLI() bool {
	_, err := exec.LookPath("docker")
	return err == nil
}

// SourceStatus describes the current log source availability.
type SourceStatus struct {
	Available bool   `json:"available"`
	Source    string `json:"source"`
	Target    string `json:"target"`
	Error     string `json:"error,omitempty"`
}

// CheckStatus returns the status of the log source without creating it.
func CheckStatus(serviceName, containerName string) SourceStatus {
	if containerName != "" {
		if IsInsideDocker() {
			if !HasDockerSocket() {
				return SourceStatus{
					Available: false,
					Source:    "docker",
					Target:    containerName,
					Error:     "Docker socket not found. Add -v /var/run/docker.sock:/var/run/docker.sock to your docker run command.",
				}
			}
		} else if !HasDockerCLI() {
			return SourceStatus{
				Available: false,
				Source:    "docker",
				Target:    containerName,
				Error:     "Docker CLI not found. Install Docker or remove container_name from config to use journalctl.",
			}
		}
		return SourceStatus{Available: true, Source: "docker", Target: containerName}
	}

	if !HasJournalctl() {
		if IsInsideDocker() {
			return SourceStatus{
				Available: false,
				Source:    "journalctl",
				Target:    serviceName,
				Error:     "journalctl not available inside Docker. Set container_name in config to read logs from Telemt's Docker container.",
			}
		}
		return SourceStatus{
			Available: false,
			Source:    "journalctl",
			Target:    serviceName,
			Error:     "journalctl not found on this system.",
		}
	}
	return SourceStatus{Available: true, Source: "journalctl", Target: serviceName}
}
