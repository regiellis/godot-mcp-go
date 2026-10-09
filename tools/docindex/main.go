// Docindex keeps a line-numbered contents block near the top of every
// agent-facing Markdown doc. Some agents read only a file's first 100 lines, so
// the block lists each section's line range for a targeted read of the rest.
//
//	go run ./tools/docindex          rewrite stale blocks
//	go run ./tools/docindex -check   exit 1 if any block is stale
package main

import (
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Docs an agent reads to use the tool: every skill file plus the install guides.
var docRoots = []string{"skills", "README.md", "INSTALL.md", "project/addons/swallowtail/README.md"}

func main() {
	check := flag.Bool("check", false, "report stale indexes without writing")
	root := flag.String("root", ".", "repository root")
	flag.Parse()

	stale, err := run(*root, !*check)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	for _, p := range stale {
		if *check {
			fmt.Println("stale:", p)
		} else {
			fmt.Println("indexed:", p)
		}
	}
	if *check && len(stale) > 0 {
		fmt.Fprintln(os.Stderr, "run: go run ./tools/docindex")
		os.Exit(1)
	}
}

// run returns the docs whose index differs from the generated one, rewriting
// them when write is set.
func run(root string, write bool) ([]string, error) {
	docs, err := listDocs(root)
	if err != nil {
		return nil, err
	}
	var stale []string
	for _, rel := range docs {
		path := filepath.Join(root, rel)
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		out := Render(string(data))
		if out == string(data) {
			continue
		}
		stale = append(stale, rel)
		if write {
			if err := os.WriteFile(path, []byte(out), 0644); err != nil {
				return nil, err
			}
		}
	}
	return stale, nil
}

func listDocs(root string) ([]string, error) {
	var docs []string
	for _, r := range docRoots {
		err := filepath.WalkDir(filepath.Join(root, r), func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !d.IsDir() && strings.EqualFold(filepath.Ext(path), ".md") {
				rel, _ := filepath.Rel(root, path)
				docs = append(docs, filepath.ToSlash(rel))
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return docs, nil
}
