package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	defaultAddr       = ":8080"
	defaultPluginName = "sevault"
	requestTimeout    = 10 * time.Second
)

type volumeInfo struct {
	Name       string            `json:"name"`
	Driver     string            `json:"driver"`
	Mountpoint string            `json:"mountpoint"`
	Status     map[string]string `json:"status"`
}

func main() {
	addr := envOr("WEBUI_ADDR", defaultAddr)
	pluginName := envOr("PLUGIN_NAME", defaultPluginName)

	mux := http.NewServeMux()
	mux.HandleFunc("/", serveIndex(pluginName))
	mux.HandleFunc("/api/volumes", volumesHandler(pluginName))
	mux.HandleFunc("/api/volumes/", volumeHandler(pluginName))

	log.Printf("Sevault WebUI listening on %s (plugin=%s)", addr, pluginName)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("webui server error: %v", err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func serveIndex(pluginName string) http.HandlerFunc {
	tmpl := template.Must(template.New("index").Parse(indexHTML))
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		if err := tmpl.Execute(w, map[string]string{"Plugin": pluginName}); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	}
}

func volumesHandler(pluginName string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			listVolumes(w, pluginName)
		case http.MethodPost:
			createVolume(w, r, pluginName)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	}
}

func volumeHandler(pluginName string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		name := strings.TrimPrefix(r.URL.Path, "/api/volumes/")
		if name == "" {
			http.Error(w, "missing volume name", http.StatusBadRequest)
			return
		}
		if err := dockerVolumeRm(name); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func listVolumes(w http.ResponseWriter, pluginName string) {
	names, err := dockerVolumeNames(pluginName)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	var vols []volumeInfo
	for _, name := range names {
		info, err := dockerVolumeInspect(name)
		if err != nil {
			http.Error(w, fmt.Sprintf("inspect %s: %v", name, err), http.StatusBadGateway)
			return
		}
		vols = append(vols, info)
	}
	writeJSON(w, vols)
}

type createRequest struct {
	Name     string `json:"name"`
	Host     string `json:"host"`
	Export   string `json:"export"`
	Vers     string `json:"vers"`
	ReadOnly bool   `json:"ro"`
	Options  string `json:"options"`
}

func createVolume(w http.ResponseWriter, r *http.Request, pluginName string) {
	var req createRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}
	if req.Name == "" || req.Host == "" || req.Export == "" {
		http.Error(w, "name, host, and export are required", http.StatusBadRequest)
		return
	}

	args := []string{"volume", "create", "-d", pluginName, "--name", req.Name, "-o", "host=" + req.Host, "-o", "export=" + req.Export}
	if req.Vers != "" {
		args = append(args, "-o", "vers="+req.Vers)
	}
	if req.ReadOnly {
		args = append(args, "-o", "ro=true")
	}
	if strings.TrimSpace(req.Options) != "" {
		args = append(args, "-o", "options="+strings.TrimSpace(req.Options))
	}

	if err := runDocker(args...); err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	info, err := dockerVolumeInspect(req.Name)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, info)
}

func dockerVolumeNames(pluginName string) ([]string, error) {
	out, err := runDockerOutput("volume", "ls", "--filter", "driver="+pluginName, "--format", "{{.Name}}")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		names = append(names, strings.TrimSpace(line))
	}
	return names, nil
}

func dockerVolumeInspect(name string) (volumeInfo, error) {
	out, err := runDockerOutput("volume", "inspect", name)
	if err != nil {
		return volumeInfo{}, err
	}
	var arr []struct {
		Name       string                 `json:"Name"`
		Driver     string                 `json:"Driver"`
		Mountpoint string                 `json:"Mountpoint"`
		Status     map[string]interface{} `json:"Status"`
	}
	if err := json.Unmarshal([]byte(out), &arr); err != nil {
		return volumeInfo{}, err
	}
	if len(arr) == 0 {
		return volumeInfo{}, fmt.Errorf("inspect returned no data for %s", name)
	}
	status := make(map[string]string)
	for k, v := range arr[0].Status {
		status[k] = fmt.Sprint(v)
	}
	return volumeInfo{
		Name:       arr[0].Name,
		Driver:     arr[0].Driver,
		Mountpoint: arr[0].Mountpoint,
		Status:     status,
	}, nil
}

func dockerVolumeRm(name string) error {
	return runDocker("volume", "rm", name)
}

func runDocker(args ...string) error {
	_, err := runDockerOutput(args...)
	return err
}

func runDockerOutput(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.Env = os.Environ()
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("docker %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

const indexHTML = `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Sevault NFS Volumes</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 24px; background: #0f172a; color: #e2e8f0; }
    h1 { margin-top: 0; }
    .card { background: #111827; padding: 16px; border-radius: 8px; margin-bottom: 16px; border: 1px solid #1f2937; }
    input, button, select { padding: 8px; border-radius: 4px; border: 1px solid #374151; background: #0b1221; color: #e2e8f0; }
    button { cursor: pointer; background: #2563eb; border: none; color: white; }
    table { width: 100%; border-collapse: collapse; margin-top: 12px; }
    th, td { padding: 8px; border-bottom: 1px solid #1f2937; text-align: left; }
    .muted { color: #9ca3af; }
  </style>
</head>
<body>
  <h1>Sevault Volumes (plugin: {{.Plugin}})</h1>

  <div class="card">
    <h3>Create Volume</h3>
    <form id="create-form">
      <div style="display:flex; gap:8px; flex-wrap: wrap;">
        <input name="name" placeholder="volume name" required>
        <input name="host" placeholder="NFS host" required>
        <input name="export" placeholder="export path (/exports)" required>
        <input name="vers" placeholder="vers (default 3)">
        <input name="options" placeholder="extra options (comma separated)">
        <label><input type="checkbox" name="ro"> read-only</label>
        <button type="submit">Create</button>
      </div>
    </form>
    <div id="message" class="muted" style="margin-top:8px;"></div>
  </div>

  <div class="card">
    <h3>Volumes</h3>
    <table id="vol-table">
      <thead><tr><th>Name</th><th>Host</th><th>Export</th><th>Mountpoint</th><th></th></tr></thead>
      <tbody></tbody>
    </table>
  </div>

<script>
async function fetchJSON(url, options) {
  const res = await fetch(url, options);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || res.statusText);
  }
  return res.json();
}

async function loadVolumes() {
  const tbody = document.querySelector("#vol-table tbody");
  tbody.innerHTML = "";
  try {
    const vols = await fetchJSON("/api/volumes");
    vols.forEach(v => {
      const host = (v.status && v.status.host) || "";
      const exp = (v.status && v.status.export) || "";
      const tr = document.createElement("tr");
      tr.innerHTML = "<td>" + v.name + "</td><td>" + host + "</td><td>" + exp + "</td><td class=\\\"muted\\\">" + v.mountpoint + "</td><td><button data-name=\\\"" + v.name + "\\\">Delete</button></td>";
      tr.querySelector("button").onclick = () => deleteVolume(v.name);
      tbody.appendChild(tr);
    });
  } catch (err) {
    setMessage(err.message);
  }
}

async function deleteVolume(name) {
  if (!confirm("Delete volume " + name + "?")) return;
  try {
    await fetch("/api/volumes/" + encodeURIComponent(name), {method:"DELETE"});
    loadVolumes();
  } catch (err) {
    setMessage(err.message);
  }
}

document.getElementById("create-form").onsubmit = async (e) => {
  e.preventDefault();
  const fd = new FormData(e.target);
  const body = {
    name: fd.get("name"),
    host: fd.get("host"),
    export: fd.get("export"),
    vers: fd.get("vers"),
    options: fd.get("options"),
    ro: fd.get("ro") === "on",
  };
  try {
    await fetchJSON("/api/volumes", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(body),
    });
    setMessage("Volume created");
    e.target.reset();
    loadVolumes();
  } catch (err) {
    setMessage(err.message);
  }
};

function setMessage(msg) {
  document.getElementById("message").textContent = msg;
}

loadVolumes();
</script>
</body>
</html>
`
