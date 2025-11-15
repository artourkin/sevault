package driver

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/docker/go-plugins-helpers/volume"
)

const (
	stateRoot       = "/var/lib/sevault"
	mountRoot       = stateRoot + "/mounts"
	mountRetryCount = 5
	mountRetryDelay = time.Second
)

type Driver struct {
	mu      sync.Mutex
	volumes map[string]*volumeInfo
}

type volumeInfo struct {
	Name    string
	Path    string
	Device  string
	Host    string
	Export  string
	Options []string
}

func New() *Driver {
	return &Driver{volumes: make(map[string]*volumeInfo)}
}

func (d *Driver) Create(r *volume.CreateRequest) error {
	host := strings.TrimSpace(r.Options["host"])
	export := strings.TrimSpace(r.Options["export"])
	if host == "" || export == "" {
		return fmt.Errorf("create requires host and export options")
	}

	path := filepath.Join(mountRoot, r.Name)
	if err := os.MkdirAll(path, 0o755); err != nil {
		return err
	}

	info := &volumeInfo{
		Name:    r.Name,
		Path:    path,
		Device:  fmt.Sprintf("%s:%s", formatHost(host), export),
		Host:    host,
		Export:  export,
		Options: buildMountOptions(host, r.Options),
	}

	d.mu.Lock()
	d.volumes[r.Name] = info
	d.mu.Unlock()
	log.Printf("registered volume %s host=%s export=%s", info.Name, info.Host, info.Export)
	return nil
}

func (d *Driver) Remove(r *volume.RemoveRequest) error {
	d.mu.Lock()
	info := d.volumes[r.Name]
	delete(d.volumes, r.Name)
	d.mu.Unlock()

	if info == nil {
		return nil
	}

	_ = os.RemoveAll(info.Path)
	return nil
}

func (d *Driver) Path(r *volume.PathRequest) (*volume.PathResponse, error) {
	d.mu.Lock()
	info := d.volumes[r.Name]
	d.mu.Unlock()
	if info == nil {
		return nil, fmt.Errorf("volume %s not found", r.Name)
	}
	return &volume.PathResponse{Mountpoint: info.Path}, nil
}

func (d *Driver) Mount(r *volume.MountRequest) (*volume.MountResponse, error) {
	d.mu.Lock()
	info := d.volumes[r.Name]
	d.mu.Unlock()
	if info == nil {
		return nil, fmt.Errorf("unknown volume %s", r.Name)
	}

	if err := os.MkdirAll(info.Path, 0o755); err != nil {
		return nil, err
	}

	flags, data := prepareMountArgs(info.Options)
	log.Printf("mount request volume=%s device=%s target=%s opts=%s", info.Name, info.Device, info.Path, strings.Join(info.Options, ","))
	var lastErr error
	for attempt := 1; attempt <= mountRetryCount; attempt++ {
		if err := mountVolume(info.Device, info.Path, "nfs", flags, data); err != nil {
			lastErr = err
			if attempt < mountRetryCount {
				log.Printf("mount attempt %d/%d for %s failed: %v (retrying in %s)", attempt, mountRetryCount, info.Device, err, mountRetryDelay)
				time.Sleep(mountRetryDelay)
				continue
			}
			return nil, fmt.Errorf("mount %s -> %s failed: %w", info.Device, info.Path, err)
		}
		log.Printf("mount successful volume=%s target=%s", info.Name, info.Path)
		return &volume.MountResponse{Mountpoint: info.Path}, nil
	}
	return nil, lastErr
}

func (d *Driver) Unmount(r *volume.UnmountRequest) error {
	target := filepath.Join(mountRoot, r.Name)
	if err := unmountVolume(target); err != nil {
		return fmt.Errorf("unmount %s failed: %w", target, err)
	}
	log.Printf("unmounted volume=%s target=%s", r.Name, target)
	return nil
}

func (d *Driver) Get(r *volume.GetRequest) (*volume.GetResponse, error) {
	d.mu.Lock()
	info := d.volumes[r.Name]
	d.mu.Unlock()
	if info == nil {
		return nil, fmt.Errorf("volume %s not found", r.Name)
	}

	status := map[string]interface{}{
		"host":   info.Host,
		"export": info.Export,
	}
	return &volume.GetResponse{Volume: &volume.Volume{
		Name:       info.Name,
		Mountpoint: info.Path,
		Status:     status,
	}}, nil
}

func (d *Driver) List() (*volume.ListResponse, error) {
	d.mu.Lock()
	defer d.mu.Unlock()

	var volumes []*volume.Volume
	for _, info := range d.volumes {
		status := map[string]interface{}{
			"host":   info.Host,
			"export": info.Export,
		}
		volumes = append(volumes, &volume.Volume{
			Name:       info.Name,
			Mountpoint: info.Path,
			Status:     status,
		})
	}
	return &volume.ListResponse{Volumes: volumes}, nil
}

func (d *Driver) Capabilities() *volume.CapabilitiesResponse {
	return &volume.CapabilitiesResponse{Capabilities: volume.Capability{Scope: "global"}}
}

func buildMountOptions(host string, opts map[string]string) []string {
	var result []string
	result = append(result, fmt.Sprintf("addr=%s", host))

	vers := strings.TrimSpace(opts["vers"])
	if vers == "" {
		vers = "4"
	}
	result = append(result, fmt.Sprintf("vers=%s", vers))

	if isTrue(opts["ro"]) {
		result = append(result, "ro")
	}

	hasNoLock := false
	if extra := strings.TrimSpace(opts["options"]); extra != "" {
		for _, part := range strings.Split(extra, ",") {
			if trimmed := strings.TrimSpace(part); trimmed != "" {
				if strings.EqualFold(trimmed, "nolock") {
					hasNoLock = true
				}
				result = append(result, trimmed)
			}
		}
	}

	if !hasNoLock {
		// Plugin rootfs does not run rpc.statd, so disable NLM locking by default.
		result = append(result, "nolock")
	}

	return result
}

func formatHost(host string) string {
	if strings.Contains(host, ":") && !strings.Contains(host, "]") {
		return "[" + host + "]"
	}
	return host
}

func isTrue(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func prepareMountArgs(opts []string) (uintptr, string) {
	var flags uintptr
	var extra []string
	for _, opt := range opts {
		switch strings.ToLower(strings.TrimSpace(opt)) {
		case "ro":
			flags |= mountFlagReadOnly
		case "rw", "":
			// ignore explicit rw markers or empty values
		default:
			extra = append(extra, opt)
		}
	}
	return flags, strings.Join(extra, ",")
}
