package dns

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/log"
	D "github.com/miekg/dns"
)

type privateDNSLogClient struct{}

func (privateDNSLogClient) Address() string  { return "udp://192.0.2.1:53" }
func (privateDNSLogClient) ResetConnection() {}
func (privateDNSLogClient) ExchangeContext(_ context.Context, request *D.Msg) (*D.Msg, error) {
	answer := new(D.Msg)
	answer.SetReply(request)
	record, _ := D.NewRR("private.example.invalid. 60 IN A 10.0.0.42")
	answer.Answer = []D.RR{record}
	return answer, nil
}

func TestPrivateDNSExchangeLogsDoNotExposeQueryOrAnswer(t *testing.T) {
	subscription := log.Subscribe()
	defer log.UnSubscribe(subscription)
	request := new(D.Msg)
	request.SetQuestion("private.example.invalid.", D.TypeA)
	if _, _, err := batchExchange(context.Background(), []dnsClient{privateDNSLogClient{}}, request); err != nil {
		t.Fatal(err)
	}
	deadline := time.After(2 * time.Second)
	seen := 0
	for seen < 2 {
		select {
		case event := <-subscription:
			if !strings.Contains(event.Payload, "[DNS]") {
				continue
			}
			seen++
			if strings.Contains(event.Payload, "private.example.invalid") ||
				strings.Contains(event.Payload, "10.0.0.42") {
				t.Fatal("DNS debug log exposed a protected query or answer")
			}
		case <-deadline:
			t.Fatal("DNS exchange did not emit expected diagnostic events")
		}
	}
}
