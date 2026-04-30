package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const exporterVersion = "dev"

type Config struct {
	ListenAddr             string
	ServerID               string
	CheckInterval          time.Duration
	CommandTimeout         time.Duration
	ContainerCheckTimeout  time.Duration
	ContainerCheckPoll     time.Duration
	DockerPath             string
	NvidiaSmiPath          string
	HostGPUCheckEnabled    bool
	DockerCheckEnabled     bool
	ContainerChecksEnabled bool
	StartStoppedContainers bool
	ContainerSSHRecovery   bool
	ContainerNVMLRecovery  bool
	ContainerImageRegex    *regexp.Regexp
	RequiredMounts         []MountRequirement
}

type MountRequirement struct {
	Source string
	Target string
}

type MountEntry struct {
	Source string
	Target string
	FSType string
}

type DockerContainer struct {
	ID     string `json:"ID"`
	Names  string `json:"Names"`
	Image  string `json:"Image"`
	State  string `json:"State"`
	Status string `json:"Status"`
}

type ContainerGPUResult struct {
	Up                     bool
	NVMLMismatchDetected   bool
	NVMLRecoveryAttempted  bool
	NVMLRecoverySuccessful bool
}

type Collector struct {
	cfg Config

	mu        sync.RWMutex
	metrics   string
	collected time.Time
}

func main() {
	configPath := flag.String("config", "", "path to an optional KEY=value config file")
	flag.Parse()

	if *configPath != "" {
		if err := loadEnvFile(*configPath); err != nil {
			log.Fatalf("failed to load config file: %v", err)
		}
	}

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	collector := &Collector{cfg: cfg}
	go collector.run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", collector.handleMetrics)
	mux.HandleFunc("/healthz", collector.handleHealthz)

	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("cluster-monitor-exporter listening on %s for server_id=%s", cfg.ListenAddr, cfg.ServerID)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server failed: %v", err)
	}
}

func loadConfig() (Config, error) {
	hostname, err := os.Hostname()
	if err != nil || strings.TrimSpace(hostname) == "" {
		hostname = "unknown"
	}

	imagePattern := envStringCompat("CLUSTER_MONITOR_EXPORTER_CONTAINER_IMAGE_REGEX", "REMOTE_BOOT_EXPORTER_CONTAINER_IMAGE_REGEX", `^(decs|dguailab/decs)(:|$)`)
	imageRegex, err := regexp.Compile(imagePattern)
	if err != nil {
		return Config{}, fmt.Errorf("invalid CLUSTER_MONITOR_EXPORTER_CONTAINER_IMAGE_REGEX: %w", err)
	}

	cfg := Config{
		ListenAddr:             envStringCompat("CLUSTER_MONITOR_EXPORTER_LISTEN_ADDR", "REMOTE_BOOT_EXPORTER_LISTEN_ADDR", ":30074"),
		ServerID:               envStringCompat("CLUSTER_MONITOR_EXPORTER_SERVER_ID", "REMOTE_BOOT_EXPORTER_SERVER_ID", hostname),
		CheckInterval:          envDurationCompat("CLUSTER_MONITOR_EXPORTER_CHECK_INTERVAL", "REMOTE_BOOT_EXPORTER_CHECK_INTERVAL", 30*time.Second),
		CommandTimeout:         envDurationCompat("CLUSTER_MONITOR_EXPORTER_COMMAND_TIMEOUT", "REMOTE_BOOT_EXPORTER_COMMAND_TIMEOUT", 10*time.Second),
		ContainerCheckTimeout:  envDurationCompat("CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_TIMEOUT", "REMOTE_BOOT_EXPORTER_CONTAINER_CHECK_TIMEOUT", 60*time.Second),
		ContainerCheckPoll:     envDurationCompat("CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_POLL", "REMOTE_BOOT_EXPORTER_CONTAINER_CHECK_POLL", 5*time.Second),
		DockerPath:             envStringCompat("CLUSTER_MONITOR_EXPORTER_DOCKER_PATH", "REMOTE_BOOT_EXPORTER_DOCKER_PATH", "docker"),
		NvidiaSmiPath:          envStringCompat("CLUSTER_MONITOR_EXPORTER_NVIDIA_SMI_PATH", "REMOTE_BOOT_EXPORTER_NVIDIA_SMI_PATH", "nvidia-smi"),
		HostGPUCheckEnabled:    envBoolCompat("CLUSTER_MONITOR_EXPORTER_HOST_GPU_CHECK_ENABLED", "REMOTE_BOOT_EXPORTER_HOST_GPU_CHECK_ENABLED", true),
		DockerCheckEnabled:     envBoolCompat("CLUSTER_MONITOR_EXPORTER_DOCKER_CHECK_ENABLED", "REMOTE_BOOT_EXPORTER_DOCKER_CHECK_ENABLED", true),
		ContainerChecksEnabled: envBoolCompat("CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECKS_ENABLED", "REMOTE_BOOT_EXPORTER_CONTAINER_CHECKS_ENABLED", true),
		StartStoppedContainers: envBoolCompat("CLUSTER_MONITOR_EXPORTER_START_STOPPED_CONTAINERS", "REMOTE_BOOT_EXPORTER_START_STOPPED_CONTAINERS", true),
		ContainerSSHRecovery:   envBoolCompat("CLUSTER_MONITOR_EXPORTER_CONTAINER_SSH_RECOVERY_ENABLED", "REMOTE_BOOT_EXPORTER_CONTAINER_SSH_RECOVERY_ENABLED", true),
		ContainerNVMLRecovery:  envBoolCompat("CLUSTER_MONITOR_EXPORTER_CONTAINER_NVML_RECOVERY_ENABLED", "REMOTE_BOOT_EXPORTER_CONTAINER_NVML_RECOVERY_ENABLED", true),
		ContainerImageRegex:    imageRegex,
		RequiredMounts:         parseRequiredMounts(envStringCompat("CLUSTER_MONITOR_EXPORTER_REQUIRED_MOUNTS", "REMOTE_BOOT_EXPORTER_REQUIRED_MOUNTS", "")),
	}

	if cfg.CheckInterval < time.Second {
		return Config{}, fmt.Errorf("CLUSTER_MONITOR_EXPORTER_CHECK_INTERVAL must be at least 1s")
	}
	if cfg.CommandTimeout < time.Second {
		return Config{}, fmt.Errorf("CLUSTER_MONITOR_EXPORTER_COMMAND_TIMEOUT must be at least 1s")
	}
	if cfg.ContainerCheckTimeout < time.Second {
		return Config{}, fmt.Errorf("CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_TIMEOUT must be at least 1s")
	}
	if cfg.ContainerCheckPoll < time.Second {
		return Config{}, fmt.Errorf("CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_POLL must be at least 1s")
	}

	return cfg, nil
}

func envString(name, fallback string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return value
}

func envStringCompat(name, legacyName, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	if value := strings.TrimSpace(os.Getenv(legacyName)); value != "" {
		return value
	}
	return fallback
}

func envBool(name string, fallback bool) bool {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}

	switch strings.ToLower(value) {
	case "1", "true", "yes", "y", "on":
		return true
	case "0", "false", "no", "n", "off":
		return false
	default:
		return fallback
	}
}

func envBoolCompat(name, legacyName string, fallback bool) bool {
	if strings.TrimSpace(os.Getenv(name)) != "" {
		return envBool(name, fallback)
	}
	if strings.TrimSpace(os.Getenv(legacyName)) != "" {
		return envBool(legacyName, fallback)
	}
	return fallback
}

func envDuration(name string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	if _, err := strconv.Atoi(value); err == nil {
		value += "s"
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envDurationCompat(name, legacyName string, fallback time.Duration) time.Duration {
	if strings.TrimSpace(os.Getenv(name)) != "" {
		return envDuration(name, fallback)
	}
	if strings.TrimSpace(os.Getenv(legacyName)) != "" {
		return envDuration(legacyName, fallback)
	}
	return fallback
}

func loadEnvFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	for lineNumber, rawLine := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "export ") {
			line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		}

		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return fmt.Errorf("%s:%d: expected KEY=value", path, lineNumber+1)
		}

		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if key == "" {
			return fmt.Errorf("%s:%d: empty key", path, lineNumber+1)
		}

		if (strings.HasPrefix(value, `"`) && strings.HasSuffix(value, `"`)) ||
			(strings.HasPrefix(value, `'`) && strings.HasSuffix(value, `'`)) {
			value = strings.TrimPrefix(strings.TrimSuffix(value, value[len(value)-1:]), value[:1])
		}

		if _, exists := os.LookupEnv(key); !exists {
			if err := os.Setenv(key, value); err != nil {
				return err
			}
		}
	}

	return nil
}

func parseRequiredMounts(raw string) []MountRequirement {
	parts := strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == '\n' || r == ';'
	})

	requirements := make([]MountRequirement, 0, len(parts))
	for _, part := range parts {
		entry := strings.TrimSpace(part)
		if entry == "" {
			continue
		}

		source, target, hasTarget := strings.Cut(entry, "=")
		req := MountRequirement{Source: strings.TrimSpace(source)}
		if hasTarget {
			req.Target = strings.TrimSpace(target)
		}
		if req.Source != "" {
			requirements = append(requirements, req)
		}
	}

	return requirements
}

func (c *Collector) run(ctx context.Context) {
	c.collectOnce()

	ticker := time.NewTicker(c.cfg.CheckInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.collectOnce()
		}
	}
}

func (c *Collector) collectOnce() {
	metrics := c.collect()

	c.mu.Lock()
	c.metrics = metrics
	c.collected = time.Now()
	c.mu.Unlock()
}

func (c *Collector) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	c.mu.RLock()
	metrics := c.metrics
	c.mu.RUnlock()

	if metrics == "" {
		http.Error(w, "metrics are not ready", http.StatusServiceUnavailable)
		return
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write([]byte(metrics))
}

func (c *Collector) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	c.mu.RLock()
	ready := c.metrics != ""
	c.mu.RUnlock()

	if !ready {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("ok\n"))
}

func (c *Collector) collect() string {
	started := time.Now()
	r := newRenderer()
	serverLabels := labels("server", c.cfg.ServerID)

	r.emit("cluster_monitor_exporter_info", "Exporter build and runtime information.", "gauge",
		labels("server", c.cfg.ServerID, "version", exporterVersion, "go_version", runtime.Version()), 1)
	r.emit("cluster_monitor_exporter_command_timeout_seconds", "Command timeout used for local health checks.", "gauge",
		serverLabels, c.cfg.CommandTimeout.Seconds())
	r.emit("cluster_monitor_exporter_check_interval_seconds", "Background collection interval.", "gauge",
		serverLabels, c.cfg.CheckInterval.Seconds())
	r.emit("cluster_monitor_exporter_container_check_timeout_seconds", "Timeout used for per-container SSH and GPU readiness checks.", "gauge",
		serverLabels, c.cfg.ContainerCheckTimeout.Seconds())

	c.collectMounts(r)
	if c.cfg.HostGPUCheckEnabled {
		c.collectHostGPU(r)
	}
	if c.cfg.DockerCheckEnabled {
		c.collectDocker(r)
	}

	r.emit("cluster_monitor_exporter_last_collection_success", "Whether the exporter finished the last collection loop.", "gauge",
		serverLabels, 1)
	r.emit("cluster_monitor_exporter_last_collection_timestamp_seconds", "Unix timestamp of the last completed collection.", "gauge",
		serverLabels, float64(time.Now().Unix()))
	r.emit("cluster_monitor_exporter_collection_duration_seconds", "Duration of the full collection loop.", "gauge",
		serverLabels, time.Since(started).Seconds())

	return r.String()
}

func (c *Collector) collectMounts(r *renderer) {
	started := time.Now()
	serverLabels := labels("server", c.cfg.ServerID)
	r.emit("cluster_monitor_host_mount_requirements", "Number of configured required mounts.", "gauge",
		serverLabels, float64(len(c.cfg.RequiredMounts)))

	if len(c.cfg.RequiredMounts) == 0 {
		r.emit("cluster_monitor_check_duration_seconds", "Duration of an individual local health check.", "gauge",
			labels("server", c.cfg.ServerID, "check", "mount"), time.Since(started).Seconds())
		return
	}

	mounts, err := readMountInfo()
	checkSuccess := 1.0
	if err != nil {
		checkSuccess = 0
		mounts = nil
	}

	for _, req := range c.cfg.RequiredMounts {
		up := 0.0
		for _, mount := range mounts {
			if mountMatches(req, mount) {
				up = 1
				break
			}
		}
		r.emit("cluster_monitor_host_mount_up", "Whether a configured required mount is present.", "gauge",
			labels("server", c.cfg.ServerID, "source", req.Source, "target", req.Target), up)
	}

	r.emit("cluster_monitor_check_success", "Whether an individual local health check executed successfully.", "gauge",
		labels("server", c.cfg.ServerID, "check", "mount"), checkSuccess)
	r.emit("cluster_monitor_check_duration_seconds", "Duration of an individual local health check.", "gauge",
		labels("server", c.cfg.ServerID, "check", "mount"), time.Since(started).Seconds())
}

func mountMatches(req MountRequirement, mount MountEntry) bool {
	if req.Source != "" && req.Source != mount.Source {
		return false
	}
	if req.Target != "" && req.Target != mount.Target {
		return false
	}
	return true
}

func readMountInfo() ([]MountEntry, error) {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return nil, err
	}

	var mounts []MountEntry
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		before, after, ok := strings.Cut(line, " - ")
		if !ok {
			continue
		}

		beforeFields := strings.Fields(before)
		afterFields := strings.Fields(after)
		if len(beforeFields) < 5 || len(afterFields) < 2 {
			continue
		}

		mounts = append(mounts, MountEntry{
			Target: unescapeMountField(beforeFields[4]),
			FSType: afterFields[0],
			Source: unescapeMountField(afterFields[1]),
		})
	}

	return mounts, nil
}

func unescapeMountField(value string) string {
	replacer := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`)
	return replacer.Replace(value)
}

func (c *Collector) collectHostGPU(r *renderer) {
	started := time.Now()
	output, err := runCommand(c.cfg.CommandTimeout, c.cfg.NvidiaSmiPath, "-L")

	up := 0.0
	count := 0
	if err == nil {
		up = 1
		for _, line := range strings.Split(string(output), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "GPU ") {
				count++
			}
		}
	}

	r.emit("cluster_monitor_host_gpu_up", "Whether host nvidia-smi responds successfully.", "gauge",
		labels("server", c.cfg.ServerID), up)
	r.emit("cluster_monitor_host_gpu_count", "Number of host GPUs reported by nvidia-smi -L.", "gauge",
		labels("server", c.cfg.ServerID), float64(count))
	r.emit("cluster_monitor_check_success", "Whether an individual local health check executed successfully.", "gauge",
		labels("server", c.cfg.ServerID, "check", "host_gpu"), up)
	r.emit("cluster_monitor_check_duration_seconds", "Duration of an individual local health check.", "gauge",
		labels("server", c.cfg.ServerID, "check", "host_gpu"), time.Since(started).Seconds())
}

func (c *Collector) collectDocker(r *renderer) {
	started := time.Now()
	_, err := runCommand(c.cfg.CommandTimeout, c.cfg.DockerPath, "info")

	up := 0.0
	if err == nil {
		up = 1
	}

	r.emit("cluster_monitor_docker_daemon_up", "Whether docker info responds successfully.", "gauge",
		labels("server", c.cfg.ServerID), up)
	r.emit("cluster_monitor_check_success", "Whether an individual local health check executed successfully.", "gauge",
		labels("server", c.cfg.ServerID, "check", "docker_daemon"), up)
	r.emit("cluster_monitor_check_duration_seconds", "Duration of an individual local health check.", "gauge",
		labels("server", c.cfg.ServerID, "check", "docker_daemon"), time.Since(started).Seconds())

	if up != 1 || !c.cfg.ContainerChecksEnabled {
		return
	}

	c.collectContainers(r)
}

func (c *Collector) collectContainers(r *renderer) {
	started := time.Now()
	containers, err := c.listContainers()
	if err != nil {
		r.emit("cluster_monitor_check_success", "Whether an individual local health check executed successfully.", "gauge",
			labels("server", c.cfg.ServerID, "check", "docker_container_list"), 0)
		r.emit("cluster_monitor_check_duration_seconds", "Duration of an individual local health check.", "gauge",
			labels("server", c.cfg.ServerID, "check", "docker_container_list"), time.Since(started).Seconds())
		return
	}

	r.emit("cluster_monitor_check_success", "Whether an individual local health check executed successfully.", "gauge",
		labels("server", c.cfg.ServerID, "check", "docker_container_list"), 1)
	r.emit("cluster_monitor_check_duration_seconds", "Duration of an individual local health check.", "gauge",
		labels("server", c.cfg.ServerID, "check", "docker_container_list"), time.Since(started).Seconds())

	if c.cfg.StartStoppedContainers {
		refreshed := c.startStoppedTargetContainers(r, containers)
		if refreshed {
			if updatedContainers, err := c.listContainers(); err == nil {
				containers = updatedContainers
			}
		}
	}

	targetCount := 0
	for _, container := range containers {
		if !c.cfg.ContainerImageRegex.MatchString(container.Image) {
			continue
		}

		targetCount++
		c.collectContainer(r, container)
	}

	r.emit("cluster_monitor_container_targets", "Number of containers matching the configured target image regex.", "gauge",
		labels("server", c.cfg.ServerID), float64(targetCount))
}

func (c *Collector) startStoppedTargetContainers(r *renderer, containers []DockerContainer) bool {
	refreshed := false
	for _, container := range containers {
		if !c.cfg.ContainerImageRegex.MatchString(container.Image) || isContainerRunning(container) {
			continue
		}

		name := container.Names
		if name == "" {
			name = container.ID
		}

		success := 0.0
		if c.startContainer(container.ID) {
			success = 1
			refreshed = true
		}

		r.emit("cluster_monitor_container_start_recovery_success", "Whether the exporter successfully started a stopped target container during the last collection.", "gauge",
			labels("server", c.cfg.ServerID, "container", name, "image", container.Image), success)
	}

	return refreshed
}

func (c *Collector) listContainers() ([]DockerContainer, error) {
	output, err := runCommand(c.cfg.CommandTimeout, c.cfg.DockerPath, "ps", "-a", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	var containers []DockerContainer
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		var container DockerContainer
		if err := json.Unmarshal([]byte(line), &container); err != nil {
			return nil, err
		}
		containers = append(containers, container)
	}

	return containers, nil
}

func (c *Collector) collectContainer(r *renderer, container DockerContainer) {
	name := container.Names
	if name == "" {
		name = container.ID
	}
	running := 0.0
	if isContainerRunning(container) {
		running = 1
	}

	baseLabels := labels("server", c.cfg.ServerID, "container", name, "image", container.Image)
	r.emit("cluster_monitor_container_running", "Whether a target container is running.", "gauge", baseLabels, running)

	sshUp := 0.0
	gpuUp := 0.0

	if running == 1 {
		sshStart := time.Now()
		if c.waitForContainerSSH(container.ID) {
			sshUp = 1
		}
		r.emit("cluster_monitor_check_duration_seconds", "Duration of an individual local health check.", "gauge",
			labels("server", c.cfg.ServerID, "check", "container_ssh", "container", name), time.Since(sshStart).Seconds())

		gpuStart := time.Now()
		gpuResult := c.waitForContainerGPU(container.ID)
		if gpuResult.Up {
			gpuUp = 1
		}
		r.emit("cluster_monitor_container_gpu_nvml_mismatch_detected", "Whether container nvidia-smi failed with an NVML driver/library version mismatch during the last collection.", "gauge",
			baseLabels, boolFloat(gpuResult.NVMLMismatchDetected))
		r.emit("cluster_monitor_container_nvml_recovery_attempted", "Whether the exporter attempted to repair the container libnvidia-ml.so.1 symlink during the last collection.", "gauge",
			baseLabels, boolFloat(gpuResult.NVMLRecoveryAttempted))
		r.emit("cluster_monitor_container_nvml_recovery_success", "Whether the exporter successfully repaired the container libnvidia-ml.so.1 symlink during the last collection.", "gauge",
			baseLabels, boolFloat(gpuResult.NVMLRecoverySuccessful))
		r.emit("cluster_monitor_check_duration_seconds", "Duration of an individual local health check.", "gauge",
			labels("server", c.cfg.ServerID, "check", "container_gpu", "container", name), time.Since(gpuStart).Seconds())
	}

	r.emit("cluster_monitor_container_ssh_up", "Whether sshd appears to be running inside a target container.", "gauge",
		baseLabels, sshUp)
	r.emit("cluster_monitor_container_gpu_up", "Whether nvidia-smi responds inside a target container.", "gauge",
		baseLabels, gpuUp)
}

func isContainerRunning(container DockerContainer) bool {
	return strings.EqualFold(container.State, "running") || strings.HasPrefix(strings.ToLower(container.Status), "up ")
}

func (c *Collector) startContainer(containerID string) bool {
	_, err := runCommand(c.cfg.CommandTimeout, c.cfg.DockerPath, "start", containerID)
	return err == nil
}

func (c *Collector) waitForContainerSSH(containerID string) bool {
	deadline := time.Now().Add(c.cfg.ContainerCheckTimeout)
	for {
		if c.checkContainerSSH(containerID) {
			return true
		}

		if time.Now().After(deadline) {
			return false
		}

		if c.cfg.ContainerSSHRecovery {
			c.startContainerSSH(containerID)
		}

		sleepUntilNextAttempt(deadline, c.cfg.ContainerCheckPoll)
	}
}

func (c *Collector) waitForContainerGPU(containerID string) ContainerGPUResult {
	result := ContainerGPUResult{}
	deadline := time.Now().Add(c.cfg.ContainerCheckTimeout)
	recoveryAttempted := false

	for {
		output, err := c.checkContainerGPU(containerID)
		if err == nil {
			result.Up = true
			return result
		}

		if isNVMLVersionMismatch(output) {
			result.NVMLMismatchDetected = true
			if c.cfg.ContainerNVMLRecovery && !recoveryAttempted {
				recoveryAttempted = true
				result.NVMLRecoveryAttempted = true
				if c.repairContainerNVML(containerID) {
					result.NVMLRecoverySuccessful = true
					continue
				}
			}
		}

		if time.Now().After(deadline) {
			return result
		}

		sleepUntilNextAttempt(deadline, c.cfg.ContainerCheckPoll)
	}
}

func (c *Collector) checkContainerSSH(containerID string) bool {
	checkCommand := "service ssh status >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh status >/dev/null 2>&1; } || ps -ef | grep '[s]shd' >/dev/null"
	_, err := runCommand(c.cfg.CommandTimeout, c.cfg.DockerPath, "exec", containerID, "sh", "-lc", checkCommand)
	return err == nil
}

func (c *Collector) startContainerSSH(containerID string) {
	startCommand := "service ssh start >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh start >/dev/null 2>&1; } || true"
	_, _ = runCommand(c.cfg.CommandTimeout, c.cfg.DockerPath, "exec", containerID, "sh", "-lc", startCommand)
}

func (c *Collector) checkContainerGPU(containerID string) ([]byte, error) {
	return runCommand(c.cfg.CommandTimeout, c.cfg.DockerPath, "exec", containerID, "nvidia-smi")
}

func isNVMLVersionMismatch(output []byte) bool {
	return strings.Contains(strings.ToLower(string(output)), "driver/library version mismatch")
}

func (c *Collector) repairContainerNVML(containerID string) bool {
	driverVersion, err := c.hostNvidiaDriverVersion()
	if err != nil {
		log.Printf("container=%s nvml_recovery=false reason=host_driver_version_error error=%v", containerID, err)
		return false
	}

	output, err := runCommand(
		c.cfg.CommandTimeout,
		c.cfg.DockerPath,
		"exec",
		containerID,
		"sh",
		"-lc",
		containerNVMLRepairScript,
		"cluster-monitor-exporter",
		driverVersion,
	)
	if err != nil {
		log.Printf("container=%s nvml_recovery=false driver_version=%s error=%v output=%q",
			containerID, driverVersion, err, truncateForLog(output, 300))
		return false
	}

	log.Printf("container=%s nvml_recovery=true driver_version=%s", containerID, driverVersion)
	return true
}

func (c *Collector) hostNvidiaDriverVersion() (string, error) {
	output, err := runCommand(c.cfg.CommandTimeout, c.cfg.NvidiaSmiPath, "--query-gpu=driver_version", "--format=csv,noheader,nounits")
	if err != nil {
		return "", err
	}

	for _, line := range strings.Split(string(output), "\n") {
		version := strings.TrimSpace(line)
		if version == "" {
			continue
		}
		if !isSafeNvidiaDriverVersion(version) {
			return "", fmt.Errorf("unsafe driver version %q", version)
		}
		return version, nil
	}

	return "", errors.New("nvidia-smi did not return a driver version")
}

func isSafeNvidiaDriverVersion(version string) bool {
	if version == "" || strings.HasPrefix(version, ".") || strings.HasSuffix(version, ".") {
		return false
	}
	for _, r := range version {
		if r != '.' && (r < '0' || r > '9') {
			return false
		}
	}
	return true
}

func truncateForLog(output []byte, limit int) string {
	text := strings.TrimSpace(string(output))
	if limit < 0 || len(text) <= limit {
		return text
	}
	return text[:limit] + "..."
}

const containerNVMLRepairScript = `set -eu
driver_version="$1"
case "$driver_version" in
  ""|.*|*.|*[!0123456789.]*)
    exit 64
    ;;
esac

lib_path=""
if command -v nvidia-smi >/dev/null 2>&1 && command -v ldd >/dev/null 2>&1; then
  nvidia_smi_path="$(command -v nvidia-smi)"
  lib_path="$(ldd "$nvidia_smi_path" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *"libnvidia-ml.so.1"*" => "*)
        path_part="${line#*=> }"
        printf '%s\n' "${path_part%% *}"
        break
        ;;
    esac
  done)"
fi

if [ -z "$lib_path" ] && command -v ldconfig >/dev/null 2>&1; then
  lib_path="$(ldconfig -p 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *"libnvidia-ml.so.1"*" => "*)
        printf '%s\n' "${line##* => }"
        break
        ;;
    esac
  done)"
fi

if [ -z "$lib_path" ]; then
  lib_path="/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1"
fi

lib_dir="${lib_path%/*}"
if [ "$lib_dir" = "$lib_path" ] || [ -z "$lib_dir" ]; then
  lib_dir="/usr/lib/x86_64-linux-gnu"
fi

target_base="libnvidia-ml.so.$driver_version"
target_path="$lib_dir/$target_base"
[ -f "$target_path" ] || exit 65

cd "$lib_dir"
if [ -e libnvidia-ml.so.1 ] && [ ! -L libnvidia-ml.so.1 ]; then
  exit 66
fi
if [ -e libnvidia-ml.so ] && [ ! -L libnvidia-ml.so ]; then
  exit 67
fi

ln -sfn "$target_base" libnvidia-ml.so.1
ln -sfn libnvidia-ml.so.1 libnvidia-ml.so
`

func sleepUntilNextAttempt(deadline time.Time, poll time.Duration) {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return
	}
	if remaining < poll {
		time.Sleep(remaining)
		return
	}
	time.Sleep(poll)
}

func runCommand(timeout time.Duration, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	output, err := cmd.CombinedOutput()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return output, fmt.Errorf("%s timed out after %s", name, timeout)
	}
	return output, err
}

type renderer struct {
	builder strings.Builder
	emitted map[string]bool
}

func newRenderer() *renderer {
	return &renderer{emitted: make(map[string]bool)}
}

func (r *renderer) emit(name, help, metricType string, metricLabels map[string]string, value float64) {
	if !r.emitted[name] {
		fmt.Fprintf(&r.builder, "# HELP %s %s\n", name, help)
		fmt.Fprintf(&r.builder, "# TYPE %s %s\n", name, metricType)
		r.emitted[name] = true
	}

	r.builder.WriteString(name)
	if len(metricLabels) > 0 {
		r.builder.WriteString("{")
		keys := make([]string, 0, len(metricLabels))
		for key := range metricLabels {
			keys = append(keys, key)
		}
		sort.Strings(keys)

		for index, key := range keys {
			if index > 0 {
				r.builder.WriteString(",")
			}
			fmt.Fprintf(&r.builder, `%s="%s"`, key, escapeLabelValue(metricLabels[key]))
		}
		r.builder.WriteString("}")
	}
	fmt.Fprintf(&r.builder, " %s\n", strconv.FormatFloat(value, 'f', -1, 64))
}

func (r *renderer) String() string {
	return r.builder.String()
}

func labels(values ...string) map[string]string {
	result := make(map[string]string, len(values)/2)
	for i := 0; i+1 < len(values); i += 2 {
		result[values[i]] = values[i+1]
	}
	return result
}

func boolFloat(value bool) float64 {
	if value {
		return 1
	}
	return 0
}

func escapeLabelValue(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, "\n", `\n`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	return value
}
