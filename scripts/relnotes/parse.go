package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// The app's own committed notes, relative to the repository root. ONE SOURCE: the app shows these
// under Preferences -> What's new while offline, and the GitHub release body is generated from the
// same array, so the two can never drift apart.
const notesPath = "Sources/EQCompanion/Prefs/ReleaseNotes.swift"

type entry struct{ kind, text string }

type release struct {
	version string
	date    string
	entries []entry
}

var (
	// One `ReleaseNote(version: "x", date: "y", entries: [ ... ])`. The entries run to the closing
	// `])`, which the file always puts on its own line.
	reBlock = regexp.MustCompile(`(?s)ReleaseNote\(version:\s*"([^"]+)",\s*date:\s*"([^"]+)",\s*entries:\s*\[(.*?)\n\s*\]\)`)
	// `ReleaseEntry(.new, "text")` — the text may carry escaped quotes.
	reEntry = regexp.MustCompile(`ReleaseEntry\(\.(\w+),\s*"((?:[^"\\]|\\.)*)"\s*\)`)
)

var kindOrder = []string{"new", "fixed", "changed"}
var kindLabel = map[string]string{"new": "New", "fixed": "Fixed", "changed": "Changed"}

// repoRoot is where the notes live. Asking git rather than walking up from the binary keeps this
// honest whether it runs from .build/, from `go run`, or from a checkout somebody moved.
func repoRoot() string {
	if out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output(); err == nil {
		if p := strings.TrimSpace(string(out)); p != "" {
			return p
		}
	}
	wd, _ := os.Getwd()
	return wd
}

func readNotes(root string) (string, error) {
	b, err := os.ReadFile(filepath.Join(root, notesPath))
	if err != nil {
		return "", fmt.Errorf("cannot read %s: %w", notesPath, err)
	}
	return string(b), nil
}

// parse returns every release in the file, newest first — the order the file is written in and the
// order the panel renders.
func parse(src string) []release {
	var out []release
	for _, m := range reBlock.FindAllStringSubmatch(src, -1) {
		r := release{version: m[1], date: m[2]}
		for _, e := range reEntry.FindAllStringSubmatch(m[3], -1) {
			text := strings.ReplaceAll(e[2], `\"`, `"`)
			text = strings.ReplaceAll(text, `\\`, `\`)
			r.entries = append(r.entries, entry{kind: e[1], text: text})
		}
		out = append(out, r)
	}
	return out
}

func versions(rs []release) []string {
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		out = append(out, r.version)
	}
	return out
}

// markdown is one release as the GitHub release body and the annotated tag's message.
func markdown(rs []release, version string) (string, bool) {
	for _, r := range rs {
		if r.version != version {
			continue
		}
		lines := []string{"_" + r.date + "_", ""}
		for _, kind := range kindOrder {
			var rows []string
			for _, e := range r.entries {
				if e.kind == kind {
					rows = append(rows, "- "+e.text)
				}
			}
			if len(rows) == 0 {
				continue
			}
			lines = append(lines, "### "+kindLabel[kind])
			lines = append(lines, rows...)
			lines = append(lines, "")
		}
		return strings.TrimRight(strings.Join(lines, "\n"), "\n") + "\n", true
	}
	return "", false
}
