package backend

import "fmt"

type NFS struct{}

func (*NFS) FSType() string { return "nfs" }

func (*NFS) Prepare(_ string, opts map[string]string) (string, []string, error) {
	host := opts["host"]   // 192.168.1.100
	export := opts["export"] // /srv/share
	vers := opts["vers"]
	if host == "" || export == "" {
		return "", nil, fmt.Errorf("nfs backend requires host and export options")
	}
	if vers == "" {
		vers = "4"
	}
	device := fmt.Sprintf("%s:%s", host, export)
	return device, []string{fmt.Sprintf("vers=%s", vers), "soft", "timeo=30"}, nil
}