function duration(seconds) {
    if (seconds === null || seconds === undefined || !isFinite(seconds) || seconds < 0) return "0:00";
    var total = Math.floor(seconds);
    var hrs = Math.floor(total / 3600);
    var mins = Math.floor((total % 3600) / 60);
    var secs = total % 60;
    var padSecs = secs < 10 ? "0" + secs : "" + secs;
    if (hrs > 0) {
        var padMins = mins < 10 ? "0" + mins : "" + mins;
        return hrs + ":" + padMins + ":" + padSecs;
    }
    return mins + ":" + padSecs;
}

function summary(state) {
    if (!state || !state.ok) return "Unavailable";
    if (state.playbackError) return "Playback error";
    if (state.state === "play") return "Playing";
    if (state.state === "pause") return "Paused";
    if (!state.playlistLength) return "Queue empty";
    return "Stopped";
}

function pillText(state, showArtist) {
    if (!state || !state.ok) return "Unavailable";
    if (state.song && (state.state === "play" || state.state === "pause")) {
        if (showArtist && state.song.artist) {
            return state.song.artist + " — " + state.song.title;
        }
        return state.song.title;
    }
    return summary(state);
}

function hoverText(state) {
    if (!state || !state.ok) return "MPD unavailable";
    if (state.song) {
        var parts = [];
        if (state.song.artist) parts.push(state.song.artist);
        if (state.song.album) parts.push(state.song.album);
        if (state.song.title) parts.push(state.song.title);
        if (parts.length) return parts.join(" • ");
    }
    return summary(state);
}

function subtitle(state) {
    if (!state || !state.ok) return (state && state.error) ? state.error : "Unavailable";
    if (state.song) {
        var parts = [];
        if (state.song.artist) parts.push(state.song.artist);
        if (state.song.album) parts.push(state.song.album);
        return parts.length ? parts.join(" · ") : "Unknown artist";
    }
    return state.playlistLength > 0 ? state.playlistLength + " tracks in queue" : "No tracks in queue";
}

function audioFormat(audio, bitrate) {
    var parts = [];
    if (audio && typeof audio === "string") {
        var tokens = audio.split(":");
        if (tokens.length === 3) {
            var rate = parseInt(tokens[0], 10);
            if (rate > 0) {
                parts.push((rate % 1000 === 0 ? (rate / 1000).toFixed(0) : (rate / 1000).toFixed(1)) + " kHz");
            }
            if (tokens[1] && tokens[1] !== "?") {
                parts.push(tokens[1] === "f" ? "32-bit float" : tokens[1] + "-bit");
            }
            var ch = parseInt(tokens[2], 10);
            if (ch === 1) parts.push("Mono");
            else if (ch === 2) parts.push("Stereo");
            else if (ch > 2) parts.push(ch + " ch");
        } else if (audio.indexOf("dsd") === 0) {
            parts.push(audio.toUpperCase());
        }
    }
    if (bitrate && isFinite(bitrate) && bitrate > 0) {
        parts.push(Math.round(bitrate) + " kbps");
    }
    return parts.join(" · ");
}

function icon(state) {
    if (!state || !state.ok) return "cloud_off";
    if (state.playbackError) return "error_outline";
    if (state.state === "play") return "music_note";
    if (state.state === "pause") return "pause_circle";
    return "album";
}

function singleLabel(singleMode) {
    if (singleMode === "oneshot") return "Single 1×";
    return "Single";
}
