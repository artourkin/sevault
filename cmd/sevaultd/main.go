package main

import (
	"log"

	"github.com/artourkin/sevault/internal/backend"
	"github.com/artourkin/sevault/internal/driver"
	"github.com/docker/go-plugins-helpers/volume"
)

func main() {
	backend := &backend.NFS{}
	drv := driver.New(backend)

	h := volume.NewHandler(drv)
	const sock = "/run/docker/plugins/sevault.sock"
	log.Printf("starting Sevault plugin at %s", sock)
	if err := h.ServeUnix("sevault", sock, 0); err != nil {
		log.Fatal(err)
	}
}