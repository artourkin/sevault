package driver

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/docker/go-plugins-helpers/volume"
)

const (
	stateRoot = "/var/lib/sevault"
	mountRoot = stateRoot + "/mounts"
)

// Backend is implemented by each storage back‑end (NFS, CIFS, …).
type Backend interface {
	Prepare(vol string, opts map[string]string) (device string, options []string, err error)
	FSType() string
}

type Driver struct {
	mu      sync.Mutex
	volumes map[string]*volumeInfo
	backend Backend
}

type volumeInfo struct {
	Name string
	Path string
}

func New(b Backend) *Driver {
	return &Driver{
		volumes: make(map[string]*volumeInfo),
		backend: b,
	}
}

// Docker Volume Driver interface methods

func (d *Driver) Create(r *volume.CreateRequest) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, ok := d.volumes[r.Name]; ok {
		return nil
	}
	path := filepath.Join(mountRoot, r.Name)
	if err := os.MkdirAll(path, 0o755); err != nil {
		return err
	}
	d.volumes[r.Name] = &volumeInfo{Name: r.Name, Path: path}
	return nil
}

func (d *Driver) Remove(r *volume.RemoveRequest) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	v, ok := d.volumes[r.Name]
	if !ok {
		return nil
	}
	_ = os.RemoveAll(v.Path)
	delete(d.volumes, r.Name)
	return nil
}

func (d *Driver) Path(r *volume.PathRequest) (*volume.PathResponse, error) {
	d.mu.Lock()
	v, ok := d.volumes[r.Name]
	d.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("volume %s not found", r.Name)
	}
	return &volume.PathResponse{Mountpoint: v.Path}, nil
}

func (d *Driver) Mount(r *volume.MountRequest) (*volume.MountResponse, error) {
	d.mu.Lock()
	v := d.volumes[r.Name]
	d.mu.Unlock()
	if v == nil {
		return nil, fmt.Errorf("unknown volume %s", r.Name)
	}
	   device, opts, err := d.backend.Prepare(r.Name, map[string]string{})
	if err != nil {
		return nil, err
	}
	mountArgs := []string{"-t", d.backend.FSType(), "-o", strings.Join(opts, ","), device, v.Path}
	if out, err := exec.Command("mount", mountArgs...).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("mount failed: %v (%s)", err, string(out))
	}
	return &volume.MountResponse{Mountpoint: v.Path}, nil
}

func (d *Driver) Unmount(r *volume.UnmountRequest) error {
	return exec.Command("umount", filepath.Join(mountRoot, r.Name)).Run()
}

func (d *Driver) Get(req *volume.GetRequest) (*volume.GetResponse, error) { /* … */ return nil, nil }
func (d *Driver) List() (*volume.ListResponse, error)                     { /* … */ return nil, nil }
func (d *Driver) Capabilities() *volume.CapabilitiesResponse {
	return &volume.CapabilitiesResponse{Capabilities: volume.Capability{Scope: "global"}}
}

func optsToString(o []string) string { return fmt.Sprintf("%s", o) } // simple joiner for options