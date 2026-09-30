package fakeip

import (
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

type testScope func(string) bool

func (s testScope) MatchDomain(domain string) bool { return s(domain) }

func TestPrivateDNSDomainAlwaysSkipsFakeIPRegardlessOfMode(t *testing.T) {
	private := testScope(func(domain string) bool {
		return domain == "api.inside.example.invalid"
	})
	for _, mode := range []C.FilterMode{C.FilterBlackList, C.FilterWhiteList} {
		skipper := &Skipper{
			Mode:        mode,
			ForceRealIP: private,
		}
		if !skipper.ShouldSkipped("api.inside.example.invalid") {
			t.Fatal("private DNS domain received a fake IP")
		}
	}
	blacklist := &Skipper{Mode: C.FilterBlackList, ForceRealIP: private}
	if blacklist.ShouldSkipped("public.example.com") {
		t.Fatal("public domain was forced to real-IP DNS")
	}
}
