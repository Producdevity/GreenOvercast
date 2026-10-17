pub var media_available = true;
pub var result: c_int = 0;
pub var calls: usize = 0;
pub var bitrate_bps: c_uint = 0;

export fn go_video_pipeline_has_media(_: ?*const anyopaque) c_int {
    return @intFromBool(media_available);
}

export fn rtcRequestBitrate(_: c_int, bitrate: c_uint) c_int {
    calls += 1;
    bitrate_bps = bitrate;
    return result;
}
