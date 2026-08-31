const std = @import("std");

pub const State = enum {
    cold_start,
    signed_out,
    device_code_pending,
    authenticating,
    loading_catalog,
    catalog,
    provisioning,
    signaling,
    connecting,
    streaming,
    shutdown,

    pub fn name(self: State) []const u8 {
        return @tagName(self);
    }
};

pub const Event = enum {
    auth_tokens_found,
    auth_no_tokens,
    auth_begin_sign_in,
    auth_success,
    auth_rejected,
    auth_sign_out,
    catalog_loaded,
    user_select_title,
    session_ready,
    rtc_sdp_ready,
    rtc_connected,
    session_ended,
    session_failed,
    user_quit,
};

pub fn transition(current: State, event: Event) State {
    if (event == .user_quit)
        return .shutdown;

    return switch (current) {
        .cold_start => switch (event) {
            .auth_tokens_found => .authenticating,
            .auth_no_tokens => .signed_out,
            else => .cold_start,
        },
        .signed_out => switch (event) {
            .auth_begin_sign_in => .device_code_pending,
            else => .signed_out,
        },
        .device_code_pending => switch (event) {
            .auth_success => .authenticating,
            else => .device_code_pending,
        },
        .authenticating => switch (event) {
            .auth_success => .loading_catalog,
            .auth_rejected => .signed_out,
            else => .authenticating,
        },
        .loading_catalog => switch (event) {
            .catalog_loaded => .catalog,
            else => .loading_catalog,
        },
        .catalog => switch (event) {
            .user_select_title => .provisioning,
            .auth_sign_out => .signed_out,
            else => .catalog,
        },
        .provisioning => switch (event) {
            .session_ready => .signaling,
            .session_ended, .session_failed => .catalog,
            else => .provisioning,
        },
        .signaling => switch (event) {
            .rtc_sdp_ready => .connecting,
            .session_ended, .session_failed => .catalog,
            else => .signaling,
        },
        .connecting => switch (event) {
            .rtc_connected => .streaming,
            .session_ended, .session_failed => .catalog,
            else => .connecting,
        },
        .streaming => switch (event) {
            .session_ended, .session_failed => .catalog,
            else => .streaming,
        },
        .shutdown => .shutdown,
    };
}

test "existing credentials reach the catalog" {
    var state = transition(.cold_start, .auth_tokens_found);
    try std.testing.expectEqual(State.authenticating, state);
    state = transition(state, .auth_success);
    try std.testing.expectEqual(State.loading_catalog, state);
    state = transition(state, .catalog_loaded);
    try std.testing.expectEqual(State.catalog, state);
}

test "first-run sign-in reaches authentication" {
    var state = transition(.cold_start, .auth_no_tokens);
    try std.testing.expectEqual(State.signed_out, state);
    state = transition(state, .auth_begin_sign_in);
    try std.testing.expectEqual(State.device_code_pending, state);
    state = transition(state, .auth_success);
    try std.testing.expectEqual(State.authenticating, state);
}

test "rejected credentials return to controller-first sign-in" {
    var state = transition(.cold_start, .auth_tokens_found);
    try std.testing.expectEqual(State.authenticating, state);
    state = transition(state, .auth_rejected);
    try std.testing.expectEqual(State.signed_out, state);
    state = transition(state, .auth_begin_sign_in);
    try std.testing.expectEqual(State.device_code_pending, state);
}

test "sign out returns the catalog to authentication" {
    var state = transition(.catalog, .auth_sign_out);
    try std.testing.expectEqual(State.signed_out, state);
    state = transition(state, .auth_begin_sign_in);
    try std.testing.expectEqual(State.device_code_pending, state);
}

test "catalog selection reaches streaming" {
    var state = transition(.catalog, .user_select_title);
    try std.testing.expectEqual(State.provisioning, state);
    state = transition(state, .session_ready);
    try std.testing.expectEqual(State.signaling, state);
    state = transition(state, .rtc_sdp_ready);
    try std.testing.expectEqual(State.connecting, state);
    state = transition(state, .rtc_connected);
    try std.testing.expectEqual(State.streaming, state);
}

test "ended and failed sessions return to the catalog" {
    try std.testing.expectEqual(State.catalog, transition(.streaming, .session_ended));
    try std.testing.expectEqual(State.catalog, transition(.streaming, .session_failed));
    try std.testing.expectEqual(State.catalog, transition(.connecting, .session_failed));
    try std.testing.expectEqual(State.catalog, transition(.signaling, .session_failed));
    try std.testing.expectEqual(State.catalog, transition(.provisioning, .session_failed));
}

test "shutdown is terminal and reachable from every active state" {
    const states = [_]State{
        .cold_start,
        .signed_out,
        .device_code_pending,
        .authenticating,
        .loading_catalog,
        .catalog,
        .provisioning,
        .signaling,
        .connecting,
        .streaming,
    };
    for (states) |state|
        try std.testing.expectEqual(State.shutdown, transition(state, .user_quit));
    try std.testing.expectEqual(State.shutdown, transition(.shutdown, .rtc_connected));
}

test "unexpected events do not advance state" {
    try std.testing.expectEqual(State.catalog, transition(.catalog, .rtc_connected));
    try std.testing.expectEqual(State.streaming, transition(.streaming, .auth_no_tokens));
}
