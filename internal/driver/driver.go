package driver

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/artourkin/sevault/internal/backend"
	"github.com/docker/go-plugins-helpers/volume"
)

const (
	stateRoot = "/var/lib/sevault"
	mountRoot = stateRoot + "/mounts"
)

// Backend is implemented by each storage back‑end (NFS, CIFS, …).
// This is now defined in internal/backend/backend.go, so we remove this local definition.
// type Backend interface {
// 	Prepare(vol string, opts map[string]string) (device string, options []string, err error)
// 	FSType() string
// }

type Driver struct {
	mu             sync.Mutex
	volumes        map[string]*volumeInfo
	backends       map[string]backend.Backend // Map of available backends
	mountedVolumes map[string]backend.Backend // To track backend per volume
}

type volumeInfo struct {
	Name string
	Path string
	Opts map[string]string
}

func New(b map[string]backend.Backend) *Driver {
	return &Driver{
		volumes:        make(map[string]*volumeInfo),
		backends:       b,
		mountedVolumes: make(map[string]backend.Backend),
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

	// Determine backend type
	backendType := r.Options["type"]
	if backendType == "" {
		backendType = r.Options["backend"] // Also check for "backend"
	}
	if backendType == "" {
		backendType = "nfs" // Default to NFS
		log.Printf("[Create] No backend type specified for volume %s, defaulting to NFS", r.Name)
	}

	selectedBackend, ok := d.backends[backendType]
	if !ok {
		log.Printf("[Create] Backend type %s not found for volume %s", backendType, r.Name)
		return fmt.Errorf("backend type %s not found", backendType)
	}

	path := filepath.Join(mountRoot, r.Name)
	if err := os.MkdirAll(path, 0o755); err != nil {
		log.Printf("[Create] Failed to create directory %s: %v", path, err)
		return err
	}
	d.volumes[r.Name] = &volumeInfo{Name: r.Name, Path: path, Opts: r.Options}
	d.mountedVolumes[r.Name] = selectedBackend // Store the selected backend
	log.Printf("[Create] Created volume %s at %s with backend %s and Opts[%v]", r.Name, path, backendType, r.Options)
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

	backendToUse, ok := d.mountedVolumes[r.Name]
	if !ok {
		// If not found in mountedVolumes, try to infer or default.
		// For now, default to NFS if available, otherwise error.
		log.Printf("[Mount] Backend for volume %s not found in mountedVolumes, attempting to default to NFS", r.Name)
		defaultBackend, foundNFS := d.backends["nfs"]
		if !foundNFS {
			log.Printf("[Mount] Default NFS backend not available for volume %s", r.Name)
			return nil, fmt.Errorf("default nfs backend not available for volume %s", r.Name)
		}
		backendToUse = defaultBackend
		// Optionally, store this inferred backend in mountedVolumes for future operations
		// d.mountedVolumes[r.Name] = backendToUse
	}

	device, opts, err := backendToUse.Prepare(r.Name, v.Opts)

	if err != nil {
		log.Printf("[Mount] Prepare failed for %s: %v", r.Name, err)
		return nil, err
	}
	mountArgs := []string{"-t", backendToUse.FSType(), "-o", strings.Join(opts, ","), device, v.Path}
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

func (d *Driver) Get(req *volume.GetRequest) (*volume.GetResponse, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	v, ok := d.volumes[req.Name]
	if !ok {
		log.Printf("[Get] Volume %s not found", req.Name)
		return nil, fmt.Errorf("volume %s not found", req.Name)
	}
	log.Printf("[Get] Volume %s: Mountpoint: %s, Opts: %v", req.Name, v.Path, v.Opts)
	return &volume.GetResponse{Volume: &volume.Volume{Name: req.Name, Mountpoint: v.Path, Status: v.Opts}}, nil
}

func (d *Driver) List() (*volume.ListResponse, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	var vols []*volume.Volume
	for name, v := range d.volumes {
		vols = append(vols, &volume.Volume{Name: name, Mountpoint: v.Path, Status: v.Opts})
	}
	log.Printf("[List] Listed volumes: %v", vols)
	return &volume.ListResponse{Volumes: vols}, nil
}

func (d *Driver) Capabilities() *volume.CapabilitiesResponse {
	return &volume.CapabilitiesResponse{Capabilities: volume.Capability{Scope: "global"}}
}

// func optsToString(o []string) string { return fmt.Sprintf("%s", o) } // This function is not used.