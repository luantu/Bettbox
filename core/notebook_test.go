package main

import (
	"context"
	"net/url"
	"os/exec"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func TestNotebookHistory(t *testing.T) {
	now := time.Unix(100, 0)
	negative := notebookObservation{now.Add(-3 * time.Second), false, 0}
	failure := notebookObservation{now.Add(-2 * time.Second), false, 0}
	lastFailure := notebookObservation{now.Add(-time.Second), false, 0}
	success := notebookObservation{now.Add(-time.Second), true, 21}
	future := notebookObservation{now.Add(time.Second), true, 12}
	for _, tc := range []struct {
		name    string
		samples []notebookObservation
		want    notebookVerdict
		delay   uint16
	}{
		{"second attempt succeeds", []notebookObservation{negative, failure, success}, notebookAvailable, 21},
		{"twice confirmed", []notebookObservation{negative, failure, lastFailure}, notebookUnavailable, 0},
		{"expected ignored", []notebookObservation{success}, notebookUnknown, 0},
		{"stale sample", []notebookObservation{negative, failure, failure}, notebookUnknown, 0},
		{"future time", []notebookObservation{negative, future}, notebookUnknown, 0},
		{"controller or path failure", []notebookObservation{negative}, notebookUnknown, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls []uint16
			verdict, delay := runNotebookHistory(notebookObservation{}, func(expected uint16) (notebookObservation, bool) {
				i := len(calls)
				calls = append(calls, expected)
				if i >= len(tc.samples) {
					return notebookObservation{}, false
				}
				return tc.samples[i], true
			}, func() time.Time { return now })
			if verdict != tc.want || delay != tc.delay || !reflect.DeepEqual(calls, []uint16{599, 200, 200}[:len(calls)]) {
				t.Fatalf("got %s / %d with calls %v", verdict, delay, calls)
			}
		})
	}
}

func testNotebookLeaf(name, id string) *notebookNode {
	return &notebookNode{identity: notebookIdentity{name, "Socks5", id}}
}

func testNotebookGroup(name, kind, current string, members ...*notebookNode) *notebookNode {
	return &notebookNode{identity: notebookIdentity{name, kind, name}, current: current, members: members, group: true}
}

func TestNotebookSelectionPlan(t *testing.T) {
	now := time.Now()
	old := testNotebookLeaf("old", "old")
	first := testNotebookLeaf("first", "first")
	second := testNotebookLeaf("second", "second")
	last := testNotebookLeaf("last", "last")
	nested := testNotebookGroup("nested", "Fallback", "first", first, last)
	root := testNotebookGroup("main", "Selector", "old", old, nested, second)
	records := map[notebookIdentity]notebookRecord{
		old.identity:    {Identity: old.identity, CheckedAt: now, Verdict: notebookUnavailable},
		first.identity:  {Identity: first.identity, CheckedAt: now, Verdict: notebookAvailable, Delay: 20},
		second.identity: {Identity: second.identity, CheckedAt: now, Verdict: notebookAvailable, Delay: 20},
		last.identity:   {Identity: last.identity, CheckedAt: now, Verdict: notebookAvailable, Delay: 1},
	}
	plan := func() *notebookSwitchPlan { return planNotebookSwitch(root, records, now, time.Minute) }
	layout := plan()
	if layout == nil || layout.after != "nested" || layout.nextPath[1] != first.identity {
		t.Fatalf("parent name or tie order lost: %+v", layout)
	}
	// Same leaf through a new intermediate group cannot authorize a stale write.
	nested.members = []*notebookNode{testNotebookGroup("new path", "Selector", "first", first), last}
	nested.current = "new path"
	if p := plan(); p == nil || sameNotebookPlan(layout, p) {
		t.Fatal("expected different valid path")
	}
	record := records[old.identity]
	for _, verdict := range []notebookVerdict{notebookUnknown, notebookAvailable} {
		record.Verdict = verdict
		records[old.identity] = record
		if plan() != nil {
			t.Fatalf("switched from %s", verdict)
		}
	}
	record.Verdict = notebookUnavailable
	for _, checked := range []time.Time{now.Add(-time.Minute - time.Second), now.Add(time.Second)} {
		record.CheckedAt = checked
		records[old.identity] = record
		if plan() != nil {
			t.Fatal("switched using out-of-window failure")
		}
	}
	record.CheckedAt = now
	records[old.identity] = record
	first.identity.ID = "replacement"
	changed := records[second.identity]
	changed.Unsupported = true
	records[second.identity] = changed
	if plan() != nil {
		t.Fatal("replacement node or business-unsupported node was selected")
	}
	cycle := testNotebookGroup("cycle", "Selector", "cycle")
	cycle.members = []*notebookNode{cycle}
	if notebookPath(cycle) != nil {
		t.Fatal("cycle resolved to a leaf")
	}
}

func notebookFixture(t *testing.T) *config.Config {
	t.Helper()
	raw, err := config.UnmarshalRawConfig([]byte(`
proxies:
  - { name: Alpha, type: socks5, server: 192.0.2.1, port: 9 }
  - { name: Beta, type: socks5, server: 192.0.2.2, port: 9 }
proxy-groups:
  - { name: Watched, type: select, proxies: [Alpha, Beta] }
  - { name: Unwatched, type: select, proxies: [Alpha, Beta] }
  - { name: Automatic, type: fallback, url: https://example.com/, interval: 60, proxies: [Alpha, Beta] }
rules: ["MATCH,DIRECT"]
`))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func installNotebookFixture(t *testing.T, fixture *config.Config, monitor *notebookMonitor) {
	t.Helper()
	runLock.Lock()
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
	oldConfig, oldInit, oldRunning := currentConfig, isInit, isRunning
	currentConfig, isInit, isRunning = fixture, true, true
	tunnel.UpdateProxies(fixture.Proxies, fixture.Providers)
	runLock.Unlock()
	t.Cleanup(func() {
		runLock.Lock()
		monitor.stopLocked()
		currentConfig, isInit, isRunning = oldConfig, oldInit, oldRunning
		tunnel.UpdateProxies(previousProxies, previousProviders)
		runLock.Unlock()
	})
}

func waitNotebook(t *testing.T, test func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		runLock.Lock()
		done := test()
		runLock.Unlock()
		if done {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("timed out waiting for notebook batch")
}

func TestNotebookMonitorForceAndScope(t *testing.T) {
	fixture := notebookFixture(t)
	probeStarted := make(chan struct{})
	releaseProbe := make(chan struct{})
	var calls atomic.Int32
	monitor := notebookMonitor{
		profile: "mock-profile", interval: 60, records: map[notebookIdentity]notebookRecord{},
		pending: map[string]bool{}, settings: notebookSettings{Watched: map[string]bool{"Watched": true, "Unwatched": false}, Selections: map[string]notebookSelection{}},
		probe: func(ctx context.Context, _ C.Proxy, id notebookIdentity) notebookRecord {
			if calls.Add(1) == 1 {
				close(probeStarted)
				select {
				case <-ctx.Done():
				case <-releaseProbe:
				}
			}
			verdict, delay := notebookUnavailable, uint16(0)
			if id.Name == "Beta" {
				verdict, delay = notebookAvailable, 15
			}
			return notebookRecord{Identity: id, CheckedAt: time.Now(), Verdict: verdict, Delay: delay}
		},
	}
	installNotebookFixture(t, fixture, &monitor)
	force := notebookRequest{Profile: monitor.profile, Force: true}
	runLock.Lock()
	monitor.kickLocked()
	runLock.Unlock()
	select {
	case <-probeStarted:
	case <-time.After(2 * time.Second):
		runLock.Lock()
		topology := captureNotebookTopology(tunnel.Proxies(), monitor.settings.Watched)
		t.Logf("ready=%t root=%#v leaves=%v", monitor.readyLocked(), topology.roots["Watched"], topology.leaves)
		if root := topology.roots["Watched"]; root != nil {
			for _, member := range root.members {
				t.Logf("member=%+v group=%t", member.identity, member.group)
			}
		}
		runLock.Unlock()
		t.Fatal("first batch never started")
	}
	runLock.Lock()
	for range 3 {
		if _, err := monitor.applyLocked(force); err != nil {
			runLock.Unlock()
			t.Fatal(err)
		}
	}
	runLock.Unlock()
	close(releaseProbe)
	waitNotebook(t, func() bool { return !monitor.inFlight && len(monitor.pending) == 0 })
	if calls.Load() != 4 {
		t.Fatalf("overlapping requests were lost or not coalesced: %d tests", calls.Load())
	}
	runLock.Lock()
	state := monitor.viewLocked()
	runLock.Unlock()
	selections := map[string]string{}
	for _, group := range state.Groups {
		selections[group.Name] = group.Selected
	}
	if selections["Watched"] != "Beta" || selections["Unwatched"] != "Alpha" {
		t.Fatalf("unexpected selections: %v", selections)
	}
	runLock.Lock()
	no := false
	_, err := monitor.applyLocked(notebookRequest{Profile: monitor.profile, Group: "Watched", Watch: &no})
	_, saved := monitor.settings.Watched["Watched"]
	runLock.Unlock()
	if err != nil || saved {
		t.Fatalf("unwatch retained automatic setting: %v", err)
	}
}

func TestNotebookQueuedBeforeCandidatesAndManualChange(t *testing.T) {
	fixture := notebookFixture(t)
	var calls atomic.Int32
	monitor := notebookMonitor{
		profile: "manual-profile", interval: 60, records: map[notebookIdentity]notebookRecord{},
		pending: map[string]bool{}, settings: notebookSettings{Watched: map[string]bool{"Watched": true}},
		probe: func(_ context.Context, _ C.Proxy, id notebookIdentity) notebookRecord {
			calls.Add(1)
			verdict := notebookUnavailable
			if id.Name == "Beta" {
				verdict = notebookAvailable
			}
			return notebookRecord{Identity: id, CheckedAt: time.Now(), Verdict: verdict, Delay: 10}
		},
	}
	installNotebookFixture(t, fixture, &monitor)
	runLock.Lock()
	tunnel.UpdateProxies(nil, nil)
	_, err := monitor.applyLocked(notebookRequest{Profile: monitor.profile, Force: true})
	queued := monitor.pending["Watched"] && !monitor.inFlight
	tunnel.UpdateProxies(fixture.Proxies, fixture.Providers)
	monitor.manualLocked("Watched")
	monitor.kickLocked()
	runLock.Unlock()
	if err != nil || !queued {
		t.Fatalf("request did not survive absent metadata: %v", err)
	}
	waitNotebook(t, func() bool { return !monitor.inFlight && len(monitor.pending) == 0 })
	runLock.Lock()
	root := captureNotebookTopology(tunnel.Proxies(), monitor.settings.Watched).roots["Watched"]
	runLock.Unlock()
	if calls.Load() != 2 || root.current != "Alpha" {
		t.Fatalf("manual intent lost or queue not drained: calls=%d selected=%s", calls.Load(), root.current)
	}
}

func TestNotebookDoesNotApplyOldPlanAfterToggleOrUnrelatedProbe(t *testing.T) {
	fixture := notebookFixture(t)
	monitor := notebookMonitor{
		profile: "test-profile", interval: 60, records: map[notebookIdentity]notebookRecord{},
		pending: map[string]bool{}, settings: notebookSettings{Watched: map[string]bool{"Watched": true}},
	}
	installNotebookFixture(t, fixture, &monitor)
	runLock.Lock()
	defer runLock.Unlock()
	topology := captureNotebookTopology(tunnel.Proxies(), monitor.settings.Watched)
	for id := range topology.leaves {
		record := notebookRecord{Identity: id, CheckedAt: time.Now(), Verdict: notebookUnavailable}
		if id.Name == "Beta" {
			record.Verdict = notebookAvailable
			record.Delay = 12
		}
		monitor.records[id] = record
	}

	monitor.applyPlansLocked(topology, nil, time.Now())
	root := topology.roots["Watched"]
	if root.proxy.Adapter().(interface{ Now() string }).Now() != "Alpha" {
		t.Fatal("applied an old plan without a fresh relevant observation")
	}
	monitor.settings.Watched["Watched"] = false
	monitor.applyPlansLocked(topology, monitor.records, time.Now())
	if root.proxy.Adapter().(interface{ Now() string }).Now() != "Alpha" {
		t.Fatal("applied plan after the switch was disabled")
	}
}

func TestNotebookGoogleSelectorOverride(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("Node.js is needed to evaluate the Google override")
	}
	program := `
const fs = require('node:fs'), vm = require('node:vm');
const ctx = vm.createContext({});
const source = fs.readFileSync('../scripts/overrides/overwrite-bettbox.js','utf8');
vm.runInContext(source.replace('const GOOGLE_NOTEBOOK_SELECTOR = false;', 'const GOOGLE_NOTEBOOK_SELECTOR = true;'), ctx);
const p = name => ({name,type:'socks5',server:'192.0.2.1',port:9});
const fixture = {proxies:[p('KR01')], 'proxy-providers': {
  airport:{type:'inline',payload:[p('JP01'),p('HK01')]}
}};
process.stdout.write(JSON.stringify(ctx.main(fixture)));`
	data, err := exec.Command("node", "-e", program).CombinedOutput()
	if err != nil {
		t.Fatalf("override evaluation: %v (%s)", err, data)
	}
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	topology := captureNotebookTopology(parsed.Proxies, map[string]bool{"Google 服务": true})
	root := topology.roots["Google 服务"]
	if root == nil || root.identity.Type != "Selector" || root.current != "Google 服务 · 自动" {
		t.Fatalf("Google selector or its default fallback missing: %+v", root)
	}
	if root.member("JP01") == nil || root.member("HK01") != nil || root.member("KR01") == nil {
		t.Fatal("static or dynamic Google candidates were not scoped correctly")
	}
	if fallback := root.member(root.current); fallback == nil || fallback.identity.Type != "Fallback" {
		t.Fatal("default Google fallback was changed")
	}
}

func TestNotebookObservedRedirectHosts(t *testing.T) {
	parse := func(value string) *url.URL {
		u, err := url.Parse(value)
		if err != nil {
			t.Fatal(err)
		}
		return u
	}
	for _, host := range []string{"notebook.google.com", "notebooklm.google", "notebook.google", "accounts.google.com"} {
		if !notebookRedirectAllowed(parse("https://" + host)) {
			t.Fatalf("expected redirect host %s to be allowed", host)
		}
	}
	for _, target := range []string{"http://notebook.google", "https://notebook.google:444", "https://notebook.google.example.org"} {
		if notebookRedirectAllowed(parse(target)) {
			t.Fatalf("unexpected redirect target allowed: %s", target)
		}
	}
	page := parse("https://notebook.google/?location=unsupported")
	if notebookFinalUnsupported(page, 301) || !notebookFinalUnsupported(page, 200) {
		t.Fatal("only the final response with the unsupported marker counts")
	}
	if notebookFinalUnsupported(parse("https://notebook.google/"), 200) {
		t.Fatal("a 200 response without the marker should leave business status unknown")
	}
}
