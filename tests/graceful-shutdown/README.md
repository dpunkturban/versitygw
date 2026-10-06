# Graceful shutdown drain test

`run.sh` checks that the gateway drains in-flight transfers on SIGTERM and
does not store a truncated upload. It runs the gateway with the azure backend
against Azurite. Everything runs in Docker. Nothing is installed on the host.

## Run

Build the image from the working tree and test it:

```sh
tests/graceful-shutdown/run.sh --build
```

Reproduce the defects with a released image:

```sh
tests/graceful-shutdown/run.sh --image ghcr.io/versity/versitygw:v1.8.0 --expect baseline
```

`--expect baseline` inverts the expectations for the three defect scenarios.
A PASS in that mode means the defect was reproduced.

Options: `--timeout` sets `VGW_SHUTDOWN_TIMEOUT` for the drain scenarios
(default `20s`). `--only NAME` runs one scenario. `--keep` keeps the
containers, the gateway logs and the work directory.

## Scenarios

The test object is 64 MiB. The client is curl with `--limit-rate`, so a
transfer at 4 MiB/s takes 16 s. SIGTERM arrives 3 s into the transfer.

| Scenario | What happens | Fixed | v1.8.0 |
| -- | -- | -- | -- |
| `truncated-put` | Client aborts a PUT after about 24 MiB (`UNSIGNED-PAYLOAD`, no checksum) | 404, no object | 200, about 24 MiB stored |
| `sigterm-get` | SIGTERM 3 s into a 16 s GET | 64 MiB downloaded | cut at SIGTERM |
| `sigterm-put` | SIGTERM 3 s into a 16 s PUT | 200, 64 MiB stored | reset after 10 s, no object |
| `over-timeout-put` | 16 s PUT, `VGW_SHUTDOWN_TIMEOUT=5s` | no object, exit within 8 s | no object, exit after 10 s (the timeout is ignored) |
| `refused-during-drain` | New connection 1 s into the drain | refused | refused |
| `idle-sigterm` | `VGW_SHUTDOWN_TIMEOUT=60s`, no traffic | exit within 3 s | exit within 3 s |

## Why the defects exist

The controllers passed `ctx.RequestCtx()` to the backend as the
`context.Context`. Its `Done` channel is the fasthttp server's done channel,
and `ShutdownWithContext` closes that channel before it waits for open
connections. Every backend call that honors the context therefore failed with
`context canceled` the moment the shutdown started. The posix backend ignores
the context, so it did not show the problem.

The fix hands the backend a `utils.RequestContext`. It reads values from the
request and takes cancellation from a server lifetime context. `ShutDown`
cancels that context only after the drain timeout. The timeout is set with
`--shutdown-timeout` or `VGW_SHUTDOWN_TIMEOUT`, default 10 s.

The truncated upload is caught by `utils.ContentLengthReader`: a body that
ends before Content-Length is rejected with `IncompleteBody`.

## Note on Docker

The gateway container shares the network namespace of a pause container
(`sleep infinity`), the way a pod's containers share the pause container's
namespace. When the gateway process exits, the kernel still delivers what is
left in its socket buffers to the client. Without that, Docker removes the
namespace together with the container, and a slow client loses the tail of a
response the gateway did write in full. The client still gets `--max-time 60`
so a scenario cannot hang.
