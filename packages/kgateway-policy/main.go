// An ExtProc candidate for Panfactum's nginx Lua policy semantics.
// Request limits and streaming body limits are opt-in experimental.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extproc "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	typepb "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

type policy struct {
	extproc.UnimplementedExternalProcessorServer
	values          map[string]string
	limits          *requestLimits
	maxRequestBytes uint64
	bodyOnly        bool
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
	var release func()
	defer func() {
		if release != nil {
			release()
		}
	}()
	seenRequest := false
	var received uint64
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
			if p.bodyOnly {
				return io.ErrUnexpectedEOF
			}
			if seenRequest {
				return io.ErrUnexpectedEOF
			}
			seenRequest = true
			if denied := declaredBodyRejection(item.RequestHeaders.Headers, p.maxRequestBytes); denied != nil {
				return stream.Send(denied)
			}

			if p.limits != nil {
				key, valid := clientKey(message)
				var accepted bool
				if valid {
					release, accepted = p.limits.acquire(key, time.Now())
				}
				if !accepted {
					return stream.Send(reject(typepb.StatusCode_TooManyRequests, "policy_request_limit"))
				}
			}
			scheme, _ := header(item.RequestHeaders.Headers, ":scheme")
			https = scheme == "https"
			response = &extproc.ProcessingResponse{Response: &extproc.ProcessingResponse_RequestHeaders{
				RequestHeaders: &extproc.HeadersResponse{},
			}}

		case *extproc.ProcessingRequest_ResponseHeaders:
			if p.bodyOnly {
				response = bodyResponseHeaders(item.ResponseHeaders.Headers)
				break
			}
			response = &extproc.ProcessingResponse{Response: &extproc.ProcessingResponse_ResponseHeaders{
				ResponseHeaders: &extproc.HeadersResponse{Response: &extproc.CommonResponse{
					HeaderMutation: p.response(item.ResponseHeaders.Headers, https),
				}},
			}}

		case *extproc.ProcessingRequest_RequestBody:
			if !p.bodyOnly || p.maxRequestBytes == 0 {
				return io.ErrUnexpectedEOF
			}
			count := uint64(len(item.RequestBody.Body))
			if count > p.maxRequestBytes-received {
				return stream.Send(reject(typepb.StatusCode_PayloadTooLarge, "policy_request_body_limit"))
			}
			received += count
			response = &extproc.ProcessingResponse{Response: &extproc.ProcessingResponse_RequestBody{RequestBody: &extproc.BodyResponse{Response: &extproc.CommonResponse{}}}}
		case *extproc.ProcessingRequest_RequestTrailers:
			response = &extproc.ProcessingResponse{Response: &extproc.ProcessingResponse_RequestTrailers{RequestTrailers: &extproc.TrailersResponse{}}}
		case *extproc.ProcessingRequest_ResponseTrailers:
			response = &extproc.ProcessingResponse{Response: &extproc.ProcessingResponse_ResponseTrailers{ResponseTrailers: &extproc.TrailersResponse{}}}
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
	bodyAddress := flag.String("body-listen", "127.0.0.1:18085", "optional body-counting listener; loopback only")
	bodyCheck := flag.Bool("body-check", false, "check the optional body listener as well")
	address := flag.String("listen", "127.0.0.1:18083", "gRPC listener; loopback by default")
	configuration := flag.String("config", "/config/headers.json", "public policy values")
	check := flag.Bool("check", false, "check the loopback gRPC health service and exit")
	maxBody := flag.Uint64("max-request-bytes", 0, "experimental streaming request body cap; requires requestBodyMode STREAMED; zero disables")
	limitsEnabled := flag.Bool("request-limits", false, "experimental per-client limits; requires trusted source.address and trailer SEND")
	flag.Parse()
	if *check {
		addresses := []string{*address}
		if *bodyCheck {
			addresses = append(addresses, *bodyAddress)
		}
		for _, target := range addresses {
			connection, e := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
			if e != nil {
				log.Fatal("health client unavailable")
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			result, e := healthpb.NewHealthClient(connection).Check(ctx, &healthpb.HealthCheckRequest{})
			cancel()
			_ = connection.Close()
			if e != nil || result.Status != healthpb.HealthCheckResponse_SERVING {
				log.Fatal("policy service unavailable")
			}
		}
		return
	}
	data, err := os.ReadFile(*configuration)
	if err != nil {
		log.Fatal("policy configuration unavailable")
	}
	if *maxBody > 1<<30 {
		log.Fatal("request body cap exceeds qualified input range")
	}
	p := &policy{maxRequestBytes: *maxBody}
	if json.Unmarshal(data, &p.values) != nil {
		log.Fatal("policy configuration invalid")
	}
	for _, key := range []string{"csp", "csp_non_html", "permissions_policy", "x_frame_options", "x_xss_protection", "referrer_policy"} {
		if p.values[key] == "" || strings.ContainsAny(p.values[key], "\r\n\x00") {
			log.Fatal("required public policy value invalid")
		}
	}
	if *limitsEnabled {
		keys := []string{"limit_rps", "limit_rpm", "limit_concurrency", "limit_clients"}
		values := make([]int, len(keys))
		for i, key := range keys {
			value, e := strconv.Atoi(p.values[key])
			if e != nil {
				log.Fatal("required request limit invalid")
			}
			values[i] = value
		}
		p.limits, err = newRequestLimits(values[0], values[1], values[2], values[3])
		if err != nil {
			log.Fatal("request limit configuration invalid")
		}
	}
	if *maxBody > 0 {
		go servePolicy(*bodyAddress, &policy{bodyOnly: true, maxRequestBytes: *maxBody})
	}
	servePolicy(*address, p)
}

func servePolicy(address string, p *policy) {
	listener, err := net.Listen("tcp", address)
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
