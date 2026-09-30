package main

import "testing"

func TestNativeVpnReadinessRequiresBothProtectionAndListener(t *testing.T) {
	for _, test := range []struct {
		name                         string
		running, protection, listener bool
		want                         bool
	}{
		{"stopped", false, true, true, false},
		{"no protection callback", true, false, true, false},
		{"TUN creation failed", true, true, false, false},
		{"fully initialized", true, true, true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := nativeVpnReady(test.running, test.protection, test.listener); got != test.want {
				t.Fatalf("readiness = %v, want %v", got, test.want)
			}
		})
	}
}
