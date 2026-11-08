// A header-only ExtProc candidate for Panfactum's nginx Lua policy semantics.
// Body, rate, connection and production qualification are separate gates.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"time"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extproc "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

type policy struct {
	extproc.UnimplementedExternalProcessorServer
	values map[string]string
}

func header(headers *core.HeaderMap, name string) (string, bool) {
	for _, item := range headers.GetHeaders() {
		if strings.EqualFold(item.Key, name) {
			if item.RawValue != nil {
				return string(item.RawValue), true
			}
			return item.Value, true
		}
	}
	return "", false
}

func (p *policy) response(headers *core.HeaderMap, https bool) *extproc.HeaderMutation {
	mutation := &extproc.HeaderMutation{}
	set := func(name, value string) {
		mutation.SetHeaders = append(mutation.SetHeaders, &core.HeaderValueOption{
			Header:       &core.HeaderValue{Key: name, RawValue: []byte(value)},
			AppendAction: core.HeaderValueOption_OVERWRITE_IF_EXISTS_OR_ADD,
		})
	}
	status, _ := header(headers, ":status")
	contentType, hasContentType := header(headers, "content-type")
	// nginx treats its special empty Content-Type field as absent, unlike an
	// ordinary empty CSP/Permissions-Policy field. Match the actual wire oracle.
	if hasContentType && contentType == "" {
		mutation.RemoveHeaders = append(mutation.RemoveHeaders, "content-type")
	}
	if status != "" && !strings.HasPrefix(status, "3") && hasContentType && contentType != "" {
		html := strings.Contains(contentType, "html")
		if _, present := header(headers, "content-security-policy"); !present {
			name := "csp_non_html"
			if html {
				name = "csp"
			}
			set("content-security-policy", p.values[name])
		}
		if html {
			if _, present := header(headers, "permissions-policy"); !present {
				set("permissions-policy", p.values["permissions_policy"])
			}
			set("x-frame-options", p.values["x_frame_options"])
			set("x-xss-protection", p.values["x_xss_protection"])
			set("referrer-policy", p.values["referrer_policy"])
		}
	}
	if https {
		set("strict-transport-security", "max-age=315360000; includeSubDomains; preload")
	}
	return mutation
}

func (p *policy) Process(stream extproc.ExternalProcessor_ProcessServer) error {
	https := false
	for {
		message, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		var response *extproc.ProcessingResponse
		switch item := message.Request.(type) {
		case *extproc.ProcessingRequest_RequestHeaders:
			scheme, _ := header(item.RequestHeaders.Headers, ":scheme")
			https = scheme == "https"
			response = &extproc.ProcessingResponse{Response: &extproc.ProcessingResponse_RequestHeaders{
				RequestHeaders: &extproc.HeadersResponse{},
			}}
		case *extproc.ProcessingRequest_ResponseHeaders:
			response = &extproc.ProcessingResponse{Response: &extproc.ProcessingResponse_ResponseHeaders{
				ResponseHeaders: &extproc.HeadersResponse{Response: &extproc.CommonResponse{
					HeaderMutation: p.response(item.ResponseHeaders.Headers, https),
				}},
			}}
		default:
			// A header-only configuration must never request body/trailer processing.
			return io.ErrUnexpectedEOF
		}
		if err := stream.Send(response); err != nil {
			return err
		}
	}
}

func main() {
	address := flag.String("listen", "127.0.0.1:18083", "gRPC listener; loopback by default")
	configuration := flag.String("config", "/config/headers.json", "public policy values")
	check := flag.Bool("check", false, "check the loopback gRPC health service and exit")
	flag.Parse()
	if *check {
		connection, err := grpc.NewClient(*address, grpc.WithTransportCredentials(insecure.NewCredentials()))
		if err != nil {
			log.Fatal("health client unavailable")
		}
		defer connection.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		result, err := healthpb.NewHealthClient(connection).Check(ctx, &healthpb.HealthCheckRequest{})
		if err != nil || result.Status != healthpb.HealthCheckResponse_SERVING {
			log.Fatal("policy service unavailable")
		}
		return
	}
	data, err := os.ReadFile(*configuration)
	if err != nil {
		log.Fatal("policy configuration unavailable")
	}
	p := &policy{}
	if json.Unmarshal(data, &p.values) != nil {
		log.Fatal("policy configuration invalid")
	}
	for _, key := range []string{"csp", "csp_non_html", "permissions_policy", "x_frame_options", "x_xss_protection", "referrer_policy"} {
		if p.values[key] == "" || strings.ContainsAny(p.values[key], "\r\n\x00") {
			log.Fatal("required public policy value invalid")
		}
	}
	listener, err := net.Listen("tcp", *address)
	if err != nil {
		log.Fatal("policy listener unavailable")
	}
	server := grpc.NewServer(grpc.MaxRecvMsgSize(128*1024), grpc.MaxConcurrentStreams(256))
	extproc.RegisterExternalProcessorServer(server, p)
	healthpb.RegisterHealthServer(server, health.NewServer())
	if server.Serve(listener) != nil {
		log.Fatal("policy service stopped")
	}
}
