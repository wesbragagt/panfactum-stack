package main

import (
	"context"
	"net"
	"testing"
	"time"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extproc "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
)

func wireClient(t *testing.T, overrides ...*policy) extproc.ExternalProcessorClient {
	t.Helper()
	listener := bufconn.Listen(1024 * 1024)
	server := grpc.NewServer()
	p := &policy{values: map[string]string{
		"csp": "synthetic-html-policy", "csp_non_html": "synthetic-non-html-policy",
		"permissions_policy": "synthetic-permissions", "x_frame_options": "SAMEORIGIN",
		"x_xss_protection": "1; mode=block", "referrer_policy": "no-referrer",
	}}
	if len(overrides) > 0 {
		p = overrides[0]
	}
	extproc.RegisterExternalProcessorServer(server, p)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	connection, err := grpc.NewClient("passthrough:///synthetic", grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return listener.Dial() }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return extproc.NewExternalProcessorClient(connection)
}

func headers(pairs ...string) *core.HeaderMap {
	result := &core.HeaderMap{}
	for n := 0; n < len(pairs); n += 2 {
		result.Headers = append(result.Headers, &core.HeaderValue{Key: pairs[n], RawValue: []byte(pairs[n+1])})
	}
	return result
}

func TestEmptyAndRepeatedHeadersSurviveProtobufTransport(t *testing.T) {
	client := wireClient(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	stream, err := client.Process(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.CloseSend()
	if err = stream.Send(&extproc.ProcessingRequest{Request: &extproc.ProcessingRequest_RequestHeaders{
		RequestHeaders: &extproc.HttpHeaders{Headers: headers(":scheme", "https")},
	}}); err != nil {
		t.Fatal(err)
	}
	if _, err = stream.Recv(); err != nil {
		t.Fatal(err)
	}
	if err = stream.Send(&extproc.ProcessingRequest{Request: &extproc.ProcessingRequest_ResponseHeaders{
		ResponseHeaders: &extproc.HttpHeaders{Headers: headers(":status", "200", "content-type", "text/html",
			"content-security-policy", "", "content-security-policy", "synthetic-second", "permissions-policy", "")},
	}}); err != nil {
		t.Fatal(err)
	}
	response, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	mutation := response.GetResponseHeaders().GetResponse().GetHeaderMutation()
	for _, changed := range mutation.GetSetHeaders() {
		if changed.Header.Key == "content-security-policy" || changed.Header.Key == "permissions-policy" {
			t.Fatal("present empty/repeated upstream policy must not be replaced")
		}
	}
}

func TestInterleavedHTTPAndHTTPSStreamsDoNotShareScheme(t *testing.T) {
	client := wireClient(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	streams := make([]extproc.ExternalProcessor_ProcessClient, 2)
	for index, scheme := range []string{"https", "http"} {
		stream, err := client.Process(ctx)
		if err != nil {
			t.Fatal(err)
		}
		streams[index] = stream
		defer stream.CloseSend()
		if err = stream.Send(&extproc.ProcessingRequest{Request: &extproc.ProcessingRequest_RequestHeaders{
			RequestHeaders: &extproc.HttpHeaders{Headers: headers(":scheme", scheme)},
		}}); err != nil {
			t.Fatal(err)
		}
		if _, err = stream.Recv(); err != nil {
			t.Fatal(err)
		}
	}
	for index, stream := range streams {
		if err := stream.Send(&extproc.ProcessingRequest{Request: &extproc.ProcessingRequest_ResponseHeaders{
			ResponseHeaders: &extproc.HttpHeaders{Headers: headers(":status", "200", "content-type", "application/json")},
		}}); err != nil {
			t.Fatal(err)
		}
		response, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		hsts := false
		for _, changed := range response.GetResponseHeaders().GetResponse().GetHeaderMutation().GetSetHeaders() {
			hsts = hsts || changed.Header.Key == "strict-transport-security"
		}
		if hsts != (index == 0) {
			t.Fatal("scheme leaked between simultaneous requests")
		}
	}
}
