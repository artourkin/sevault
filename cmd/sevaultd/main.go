package main

import (
	"log"

	"github.com/artourkin/sevault/internal/driver"
	"github.com/docker/go-plugins-helpers/volume"
)

func main() {
	h := volume.NewHandler(driver.New())
	log.Println("sevault volume plugin listening on unix:///run/docker/plugins/sevault.sock")
	if err := h.ServeUnix("sevault", 0); err != nil {
		log.Fatal(err)
	}
}
