package main

import "sync/atomic"

const (
	nativeModeKnown uint32 = 1 << iota
	nativeTunRequired
	nativeTunReady
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
		next := old&nativeTunReady | nativeModeKnown
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
			next |= nativeTunReady
		}
		if a.flags.CompareAndSwap(old, next) {
			return
		}
	}
}

func (a *nativeVpnAdmission) AllowsTransport() bool {
	flags := a.flags.Load()
	return flags&nativeModeKnown != 0 &&
		(flags&nativeTunRequired == 0 || flags&nativeTunReady != 0)
}

// A running timestamp alone can survive a failed TUN constructor. Publishing
// readiness requires both installed protection and a live listener.
func nativeVpnReady(running, protection, listener bool) bool {
	return running && protection && listener
}
