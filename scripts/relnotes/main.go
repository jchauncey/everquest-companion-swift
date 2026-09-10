// relnotes reads and writes the app's own release notes (Sources/EQCompanion/Prefs/ReleaseNotes.swift).
//
// THE NOTES ARE COMMITTED SOURCE, not a fetch: the app must be able to say what changed while
// offline, in a game session (the reasoning is in that file's header). This tool never becomes a
// dependency of that — `render` only reformats what a human wrote, and `draft` writes a first pass
// a human then edits. Nothing in the release path calls `draft`.
//
//	relnotes render <version>    the GitHub release body and the annotated tag's message
//	relnotes list                the versions the notes carry
//	relnotes draft <version>     a first pass from the commits since the last release, via claude -p
//
// `render` exits non-zero when a version has no notes, which is what makes `make tag` refuse to tag
// a release nobody has written notes for.
package main

import (
	"fmt"
	"os"
	"strings"
)

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fail("usage: relnotes render <version> | list | draft <version> [flags]")
	}
	root := repoRoot()
	src, err := readNotes(root)
	if err != nil {
		fail("%v", err)
	}
	releases := parse(src)

	switch os.Args[1] {
	case "render":
		if len(os.Args) != 3 {
			fail("usage: relnotes render <version>")
		}
		version := os.Args[2]
		md, ok := markdown(releases, version)
		if !ok {
			fail("no release notes for %s in %s\n  the file carries: %s\n"+
				"  add a ReleaseNote for %s before tagging it.",
				version, notesPath, strings.Join(versions(releases), ", "), version)
		}
		fmt.Print(md)

	case "list":
		for _, r := range releases {
			fmt.Printf("%s\t%s\t%d entries\n", r.version, r.date, len(r.entries))
		}

	case "draft":
		draft(root, src, releases, os.Args[2:])

	default:
		fail("unknown command %q — render, list or draft", os.Args[1])
	}
}
