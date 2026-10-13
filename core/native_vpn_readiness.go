package main

import "sync/atomic"

const (
	nativeModeKnown uint32 = 1 << iota
	nativeTunRequired
	nativeTunReady
	nativeTransportDenied
)

// A single atomic snapshot is read by the CorpLink dial guard. It must never
// depend on native lifecycle locks, mutable CoreState or JNI on a hot path.
type nativeVpnAdmission struct{ flags atomic.Uint32 }

// Installed only by the Android library. Other platforms retain their state
// update behavior and do not acquire a native startup dependency.
var nativeVpnStateChanged func(string)

func (a *nativeVpnAdmission) SetMode(required bool) {
	for {
		old := a.flags.Load()
		next := old&(nativeTunReady|nativeTransportDenied) | nativeModeKnown
		if required {
			next |= nativeTunRequired
		}
		if a.flags.CompareAndSwap(old, next) {
			return
		}
	}
}

func (a *nativeVpnAdmission) SetReady(ready bool) {
	for {
		old := a.flags.Load()
		next := old &^ nativeTunReady
		if ready {
			next &^= nativeTransportDenied
			next |= nativeTunReady
		}
		if a.flags.CompareAndSwap(old, next) {
			return
		}
	}
}

// Publish the authoritative mode and readiness together, only after a native
// start succeeds. For VPN mode the caller must have installed protect/listener
// first; proxy-only mode has no TUN and must not retain stale TUN readiness.
func (a *nativeVpnAdmission) SetStarted(required bool) {
	flags := nativeModeKnown
	if required {
		flags |= nativeTunRequired | nativeTunReady
	}
	a.flags.Store(flags)
}

// The Android caller holds tunLock while reading the real native resources.
// An invalid snapshot must revoke stale readiness without inventing a denial.
func (a *nativeVpnAdmission) RestoreReady(running, protection, listener bool) bool {
	if !nativeVpnReady(running, protection, listener) {
		a.SetReady(false)
		return false
	}
	a.SetStarted(true)
	return true
}

func (a *nativeVpnAdmission) AllowsTransport() bool {
	for {
		flags := a.flags.Load()
		if nativeVpnAllowsTransport(flags) {
			return true
		}
		// Record only an actual refusal. A concurrent readiness publication
		// invalidates this snapshot, so retry rather than restoring its denial.
		if a.flags.CompareAndSwap(flags, flags|nativeTransportDenied) {
			return false
		}
	}
}

func (a *nativeVpnAdmission) RepairRequired() bool {
	flags := a.flags.Load()
	return flags&nativeTransportDenied != 0 && !nativeVpnAllowsTransport(flags)
}

func nativeVpnAllowsTransport(flags uint32) bool {
	return flags&nativeModeKnown != 0 &&
		(flags&nativeTunRequired == 0 || flags&nativeTunReady != 0)
}

// A running timestamp alone can survive a failed TUN constructor. Publishing
// readiness requires both installed protection and a live listener.
func nativeVpnReady(running, protection, listener bool) bool {
	return running && protection && listener
}
