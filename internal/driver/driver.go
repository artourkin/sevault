package driver

import (
	"fmt"
	"log"
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
		log.Printf("[Create] Volume %s already exists", r.Name)
		return nil
	}
	path := filepath.Join(mountRoot, r.Name)
	if err := os.MkdirAll(path, 0o755); err != nil {
		log.Printf("[Create] Failed to create directory %s: %v", path, err)
		return err
	}
	d.volumes[r.Name] = &volumeInfo{Name: r.Name, Path: path}
	log.Printf("[Create] Created volume %s at %s", r.Name, path)
	return nil
}

func (d *Driver) Remove(r *volume.RemoveRequest) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	v, ok := d.volumes[r.Name]
	if !ok {
		log.Printf("[Remove] Volume %s not found", r.Name)
		return nil
	}
	_ = os.RemoveAll(v.Path)
	delete(d.volumes, r.Name)
	log.Printf("[Remove] Removed volume %s", r.Name)
	return nil
}

func (d *Driver) Path(r *volume.PathRequest) (*volume.PathResponse, error) {
	d.mu.Lock()
	v, ok := d.volumes[r.Name]
	d.mu.Unlock()
	if !ok {
		log.Printf("[Path] Volume %s not found", r.Name)
		return nil, fmt.Errorf("volume %s not found", r.Name)
	}
	log.Printf("[Path] Volume %s mountpoint: %s", r.Name, v.Path)
	return &volume.PathResponse{Mountpoint: v.Path}, nil
}

func (d *Driver) Mount(r *volume.MountRequest) (*volume.MountResponse, error) {
	d.mu.Lock()
	v := d.volumes[r.Name]
	d.mu.Unlock()
	if v == nil {
		log.Printf("[Mount] Unknown volume %s", r.Name)
		return nil, fmt.Errorf("unknown volume %s", r.Name)
	}
	device, opts, err := d.backend.Prepare(r.Name, map[string]string{})
	if err != nil {
		log.Printf("[Mount] Prepare failed for %s: %v", r.Name, err)
		return nil, err
	}
	mountArgs := []string{"-t", d.backend.FSType(), "-o", strings.Join(opts, ","), device, v.Path}
	log.Printf("[Mount] Running: mount %s", strings.Join(mountArgs, " "))
	if out, err := exec.Command("mount", mountArgs...).CombinedOutput(); err != nil {
		log.Printf("[Mount] mount failed: %v (%s)", err, string(out))
		return nil, fmt.Errorf("mount failed: %v (%s)", err, string(out))
	}
	log.Printf("[Mount] Mounted %s at %s", r.Name, v.Path)
	return &volume.MountResponse{Mountpoint: v.Path}, nil
}

func (d *Driver) Unmount(r *volume.UnmountRequest) error {
	mountPath := filepath.Join(mountRoot, r.Name)
	log.Printf("[Unmount] Unmounting %s", mountPath)
	err := exec.Command("umount", mountPath).Run()
	if err != nil {
		log.Printf("[Unmount] Failed to unmount %s: %v", mountPath, err)
	} else {
		log.Printf("[Unmount] Unmounted %s", mountPath)
	}
	return err
}

func (d *Driver) Get(req *volume.GetRequest) (*volume.GetResponse, error) { /* … */ return nil, nil }
func (d *Driver) List() (*volume.ListResponse, error)                     { /* … */ return nil, nil }
func (d *Driver) Capabilities() *volume.CapabilitiesResponse {
	return &volume.CapabilitiesResponse{Capabilities: volume.Capability{Scope: "global"}}
}

func optsToString(o []string) string { return fmt.Sprintf("%s", o) } // simple joiner for options