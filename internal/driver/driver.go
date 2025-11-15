package driver

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/docker/go-plugins-helpers/volume"
)

const mountRoot = "/var/lib/sevault/mounts"

// Driver is a tiny in-memory implementation of a Docker volume driver.
type Driver struct {
	mu      sync.Mutex
	volumes map[string]*volumeInfo
}

type volumeInfo struct {
	name       string
	mountpoint string
	device     string
	config     mountConfig
}

type mountConfig struct {
	host     string
	export   string
	version  string
	readOnly bool
}

func New() *Driver {
	return &Driver{volumes: make(map[string]*volumeInfo)}
}

func (d *Driver) Create(r *volume.CreateRequest) error {
	cfg, err := parseMountConfig(r.Options)
	if err != nil {
		return err
	}

	mountpoint := filepath.Join(mountRoot, r.Name)
	if err := os.MkdirAll(mountpoint, 0o755); err != nil {
		return err
	}

	info := &volumeInfo{
		name:       r.Name,
		mountpoint: mountpoint,
		device:     fmt.Sprintf("%s:%s", formatHost(cfg.host), cfg.export),
		config:     cfg,
	}

	d.mu.Lock()
	d.volumes[r.Name] = info
	d.mu.Unlock()
	log.Printf("volume registered name=%s host=%s export=%s vers=%s ro=%t", r.Name, cfg.host, cfg.export, cfg.version, cfg.readOnly)
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
	_ = os.RemoveAll(info.mountpoint)
	return nil
}

func (d *Driver) Path(r *volume.PathRequest) (*volume.PathResponse, error) {
	info, err := d.lookup(r.Name)
	if err != nil {
		return nil, err
	}
	return &volume.PathResponse{Mountpoint: info.mountpoint}, nil
}

func (d *Driver) Mount(r *volume.MountRequest) (*volume.MountResponse, error) {
	info, err := d.lookup(r.Name)
	if err != nil {
		return nil, err
	}

	if err := os.MkdirAll(info.mountpoint, 0o755); err != nil {
		return nil, err
	}

	flags, data := mountArguments(info.config)
	if err := mountVolume(info.device, info.mountpoint, "nfs", flags, data); err != nil {
		return nil, fmt.Errorf("mount %s -> %s failed: %w", info.device, info.mountpoint, err)
	}
	log.Printf("volume mounted name=%s target=%s", info.name, info.mountpoint)
	return &volume.MountResponse{Mountpoint: info.mountpoint}, nil
}

func (d *Driver) Unmount(r *volume.UnmountRequest) error {
	target := filepath.Join(mountRoot, r.Name)
	if err := unmountVolume(target); err != nil {
		return fmt.Errorf("unmount %s failed: %w", r.Name, err)
	}
	log.Printf("volume unmounted name=%s", r.Name)
	return nil
}

func (d *Driver) Get(r *volume.GetRequest) (*volume.GetResponse, error) {
	info, err := d.lookup(r.Name)
	if err != nil {
		return nil, err
	}
	return &volume.GetResponse{Volume: describeVolume(info)}, nil
}

func (d *Driver) List() (*volume.ListResponse, error) {
	d.mu.Lock()
	defer d.mu.Unlock()

	var volumes []*volume.Volume
	for _, info := range d.volumes {
		volumes = append(volumes, describeVolume(info))
	}
	return &volume.ListResponse{Volumes: volumes}, nil
}

func (d *Driver) Capabilities() *volume.CapabilitiesResponse {
	return &volume.CapabilitiesResponse{Capabilities: volume.Capability{Scope: "global"}}
}

func (d *Driver) lookup(name string) (*volumeInfo, error) {
	d.mu.Lock()
	defer d.mu.Unlock()

	info, ok := d.volumes[name]
	if !ok {
		return nil, fmt.Errorf("volume %s not found", name)
	}
	return info, nil
}

func describeVolume(info *volumeInfo) *volume.Volume {
	status := map[string]interface{}{
		"host":   info.config.host,
		"export": info.config.export,
		"vers":   info.config.version,
		"ro":     info.config.readOnly,
	}
	return &volume.Volume{
		Name:       info.name,
		Mountpoint: info.mountpoint,
		Status:     status,
	}
}

func parseMountConfig(opts map[string]string) (mountConfig, error) {
	cfg := mountConfig{
		host:     strings.TrimSpace(opts["host"]),
		export:   strings.TrimSpace(opts["export"]),
		version:  strings.TrimSpace(opts["vers"]),
		readOnly: isTrue(opts["ro"]),
	}

	if cfg.host == "" || cfg.export == "" {
		return mountConfig{}, fmt.Errorf("host and export options are required")
	}

	if cfg.version == "" {
		cfg.version = "4"
	}

	return cfg, nil
}

func mountArguments(cfg mountConfig) (uintptr, string) {
	var flags uintptr
	if cfg.readOnly {
		flags |= mountFlagReadOnly
	}

	options := []string{
		fmt.Sprintf("addr=%s", cfg.host),
		fmt.Sprintf("vers=%s", cfg.version),
		"nolock", // statd is not running inside the plugin rootfs
	}

	return flags, strings.Join(options, ",")
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
