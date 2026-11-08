package main

import (
	"context"
	"encoding/json"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extproc "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"google.golang.org/protobuf/types/known/structpb"
)

func limits(t *testing.T, rps, rpm, concurrent, capacity int) *requestLimits {
	t.Helper()
	l, err := newRequestLimits(rps, rpm, concurrent, capacity)
	if err != nil {
		t.Fatal(err)
	}
	return l
}
func accepted(l *requestLimits, key string, now time.Time) bool {
	release, ok := l.acquire(key, now)
	if ok {
		release()
	}
	return ok
}

func TestLeakyBucketBoundaryAndRejectedDebt(t *testing.T) {
	now := time.Unix(100, 0)
	l := limits(t, 60, 1000, 60, 10)
	for i := 0; i < 181; i++ {
		if !accepted(l, "a", now) {
			t.Fatalf("rejected burst request %d", i+1)
		}
	}
	for i := 0; i < 5; i++ {
		if accepted(l, "a", now.Add(time.Millisecond)) {
			t.Fatal("burst overflow accepted")
		}
	}
	if !accepted(l, "a", now.Add(17*time.Millisecond)) {
		t.Fatal("rejected requests incorrectly committed debt")
	}
	if !accepted(l, "b", now) {
		t.Fatal("separate client shared bucket")
	}
	if !accepted(l, "other-host/a", now) {
		t.Fatal("separate ingress shared bucket")
	}
}
func TestMinuteBucketUsesNginxIntegerRate(t *testing.T) {
	now := time.Unix(100, 0)
	l := limits(t, 100000, 1000, 60, 10)
	for i := 0; i < 3001; i++ {
		if !accepted(l, "a", now) {
			t.Fatalf("rejected minute burst request %d", i+1)
		}
	}
	if accepted(l, "a", now.Add(60*time.Millisecond)) {
		t.Fatal("RPM decay rounded upward")
	}
	if !accepted(l, "a", now.Add(61*time.Millisecond)) {
		t.Fatal("RPM debt did not decay")
	}
}
func TestConcurrencyReleaseAndCapacity(t *testing.T) {
	now := time.Unix(100, 0)
	l := limits(t, 60, 1000, 2, 1)
	first, ok := l.acquire("a", now)
	if !ok {
		t.Fatal("first")
	}
	second, ok := l.acquire("a", now)
	if !ok {
		t.Fatal("second")
	}
	if _, ok = l.acquire("a", now); ok {
		t.Fatal("concurrency overflow")
	}
	if accepted(l, "b", now.Add(time.Hour)) {
		t.Fatal("evicted active identity")
	}
	first()
	first()
	if !accepted(l, "a", now) {
		t.Fatal("slot not released")
	}
	second()
	if accepted(l, "b", now) {
		t.Fatal("evicted identity with remaining rate debt")
	}
	if !accepted(l, "b", now.Add(time.Hour)) {
		t.Fatal("drained inactive identity not reclaimed")
	}
	if len(l.states) != 1 {
		t.Fatal("unbounded identity state")
	}
}
func TestConcurrentAdmissionAtomic(t *testing.T) {
	now := time.Unix(100, 0)
	l := limits(t, 100000, 10000000, 17, 10)
	var admitted atomic.Int32
	var wait sync.WaitGroup
	releases := make(chan func(), 100)
	for i := 0; i < 100; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if release, ok := l.acquire("a", now); ok {
				admitted.Add(1)
				releases <- release
			}
		}()
	}
	wait.Wait()
	close(releases)
	if admitted.Load() != 17 {
		t.Fatalf("admitted %d", admitted.Load())
	}
	for f := range releases {
		f()
	}
	if !accepted(l, "a", now) {
		t.Fatal("atomic slots leaked")
	}
}
func TestOnlyProtectedAddressAttributeProvidesClientIdentity(t *testing.T) {
	attrs, _ := structpb.NewStruct(map[string]any{"source.address": "2001:db8::5"})
	request := &extproc.ProcessingRequest{Attributes: map[string]*structpb.Struct{"envoy.filters.http.ext_proc": attrs}, Request: &extproc.ProcessingRequest_RequestHeaders{RequestHeaders: &extproc.HttpHeaders{Headers: &core.HeaderMap{Headers: []*core.HeaderValue{{Key: ":authority", RawValue: []byte("AUTHENTIK.example")}, {Key: "x-forwarded-for", RawValue: []byte("198.51.100.99")}}}}}}
	key, ok := clientKey(request)
	if !ok || key != "authentik.example\x002001:db8::5" {
		t.Fatalf("unexpected key %q", key)
	}
	for _, address := range []string{"[2001:db8::5]:4567", "[2001:db8::5]:5678"} {
		socketAddress, _ := structpb.NewStruct(map[string]any{"source.address": address})
		request.Attributes = map[string]*structpb.Struct{"envoy.filters.http.ext_proc": socketAddress}
		got, valid := clientKey(request)
		if !valid || got != key {
			t.Fatal("socket port split client identity", got)
		}
	}
	request.Attributes = nil
	if _, ok = clientKey(request); ok {
		t.Fatal("trusted spoofable client header")
	}
	attrs, _ = structpb.NewStruct(map[string]any{"source.address": "bad/address"})
	request.Attributes = map[string]*structpb.Struct{"envoy.filters.http.ext_proc": attrs}
	if _, ok = clientKey(request); ok {
		t.Fatal("accepted invalid attribute")
	}
}

func TestGRPCConcurrentRejectionAndCancellationRelease(t *testing.T) {
	l := limits(t, 100000, 10000000, 1, 10)
	client := wireClient(t, &policy{values: map[string]string{}, limits: l})
	attrs, _ := structpb.NewStruct(map[string]any{"source.address": "198.51.100.4"})
	req := &extproc.ProcessingRequest{Attributes: map[string]*structpb.Struct{"envoy.filters.http.ext_proc": attrs}, Request: &extproc.ProcessingRequest_RequestHeaders{RequestHeaders: &extproc.HttpHeaders{Headers: headers(":scheme", "https", ":authority", "synthetic.example")}}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first, err := client.Process(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err = first.Send(req); err != nil {
		t.Fatal(err)
	}
	if response, e := first.Recv(); e != nil || response.GetRequestHeaders() == nil {
		t.Fatal("first admission failed", e)
	}
	rejected, err := client.Process(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer rejected.CloseSend()
	if err = rejected.Send(req); err != nil {
		t.Fatal(err)
	}
	response, err := rejected.Recv()
	if err != nil || response.GetImmediateResponse().GetStatus().GetCode() != 429 {
		t.Fatal("concurrent request not rejected", err)
	}
	cancel()
	deadline := time.Now().Add(time.Second)
	for {
		l.mu.Lock()
		active := l.states["synthetic.example\x00198.51.100.4"].Value.(*clientState).active
		l.mu.Unlock()
		if active == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("cancelled RPC leaked concurrency slot")
		}
		time.Sleep(time.Millisecond)
	}
	if !accepted(l, "synthetic.example\x00198.51.100.4", time.Now()) {
		t.Fatal("released client rejected")
	}
}

func TestAuthorityVariantsCannotSplitOneClientQuota(t *testing.T) {
	attrs, _ := structpb.NewStruct(map[string]any{"source.address": "198.51.100.1:1234"})
	for _, host := range []string{"AUTHENTIK.example", "authentik.example.", "authentik.example:443", "authentik.example:12345", "AUTHENTIK.example.:8443"} {
		message := &extproc.ProcessingRequest{Attributes: map[string]*structpb.Struct{"envoy.filters.http.ext_proc": attrs}, Request: &extproc.ProcessingRequest_RequestHeaders{RequestHeaders: &extproc.HttpHeaders{Headers: headers(":authority", host)}}}
		key, ok := clientKey(message)
		if !ok || key != "authentik.example\x00198.51.100.1" {
			t.Fatalf("authority split quota: %q %q", host, key)
		}
	}
}

func TestNginxMillisecondClockDoesNotLoseFractionalDecay(t *testing.T) {
	now := time.Unix(100, 900000)
	l := limits(t, 60, 1000, 60, 10)
	for i := 0; i < 181; i++ {
		if !accepted(l, "a", now) {
			t.Fatal("initial burst")
		}
	}
	if !accepted(l, "a", time.Unix(100, 17100000)) {
		t.Fatal("fractional timestamps incorrectly reduced refill")
	}
}

func TestActualNginxMillisecondRateTraces(t *testing.T) {
	data, err := os.ReadFile("testdata/nginx-rate-traces.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name                           string
			RPS, RPM, Concurrent, Requests int
			Observations                   []struct {
				MS                 int64
				Accepted, Rejected int
			}
		}
	}
	if err = json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) != 2 {
		t.Fatal("missing nginx cases")
	}
	for _, scenario := range fixture.Cases {
		t.Run(scenario.Name, func(t *testing.T) {
			limiter := limits(t, scenario.RPS, scenario.RPM, scenario.Concurrent, 10)
			total := 0
			for _, observation := range scenario.Observations {
				got := 0
				count := observation.Accepted + observation.Rejected
				for i := 0; i < count; i++ {
					if accepted(limiter, "synthetic", time.UnixMilli(100000+observation.MS)) {
						got++
					}
				}
				if got != observation.Accepted {
					t.Fatalf("nginx ms%d: admitted%d wanted%d over%d requests", observation.MS, got, observation.Accepted, count)
				}
				total += count
			}
			if total != scenario.Requests {
				t.Fatal("trace truncated")
			}
		})
	}
}
