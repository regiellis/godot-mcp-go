package main

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// writeFileAtomic writes data to a temporary file in the target's directory
// and renames it into place, so a reader never sees a half-written file and a
// failed write leaves any previous file intact.
func writeFileAtomic(path string, data []byte) error {
	dir, base := filepath.Split(path)
	if dir == "" {
		dir = "."
	}
	tmp, err := os.CreateTemp(dir, "."+base+".tmp-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	_, err = tmp.Write(data)
	if err == nil {
		err = tmp.Sync()
	}
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Chmod(name, 0o644)
	}
	if err == nil {
		err = os.Rename(name, path)
	}
	if err != nil {
		_ = os.Remove(name)
	}
	return err
}

// automationOutputs carries the --report and --junit destinations of one run.
type automationOutputs struct {
	reportPath, junitPath string
	suiteClass            string
	started               time.Time
}

// write saves both requested files, reporting each failure on stderr as an
// output error. It returns false when any file could not be written.
func (o automationOutputs) write(report automationReport) bool {
	ok := true
	fail := func(path string, err error) {
		emitCLIError("output", fmt.Sprintf("could not write %s: %v", path, err), map[string]any{"path": path})
		ok = false
	}
	if o.reportPath != "" {
		doc, err := encodeAutomationReport(report)
		if err == nil {
			err = writeFileAtomic(o.reportPath, doc)
		}
		if err != nil {
			fail(o.reportPath, err)
		}
	}
	if o.junitPath != "" {
		doc, err := automationJUnit(report, o.suiteClass, o.started, time.Since(o.started))
		if err == nil {
			err = writeFileAtomic(o.junitPath, doc)
		}
		if err != nil {
			fail(o.junitPath, err)
		}
	}
	return ok
}

type junitSuites struct {
	XMLName  xml.Name     `xml:"testsuites"`
	Name     string       `xml:"name,attr"`
	Tests    int          `xml:"tests,attr"`
	Failures int          `xml:"failures,attr"`
	Errors   int          `xml:"errors,attr"`
	Skipped  int          `xml:"skipped,attr"`
	Time     string       `xml:"time,attr"`
	Suites   []junitSuite `xml:"testsuite"`
}

type junitSuite struct {
	Name       string          `xml:"name,attr"`
	Tests      int             `xml:"tests,attr"`
	Failures   int             `xml:"failures,attr"`
	Errors     int             `xml:"errors,attr"`
	Skipped    int             `xml:"skipped,attr"`
	Time       string          `xml:"time,attr"`
	Timestamp  string          `xml:"timestamp,attr"`
	Properties []junitProperty `xml:"properties>property,omitempty"`
	Cases      []junitCase     `xml:"testcase"`
	SystemErr  string          `xml:"system-err,omitempty"`
}

type junitProperty struct {
	Name  string `xml:"name,attr"`
	Value string `xml:"value,attr"`
}

type junitCase struct {
	Name      string        `xml:"name,attr"`
	Classname string        `xml:"classname,attr"`
	Time      string        `xml:"time,attr"`
	Failure   *junitProblem `xml:"failure,omitempty"`
	Error     *junitProblem `xml:"error,omitempty"`
	Skipped   *junitSkipped `xml:"skipped,omitempty"`
	SystemOut string        `xml:"system-out,omitempty"`
}

type junitProblem struct {
	Message string `xml:"message,attr"`
	Type    string `xml:"type,attr"`
	Body    string `xml:",chardata"`
}

type junitSkipped struct {
	Message string `xml:"message,attr,omitempty"`
}

func junitSeconds(d time.Duration) string {
	return strconv.FormatFloat(d.Seconds(), 'f', 3, 64)
}

// automationJUnit renders a report as one test suite with a test case per
// step. Assertion failures map to <failure>; every other error kind maps to
// <error>. A plan-level error (preflight, setup, cancellation between steps)
// adds a "plan" test case so CI dashboards show it, plus a suite system-err.
func automationJUnit(report automationReport, class string, started time.Time, elapsed time.Duration) ([]byte, error) {
	suite := junitSuite{
		Name:       "swallowtail.automate",
		Time:       junitSeconds(elapsed),
		Timestamp:  started.UTC().Format(time.RFC3339),
		Properties: []junitProperty{{Name: "dry_run", Value: strconv.FormatBool(report.DryRun)}, {Name: "ok", Value: strconv.FormatBool(report.OK)}},
	}
	width := len(strconv.Itoa(max(len(report.Steps)-1, 0)))
	width = max(width, 2)
	for _, step := range report.Steps {
		c := junitCase{
			Name:      fmt.Sprintf("%0*d %s", width, step.Index, step.Method),
			Classname: class,
			Time:      junitSeconds(time.Duration(step.DurationMS) * time.Millisecond),
		}
		switch step.Status {
		case "skipped":
			reason := step.SkipReason
			if reason == "" {
				reason = "not run: the plan stopped before this step"
			}
			c.Skipped = &junitSkipped{Message: reason}
			suite.Skipped++
		case "validated":
			c.SystemOut = "validated by dry run; not executed"
		case "failed":
			problem := &junitProblem{Message: "step failed", Type: "error"}
			if step.Error != nil {
				problem.Message, problem.Type = step.Error.Message, step.Error.Kind
				problem.Body = junitDetail(step.Error, step.FailedAssertions)
			}
			if problem.Type == "assertion" {
				c.Failure = problem
				suite.Failures++
			} else {
				c.Error = problem
				suite.Errors++
			}
		}
		if step.Attempts > 0 && c.SystemOut == "" {
			c.SystemOut = fmt.Sprintf("wait_until attempts: %d", step.Attempts)
		}
		suite.Cases = append(suite.Cases, c)
	}
	if report.Error != nil {
		suite.Cases = append(suite.Cases, junitCase{
			Name:      "plan",
			Classname: class,
			Time:      "0.000",
			Error:     &junitProblem{Message: report.Error.Message, Type: report.Error.Kind, Body: junitDetail(report.Error, nil)},
		})
		suite.Errors++
		suite.SystemErr = report.Error.Kind + ": " + report.Error.Message
	}
	suite.Tests = len(suite.Cases)
	doc := junitSuites{Name: suite.Name, Tests: suite.Tests, Failures: suite.Failures, Errors: suite.Errors, Skipped: suite.Skipped, Time: suite.Time, Suites: []junitSuite{suite}}
	body, err := xml.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, err
	}
	return append([]byte(xml.Header), append(body, '\n')...), nil
}

// junitDetail is the readable body of a failure: the message, then the
// failed assertions and error data as indented JSON.
func junitDetail(e *automationError, failures []automationAssertionFailure) string {
	detail := map[string]any{"kind": e.Kind, "message": e.Message}
	if e.Data != nil {
		detail["data"] = e.Data
	}
	if len(failures) > 0 {
		detail["failed_assertions"] = failures
	}
	b, err := json.MarshalIndent(detail, "", "  ")
	if err != nil {
		return e.Message
	}
	return string(b)
}

// checkAutomationOutputs refuses report paths that cannot be written before
// the plan runs, so a long run does not end on a missing directory.
func checkAutomationOutputs(paths ...string) error {
	seen := map[string]string{}
	for _, path := range paths {
		if path == "" {
			continue
		}
		abs, err := filepath.Abs(path)
		if err != nil {
			return err
		}
		key := abs
		if runtime.GOOS != "linux" {
			// Windows and macOS file systems usually ignore case.
			key = strings.ToLower(abs)
		}
		if other, ok := seen[key]; ok {
			return fmt.Errorf("--report and --junit must name different files (%s and %s)", other, path)
		}
		seen[key] = path
		if st, err := os.Stat(filepath.Dir(abs)); err != nil || !st.IsDir() {
			return fmt.Errorf("report directory for %s does not exist", path)
		}
		if st, err := os.Stat(abs); err == nil && st.IsDir() {
			return fmt.Errorf("report path %s is a directory", path)
		}
	}
	return nil
}

// encodeAutomationReport produces the exact bytes printed on stdout, so the
// --report file and stdout carry the same document.
func encodeAutomationReport(report automationReport) ([]byte, error) {
	var b bytes.Buffer
	if err := json.NewEncoder(&b).Encode(report); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}
