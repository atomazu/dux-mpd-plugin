import QtQuick
import Quickshell.Io
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root
    property var pending: []
    property var active: null
    property var snapshot: ({
            ok: false,
            error: "Connecting…",
            state: "stop",
            volume: null,
            repeat: false,
            random: false,
            single: "off",
            consume: "off",
            elapsed: 0,
            syncedAt: 0,
            duration: 0,
            playlistVersion: 0,
            playlistLength: 0,
            songPosition: 0,
            songId: -1,
            bitrate: null,
            audio: "",
            playbackError: "",
            song: null,
            artUrl: ""
        })
    property double baseElapsed: 0
    property double baseTime: 0
    property string lastSignature: ""
    property string actionError: ""
    property string lastActionError: ""

    function signatureFor(s) {
        if (!s)
            return "";
        return JSON.stringify({
            ok: !!s.ok,
            error: s.error || "",
            state: s.state || "stop",
            volume: s.volume !== undefined ? s.volume : null,
            repeat: !!s.repeat,
            random: !!s.random,
            single: s.single || "off",
            consume: s.consume || "off",
            duration: Math.round((s.duration || 0) * 10),
            playlistVersion: s.playlistVersion || 0,
            playlistLength: s.playlistLength || 0,
            songPosition: s.songPosition || 0,
            songId: s.songId !== undefined ? s.songId : -1,
            bitrate: s.bitrate || null,
            audio: s.audio || "",
            playbackError: s.playbackError || "",
            song: s.song || null,
            artUrl: s.artUrl || ""
        });
    }

    function publishState(force) {
        const sig = signatureFor(snapshot);
        if (force || sig !== lastSignature) {
            lastSignature = sig;
            PluginService.setGlobalVar("mpdControl", "state", snapshot);
        }
        if (actionError !== lastActionError) {
            lastActionError = actionError;
            PluginService.setGlobalVar("mpdControl", "actionError", actionError);
        }
    }

    function enqueue(action, target) {
        const cleanTarget = target !== undefined && target !== null ? String(target) : "";
        if (action !== "snapshot" && !snapshot.ok)
            return;
        if (action === "snapshot") {
            if (worker.running || pending.some(item => item.action === "snapshot"))
                return;
            pending = pending.concat([
                {
                    action: "snapshot",
                    target: ""
                }
            ]);
            next();
            return;
        }
        if (action === "queue") {
            const existingQueueIdx = pending.findIndex(item => item.action === "queue");
            if (existingQueueIdx >= 0) {
                const copy = pending.slice();
                copy[existingQueueIdx] = {
                    action: "queue",
                    target: cleanTarget
                };
                pending = copy;
                next();
                return;
            }
            pending = pending.concat([
                {
                    action: "queue",
                    target: cleanTarget
                }
            ]);
            next();
            return;
        }
        if (action === "volume") {
            const parsedVol = Math.max(0, Math.min(100, Math.round(Number(cleanTarget))));
            if (isFinite(parsedVol) && snapshot.volume !== parsedVol) {
                snapshot = Object.assign({}, snapshot, {
                    volume: parsedVol
                });
                publishState(false);
            }
            const existingIndex = pending.findIndex(item => item.action === "volume");
            if (existingIndex >= 0) {
                const copy = pending.slice();
                copy[existingIndex] = {
                    action: "volume",
                    target: String(parsedVol)
                };
                pending = copy;
                next();
                return;
            }
        }
        pending = pending.filter(item => item.action !== "snapshot").concat([
            {
                action: action,
                target: cleanTarget
            }
        ]);
        next();
    }

    function next() {
        if (worker.running || !pending.length)
            return;
        active = pending[0];
        pending = pending.slice(1);
        const cmd = ["python3", decodeURIComponent(Qt.resolvedUrl("backend.py").toString().replace(/^file:\/\//, "")), "--address", pluginData.address || "", "--password-file", pluginData.passwordPath || "", "--action", active.action, "--target", active.target];
        if (pluginData.showArt === false)
            cmd.push("--no-art");
        worker.command = cmd;
        worker.running = true;
    }

    function complete(result) {
        if (active.action === "snapshot") {
            if (result.ok) {
                const now = Date.now();
                const expectedElapsed = snapshot.ok && snapshot.state === "play" && baseTime > 0 ? Math.min(result.duration || Infinity, baseElapsed + Math.max(0, (now - baseTime) / 1000)) : (snapshot.elapsed || 0);
                const elapsedDrift = Math.abs((result.elapsed || 0) - expectedElapsed);
                const stateTransitioned = result.state !== snapshot.state || (result.song?.file || "") !== (snapshot.song?.file || "");
                baseElapsed = result.elapsed || 0;
                baseTime = now;
                result.syncedAt = now;
                result.updated = now;
                snapshot = result;
                publishState(stateTransitioned || elapsedDrift > 1.5);
            } else {
                snapshot = {
                    ok: false,
                    error: result.error,
                    state: snapshot.state || "stop",
                    volume: snapshot.volume !== undefined ? snapshot.volume : null,
                    repeat: !!snapshot.repeat,
                    random: !!snapshot.random,
                    single: snapshot.single || "off",
                    consume: snapshot.consume || "off",
                    elapsed: snapshot.elapsed || 0,
                    syncedAt: snapshot.syncedAt || 0,
                    duration: snapshot.duration || 0,
                    playlistVersion: snapshot.playlistVersion || 0,
                    playlistLength: snapshot.playlistLength || 0,
                    songPosition: snapshot.songPosition || 0,
                    songId: snapshot.songId !== undefined ? snapshot.songId : -1,
                    bitrate: snapshot.bitrate || null,
                    audio: snapshot.audio || "",
                    playbackError: snapshot.playbackError || "",
                    song: snapshot.song || null,
                    artUrl: snapshot.artUrl || "",
                    updated: snapshot.updated
                };
                publishState(false);
            }
        } else if (active.action === "queue") {
            if (result.ok) {
                result.nonce = Date.now() + Math.random();
                PluginService.setGlobalVar("mpdControl", "queue", result);
            } else {
                actionError = result.error || "Failed to load queue.";
                publishState(false);
            }
        } else {
            actionError = result.ok ? "" : result.error;
            if (!pending.some(item => item.action === "snapshot")) {
                pending = pending.concat([
                    {
                        action: "snapshot",
                        target: ""
                    }
                ]);
            }
            publishState(false);
        }
        Qt.callLater(next);
    }

    Process {
        id: worker
        property string output: ""
        stdout: StdioCollector {
            onStreamFinished: worker.output = text
        }
        onExited: (code, status) => {
            let result;
            try {
                result = JSON.parse(worker.output);
            } catch (e) {
                result = {
                    ok: false,
                    error: "Backend failed. Ensure Python 3 is installed."
                };
            }
            worker.output = "";
            root.complete(result);
        }
    }

    Connections {
        target: PluginService
        function onGlobalVarChanged(id, name) {
            if (id !== "mpdControl" || name !== "request")
                return;
            const request = PluginService.getGlobalVar(id, name, null);
            if (request)
                root.enqueue(request.action, request.target);
        }
    }

    Timer {
        interval: 4000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.enqueue("snapshot", "")
    }

    onPluginDataChanged: {
        lastSignature = "";
        if (!worker.running)
            enqueue("snapshot", "");
    }

    Component.onDestruction: PluginService.setGlobalVar("mpdControl", "state", {
        ok: false,
        error: "Plugin disabled",
        state: "stop",
        volume: null,
        repeat: false,
        random: false,
        single: "off",
        consume: "off",
        elapsed: 0,
        syncedAt: 0,
        duration: 0,
        playlistVersion: 0,
        playlistLength: 0,
        songPosition: 0,
        songId: -1,
        bitrate: null,
        audio: "",
        playbackError: "",
        song: null,
        artUrl: ""
    })
}
