package main

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"sort"
	"time"

	"core/toolbox"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

const notebookDefaultInterval = 60

type notebookSelection struct {
	Before string `json:"before"`
	After  string `json:"after"`
}

type notebookSettings struct {
	// Presence means watched. The value controls automatic switching.
	Watched    map[string]bool              `json:"watched"`
	Notify     bool                         `json:"notify"`
	Selections map[string]notebookSelection `json:"selections,omitempty"`
}

type notebookChange struct {
	Profile  string `json:"profile"`
	Group    string `json:"group"`
	Selected string `json:"selected"`
	Notify   bool   `json:"notify"`
}

type notebookMemberView struct {
	Name        string          `json:"name"`
	Verdict     notebookVerdict `json:"verdict"`
	Delay       uint16          `json:"delay,omitempty"`
	Unsupported bool            `json:"unsupported,omitempty"`
}

type notebookGroupView struct {
	Name       string               `json:"name"`
	Type       string               `json:"type"`
	Selected   string               `json:"selected"`
	Watched    bool                 `json:"watched"`
	AutoSwitch bool                 `json:"autoSwitch"`
	Members    []notebookMemberView `json:"members"`
}

type notebookView struct {
	Profile      string              `json:"profile"`
	Ready        bool                `json:"ready"`
	Interval     int                 `json:"interval"`
	Notify       bool                `json:"notify"`
	Busy         bool                `json:"busy"`
	Pending      bool                `json:"pending"`
	WatchedCount int                 `json:"watchedCount"`
	Checked      *time.Time          `json:"checked,omitempty"`
	Groups       []notebookGroupView `json:"groups"`
}

type notebookRequest struct {
	Profile    string `json:"profile"`
	Group      string `json:"group"`
	Watch      *bool  `json:"watch"`
	AutoSwitch *bool  `json:"autoSwitch"`
	Notify     *bool  `json:"notify"`
	Interval   *int   `json:"interval"`
	Force      bool   `json:"force"`
	Manual     bool   `json:"manual"`
	Network    bool   `json:"network"`
}

// All fields belong to runLock. Network calls execute outside that lock.
type notebookMonitor struct {
	profile      string
	revision     uint64
	settings     notebookSettings
	interval     int
	records      map[notebookIdentity]notebookRecord
	pending      map[string]bool
	batchCancel  context.CancelFunc
	inFlight     bool
	pollCancel   context.CancelFunc
	manualUntil  time.Time
	networkReady time.Time
	probe        func(context.Context, C.Proxy, notebookIdentity) notebookRecord
	lastChecked  time.Time
}

var notebook = notebookMonitor{interval: notebookDefaultInterval, probe: probeNotebook}

func notebookStoreKey(profile string) string {
	return "profile:" + profile
}

func notebookStoreGet(key string, value any) {
	data, _ := json.Marshal(map[string]string{"ns": "notebook", "key": key})
	_ = json.Unmarshal([]byte(toolbox.HandleStoreGet(string(data))), value)
}

func notebookStoreSet(key string, value any) {
	data, err := json.Marshal(map[string]any{"ns": "notebook", "key": key, "data": value})
	if err == nil {
		toolbox.HandleStoreSet(string(data))
	}
}

func (monitor *notebookMonitor) invalidateLocked() {
	monitor.revision++
	if monitor.batchCancel != nil {
		monitor.batchCancel()
	}
}

func (monitor *notebookMonitor) resetLocked(profile string) {
	monitor.invalidateLocked()
	monitor.interval = notebookDefaultInterval
	notebookStoreGet("interval", &monitor.interval)
	if monitor.interval < 1 || monitor.interval > 1440 {
		monitor.interval = notebookDefaultInterval
	}
	previousProfile := monitor.profile
	monitor.profile = profile
	monitor.settings = notebookSettings{}
	if profile != "" {
		notebookStoreGet(notebookStoreKey(profile), &monitor.settings)
	}
	if monitor.settings.Watched == nil {
		monitor.settings.Watched = make(map[string]bool)
	}
	if monitor.settings.Selections == nil {
		monitor.settings.Selections = make(map[string]notebookSelection)
	}
	monitor.records = make(map[notebookIdentity]notebookRecord)
	if previousProfile != profile || monitor.pending == nil {
		monitor.pending = make(map[string]bool)
	}
	monitor.lastChecked = time.Time{}
	monitor.manualUntil = time.Time{}
	monitor.networkReady = time.Time{}
	// A confirmed automatic selection is durable even if Flutter was closed.
	// A different, newer user selection in the profile always wins.
	for name, selection := range monitor.settings.Selections {
		root := tunnel.Proxies()[name]
		if root == nil || root.Type() != C.Selector {
			continue
		}
		if selector, ok := root.Adapter().(*outboundgroup.Selector); ok && selector.Now() == selection.Before {
			_ = selector.Set(selection.After)
		}
	}
	monitor.syncPollLocked()
}

func (monitor *notebookMonitor) readyLocked() bool {
	return isInit && isRunning && monitor.profile != "" && currentConfig != nil
}

func (monitor *notebookMonitor) syncPollLocked() {
	if !monitor.readyLocked() || len(monitor.settings.Watched) == 0 {
		if monitor.pollCancel != nil {
			monitor.pollCancel()
			monitor.pollCancel = nil
		}
		return
	}
	if monitor.pollCancel == nil {
		ctx, cancel := context.WithCancel(context.Background())
		monitor.pollCancel = cancel
		go func() {
			ticker := time.NewTicker(10 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					runLock.Lock()
					if ctx.Err() == nil {
						monitor.kickLocked()
					}
					runLock.Unlock()
				}
			}
		}()
	}
	monitor.kickLocked()
}

func (monitor *notebookMonitor) stopLocked() {
	monitor.invalidateLocked()
	monitor.records = make(map[notebookIdentity]notebookRecord)
	monitor.lastChecked = time.Time{}
	if monitor.pollCancel != nil {
		monitor.pollCancel()
		monitor.pollCancel = nil
	}
}

func (monitor *notebookMonitor) saveLocked() {
	if monitor.profile != "" {
		notebookStoreSet(notebookStoreKey(monitor.profile), monitor.settings)
	}
}

func (monitor *notebookMonitor) manualLocked(group string) {
	if len(monitor.settings.Watched) == 0 {
		return
	}
	monitor.invalidateLocked()
	// Cover the interval before the existing debounced UI selection is sent.
	monitor.manualUntil = time.Now().Add(3 * time.Second)
	if _, exists := monitor.settings.Selections[group]; exists {
		delete(monitor.settings.Selections, group)
		monitor.saveLocked()
	}
}

func (monitor *notebookMonitor) viewLocked() notebookView {
	view := notebookView{
		Profile: monitor.profile, Ready: monitor.readyLocked(),
		Interval: monitor.interval, Notify: monitor.settings.Notify,
		Busy: monitor.inFlight, Pending: len(monitor.pending) > 0, WatchedCount: len(monitor.settings.Watched),
		Groups: []notebookGroupView{},
	}
	if !monitor.lastChecked.IsZero() {
		checked := monitor.lastChecked
		view.Checked = &checked
	}
	if !view.Ready {
		return view
	}
	proxies := tunnel.Proxies()
	topology := captureNotebookTopology(proxies, monitor.settings.Watched)
	now := time.Now()
	age := max(120*time.Second, 2*time.Duration(monitor.interval)*time.Minute)
	for _, name := range orderedGroupNames(proxies) {
		_, group, ok := proxyGroupOf(proxies[name])
		if !ok || group.Hidden() {
			continue
		}
		auto, watched := monitor.settings.Watched[name]
		item := notebookGroupView{Name: name, Type: proxies[name].Type().String(), Watched: watched, AutoSwitch: auto && proxies[name].Type() == C.Selector}
		if root := topology.roots[name]; root != nil {
			item.Selected = root.current
			for _, member := range root.members {
				name := member.identity.Name
				record := notebookPathRecord(notebookPath(root.member(name)), monitor.records, now, age)
				item.Members = append(item.Members, notebookMemberView{name, record.Verdict, record.Delay, record.Unsupported})
			}
		}
		view.Groups = append(view.Groups, item)
	}
	return view
}

func applyNotebookRequest(data string) (notebookView, error) {
	var request notebookRequest
	if err := json.Unmarshal([]byte(data), &request); err != nil {
		return notebookView{}, err
	}
	runLock.Lock()
	defer runLock.Unlock()
	return notebook.applyLocked(request)
}

func (monitor *notebookMonitor) applyLocked(request notebookRequest) (notebookView, error) {
	if request.Network {
		if len(monitor.settings.Watched) != 0 {
			monitor.invalidateLocked()
			clear(monitor.records)
			monitor.lastChecked = time.Time{}
			monitor.networkReady = time.Now().Add(2 * time.Second)
		}
		return notebookView{}, nil
	}
	if request.Manual {
		if request.Profile == "" || request.Profile == monitor.profile {
			monitor.manualLocked(request.Group)
		}
		return notebookView{}, nil
	}
	if request.Profile == "" || request.Profile != monitor.profile {
		return notebookView{}, errors.New("Notebook profile changed")
	}

	if request.Interval != nil && (*request.Interval < 1 || *request.Interval > 1440) {
		return notebookView{}, errors.New("Notebook interval must be between 1 and 1440 minutes")
	}
	auto, watched := monitor.settings.Watched[request.Group]
	if request.AutoSwitch != nil && (!watched || request.Watch != nil) {
		return notebookView{}, errors.New("Automatic Notebook switching requires a watched group")
	}
	if request.AutoSwitch != nil && *request.AutoSwitch {
		proxy := tunnel.Proxies()[request.Group]
		if !watched || proxy == nil || proxy.Type() != C.Selector {
			return notebookView{}, errors.New("Automatic Notebook switching requires a watched Selector")
		}
	}
	changed := false
	if request.Watch != nil && *request.Watch != watched {
		if *request.Watch {
			if _, _, ok := proxyGroupOf(tunnel.Proxies()[request.Group]); !ok {
				return notebookView{}, errors.New("Notebook group no longer exists")
			}
			monitor.settings.Watched[request.Group] = false
		} else {
			delete(monitor.settings.Watched, request.Group)
			delete(monitor.pending, request.Group)
		}
		changed = true
	}
	if request.AutoSwitch != nil && *request.AutoSwitch != auto {
		monitor.settings.Watched[request.Group] = *request.AutoSwitch
		if *request.AutoSwitch {
			monitor.pending[request.Group] = true
		}
		changed = true
	}
	if request.Notify != nil && *request.Notify != monitor.settings.Notify {
		monitor.settings.Notify = *request.Notify
		changed = true
	}
	if request.Interval != nil && *request.Interval != monitor.interval {
		monitor.interval = *request.Interval
		notebookStoreSet("interval", monitor.interval)
		changed = true
	}
	if changed {
		monitor.invalidateLocked()
		monitor.saveLocked()
	}
	if request.Force {
		for name := range monitor.settings.Watched {
			if request.Group == "" || request.Group == name {
				monitor.pending[name] = true
			}
		}
	}
	monitor.syncPollLocked()
	return monitor.viewLocked(), nil
}

func (monitor *notebookMonitor) kickLocked() {
	if monitor.inFlight || !monitor.readyLocked() || len(monitor.settings.Watched) == 0 || time.Now().Before(monitor.networkReady) {
		return
	}
	proxies := tunnel.Proxies()
	topology := captureNotebookTopology(proxies, monitor.settings.Watched)
	for id := range monitor.records {
		if _, exists := topology.leaves[id]; !exists {
			delete(monitor.records, id)
		}
	}
	forced := make(map[notebookIdentity]C.Proxy)
	consumed := make(map[string]bool)
	for group := range monitor.pending {
		candidates := captureNotebookTopology(proxies, map[string]bool{group: false}).leaves
		if len(candidates) != 0 {
			maps.Copy(forced, candidates)
			consumed[group] = true
			delete(monitor.pending, group)
		}
	}
	age := time.Duration(monitor.interval) * time.Minute
	now := time.Now()
	var targets []notebookIdentity
	for id := range topology.leaves {
		record, seen := monitor.records[id]
		if forced[id] != nil || !seen || (now.Sub(monitor.lastChecked) >= age && !record.valid(id, now, age)) {
			targets = append(targets, id)
		}
	}
	if len(targets) == 0 {
		return
	}
	sort.Slice(targets, func(i, j int) bool {
		if targets[i].Name != targets[j].Name {
			return targets[i].Name < targets[j].Name
		}
		return targets[i].ID < targets[j].ID
	})
	ctx, cancel := context.WithCancel(context.Background())
	monitor.batchCancel = cancel
	monitor.inFlight = true
	revision := monitor.revision
	go monitor.runBatch(ctx, cancel, revision, monitor.profile, topology, targets, consumed)
}

func (monitor *notebookMonitor) runBatch(ctx context.Context, cancel context.CancelFunc, revision uint64, profile string, topology notebookTopology, targets []notebookIdentity, forced map[string]bool) {
	defer cancel()
	samples := make(map[notebookIdentity]notebookRecord, len(targets))
	for _, id := range targets {
		if ctx.Err() != nil {
			break
		}
		samples[id] = monitor.probe(ctx, topology.leaves[id], id)
	}
	runLock.Lock()
	defer runLock.Unlock()
	monitor.inFlight = false
	monitor.batchCancel = nil
	if ctx.Err() != nil || monitor.revision != revision || !monitor.readyLocked() {
		if monitor.profile == profile {
			for name := range forced {
				if _, watched := monitor.settings.Watched[name]; watched {
					monitor.pending[name] = true
				}
			}
		}
		monitor.kickLocked()
		return
	}
	live := captureNotebookTopology(tunnel.Proxies(), monitor.settings.Watched)
	for id, result := range samples {
		if live.leaves[id] == topology.leaves[id] {
			monitor.records[id] = result
		}
	}
	now := time.Now()
	monitor.lastChecked = now
	if !now.Before(monitor.manualUntil) {
		monitor.applyPlansLocked(topology, samples, now)
	}
	monitor.kickLocked()
}

func (monitor *notebookMonitor) applyPlansLocked(topology notebookTopology, samples map[notebookIdentity]notebookRecord, now time.Time) {
	age := time.Duration(monitor.interval) * time.Minute
	for _, name := range orderedGroupNames(tunnel.Proxies()) {
		if !monitor.settings.Watched[name] {
			continue
		}
		plan := planNotebookSwitch(topology.roots[name], monitor.records, now, age)
		if plan == nil {
			continue
		}
		// Unrelated discovery probes must not replay an old failed plan.
		_, newFailure := samples[plan.beforePath[len(plan.beforePath)-1]]
		_, newSuccess := samples[plan.nextPath[len(plan.nextPath)-1]]
		if !newFailure && !newSuccess {
			continue
		}
		latest := captureNotebookTopology(tunnel.Proxies(), map[string]bool{name: true})
		root := latest.roots[name]
		if !sameNotebookPlan(plan, planNotebookSwitch(root, monitor.records, time.Now(), age)) {
			continue
		}
		selector, ok := root.proxy.Adapter().(*outboundgroup.Selector)
		if !ok {
			continue
		}
		err := selector.Set(plan.after)
		observed := selector.Now()
		if err != nil || observed != plan.after {
			continue
		}
		monitor.settings.Selections[name] = notebookSelection{plan.before, observed}
		monitor.saveLocked()
		sendMessage(Message{GroupsChangedMessage, nil})
		sendMessage(Message{NotebookSwitchMessage, notebookChange{monitor.profile, name, observed, monitor.settings.Notify}})
	}
}
