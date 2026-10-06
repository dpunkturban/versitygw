#!/usr/bin/env bash
# Graceful shutdown drain test for the azure backend.
#
# Runs versitygw against Azurite in Docker and checks what happens to
# transfers that are in flight when the gateway gets SIGTERM, and to an
# upload whose client disconnects mid-body. Nothing is installed on the host:
# the gateway, Azurite and the curl client all run in containers.
#
# See README.md in this directory for the scenarios and the expected results.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

IMAGE="versitygw:graceful-shutdown"
EXPECT="fixed"
BUILD=0
KEEP=0
DRAIN_TIMEOUT="20s"
ONLY=""

# The public Azurite development account. This is not a secret: Microsoft
# documents it for local testing.
AZ_ACCOUNT="devstoreaccount1"
AZ_KEY="Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="

VGW_ACCESS="testak"
VGW_SECRET="testsecret"
BUCKET="drain-test"
OBJECT_MIB=64
OBJECT_BYTES=$((OBJECT_MIB * 1024 * 1024))

NET="vgw-drain-$$"
AZURITE="azurite-$$"
VGW="vgw-$$"
# VGW_NET holds the gateway's network namespace the way the pause container
# holds a pod's. When the gateway process exits, the kernel still delivers
# what is left in its socket buffers. Without it Docker tears the namespace
# down with the container, and a slow client loses the tail of a response
# the gateway did write in full. The gateway is reached under this name.
VGW_NET="vgw-net-$$"
PAUSE_IMAGE="alpine:3.20"
CURL_IMAGE="curlimages/curl:8.16.0"
AZURITE_IMAGE="mcr.microsoft.com/azure-storage/azurite:latest"

usage() {
	cat <<USAGE
Usage: $0 [options]

  --build            build $IMAGE from the working tree first
  --image IMAGE      gateway image to test (default: $IMAGE)
  --expect MODE      fixed | baseline. What the run is expected to show.
                     fixed: transfers drain. baseline: the v1.8.0 defects.
  --timeout DUR      VGW_SHUTDOWN_TIMEOUT for the drain scenarios (default: $DRAIN_TIMEOUT)
  --only NAME        run one scenario (see README.md)
  --keep             keep the containers and the work directory on exit
  -h, --help         this text

Examples:
  $0 --build                                              # the fix
  $0 --image ghcr.io/versity/versitygw:v1.8.0 --expect baseline   # the defects
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
	--build) BUILD=1 ;;
	--image) IMAGE="$2"; shift ;;
	--expect) EXPECT="$2"; shift ;;
	--timeout) DRAIN_TIMEOUT="$2"; shift ;;
	--only) ONLY="$2"; shift ;;
	--keep) KEEP=1 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

case "$EXPECT" in fixed | baseline) ;; *) echo "--expect must be fixed or baseline" >&2; exit 2 ;; esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vgw-drain.XXXXXX")"
mkdir -p "$WORK/logs"
RESULTS=()
FAILED=0

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

cleanup() {
	if [ "$KEEP" = 1 ]; then
		log "keeping containers and $WORK"
		return
	fi
	docker rm -f "$VGW" "$VGW_NET" "$AZURITE" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

# curl runs in a container on the test network. The work directory is mounted
# at /w for the upload source and the download target.
curl_s3() {
	docker run --rm --network "$NET" -v "$WORK:/w" "$CURL_IMAGE" \
		-sS --aws-sigv4 aws:amz:us-east-1:s3 --user "$VGW_ACCESS:$VGW_SECRET" "$@"
}

# vgw_start TIMEOUT: starts the gateway with the given shutdown timeout and
# waits until it answers.
vgw_start() {
	docker rm -f "$VGW" >/dev/null 2>&1 || true
	docker run -d --name "$VGW" --network "container:$VGW_NET" \
		-e ROOT_ACCESS_KEY="$VGW_ACCESS" -e ROOT_SECRET_KEY="$VGW_SECRET" \
		-e VGW_PORT=:7070 -e VGW_SHUTDOWN_TIMEOUT="$1" \
		"$IMAGE" azure --account "$AZ_ACCOUNT" --access-key "$AZ_KEY" \
		--url "http://$AZURITE:10000/$AZ_ACCOUNT" >/dev/null
	for _ in $(seq 1 50); do
		code="$(curl_s3 -o /dev/null -w '%{http_code}' --max-time 2 "http://$VGW_NET:7070/" 2>/dev/null || true)"
		if [ "$code" != "000" ] && [ -n "$code" ]; then
			return 0
		fi
		sleep 0.2
	done
	log "gateway did not come up"
	docker logs "$VGW" >&2 || true
	exit 1
}

# vgw_sigterm NAME: sends SIGTERM and prints how many seconds the gateway
# took to exit.
vgw_sigterm() {
	local t0 t1
	t0="$(date +%s)"
	docker kill -s TERM "$VGW" >/dev/null
	docker wait "$VGW" >/dev/null
	t1="$(date +%s)"
	docker logs "$VGW" >"$WORK/logs/$1.log" 2>&1 || true
	echo $((t1 - t0))
}

# head_object KEY: prints "<http code> <content-length>" for the key, using a
# fresh gateway. The gateway from the scenario is gone by then.
head_object() {
	vgw_start 10s
	local out
	out="$(curl_s3 -I --max-time 10 "http://$VGW_NET:7070/$BUCKET/$1" 2>/dev/null || true)"
	docker rm -f "$VGW" >/dev/null 2>&1 || true
	local code len
	code="$(printf '%s' "$out" | awk 'NR==1{print $2}')"
	len="$(printf '%s' "$out" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')"
	echo "${code:-000} ${len:-0}"
}

# object_state KEY: prints "404", "200 complete" or "200 truncated (<bytes>)".
object_state() {
	local head code len
	head="$(head_object "$1")"
	code="${head% *}"
	len="${head#* }"
	case "$code" in
	404) echo "404" ;;
	200)
		if [ "$len" = "$OBJECT_BYTES" ]; then echo "200 complete"; else echo "200 truncated ($len bytes)"; fi
		;;
	*) echo "$head" ;;
	esac
}

# record NAME RESULT EXPECTED DETAIL
record() {
	local status="PASS"
	if [ "$2" != "$3" ]; then
		status="FAIL"
		FAILED=1
	fi
	RESULTS+=("$(printf '%-24s %-4s got: %-32s want: %-32s %s' "$1" "$status" "$2" "$3" "$4")")
	log "$1: $status ($2)"
}

# expect NAME: prints the expected outcome of a scenario for the current mode.
expect() {
	case "$EXPECT:$1" in
	fixed:truncated-put) echo "404" ;;
	baseline:truncated-put) echo "200 truncated" ;;
	fixed:sigterm-get) echo "complete" ;;
	baseline:sigterm-get) echo "cut" ;;
	fixed:sigterm-put) echo "200 complete" ;;
	baseline:sigterm-put) echo "404" ;;
	fixed:over-timeout-put) echo "404 exit<8s" ;;
	baseline:over-timeout-put) echo "404 exit>=8s" ;;
	*:refused-during-drain) echo "refused" ;;
	*:idle-sigterm) echo "exit<3s" ;;
	esac
}

run_scenario() {
	if [ -n "$ONLY" ] && [ "$ONLY" != "$1" ]; then
		return
	fi
	log "=== $1"
	"scenario_$(printf '%s' "$1" | tr '-' '_')"
}

# --- scenarios ---------------------------------------------------------------

# A client that disconnects mid-body must not leave a truncated object behind.
# 8 MiB/s for 3 s sends about 24 MiB of the 64 MiB.
scenario_truncated_put() {
	vgw_start 10s
	curl_s3 -o /dev/null -T /w/obj -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
		--limit-rate 8M --max-time 3 "http://$VGW_NET:7070/$BUCKET/cut" 2>/dev/null || true
	docker rm -f "$VGW" >/dev/null
	local state
	state="$(object_state cut)"
	record truncated-put "${state%% (*}" "$(expect truncated-put)" "HEAD after an aborted 64 MiB PUT: $state"
}

# SIGTERM 3 s into a 16 s download. The download must complete.
scenario_sigterm_get() {
	vgw_start "$DRAIN_TIMEOUT"
	rm -f "$WORK/get.out"
	curl_s3 -o /w/get.out -w '%{size_download} %{http_code} %{exitcode}' --limit-rate 4M --max-time 60 \
		"http://$VGW_NET:7070/$BUCKET/full" >"$WORK/get.res" 2>/dev/null &
	local client=$!
	sleep 3
	local exit_s
	exit_s="$(vgw_sigterm sigterm-get)"
	wait "$client" || true
	local got size code curl_exit
	read -r size code curl_exit <"$WORK/get.res" || true
	if [ "${size:-0}" = "$OBJECT_BYTES" ]; then got="complete"; else got="cut"; fi
	record sigterm-get "$got" "$(expect sigterm-get)" "downloaded ${size:-0} of $OBJECT_BYTES bytes (http ${code:-000} curl ${curl_exit:-?}), gateway exited ${exit_s}s after SIGTERM"
}

# SIGTERM 3 s into a 16 s upload. The upload must complete and be stored whole.
scenario_sigterm_put() {
	vgw_start "$DRAIN_TIMEOUT"
	curl_s3 -o /dev/null -w 'http %{http_code} curl %{exitcode}' -T /w/obj -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
		--limit-rate 4M --max-time 60 "http://$VGW_NET:7070/$BUCKET/drained" >"$WORK/put.res" 2>/dev/null &
	local client=$!
	sleep 3
	local exit_s
	exit_s="$(vgw_sigterm sigterm-put)"
	wait "$client" || true
	local client_res state
	client_res="$(cat "$WORK/put.res" 2>/dev/null || echo "no result")"
	state="$(object_state drained)"
	record sigterm-put "$state" "$(expect sigterm-put)" "PUT: $client_res, gateway exited ${exit_s}s after SIGTERM"
}

# The upload takes 16 s, the timeout is 5 s. The gateway must stop within the
# timeout and must not store a partial object.
scenario_over_timeout_put() {
	vgw_start 5s
	curl_s3 -o /dev/null -w 'http %{http_code} curl %{exitcode}' -T /w/obj -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
		--limit-rate 4M --max-time 60 "http://$VGW_NET:7070/$BUCKET/over" >"$WORK/over.res" 2>/dev/null &
	local client=$!
	sleep 3
	local exit_s
	exit_s="$(vgw_sigterm over-timeout-put)"
	wait "$client" || true
	local client_res state got
	client_res="$(cat "$WORK/over.res" 2>/dev/null || echo "no result")"
	state="$(object_state over)"
	got="${state%% *}"
	if [ "$exit_s" -lt 8 ]; then got="$got exit<8s"; else got="$got exit>=8s"; fi
	record over-timeout-put "$got" "$(expect over-timeout-put)" "PUT: $client_res, gateway exited ${exit_s}s after SIGTERM (timeout 5s)"
}

# A connection that opens during the drain must be refused.
scenario_refused_during_drain() {
	vgw_start "$DRAIN_TIMEOUT"
	curl_s3 -o /dev/null --limit-rate 4M --max-time 60 "http://$VGW_NET:7070/$BUCKET/full" >/dev/null 2>&1 &
	local client=$!
	sleep 3
	docker kill -s TERM "$VGW" >/dev/null
	sleep 1
	local got="answered"
	if ! curl_s3 -o /dev/null --max-time 5 "http://$VGW_NET:7070/$BUCKET/full" >/dev/null 2>&1; then
		got="refused"
	fi
	docker wait "$VGW" >/dev/null
	docker logs "$VGW" >"$WORK/logs/refused-during-drain.log" 2>&1 || true
	wait "$client" || true
	record refused-during-drain "$got" "$(expect refused-during-drain)" "new request 1 s into the drain"
}

# With nothing in flight the gateway must exit at once, whatever the timeout.
scenario_idle_sigterm() {
	vgw_start 60s
	local exit_s
	exit_s="$(vgw_sigterm idle-sigterm)"
	local got="exit=${exit_s}s"
	if [ "$exit_s" -lt 3 ]; then got="exit<3s"; fi
	record idle-sigterm "$got" "$(expect idle-sigterm)" "VGW_SHUTDOWN_TIMEOUT=60s, no traffic"
}

# --- main --------------------------------------------------------------------

if [ "$BUILD" = 1 ]; then
	log "building $IMAGE from $REPO_DIR"
	docker build -q -t "$IMAGE" "$REPO_DIR" >/dev/null
fi

log "image: $IMAGE, expect: $EXPECT, drain timeout: $DRAIN_TIMEOUT, work: $WORK"
head -c "$OBJECT_BYTES" /dev/urandom >"$WORK/obj"

docker network create "$NET" >/dev/null
docker run -d --name "$AZURITE" --network "$NET" "$AZURITE_IMAGE" \
	azurite-blob --blobHost 0.0.0.0 --loose --skipApiVersionCheck >/dev/null
docker run -d --name "$VGW_NET" --network "$NET" "$PAUSE_IMAGE" sleep infinity >/dev/null

# bucket and a full object for the download scenarios
vgw_start 10s
curl_s3 -o /dev/null -X PUT "http://$VGW_NET:7070/$BUCKET"
curl_s3 -o /dev/null -T /w/obj -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" "http://$VGW_NET:7070/$BUCKET/full"
docker rm -f "$VGW" >/dev/null

run_scenario truncated-put
run_scenario sigterm-get
run_scenario sigterm-put
run_scenario over-timeout-put
run_scenario refused-during-drain
run_scenario idle-sigterm

echo
echo "image: $IMAGE   expect: $EXPECT   drain timeout: $DRAIN_TIMEOUT"
printf '%s\n' "${RESULTS[@]}"
echo
if [ "$FAILED" = 1 ]; then
	echo "RESULT: FAIL (gateway logs in $WORK/logs, use --keep to keep them)"
	KEEP=1
	exit 1
fi
echo "RESULT: PASS"
