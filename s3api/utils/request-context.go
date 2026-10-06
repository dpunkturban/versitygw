// Copyright 2026 Versity Software
// This file is licensed under the Apache License, Version 2.0
// (the "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package utils

import (
	"context"

	"github.com/valyala/fasthttp"
)

// RequestContext is the context.Context the gateway hands to backends for
// one request.
//
// Values come from the fasthttp request: everything the middlewares store
// with ctx.Locals (the account, the bucket owner, the RDMA descriptor) is
// still found with ctx.Value(key) in the backend.
//
// Cancellation comes from the server lifetime context instead of the
// request. *fasthttp.RequestCtx is canceled the moment the server starts to
// shut down, because its Done channel is the server's own done channel.
// Handing that to a backend aborts every in-flight upload and download at
// SIGTERM, so the graceful shutdown drains nothing that does backend I/O.
// The lifetime context is canceled only once the drain timeout has passed,
// so a transfer that can finish within the timeout does finish.
type RequestContext struct {
	context.Context
	rctx *fasthttp.RequestCtx
}

// NewRequestContext returns the context for one request. lifetime is the
// server lifetime context and rctx the fasthttp request the values come from.
func NewRequestContext(lifetime context.Context, rctx *fasthttp.RequestCtx) *RequestContext {
	return &RequestContext{Context: lifetime, rctx: rctx}
}

// Value returns the fasthttp user value stored under key, and falls back to
// the lifetime context when the request holds none.
func (c *RequestContext) Value(key any) any {
	if c.rctx != nil {
		if v := c.rctx.Value(key); v != nil {
			return v
		}
	}
	return c.Context.Value(key)
}

// FastHTTPRequestCtx returns the *fasthttp.RequestCtx behind ctx. It accepts
// both the raw request context and a RequestContext, so code that needs the
// request itself (response headers, the connection) keeps working when a
// backend is called with either.
func FastHTTPRequestCtx(ctx context.Context) (*fasthttp.RequestCtx, bool) {
	switch c := ctx.(type) {
	case *fasthttp.RequestCtx:
		return c, c != nil
	case *RequestContext:
		return c.rctx, c.rctx != nil
	}
	return nil, false
}
