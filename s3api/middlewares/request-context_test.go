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

package middlewares

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gofiber/fiber/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/versity/versitygw/s3api/utils"
)

func TestRequestContext(t *testing.T) {
	lifetime, stop := context.WithCancel(context.Background())
	defer stop()

	app := fiber.New()
	app.Use("*", RequestContext(lifetime))
	app.Get("/", func(ctx fiber.Ctx) error {
		ctx.Locals("account", "the-account")

		rc, ok := ctx.Context().(*utils.RequestContext)
		require.True(t, ok, "ctx.Context() is %T, want *utils.RequestContext", ctx.Context())
		assert.Equal(t, "the-account", rc.Value("account"), "request values must be visible through the context")
		assert.NoError(t, rc.Err(), "the context must not be canceled while the lifetime runs")

		rctx, ok := utils.FastHTTPRequestCtx(rc)
		require.True(t, ok)
		assert.Same(t, ctx.RequestCtx(), rctx)

		return ctx.SendStatus(http.StatusNoContent)
	})

	resp, err := app.Test(httptest.NewRequest(http.MethodGet, "/", nil))
	require.NoError(t, err)
	assert.Equal(t, http.StatusNoContent, resp.StatusCode)
}
