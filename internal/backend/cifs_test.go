package backend

import (
	"slices"
	"testing"
)

func TestCIFSPrepareWithHostAndShare(t *testing.T) {
	b := &CIFS{}
	device, opts, err := b.Prepare("vol", map[string]string{
		"host":     "nas.local",
		"share":    "data",
		"username": "user",
		"password": "secret",
		"domain":   "WORK",
		"vers":     "3.1.1",
		"uid":      "1000",
		"options":  "nounix,noserverino",
	})
	if err != nil {
		t.Fatalf("Prepare returned unexpected error: %v", err)
	}
	if device != "//nas.local/data" {
		t.Fatalf("unexpected device: %s", device)
	}

	expected := []string{
		"username=user",
		"password=secret",
		"domain=WORK",
		"vers=3.1.1",
		"rw",
		"uid=1000",
		"nounix",
		"noserverino",
	}
	if !slices.Equal(opts, expected) {
		t.Fatalf("unexpected mount options\nexpected: %v\ngot:      %v", expected, opts)
	}
}

func TestCIFSPrepareWithUNC(t *testing.T) {
	b := &CIFS{}
	device, opts, err := b.Prepare("vol", map[string]string{
		"export": "//nas.local/share",
		"ro":     "true",
	})
	if err != nil {
		t.Fatalf("Prepare returned unexpected error: %v", err)
	}
	if device != "//nas.local/share" {
		t.Fatalf("unexpected device: %s", device)
	}

	expected := []string{
		"guest",
		"vers=3.0",
		"ro",
	}
	if !slices.Equal(opts, expected) {
		t.Fatalf("unexpected mount options\nexpected: %v\ngot:      %v", expected, opts)
	}
}

func TestCIFSPrepareValidation(t *testing.T) {
	b := &CIFS{}
	_, _, err := b.Prepare("vol", map[string]string{
		"host": "nas.local",
	})
	if err == nil {
		t.Fatal("expected error when share/export is missing")
	}
}
