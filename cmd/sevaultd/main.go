package main

import (
	"log"

	"github.com/artourkin/sevault/internal/backend"
	"github.com/artourkin/sevault/internal/driver"
	"github.com/docker/go-plugins-helpers/volume"
)

func main() {
	availableBackends := map[string]backend.Backend{"nfs": &backend.NFS{}}
	drv := driver.New(availableBackends)

	h := volume.NewHandler(drv)
	const sock = "sevault.sock"
	log.Printf("starting Sevault plugin at %s", sock)
	if err := h.ServeUnix(sock, 0); err != nil {
		log.Fatal(err)
	}
}