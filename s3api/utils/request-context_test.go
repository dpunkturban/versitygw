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
	"errors"
	"testing"

	"github.com/valyala/fasthttp"
)

type lifetimeKey struct{}

func TestRequestContext_valuesComeFromTheRequestFirst(t *testing.T) {
	rctx := &fasthttp.RequestCtx{}
	rctx.SetUserValue("account", "request-account")
	rctx.SetUserValue("shared", "from-request")

	lifetime := context.WithValue(context.Background(), lifetimeKey{}, "from-lifetime")
	lifetime = context.WithValue(lifetime, "shared", "from-lifetime") //nolint:staticcheck // string key mirrors the request values

	ctx := NewRequestContext(lifetime, rctx)

	if got := ctx.Value("account"); got != "request-account" {
		t.Errorf("Value(account) = %v, want the request user value", got)
	}
	if got := ctx.Value("shared"); got != "from-request" {
		t.Errorf("Value(shared) = %v, want the request value to win", got)
	}
	if got := ctx.Value(lifetimeKey{}); got != "from-lifetime" {
		t.Errorf("Value(lifetimeKey) = %v, want the lifetime value as fallback", got)
	}
	if got := ctx.Value("missing"); got != nil {
		t.Errorf("Value(missing) = %v, want nil", got)
	}
}

func TestRequestContext_toleratesANilRequest(t *testing.T) {
	ctx := NewRequestContext(context.WithValue(context.Background(), lifetimeKey{}, 1), nil)
	if got := ctx.Value(lifetimeKey{}); got != 1 {
		t.Errorf("Value(lifetimeKey) = %v, want 1", got)
	}
	if _, ok := FastHTTPRequestCtx(ctx); ok {
		t.Error("FastHTTPRequestCtx() reported a request for a nil request")
	}
}

// The request's own Done channel is the server shutdown signal. The
// RequestContext must not expose it: it is done only when the lifetime ends.
func TestRequestContext_isCanceledByTheLifetimeOnly(t *testing.T) {
	lifetime, stop := context.WithCancel(context.Background())
	defer stop()

	ctx := NewRequestContext(lifetime, &fasthttp.RequestCtx{})

	select {
	case <-ctx.Done():
		t.Fatal("context done before the lifetime ended")
	default:
	}
	if err := ctx.Err(); err != nil {
		t.Fatalf("Err() = %v before the lifetime ended", err)
	}

	stop()

	select {
	case <-ctx.Done():
	default:
		t.Fatal("context not done after the lifetime ended")
	}
	if err := ctx.Err(); !errors.Is(err, context.Canceled) {
		t.Fatalf("Err() = %v, want context.Canceled", err)
	}
}

func TestFastHTTPRequestCtx(t *testing.T) {
	rctx := &fasthttp.RequestCtx{}

	got, ok := FastHTTPRequestCtx(rctx)
	if !ok || got != rctx {
		t.Errorf("FastHTTPRequestCtx(raw) = %v, %v; want the request itself", got, ok)
	}

	got, ok = FastHTTPRequestCtx(NewRequestContext(context.Background(), rctx))
	if !ok || got != rctx {
		t.Errorf("FastHTTPRequestCtx(RequestContext) = %v, %v; want the wrapped request", got, ok)
	}

	if got, ok := FastHTTPRequestCtx(context.Background()); ok || got != nil {
		t.Errorf("FastHTTPRequestCtx(Background) = %v, %v; want none", got, ok)
	}
}
