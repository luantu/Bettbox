package main

import (
	"sync"
	"testing"
)

func TestNativeVpnSmartPausePreservesProtectedTransport(t *testing.T) {
	var a nativeVpnAdmission
	a.SetStarted(true)
	if !a.SetPaused(true) || !a.AllowsTransport() || a.RepairRequired() {
		t.Fatal("smart pause must keep protected WG transport without a TUN")
	}
	a.SetMode(true) // periodic configuration updates must not lose soft pause
	if !a.AllowsTransport() {
		t.Fatal("configuration update revoked maintenance")
	}
	a.SetStarted(true) // restore only the system TUN
	if !a.AllowsTransport() {
		t.Fatal("resume revoked protected transport")
	}
	a.SetReady(false) // explicit hard stop
	if a.AllowsTransport() {
		t.Fatal("hard stop retained maintenance admission")
	}
}

func TestNativeVpnSmartPauseRequiresRetainedProtection(t *testing.T) {
	var a nativeVpnAdmission
	a.SetStarted(true)
	if a.SetPaused(false) || a.AllowsTransport() {
		t.Fatal("missing protection must fail closed even after a working TUN")
	}
}

func TestNativeVpnRestoreAdmissionRequiresLiveNativeTun(t *testing.T) {
	for _, test := range []struct {
		name                          string
		running, protection, listener bool
		want                          bool
	}{
		{"stopped", false, true, true, false},
		{"no protection", true, false, true, false},
		{"no listener", true, true, false, false},
		{"live native TUN", true, true, true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			var admission nativeVpnAdmission
			admission.SetMode(true)
			admission.AllowsTransport()
			if got := admission.RestoreReady(test.running, test.protection, test.listener); got != test.want {
				t.Fatalf("restore = %v, want %v", got, test.want)
			}
			if got := admission.AllowsTransport(); got != test.want {
				t.Fatalf("transport after restore = %v, want %v", got, test.want)
			}
			if got := admission.RepairRequired(); got != !test.want {
				t.Fatalf("pending repair after restore = %v, want %v", got, !test.want)
			}
		})
	}
}

func TestNativeVpnInvalidRestoreRevokesStaleReadiness(t *testing.T) {
	var admission nativeVpnAdmission
	admission.SetStarted(true)
	if admission.RestoreReady(true, true, false) {
		t.Fatal("restore admitted a missing native listener")
	}
	if admission.RepairRequired() {
		t.Fatal("failed restore manufactured a guard denial")
	}
	if admission.AllowsTransport() {
		t.Fatal("failed restore retained stale readiness")
	}
}

func TestNativeVpnRestoreReconcilesUnknownAndStaleMode(t *testing.T) {
	for _, knownProxy := range []bool{false, true} {
		var admission nativeVpnAdmission
		if knownProxy {
			admission.SetMode(false)
		}
		if !admission.RestoreReady(true, true, true) || !admission.AllowsTransport() || admission.RepairRequired() {
			t.Fatal("live native TUN did not restore admission from unknown/stale mode")
		}
		admission.SetReady(false)
		if admission.RepairRequired() {
			t.Fatal("restored admission retained an old denial")
		}
		if admission.AllowsTransport() {
			t.Fatal("restored native TUN retained proxy-only admission after stop")
		}
	}
}

func TestNativeVpnInvalidRestorePreservesProxyOnlyMode(t *testing.T) {
	var admission nativeVpnAdmission
	admission.SetStarted(false)
	if admission.RestoreReady(true, false, false) {
		t.Fatal("proxy-only runtime was mistaken for a live native TUN")
	}
	if admission.RepairRequired() || !admission.AllowsTransport() {
		t.Fatal("invalid restore changed explicit proxy-only admission")
	}
}

func TestNativeVpnProxyStartDiscardsOldTunReadiness(t *testing.T) {
	var admission nativeVpnAdmission
	admission.SetStarted(true)
	admission.SetStarted(false)
	admission.SetMode(true)
	if admission.AllowsTransport() {
		t.Fatal("VPN mode reused TUN readiness from before proxy-only start")
	}
}

func TestNativeVpnRepairRequiresGuardDenial(t *testing.T) {
	var admission nativeVpnAdmission
	if admission.RepairRequired() {
		t.Fatal("startup without a guard denial requested repair")
	}
	admission.SetMode(true)
	admission.SetReady(false)
	if admission.RepairRequired() {
		t.Fatal("unready state without a guard denial requested repair")
	}
	if admission.AllowsTransport() {
		t.Fatal("guard admitted an unprotected VPN transport")
	}
	if !admission.RepairRequired() {
		t.Fatal("real guard denial did not request native repair")
	}
}

func TestNativeVpnRepairSurvivesBenignUpdates(t *testing.T) {
	var admission nativeVpnAdmission
	// A refusal before mode arrives is still a real guard denial.
	if admission.AllowsTransport() || !admission.RepairRequired() {
		t.Fatal("unknown-mode guard refusal was not recorded")
	}
	admission.SetMode(true)
	admission.SetReady(false)
	for i := 0; i < 3; i++ {
		admission.SetMode(true)
		admission.SetReady(false)
		if !admission.RepairRequired() {
			t.Fatal("benign mode/readiness update erased pending denial")
		}
	}
}

func TestNativeVpnRepairClearsOnReadiness(t *testing.T) {
	var admission nativeVpnAdmission
	admission.SetMode(true)
	if admission.AllowsTransport() || !admission.RepairRequired() {
		t.Fatal("unready VPN was not refused and recorded")
	}
	admission.SetReady(true)
	if admission.RepairRequired() || !admission.AllowsTransport() {
		t.Fatal("successful readiness did not permit transport without repair")
	}
	admission.SetReady(false)
	if admission.RepairRequired() {
		t.Fatal("readiness loss resurrected a resolved denial")
	}
	if admission.AllowsTransport() || !admission.RepairRequired() {
		t.Fatal("new guard refusal after readiness loss was not recorded")
	}
}

func TestNativeVpnRepairSuppressedInProxyOnlyMode(t *testing.T) {
	var admission nativeVpnAdmission
	admission.SetMode(true)
	if admission.AllowsTransport() {
		t.Fatal("unready VPN was admitted")
	}
	admission.SetMode(false)
	admission.SetReady(false)
	if admission.RepairRequired() || !admission.AllowsTransport() {
		t.Fatal("proxy-only mode requested VPN repair or blocked transport")
	}
}

func TestNativeVpnSuccessfulStartReconcilesMode(t *testing.T) {
	for _, test := range []struct {
		name string
		mode int // -1 unknown, 0 proxy-only, 1 VPN
		fd   int
	}{
		{"VPN from unknown mode", -1, 7},
		{"VPN from stale proxy mode", 0, 7},
		{"proxy from unknown mode", -1, 0},
		{"proxy from stale VPN mode", 1, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			var admission nativeVpnAdmission
			if test.mode >= 0 {
				admission.SetMode(test.mode == 1)
			}
			admission.AllowsTransport() // Record a real refusal where applicable.
			admission.SetStarted(test.fd > 0)
			if !admission.AllowsTransport() || admission.RepairRequired() {
				t.Fatal("successful native start retained unknown/stale admission mode")
			}
			admission.SetReady(false)
			if admission.RepairRequired() {
				t.Fatal("successful native start left a pending denial")
			}
			if got := admission.AllowsTransport(); got != (test.fd == 0) {
				t.Fatalf("after readiness loss transport allowed = %v, want %v", got, test.fd == 0)
			}
		})
	}
}

func TestNativeVpnConcurrentRecoveryClearsStaleDenials(t *testing.T) {
	for i := 0; i < 500; i++ {
		var admission nativeVpnAdmission
		admission.SetMode(true)
		start := make(chan struct{})
		var workers sync.WaitGroup
		workers.Add(3)
		for j := 0; j < 2; j++ {
			go func() {
				defer workers.Done()
				<-start
				for k := 0; k < 8; k++ {
					admission.AllowsTransport()
				}
			}()
		}
		go func() {
			defer workers.Done()
			<-start
			switch i % 3 {
			case 0:
				admission.SetReady(true)
			case 1:
				admission.SetStarted(true)
			case 2:
				admission.RestoreReady(true, true, true)
			}
		}()
		close(start)
		workers.Wait()
		if !admission.AllowsTransport() || admission.RepairRequired() {
			t.Fatal("concurrent denial overrode successful readiness")
		}
		admission.SetReady(false)
		if admission.RepairRequired() {
			t.Fatal("stale concurrent denial survived successful readiness")
		}
	}
}

func TestNativeVpnConcurrentBenignUpdatesPreserveDenial(t *testing.T) {
	var admission nativeVpnAdmission
	admission.SetMode(true)
	admission.AllowsTransport()
	var workers sync.WaitGroup
	workers.Add(3)
	go func() {
		defer workers.Done()
		for i := 0; i < 1000; i++ {
			admission.SetMode(true)
		}
	}()
	go func() {
		defer workers.Done()
		for i := 0; i < 1000; i++ {
			admission.SetReady(false)
			admission.RestoreReady(false, true, true)
		}
	}()
	go func() {
		defer workers.Done()
		for i := 0; i < 1000; i++ {
			if !admission.RepairRequired() {
				t.Error("concurrent benign update lost pending denial")
				return
			}
		}
	}()
	workers.Wait()
}

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
