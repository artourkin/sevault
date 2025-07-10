package backend

// Backend is implemented by each storage back-end (NFS, CIFS, …).
type Backend interface {
	Prepare(volName string, opts map[string]string) (device string, mountOptions []string, err error)
	FSType() string
}
