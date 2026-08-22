/*
 * aerion_core.h — C-ABI surface of the aerion-core VPN kernel (iOS/staticlib).
 *
 * Driven by a Swift Network Extension. Unless noted, `input` is a NUL-terminated
 * UTF-8 JSON string; every non-void function returns a heap-allocated, NUL-terminated
 * UTF-8 JSON string that the caller MUST release with `aerion_free_string`.
 *
 * On error or an internal panic, the returned JSON is {"ok":false,"error":"..."}.
 * All functions are panic-safe: they never unwind across the C ABI.
 */
#ifndef AERION_CORE_H
#define AERION_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Callback invoked for every core log line. `ctx` is the opaque pointer passed to
 * aerion_set_log_callback. `level` and `message` are only valid for the duration of
 * the call — copy them before returning. */
typedef void (*AerionLogCallback)(void *ctx, const char *level, const char *message);

/* Callback invoked for every core event. `ctx` is the opaque pointer passed to
 * aerion_set_event_callback. `event_json` is only valid for the duration of the
 * call — copy it before returning. */
typedef void (*AerionEventCallback)(void *ctx, const char *event_json);

/* Start the TUN-backed VPN. `input` carries the tun_fd (required) plus routing/DNS
 * options. Returns session JSON including "session_id". */
char *aerion_start_vpn(const char *input);

/* Stop a VPN session started by aerion_start_vpn. Idempotent. */
char *aerion_stop_vpn(int64_t session_id);

/* Start a loopback SOCKS5 listener for the given node. Returns "session_id" and
 * "socks_addr". */
char *aerion_start_socks(const char *input);

/* Stop a SOCKS session started by aerion_start_socks. Idempotent. */
char *aerion_stop_socks(int64_t session_id);

/* Probe a node's reachability/latency through a temporary SOCKS listener. */
char *aerion_test_node(const char *input);

/* Start the mihomo rule-based route proxy. Returns "session_id" and "socks_addr". */
char *aerion_start_route(const char *input);

/* Stop a route session started by aerion_start_route. Idempotent. */
char *aerion_stop_route(int64_t session_id);

/* Inspect a mihomo route config. NOTE: `input` here is raw YAML text, not JSON.
 * Returns a summary JSON (rule counts, preview). Runs synchronously. */
char *aerion_inspect_route(const char *input);

/* Release a string returned by any of the functions above. NULL is ignored. */
void aerion_free_string(char *ptr);

/* Register (or, with cb == NULL, unregister) the log callback. `ctx` is stored and
 * passed back on every invocation. */
void aerion_set_log_callback(void *ctx, AerionLogCallback cb);

/* Register (or, with cb == NULL, unregister) the event callback. `ctx` is stored and
 * passed back on every invocation. */
void aerion_set_event_callback(void *ctx, AerionEventCallback cb);

#ifdef __cplusplus
}
#endif

#endif /* AERION_CORE_H */
