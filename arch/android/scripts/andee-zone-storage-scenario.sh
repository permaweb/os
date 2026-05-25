#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

require_tool curl
require_tool python3
require_tool erl

"$ROOT/scripts/stage-android-devices.sh"

OUT="$BUILD_DIR/andee-zone-storage"
NODE1_PORT="${ANDEE_ZONE_NODE1_PORT:-18746}"
NODE2_PORT="${ANDEE_ZONE_NODE2_PORT:-18747}"
NODE1_URL="http://127.0.0.1:$NODE1_PORT"
NODE2_URL="http://127.0.0.1:$NODE2_PORT"
ZONE_NAME="${ANDEE_ZONE_NAME:-overnight-storage}"
COOKIE="andee_zone_storage"
NODE1_NAME="andee_zone_storage_1"
NODE2_NAME="andee_zone_storage_2"
SENTINEL_KEY="data/andee-zone-storage/sentinel"
SENTINEL_VALUE="andee-zone-storage-sentinel-$(date +%Y%m%d%H%M%S)"

rm -rf "$OUT"
mkdir -p "$OUT"

(cd "$ANDEE_DEVICE_ROOT" && "$ROOT/scripts/verified-rebar3.sh" compile)

HB_SRC="$ANDEE_DEVICE_ROOT/_build/default/lib/hb/src"
HB_APP="$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
mkdir -p "$OUT/probe-src" "$OUT/probe-ebin"
cat >"$OUT/probe-src/andee_zone_storage_probe.erl" <<'ERL'
-module(andee_zone_storage_probe).
-export([write_read/3, read/2]).

write_read(Server, Key, Value) ->
    Opts = hb_http_server:get_opts(#{<<"http-server">> => Server}),
    ok = hb_store:write(#{Key => Value}, Opts),
    ok = flush_encrypted(Opts),
    hb_store:read(Key, Opts).

read(Server, Key) ->
    Opts = hb_http_server:get_opts(#{<<"http-server">> => Server}),
    hb_store:read(Key, Opts).

flush_encrypted(Opts) ->
    Stores = hb_opts:get(<<"store">>, [], Opts),
    lists:foreach(
        fun
            (Store = #{<<"store-module">> := hb_store_andee_encrypted}) ->
                ok = hb_store_andee_encrypted:flush(Store);
            (Store = #{<<"store-module">> := <<"hb_store_andee_encrypted">>}) ->
                ok = hb_store_andee_encrypted:flush(Store);
            (_) ->
                ok
        end,
        case is_list(Stores) of
            true -> Stores;
            false -> [Stores]
        end
    ).
ERL
erlc -pa "$HB_APP/ebin" -I "$HB_APP/include" \
    -o "$OUT/probe-ebin" "$OUT/probe-src/andee_zone_storage_probe.erl"
if ! erlc -pa "$HB_APP/ebin" +'{feature,maybe_expr,enable}' \
    -I "$HB_APP/include" \
    -I "$HB_SRC/core" \
    -o "$HB_APP/ebin" \
    "$HB_SRC/preloaded/message/dev_message.erl" \
    "$HB_SRC/preloaded/codec/dev_structured.erl" \
    "$HB_SRC/preloaded/codec/dev_flat.erl" \
    "$HB_SRC/preloaded/codec/dev_json.erl" \
    "$HB_SRC/preloaded/codec/dev_json_iface.erl" \
    "$HB_SRC/preloaded/codec/dev_httpsig_keyid.erl" \
    "$HB_SRC/preloaded/codec/dev_httpsig_siginfo.erl" \
    "$HB_SRC/preloaded/codec/dev_httpsig_conv.erl" \
    "$HB_SRC/preloaded/codec/dev_httpsig_proxy.erl" \
    "$HB_SRC/preloaded/codec/dev_httpsig.erl" \
    "$HB_SRC/preloaded/codec/lib_arweave_common.erl" \
    "$HB_SRC/preloaded/codec/dev_ans104.erl" \
    "$HB_SRC/preloaded/codec/dev_tx.erl" \
    "$HB_SRC/preloaded/auth/dev_cookie_auth.erl" \
    "$HB_SRC/preloaded/auth/dev_cookie.erl" \
    "$HB_SRC/preloaded/auth/dev_auth_hook.erl" \
    "$HB_SRC/preloaded/auth/dev_http_auth.erl" \
    "$HB_SRC/preloaded/auth/dev_secret.erl" \
    "$HB_SRC/preloaded/node/dev_meta.erl" \
    "$HB_SRC/preloaded/node/dev_hyperbuddy.erl" \
    "$HB_SRC/preloaded/node/dev_cache.erl" \
    "$HB_SRC/preloaded/node/dev_router.erl" \
    "$HB_SRC/preloaded/node/dev_node_process.erl" \
    "$HB_SRC/preloaded/node/dev_location_cache.erl" \
    "$HB_SRC/preloaded/node/dev_location.erl" \
    "$HB_SRC/preloaded/node/dev_cron.erl" \
    "$HB_SRC/preloaded/name/dev_name.erl" \
    "$HB_SRC/preloaded/name/dev_b32_name.erl" \
    "$HB_SRC/preloaded/name/dev_local_name.erl" \
    "$HB_SRC/preloaded/util/dev_relay.erl" \
    "$HB_SRC/preloaded/util/dev_stack.erl" \
    "$HB_SRC/preloaded/process/lib_process.erl" \
    "$HB_SRC/preloaded/process/dev_process_cache.erl" \
    "$HB_SRC/preloaded/process/dev_scheduler_cache.erl" \
    "$HB_SRC/preloaded/process/dev_scheduler_formats.erl" \
    "$HB_SRC/preloaded/process/dev_scheduler_registry.erl" \
    "$HB_SRC/preloaded/process/dev_scheduler_server.erl" \
    "$HB_SRC/preloaded/process/dev_process_worker.erl" \
    "$HB_SRC/preloaded/process/dev_push.erl" \
    "$HB_SRC/preloaded/process/dev_scheduler.erl" \
    "$HB_SRC/preloaded/process/dev_process.erl" \
    "$HB_SRC/preloaded/vm/dev_lua_lib.erl" \
    "$HB_SRC/preloaded/vm/dev_lua.erl" \
    "$HB_SRC/preloaded/query/dev_query.erl" \
    "$HB_SRC/preloaded/query/dev_query_graphql.erl" \
    "$HB_SRC/preloaded/query/dev_match.erl" \
    "$HB_SRC/preloaded/arweave/dev_manifest.erl" \
    "$HB_SRC/preloaded/arweave/dev_arweave.erl" \
    "$HB_SRC/preloaded/arweave/dev_bundler.erl" \
    "$HB_SRC/preloaded/arweave/dev_bundler_task.erl" \
    "$HB_SRC/preloaded/arweave/dev_bundler_cache.erl" \
    "$HB_SRC/preloaded/arweave/dev_bundler_recovery.erl" \
    "$HB_SRC/preloaded/payment/dev_p4.erl" \
    "$HB_SRC/preloaded/payment/dev_simple_pay.erl" \
    "$HB_SRC/preloaded/payment/dev_metering.erl" \
        >"$OUT/host-preloaded-compile.log" 2>&1; then
    cat "$OUT/host-preloaded-compile.log" >&2
    exit 1
fi

PIDS=()
cleanup() {
    local pid
    for pid in "${PIDS[@]:-}"; do
        if kill -0 "$pid" >/dev/null 2>&1; then
            kill "$pid" >/dev/null 2>&1 || true
            wait "$pid" >/dev/null 2>&1 || true
        fi
    done
}
trap cleanup EXIT

urlencode() {
    python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

make_config() {
    local port="$1"
    local url="$2"
    local name="$3"
    local encrypted_root="$4"
    local out="$5"
    python3 - <<'PY' "$ANDEE_CONFIG" "$port" "$url" "$name" "$encrypted_root" "$out"
import json, pathlib, sys
base = json.loads(pathlib.Path(sys.argv[1]).read_text())
base["port"] = int(sys.argv[2])
base["public-url"] = sys.argv[3]
base["zone-self-url"] = sys.argv[3]
base["name"] = sys.argv[4]
base["encrypted-volumes"] = True
base["encrypted-volume-root"] = sys.argv[5]
base["allow-rejected-peer-attestation"] = True
pathlib.Path(sys.argv[6]).write_text(json.dumps(base, indent=2) + "\n")
PY
}

start_node() {
    local node_name="$1"
    local config="$2"
    local log="$3"
    (
        cd "$ANDEE_DEVICE_ROOT"
        exec erl -sname "$node_name" -setcookie "$COOKIE" \
            -pa "$OUT/probe-ebin" \
            -pa _build/default/lib/*/ebin \
            -noshell \
            -eval "andee_bootstrap:start(<<\"$config\">>)."
    ) >"$log" 2>&1 &
    PIDS+=("$!")
}

wait_for_node() {
    local url="$1"
    local name="$2"
    local i
    for i in $(seq 1 80); do
        if curl -fsS --max-time 2 \
            -H 'Accept: application/json' \
            "$url/~meta@1.0/info" >"$OUT/$name.meta.json" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    echo "node did not boot: $url" >&2
    return 1
}

post_json() {
    local url="$1"
    local out="$2"
    local code
    code="$(curl -sS --max-time 60 \
        -X POST \
        -H 'Accept: application/json' \
        -o "$out" \
        -w '%{http_code}' \
        "$url")"
    printf '%s\n' "$code" >"$out.http"
    test "$code" = "200"
}

get_json() {
    local url="$1"
    local out="$2"
    local code
    code="$(curl -sS --max-time 60 \
        -H 'Accept: application/json' \
        -o "$out" \
        -w '%{http_code}' \
        "$url")"
    printf '%s\n' "$code" >"$out.http"
    test "$code" = "200"
}

materialize() {
    local base="$1"
    local input="$2"
    local output="$3"
    python3 "$ROOT/scripts/materialize-ao-json.py" \
        "$input" \
        --base-url "$base" \
        --output "$output"
}

json_field() {
    local file="$1"
    local expr="$2"
    python3 - <<'PY' "$file" "$expr"
import json, sys
value = json.loads(open(sys.argv[1]).read())
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

node_address_from_log() {
    local log="$1"
    sed -n 's/^AndEE HyperBEAM node started on port [0-9][0-9]* as //p' \
        "$log" | tail -1
}

rpc_eval() {
    local eval="$1"
    local name="andee_zone_probe_${RANDOM}_$$"
    (
        cd "$ANDEE_DEVICE_ROOT"
        exec erl -hidden -noshell -sname "$name" -setcookie "$COOKIE" \
            -pa "$OUT/probe-ebin" \
            -pa _build/default/lib/*/ebin \
            -eval "$eval"
    )
}

rpc_write_read_sentinel() {
    local node_name="$1"
    local server_id="$2"
    local out="$3"
    rpc_eval "
        Host = lists:nth(2, string:split(atom_to_list(node()), \"@\")),
        Node = list_to_atom(\"$node_name@\" ++ Host),
        Server = <<\"$server_id\">>,
        Key = <<\"$SENTINEL_KEY\">>,
        Value = <<\"$SENTINEL_VALUE\">>,
        case rpc:call(Node, andee_zone_storage_probe, write_read,
                      [Server, Key, Value], 10000) of
            {ok, Value} ->
                io:format(\"~s~n\", [Value]),
                halt(0);
            Other ->
                io:format(\"unexpected-write-read: ~p~n\", [Other]),
                halt(1)
        end.
    " >"$out"
}

rpc_expect_sentinel_missing() {
    local node_name="$1"
    local server_id="$2"
    local out="$3"
    rpc_eval "
        Host = lists:nth(2, string:split(atom_to_list(node()), \"@\")),
        Node = list_to_atom(\"$node_name@\" ++ Host),
        Server = <<\"$server_id\">>,
        Key = <<\"$SENTINEL_KEY\">>,
        case rpc:call(Node, andee_zone_storage_probe, read,
                      [Server, Key], 10000) of
            {error, not_found} ->
                io:format(\"missing-before-rejoin~n\"),
                halt(0);
            Other ->
                io:format(\"unexpected-read-before-rejoin: ~p~n\", [Other]),
                halt(1)
        end.
    " >"$out"
}

rpc_read_sentinel() {
    local node_name="$1"
    local server_id="$2"
    local out="$3"
    rpc_eval "
        Host = lists:nth(2, string:split(atom_to_list(node()), \"@\")),
        Node = list_to_atom(\"$node_name@\" ++ Host),
        Server = <<\"$server_id\">>,
        Key = <<\"$SENTINEL_KEY\">>,
        Value = <<\"$SENTINEL_VALUE\">>,
        case rpc:call(Node, andee_zone_storage_probe, read,
                      [Server, Key], 10000) of
            {ok, Value} ->
                io:format(\"~s~n\", [Value]),
                halt(0);
            Other ->
                io:format(\"unexpected-read-after-rejoin: ~p~n\", [Other]),
                halt(1)
        end.
    " >"$out"
}

assert_status_opened() {
    local file="$1"
    python3 - <<'PY' "$file"
import json, sys
doc = json.loads(open(sys.argv[1]).read())
body = doc["body"]
volume = body["encrypted-volume"]
assert body["initialized"] is True or body["initialized"] == "true", body
assert volume["enabled"] is True or volume["enabled"] == "true", volume
assert volume["opened"] is True or volume["opened"] == "true", volume
assert isinstance(volume["store-id"], str) and len(volume["store-id"]) == 43, volume
PY
}

assert_store_file_opaque() {
    local dir="$1"
    local name="$2"
    local file
    file="$(find "$dir" -name store.bin -type f | head -1)"
    test -n "$file"
    test -s "$file"
    if LC_ALL=C grep -a "$ZONE_NAME" "$file" >/dev/null; then
        echo "encrypted store contains plaintext zone name: $file" >&2
        return 1
    fi
    printf '%s\n' "$file" >"$OUT/$name.store-file.txt"
}

make_config "$NODE1_PORT" "$NODE1_URL" "host-andee-zone-storage-1" \
    "$OUT/node1-encrypted" "$OUT/node1.json"
make_config "$NODE2_PORT" "$NODE2_URL" "host-andee-zone-storage-2" \
    "$OUT/node2-encrypted" "$OUT/node2.json"

start_node "$NODE1_NAME" "$OUT/node1.json" "$OUT/node1.log"
start_node "$NODE2_NAME" "$OUT/node2.json" "$OUT/node2.log"
wait_for_node "$NODE1_URL" node1
wait_for_node "$NODE2_URL" node2

INIT_URL="$NODE1_URL/~zone@1.0/init?name=$(urlencode "$ZONE_NAME")&self-url=$(urlencode "$NODE1_URL")&template-measurement-device=andee%401.0"
post_json "$INIT_URL" "$OUT/init.raw.json"
materialize "$NODE1_URL" "$OUT/init.raw.json" "$OUT/init.materialized.json"
assert_status_opened "$OUT/init.materialized.json"
RING_ADDRESS="$(json_field "$OUT/init.materialized.json" "body.zone.ring-address")"
assert_store_file_opaque "$OUT/node1-encrypted" node1

JOIN_URL="$NODE2_URL/~zone@1.0/join?name=$(urlencode "$ZONE_NAME")&peer-url=$(urlencode "$NODE1_URL")&self-url=$(urlencode "$NODE2_URL")&expected-ring-address=$(urlencode "$RING_ADDRESS")&allow-rejected-peer-attestation=true"
post_json "$JOIN_URL" "$OUT/join.raw.json"
materialize "$NODE2_URL" "$OUT/join.raw.json" "$OUT/join.materialized.json"
assert_status_opened "$OUT/join.materialized.json"
assert_store_file_opaque "$OUT/node2-encrypted" node2-before-restart
NODE2_ADDRESS="$(node_address_from_log "$OUT/node2.log")"
test -n "$NODE2_ADDRESS"
rpc_write_read_sentinel "$NODE2_NAME" "$NODE2_ADDRESS" \
    "$OUT/sentinel-write-read.txt"

LAST_INDEX=$((${#PIDS[@]} - 1))
NODE2_PID="${PIDS[$LAST_INDEX]}"
kill "$NODE2_PID" >/dev/null 2>&1 || true
wait "$NODE2_PID" >/dev/null 2>&1 || true
unset "PIDS[$LAST_INDEX]"

start_node "$NODE2_NAME" "$OUT/node2.json" "$OUT/node2-restart.log"
wait_for_node "$NODE2_URL" node2-restart
NODE2_RESTART_ADDRESS="$(node_address_from_log "$OUT/node2-restart.log")"
test -n "$NODE2_RESTART_ADDRESS"
rpc_expect_sentinel_missing "$NODE2_NAME" "$NODE2_RESTART_ADDRESS" \
    "$OUT/sentinel-before-rejoin.txt"

REJOIN_URL="$NODE2_URL/~zone@1.0/join?name=$(urlencode "$ZONE_NAME")&peer-url=$(urlencode "$NODE1_URL")&self-url=$(urlencode "$NODE2_URL")&expected-ring-address=$(urlencode "$RING_ADDRESS")&allow-rejected-peer-attestation=true"
post_json "$REJOIN_URL" "$OUT/rejoin.raw.json"
materialize "$NODE2_URL" "$OUT/rejoin.raw.json" "$OUT/rejoin.materialized.json"
assert_status_opened "$OUT/rejoin.materialized.json"
assert_store_file_opaque "$OUT/node2-encrypted" node2-after-restart
rpc_read_sentinel "$NODE2_NAME" "$NODE2_RESTART_ADDRESS" \
    "$OUT/sentinel-after-rejoin.txt"
get_json "$NODE2_URL/~measurement@1.0/boot" \
    "$OUT/node2-boot-after-rejoin.raw.json"
materialize "$NODE2_URL" \
    "$OUT/node2-boot-after-rejoin.raw.json" \
    "$OUT/node2-boot-after-rejoin.materialized.json"

python3 - <<'PY' "$OUT/summary.json" "$RING_ADDRESS" "$OUT"
import json, pathlib, sys
out = pathlib.Path(sys.argv[3])
summary = {
    "passed": True,
    "scenario": "host-andee-zone-encrypted-store-rejoin",
    "ring_address": sys.argv[2],
    "node1_store_file": (out / "node1.store-file.txt").read_text().strip(),
    "node2_store_file_before_restart": (out / "node2-before-restart.store-file.txt").read_text().strip(),
    "node2_store_file_after_restart": (out / "node2-after-restart.store-file.txt").read_text().strip(),
    "sentinel_key": "data/andee-zone-storage/sentinel",
    "sentinel_value": (out / "sentinel-after-rejoin.txt").read_text().strip(),
    "sentinel_missing_before_rejoin": (out / "sentinel-before-rejoin.txt").read_text().strip() == "missing-before-rejoin",
    "evidence": {
        "init": str(out / "init.materialized.json"),
        "join": str(out / "join.materialized.json"),
        "rejoin": str(out / "rejoin.materialized.json"),
        "sentinel_write_read": str(out / "sentinel-write-read.txt"),
        "sentinel_before_rejoin": str(out / "sentinel-before-rejoin.txt"),
        "sentinel_after_rejoin": str(out / "sentinel-after-rejoin.txt"),
        "node2_boot_after_rejoin": str(out / "node2-boot-after-rejoin.materialized.json"),
    },
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(summary, indent=2) + "\n")
PY

echo "zone encrypted-storage scenario evidence: $OUT"
