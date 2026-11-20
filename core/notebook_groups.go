package main

import (
	"reflect"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

type notebookNode struct {
	identity notebookIdentity
	proxy    C.Proxy
	current  string
	members  []*notebookNode
	group    bool
}

type notebookTopology struct {
	roots  map[string]*notebookNode
	leaves map[notebookIdentity]C.Proxy
}

func captureNotebookTopology(proxies map[string]C.Proxy, watched map[string]bool) notebookTopology {
	result := notebookTopology{
		roots:  make(map[string]*notebookNode, len(watched)),
		leaves: make(map[notebookIdentity]C.Proxy),
	}
	visited := make(map[C.Proxy]*notebookNode)
	var visit func(C.Proxy) *notebookNode
	visit = func(proxy C.Proxy) *notebookNode {
		if node := visited[proxy]; node != nil {
			return node
		}
		node := &notebookNode{identity: notebookProxyIdentity(proxy), proxy: proxy}
		visited[proxy] = node
		if _, group, ok := proxyGroupOf(proxy); ok {
			node.group = true
			switch node.identity.Type {
			case "Selector", "Fallback", "URLTest":
				node.current = group.Now()
			}
			for _, member := range group.Proxies() {
				if member != nil {
					node.members = append(node.members, visit(member))
				}
			}
		} else if notebookLeaf(node.identity) {
			result.leaves[node.identity] = proxy
		}
		return node
	}
	for name := range watched {
		if proxy := proxies[name]; proxy != nil {
			result.roots[name] = visit(proxy)
		}
	}
	return result
}

// Set only accepts a member name, so duplicate names are ambiguous even when
// both underlying nodes have independent, valid probe records.
func (node *notebookNode) member(name string) *notebookNode {
	var found *notebookNode
	for _, member := range node.members {
		if member.identity.Name == name {
			if found != nil && found.identity != member.identity {
				return nil
			}
			found = member
		}
	}
	return found
}

func notebookPath(node *notebookNode) []notebookIdentity {
	var path []notebookIdentity
	visited := make(map[*notebookNode]bool)
	for node != nil && !visited[node] {
		if node.identity.ID == "" {
			return nil
		}
		visited[node] = true
		path = append(path, node.identity)
		if !node.group {
			if notebookLeaf(node.identity) {
				return path
			}
			return nil
		}
		if node.current == "" {
			return nil
		}
		node = node.member(node.current)
	}
	return nil
}

func notebookPathRecord(path []notebookIdentity, records map[notebookIdentity]notebookRecord, now time.Time, age time.Duration) notebookRecord {
	if len(path) != 0 {
		leaf := path[len(path)-1]
		if record := records[leaf]; record.valid(leaf, now, age) {
			return record
		}
	}
	return notebookRecord{Verdict: notebookUnknown}
}

type notebookSwitchPlan struct {
	root                 notebookIdentity
	before, after        string
	beforePath, nextPath []notebookIdentity
}

func planNotebookSwitch(root *notebookNode, records map[notebookIdentity]notebookRecord, now time.Time, age time.Duration) *notebookSwitchPlan {
	if root == nil || root.identity.Type != "Selector" || root.identity.ID == "" {
		return nil
	}
	current := notebookPath(root.member(root.current))
	if notebookPathRecord(current, records, now, age).Verdict != notebookUnavailable {
		return nil
	}
	best := uint16(65535)
	var plan *notebookSwitchPlan
	for _, candidate := range root.members {
		name := candidate.identity.Name
		if name == root.current || root.member(name) == nil {
			continue
		}
		path := notebookPath(candidate)
		record := notebookPathRecord(path, records, now, age)
		if record.Verdict == notebookAvailable && !record.Unsupported && record.Delay > 0 && record.Delay < best {
			best = record.Delay
			plan = &notebookSwitchPlan{root.identity, root.current, name, current, path}
		}
	}
	return plan
}

func sameNotebookPlan(a, b *notebookSwitchPlan) bool {
	return a != nil && b != nil && reflect.DeepEqual(a, b)
}
