package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Draft one release's notes with `claude -p`, from the commits since the last release.
//
// A DRAFT, NOT THE NOTES. `make tag` never calls this: the notes ship inside the build, so they
// must not depend on a CLI, a network or a model being in the mood. This writes a first pass a
// human then edits — the commit log knows what changed, but only a person knows which of it a
// player would care about, and the voice rules exist because the log's own words (module names,
// wave names, ticket ids) are exactly what the notes must not say.
//
// The voice rules are not restated here. They are read out of the header of ReleaseNotes.swift, so
// there is one copy of them and editing that file is what changes what this asks for.
//
// REDRAFTING is the normal case, not the exception: the first pass is the one you read to find out
// what you actually want said. --redraft replaces the block, keeps the date the release already
// claims, saves what it replaced under .build/ so a hand-edit is never lost to a re-roll, and takes
// --note to steer the next pass. It refuses once the version is tagged, because those words shipped
// inside that build and the app cannot be sent a correction.

const anchor = "    static let all: [ReleaseNote] = [\n"

var (
	// One entry, exactly as the file spells them: 12 spaces, a known kind, and a Swift string whose
	// only escapes are \" and \\. Anything else — a smart quote, a newline, an interpolation — is a
	// draft that would not compile, and is refused rather than pasted into the source.
	reEntryLine = regexp.MustCompile(`^            ReleaseEntry\(\.(new|fixed|changed), "(?:[^"\\\n]|\\"|\\\\)*"\),?$`)
	reHeadLine  = regexp.MustCompile(`^ReleaseNote\(version: "([0-9.]+)", date: "\d{4}-\d{2}-\d{2}", entries: \[$`)
	reFence     = regexp.MustCompile("(?m)^\\s*```[a-z]*\\s*$")
	reShape     = regexp.MustCompile(`(?sm)^        ReleaseNote\(version:.*?^        \]\),$`)
)

func git(root string, args ...string) string {
	out, err := exec.Command("git", append([]string{"-C", root}, args...)...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// existingBlock is the block already in the file for this version, and the date it claims.
func existingBlock(src, version string) (block, date string) {
	re := regexp.MustCompile(`(?sm)^        ReleaseNote\(version: "` + regexp.QuoteMeta(version) +
		`", date: "(\d{4}-\d{2}-\d{2})".*?^        \]\),\n`)
	m := re.FindStringSubmatch(src)
	if m == nil {
		return "", ""
	}
	return m[0], m[1]
}

// defaultSince is where the release BEFORE this one ended: its tag if one exists, else the commit
// that set VERSION. The version being drafted is skipped — a redraft covers the same commits as the
// draft it replaces, not the empty range between itself and HEAD.
func defaultSince(root string, releases []release, version string) string {
	for _, r := range releases {
		if r.version == version {
			continue
		}
		if tag := "v" + r.version; git(root, "rev-parse", "-q", "--verify", "refs/tags/"+tag) != "" {
			return tag
		}
		break
	}
	if bump := git(root, "log", "--format=%H", "-1", "--", "VERSION"); bump != "" {
		return bump
	}
	return git(root, "rev-list", "--max-parents=0", "HEAD")
}

// voiceRules is the leading comment block of ReleaseNotes.swift — the one statement of how notes
// are written, quoted to the model rather than paraphrased.
func voiceRules(src string) string {
	var lines []string
	for _, line := range strings.Split(src, "\n") {
		if !strings.HasPrefix(line, "//") {
			break
		}
		lines = append(lines, strings.TrimRight(strings.TrimLeft(line, "/ "), " "))
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func buildPrompt(root, src, version, since, date, note, replacing string) string {
	log := git(root, "log", "--reverse", "--format=%s%n%b%n---", since+"..HEAD")
	if log == "" {
		fail("no commits between %s and HEAD — nothing to draft", since)
	}
	var steer strings.Builder
	if replacing != "" {
		steer.WriteString("\nA draft of these notes already exists and is being replaced. Here it is." +
			"\nDo not reproduce it — it is what somebody read and did not want:\n\n" + replacing)
	}
	if note != "" {
		steer.WriteString("\nWhat to do differently this time, which overrides your own judgement" +
			" where the two disagree: " + note + "\n")
	}
	shape := reShape.FindString(src)

	return fmt.Sprintf(`You are writing the release notes for version %s of EQ Companion, a macOS
companion app for EverQuest, dated %s.

These are the rules the notes are written by. They are the header of the file the notes live in,
and they are binding:

%s

Here is the shape of the answer — the previous release, exactly as it is written in that file:

%s

Here are the commits since the last release, oldest first, subject then body, separated by ---.
They are the raw material and they are written for developers: translate them. Several commits are
often one thing a player would notice; say the thing, once, and drop anything a player would never
see (tests, refactors, CI, docs, internal naming).

%s
%s
Answer with the Swift block for %s and nothing else: no markdown fences, no commentary.
Start with `+"`"+`        ReleaseNote(version: "%s", date: "%s", entries: [`+"`"+` and end with
`+"`"+`        ]),`+"`"+`. Indent each ReleaseEntry by 12 spaces. Inside the strings use only plain ASCII
quotes escaped as \" and plain hyphens, never a smart quote, and never a backslash otherwise.`,
		version, date, voiceRules(src), shape, log, steer.String(), version, version, date)
}

func askClaude(prompt, model string) string {
	if _, err := exec.LookPath("claude"); err != nil {
		fail("claude CLI not found — this command drafts notes with `claude -p`")
	}
	args := []string{"-p"}
	if model != "" {
		args = append(args, "--model", model)
	}
	cmd := exec.Command("claude", args...)
	cmd.Stdin = strings.NewReader(prompt)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		fail("claude -p failed (%v):\n%s", err, strings.TrimSpace(errb.String()))
	}
	return out.String()
}

// clean strips anything around the block and proves it is the block we asked for.
func clean(out, version, date string) (string, error) {
	lines := strings.Split(reFence.ReplaceAllString(out, ""), "\n")
	for i := range lines {
		lines[i] = strings.TrimRight(lines[i], " \t\r")
	}
	start, end := -1, -1
	for i, l := range lines {
		if strings.HasPrefix(strings.TrimSpace(l), "ReleaseNote(version:") {
			start = i
			break
		}
	}
	if start < 0 {
		return "", fmt.Errorf("the answer contains no ReleaseNote block")
	}
	for i := len(lines) - 1; i > start; i-- {
		if strings.TrimSpace(lines[i]) == "])," {
			end = i
			break
		}
	}
	if end < 0 {
		return "", fmt.Errorf("the block is not closed")
	}
	head := reHeadLine.FindStringSubmatch(strings.TrimSpace(lines[start]))
	if head == nil {
		return "", fmt.Errorf("the block's first line is not a ReleaseNote header: %q", strings.TrimSpace(lines[start]))
	}
	if head[1] != version {
		return "", fmt.Errorf("the block is for %s, not %s", head[1], version)
	}
	body := lines[start+1 : end]
	if len(body) == 0 {
		return "", fmt.Errorf("the block has no entries")
	}
	for _, l := range body {
		if !reEntryLine.MatchString(l) {
			return "", fmt.Errorf("not a well-formed entry line: %q", strings.TrimSpace(l))
		}
	}
	// The header is ours, not the model's: a redraft keeps the date the release already claims.
	block := []string{fmt.Sprintf(`        ReleaseNote(version: %q, date: %q, entries: [`, version, date)}
	block = append(block, body...)
	block = append(block, "        ]),")
	return strings.Join(block, "\n") + "\n", nil
}

func draft(root, src string, releases []release, argv []string) {
	fs := flag.NewFlagSet("draft", flag.ExitOnError)
	redraft := fs.Bool("redraft", false, "replace the notes this version already has (keeping their date)")
	note := fs.String("note", "", "how this pass should differ, e.g. 'shorter, lead with search'")
	since := fs.String("since", "", "ref the previous release ended at (default: its tag, or the VERSION bump)")
	model := fs.String("model", "", "model for claude -p")
	dryRun := fs.Bool("dry-run", false, "print the draft instead of inserting it")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: relnotes draft <version> [flags]")
		fs.PrintDefaults()
	}
	if len(argv) == 0 || strings.HasPrefix(argv[0], "-") {
		fs.Usage()
		os.Exit(1)
	}
	version := argv[0]
	fs.Parse(argv[1:])

	old, oldDate := existingBlock(src, version)
	switch {
	case old != "" && !*redraft:
		fail("%s already has notes — pass --redraft to replace them, or edit them by hand", version)
	case old == "" && *redraft:
		fail("%s has no notes to redraft — drop --redraft to write them", version)
	case old != "" && git(root, "rev-parse", "-q", "--verify", "refs/tags/v"+version) != "":
		fail("v%s is tagged — those words shipped inside that build and every copy of it will keep\n"+
			"showing them. Edit by hand if the GitHub body needs a correction.", version)
	}

	date := oldDate
	if date == "" {
		date = time.Now().Format("2006-01-02")
	}
	from := *since
	if from == "" {
		from = defaultSince(root, releases, version)
	}
	verb := "drafting"
	if old != "" {
		verb = "redrafting"
	}
	fmt.Fprintf(os.Stderr, "%s %s from %s..HEAD\n", verb, version, from)

	replacing := ""
	if *redraft {
		replacing = old
	}
	block, err := clean(askClaude(buildPrompt(root, src, version, from, date, *note, replacing), *model), version, date)
	if err != nil {
		fail("the draft came back unusable: %v", err)
	}
	if *dryRun {
		fmt.Print(block)
		return
	}

	if old != "" {
		// What it replaced, kept: a redraft must never be the thing that loses an edit somebody made
		// by hand. .build/ is git-ignored and survives until `make clean`.
		os.MkdirAll(filepath.Join(root, ".build"), 0o755)
		kept := filepath.Join(root, ".build", "release-notes-"+version+".previous.swift")
		if err := os.WriteFile(kept, []byte(old), 0o644); err != nil {
			fail("cannot save what is being replaced: %v", err)
		}
		src = strings.Replace(src, old, block, 1)
		fmt.Fprintf(os.Stderr, "replaced — what was there is in %s\n", ".build/release-notes-"+version+".previous.swift")
	} else {
		src = strings.Replace(src, anchor, anchor+block, 1)
	}
	if err := os.WriteFile(filepath.Join(root, notesPath), []byte(src), 0o644); err != nil {
		fail("cannot write %s: %v", notesPath, err)
	}
	fmt.Fprintf(os.Stderr, "drafted %s into %s — READ IT AND EDIT IT.\n"+
		"then: swift test --filter EQCompanionTests.ReleaseNotesTests, commit the notes (make tag refuses a dirty tree -\n"+
		"      they ship inside the build), and make tag V=%s\n",
		version, notesPath, version)
}
