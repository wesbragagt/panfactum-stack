package main

import (
	"context"
	extproc "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"testing"
	"time"
)

func bodyStream(t *testing.T, cap uint64) extproc.ExternalProcessor_ProcessClient {
	t.Helper()
	client := wireClient(t, &policy{maxRequestBytes: cap, bodyOnly: true})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	t.Cleanup(cancel)
	stream, err := client.Process(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stream.CloseSend() })
	return stream
}
func TestDeclaredOversizeAndInvalidLengthRejectedBeforeBody(t *testing.T) {
	for _, scenario := range []struct {
		length string
		status int32
	}{{"6", 413}, {"-1", 400}, {"not-a-size", 400}, {"9223372036854775808", 400}} {
		t.Run(scenario.length, func(t *testing.T) {
			client := wireClient(t, &policy{maxRequestBytes: 5})
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			stream, err := client.Process(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer stream.CloseSend()
			if err = stream.Send(&extproc.ProcessingRequest{Request: &extproc.ProcessingRequest_RequestHeaders{RequestHeaders: &extproc.HttpHeaders{Headers: headers(":scheme", "https", ":authority", "synthetic.example", "content-length", scenario.length)}}}); err != nil {
				t.Fatal(err)
			}
			response, err := stream.Recv()
			if err != nil || int32(response.GetImmediateResponse().GetStatus().GetCode()) != scenario.status {
				t.Fatal("declared body admission", err, response)
			}
		})
	}
}
func TestBodyBoundaryAndChunkedOverflow(t *testing.T) {
	for _, scenario := range []struct {
		name   string
		last   int
		reject bool
	}{{"at_cap", 3, false}, {"overflow", 4, true}} {
		t.Run(scenario.name, func(t *testing.T) {
			stream := bodyStream(t, 5)
			for index, size := range []int{2, scenario.last} {
				if err := stream.Send(&extproc.ProcessingRequest{Request: &extproc.ProcessingRequest_RequestBody{RequestBody: &extproc.HttpBody{Body: make([]byte, size), EndOfStream: index == 1}}}); err != nil {
					t.Fatal(err)
				}
				response, err := stream.Recv()
				if err != nil {
					t.Fatal(err)
				}
				if index == 1 && scenario.reject {
					if response.GetImmediateResponse().GetStatus().GetCode() != 413 {
						t.Fatal("overflow accepted")
					}
				} else if response.GetRequestBody() == nil || response.GetRequestBody().GetResponse().GetBodyMutation() != nil {
					t.Fatal("processor replaced body")
				}
			}
		})
	}
}
func TestHeaderOnlyStageRejectsUnexpectedBody(t *testing.T) {
	client := wireClient(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	stream, err := client.Process(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.CloseSend()
	if err = stream.Send(&extproc.ProcessingRequest{Request: &extproc.ProcessingRequest_RequestBody{RequestBody: &extproc.HttpBody{Body: []byte("synthetic")}}}); err != nil {
		t.Fatal(err)
	}
	if _, err = stream.Recv(); err == nil {
		t.Fatal("header stage accepted body messages")
	}
}
func TestBodyStageOnlyOptsOutAfterRealWebSocketSwitch(t *testing.T) {
	for _, scenario := range []struct {
		status, upgrade string
		override        bool
	}{{"101", "websocket", true}, {"200", "websocket", false}, {"101", "", false}} {
		t.Run(scenario.status+scenario.upgrade, func(t *testing.T) {
			stream := bodyStream(t, 5)
			if err := stream.Send(&extproc.ProcessingRequest{Request: &extproc.ProcessingRequest_ResponseHeaders{ResponseHeaders: &extproc.HttpHeaders{Headers: headers(":status", scenario.status, "upgrade", scenario.upgrade, "content-security-policy", "synthetic-upstream")}}}); err != nil {
				t.Fatal(err)
			}
			response, err := stream.Recv()
			if err != nil {
				t.Fatal(err)
			}
			if (response.ModeOverride != nil) != scenario.override {
				t.Fatal("incorrect protocol switch exemption")
			}
			if response.GetResponseHeaders().GetResponse().GetHeaderMutation() != nil {
				t.Fatal("body stage changed upstream headers")
			}
		})
	}
}
