package outbound

import (
	"reflect"
	"testing"
)

type reconnectRecordingBind struct {
	wireGuardBind
	events *[]string
}

func (b *reconnectRecordingBind) ReconnectTransport() {
	*b.events = append(*b.events, "transport reset")
}

type reconnectRecordingDevice struct {
	wireguardGoDevice
	events *[]string
}

func (d *reconnectRecordingDevice) RestartHandshakeForPeers() {
	*d.events = append(*d.events, "new handshake")
}

func TestWireGuardReconnectStartsNewHandshakeAfterTransportReset(t *testing.T) {
	var events []string
	w := &WireGuard{
		option: WireGuardOption{TCP: true},
		bind:   &reconnectRecordingBind{events: &events},
		device: &reconnectRecordingDevice{events: &events},
	}

	w.Reconnect()
	if want := []string{"transport reset", "new handshake"}; !reflect.DeepEqual(events, want) {
		t.Fatalf("Reconnect events = %v, want %v", events, want)
	}
}
