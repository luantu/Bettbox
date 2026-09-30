package main

import "testing"

func TestNativeVpnAdmissionRequiresExplicitModeAndSuccessfulTun(t *testing.T) {
	var admission nativeVpnAdmission
	if admission.AllowsTransport() {
		t.Fatal("unknown mode allowed a transport")
	}
	admission.SetMode(true)
	if admission.AllowsTransport() {
		t.Fatal("VPN-required mode allowed a pre-TUN transport")
	}
	admission.SetReady(true)
	if !admission.AllowsTransport() {
		t.Fatal("installed TUN/protect did not admit a transport")
	}
	admission.SetReady(false)
	if admission.AllowsTransport() {
		t.Fatal("stopped/failed TUN retained admission")
	}
	admission.SetMode(false)
	if !admission.AllowsTransport() {
		t.Fatal("explicit proxy-only mode was blocked")
	}
	admission.SetMode(true)
	if admission.AllowsTransport() {
		t.Fatal("proxy-only to VPN mode reused stale readiness")
	}
}
