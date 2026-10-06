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

	"github.com/gofiber/fiber/v3"
	"github.com/versity/versitygw/s3api/utils"
)

// RequestContext installs the context.Context that the handlers pass to the
// backend as ctx.Context(). It carries the request's values and is canceled
// with the server lifetime, not with the start of the shutdown. See
// utils.RequestContext for why the raw fasthttp request does not do.
//
// Register it before every route so every handler and middleware sees it.
func RequestContext(lifetime context.Context) fiber.Handler {
	return func(ctx fiber.Ctx) error {
		ctx.SetContext(utils.NewRequestContext(lifetime, ctx.RequestCtx()))
		return ctx.Next()
	}
}
