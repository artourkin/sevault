package backend

import (
	"fmt"
	"strings"
)

type CIFS struct{}

func (*CIFS) FSType() string { return "cifs" }

func (*CIFS) Prepare(_ string, opts map[string]string) (string, []string, error) {
	share := firstNonEmpty(opts["share"], opts["export"])
	host := strings.TrimSpace(opts["host"])

	if share == "" {
		return "", nil, fmt.Errorf("cifs backend requires share or export option")
	}

	device, err := buildDevice(host, share)
	if err != nil {
		return "", nil, err
	}

	var options []string

	username := firstNonEmpty(opts["username"], opts["user"])
	password := firstNonEmpty(opts["password"], opts["pass"])
	domain := strings.TrimSpace(opts["domain"])
	vers := strings.TrimSpace(opts["vers"])
	sec := strings.TrimSpace(opts["sec"])

	if username != "" {
		options = append(options, fmt.Sprintf("username=%s", username))
	} else if !containsGuestHint(opts["options"]) {
		options = append(options, "guest")
	}

	if password != "" {
		options = append(options, fmt.Sprintf("password=%s", password))
	}

	if domain != "" {
		options = append(options, fmt.Sprintf("domain=%s", domain))
	}

	if vers != "" {
		options = append(options, fmt.Sprintf("vers=%s", vers))
	} else {
		options = append(options, "vers=3.0")
	}

	if sec != "" {
		options = append(options, fmt.Sprintf("sec=%s", sec))
	}

	if isTrue(opts["ro"]) {
		options = append(options, "ro")
	} else if !flagPresent(opts["options"], "ro") && !flagPresent(opts["options"], "rw") {
		options = append(options, "rw")
	}

	for _, key := range []string{"uid", "gid", "file_mode", "dir_mode"} {
		if val := strings.TrimSpace(opts[key]); val != "" {
			options = append(options, fmt.Sprintf("%s=%s", key, val))
		}
	}

	if extra := strings.TrimSpace(opts["options"]); extra != "" {
		for _, part := range strings.Split(extra, ",") {
			if trimmed := strings.TrimSpace(part); trimmed != "" {
				options = append(options, trimmed)
			}
		}
	}

	return device, options, nil
}

func buildDevice(host, share string) (string, error) {
	trimmedShare := strings.TrimSpace(share)
	if strings.HasPrefix(trimmedShare, "//") {
		if strings.Count(trimmedShare, "/") < 3 {
			return "", fmt.Errorf("cifs export must include share name: %s", trimmedShare)
		}
		return trimmedShare, nil
	}

	if host == "" {
		return "", fmt.Errorf("cifs backend requires host when share is not an UNC path")
	}

	cleanShare := strings.TrimPrefix(trimmedShare, "/")
	if cleanShare == "" {
		return "", fmt.Errorf("cifs export cannot be empty")
	}

	return fmt.Sprintf("//%s/%s", host, cleanShare), nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if value := strings.TrimSpace(v); value != "" {
			return value
		}
	}
	return ""
}

func isTrue(val string) bool {
	switch strings.ToLower(strings.TrimSpace(val)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func containsGuestHint(extra string) bool {
	lower := strings.ToLower(extra)
	if strings.Contains(lower, "credentials=") {
		return true
	}
	for _, part := range strings.Split(lower, ",") {
		if strings.TrimSpace(part) == "guest" {
			return true
		}
	}
	return false
}

func flagPresent(extra, flag string) bool {
	flag = strings.ToLower(flag)
	for _, part := range strings.Split(strings.ToLower(extra), ",") {
		if strings.TrimSpace(part) == flag {
			return true
		}
	}
	return false
}
