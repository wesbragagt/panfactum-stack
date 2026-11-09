package main

import (
	"strconv"
	"strings"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	processing "github.com/envoyproxy/go-control-plane/envoy/extensions/filters/http/ext_proc/v3"
	extproc "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	typepb "github.com/envoyproxy/go-control-plane/envoy/type/v3"
)

func reject(code typepb.StatusCode, detail string) *extproc.ProcessingResponse {
	// Native listener local-reply policy supplies fixed plaintext and security
	// headers even if this processor is unavailable. Never reflect request data.
	return &extproc.ProcessingResponse{Response: &extproc.ProcessingResponse_ImmediateResponse{ImmediateResponse: &extproc.ImmediateResponse{Status: &typepb.HttpStatus{Code: code}, Details: detail}}}
}

func declaredBodyRejection(headers *core.HeaderMap, maximum uint64) *extproc.ProcessingResponse {
	if maximum == 0 {
		return nil
	}
	raw, present := header(headers, "content-length")
	if !present {
		return nil
	}
	size, err := strconv.ParseUint(strings.Trim(raw, " \t"), 10, 63)
	if err != nil {
		return reject(typepb.StatusCode_BadRequest, "policy_invalid_content_length")
	}
	if size > maximum {
		return reject(typepb.StatusCode_PayloadTooLarge, "policy_request_body_limit")
	}
	return nil
}

func bodyResponseHeaders(headers *core.HeaderMap) *extproc.ProcessingResponse {
	response := &extproc.ProcessingResponse{Response: &extproc.ProcessingResponse_ResponseHeaders{ResponseHeaders: &extproc.HeadersResponse{}}}
	status, _ := header(headers, ":status")
	upgrade, _ := header(headers, "upgrade")
	// Count HTTP bytes until a real upstream WebSocket switch. Header processing
	// is skipped by this separate filter so a body-free handshake cannot stall.
	if status == "101" && strings.EqualFold(upgrade, "websocket") {
		response.ModeOverride = &processing.ProcessingMode{RequestHeaderMode: processing.ProcessingMode_SKIP, ResponseHeaderMode: processing.ProcessingMode_SEND, RequestBodyMode: processing.ProcessingMode_NONE, ResponseBodyMode: processing.ProcessingMode_NONE, RequestTrailerMode: processing.ProcessingMode_SKIP, ResponseTrailerMode: processing.ProcessingMode_SKIP}
	}
	return response
}
