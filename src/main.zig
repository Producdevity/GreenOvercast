const std = @import("std");
const state_mod = @import("app/state.zig");
const release_mod = @import("app/release.zig");

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    std.debug.print("PANIC: {s}\n", .{message});
    std.posix.abort();
}

fn move(state: *state_mod.State, event: state_mod.Event, expected: state_mod.State) bool {
    const previous = state.*;
    const next = state_mod.transition(previous, event);
    if (next != expected) {
        std.debug.print("Invalid release transition: {s} -> {s}, expected {s}\n", .{
            previous.name(),
            next.name(),
            expected.name(),
        });
        return false;
    }
    state.* = next;
    std.debug.print("Lifecycle: {s} -> {s}\n", .{ previous.name(), next.name() });
    return true;
}

fn finish(state: *state_mod.State, exit_code: u8) u8 {
    if (state.* != .shutdown) {
        if (!move(state, .user_quit, .shutdown)) return 1;
    }
    return exit_code;
}

fn stage(result: release_mod.Result) enum { ok, cancelled, failed } {
    return switch (result) {
        .ok => .ok,
        .cancelled => .cancelled,
        else => .failed,
    };
}

fn runSelectedSession(release: *release_mod.Release, state: *state_mod.State) release_mod.Result {
    var result = release.createSession();
    if (result != .ok) return result;

    result = release.waitReady();
    if (result != .ok) return result;
    if (!move(state, .session_ready, .signaling)) return .failed;

    result = release.connect();
    if (result != .ok) return result;
    result = release.waitProvisioned();
    if (result != .ok) return result;
    result = release.setupWebrtc();
    if (result != .ok) return result;
    if (!move(state, .rtc_sdp_ready, .connecting)) return .failed;

    result = release.waitConnected();
    if (result != .ok) return result;
    if (!move(state, .rtc_connected, .streaming)) return .failed;
    return release.stream();
}

pub fn main() u8 {
    var args = std.process.args();
    defer args.deinit();
    _ = args.next();
    const requested_title = args.next() orelse "";

    const release = release_mod.Release.open(requested_title) orelse return 1;
    defer release.close();

    var state = state_mod.State.cold_start;
    var needs_sign_in = false;
    const credentials = release.loadCredentials();
    if (credentials == .missing_credentials) {
        if (!move(&state, .auth_no_tokens, .signed_out)) return 1;
        needs_sign_in = true;
    } else if (credentials == .ok) {
        if (!move(&state, .auth_tokens_found, .authenticating)) return 1;
    } else {
        return finish(&state, 1);
    }

    var reauth_attempted = false;
    while (true) {
        if (needs_sign_in) {
            reauth_attempted = true;
            needs_sign_in = false;
            if (!move(&state, .auth_begin_sign_in, .device_code_pending)) return 1;
            switch (stage(release.deviceSignIn())) {
                .ok => if (!move(&state, .auth_success, .authenticating)) return 1,
                .cancelled => return finish(&state, 0),
                .failed => return finish(&state, 1),
            }
        }

        const auth_result = release.refreshAuth();
        if (auth_result == .reauth_required and !reauth_attempted) {
            if (!move(&state, .auth_rejected, .signed_out)) return 1;
            needs_sign_in = true;
            continue;
        }
        switch (stage(auth_result)) {
            .ok => if (!move(&state, .auth_success, .loading_catalog)) return 1,
            .cancelled => return finish(&state, 0),
            .failed => return finish(&state, 1),
        }
        break;
    }
    switch (stage(release.loadCatalog())) {
        .ok => if (!move(&state, .catalog_loaded, .catalog)) return 1,
        .cancelled => return finish(&state, 0),
        .failed => return finish(&state, 1),
    }
    while (true) {
        switch (stage(release.pickTitle())) {
            .ok => if (!move(&state, .user_select_title, .provisioning)) return 1,
            .cancelled => return finish(&state, 0),
            .failed => return finish(&state, 1),
        }

        const outcome = runSelectedSession(release, &state);
        if (outcome == .cancelled) return finish(&state, 0);

        const return_event: state_mod.Event = if (outcome == .session_ended or outcome == .ok)
            .session_ended
        else
            .session_failed;
        switch (stage(release.resetSession())) {
            .ok => {},
            .cancelled => return finish(&state, 0),
            .failed => return finish(&state, 1),
        }
        if (!move(&state, return_event, .catalog)) return 1;
    }
}
