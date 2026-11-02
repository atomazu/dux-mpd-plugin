import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets as Material
import qs.Modules.Plugins
import "Format.js" as Format

PluginComponent {
    id: root

    PluginGlobalVar {
        id: stateVar
        varName: "state"
        defaultValue: ({
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
                playlistLength: 0,
                songPosition: 0,
                bitrate: null,
                audio: "",
                playbackError: "",
                song: null,
                artUrl: ""
            })
    }
    PluginGlobalVar {
        id: errorVar
        varName: "actionError"
        defaultValue: ""
    }

    readonly property var state: stateVar.value
    readonly property string actionError: errorVar.value

    // Typed primitive properties prevent unnecessary QML re-evaluations when unrelated state fields update.
    readonly property bool ok: !!state.ok
    readonly property string errorText: state.error || ""
    readonly property bool hasUpdated: !!state.updated
    readonly property string playerState: state.state || "stop"
    readonly property bool isPlaying: ok && playerState === "play"
    readonly property bool isPaused: ok && playerState === "pause"
    readonly property bool ready: ok
    readonly property bool canToggle: ok && (playlistLength > 0 || playerState === "play" || playerState === "pause")
    readonly property int backendVolume: state.volume !== null && state.volume !== undefined ? state.volume : -1
    readonly property int volume: pendingVolume >= 0 ? pendingVolume : backendVolume
    readonly property bool repeat: !!state.repeat
    readonly property bool random: !!state.random
    readonly property string single: state.single || "off"
    readonly property string consume: state.consume || "off"
    readonly property double elapsed: state.elapsed || 0
    readonly property double syncedAt: state.syncedAt || 0
    readonly property double duration: state.duration || 0
    readonly property int playlistLength: state.playlistLength || 0
    readonly property int songPosition: state.songPosition || 0
    readonly property int bitrate: state.bitrate || 0
    readonly property string audio: state.audio || ""
    readonly property string playbackError: state.playbackError || ""
    readonly property bool hasSong: !!state.song
    readonly property string songTitle: state.song ? (state.song.title || "") : ""
    readonly property string songArtist: state.song ? (state.song.artist || "") : ""
    readonly property string songAlbum: state.song ? (state.song.album || "") : ""
    readonly property string artUrl: state.artUrl || ""
    readonly property string statusIcon: Format.icon(state)
    readonly property string statusSummary: Format.summary(state)
    readonly property string statusSubtitle: Format.subtitle(state)
    readonly property string hoverText: Format.hoverText(state)
    readonly property string barText: Format.pillText(state, pluginData.showArtist !== false)
    readonly property int badgeSize: Math.max(18, Math.min(widgetThickness - 4, iconSize + 2))

    property int pendingVolume: -1
    property real scrollAccumulatorY: 0
    property Item hoveredPillItem: null

    onBackendVolumeChanged: {
        if (!volumeCommitTimer.running)
            pendingVolume = -1;
    }

    Timer {
        id: volumeCommitTimer
        interval: 35
        repeat: false
        onTriggered: {
            if (root.pendingVolume >= 0) {
                const targetVol = root.pendingVolume;
                root.request("volume", targetVol);
            }
        }
    }

    Timer {
        id: pendingVolumeResetTimer
        interval: 600
        repeat: false
        onTriggered: root.pendingVolume = -1
    }

    function request(action, target) {
        PluginService.setGlobalVar("mpdControl", "request", {
            action: action,
            target: target !== undefined && target !== null ? String(target) : "",
            nonce: Date.now() + Math.random()
        });
    }

    function handleWheel(wheelEvent) {
        if (!root.ok || root.backendVolume < 0)
            return;
        wheelEvent.accepted = true;
        const deltaY = wheelEvent.angleDelta.y;
        const isMouseWheelY = Math.abs(deltaY) >= 120 && (Math.abs(deltaY) % 120) === 0;
        const step = SettingsData.audioWheelScrollAmount || 5;
        const base = root.pendingVolume >= 0 ? root.pendingVolume : root.backendVolume;
        let nextVol = base;
        if (isMouseWheelY) {
            const notches = Math.round(deltaY / 120);
            nextVol = Math.max(0, Math.min(100, base + notches * step));
        } else {
            root.scrollAccumulatorY += deltaY;
            if (Math.abs(root.scrollAccumulatorY) >= 100) {
                nextVol = Math.max(0, Math.min(100, base + (root.scrollAccumulatorY > 0 ? 1 : -1)));
                root.scrollAccumulatorY = 0;
            }
        }
        if (nextVol !== base) {
            root.pendingVolume = nextVol;
            volumeCommitTimer.restart();
            pendingVolumeResetTimer.restart();
        }
    }

    Loader {
        id: tooltipLoader
        active: false
        sourceComponent: DTooltip {}
    }

    function findBarPill(item) {
        let cur = item;
        while (cur) {
            if (typeof cur.contextMenuAnchor === "function")
                return cur;
            cur = cur.parent;
        }
        return null;
    }

    function computeTooltipAnchor(item) {
        const pill = findBarPill(item);
        if (pill)
            return pill.contextMenuAnchor();
        const screen = root.parentScreen || Screen;
        const vertical = root.isVertical;
        const edge = root.axis?.edge ?? (vertical ? "left" : "top");
        const gap = Math.max(Theme.spacingXS, root.barSpacing ?? Theme.spacingXS);
        const edgeInset = root.barThickness + root.barSpacing + gap;
        const globalPos = item.mapToGlobal(item.width / 2, item.height / 2);
        const relativeX = globalPos.x - (screen.x || 0);
        const relativeY = globalPos.y - (screen.y || 0);
        if (vertical) {
            return {
                x: edge === "left" ? edgeInset : screen.width - edgeInset,
                y: relativeY,
                isVertical: true,
                edge: edge,
                screen: screen
            };
        }
        return {
            x: relativeX,
            y: edge === "bottom" ? screen.height - edgeInset : edgeInset,
            isVertical: false,
            edge: edge,
            screen: screen
        };
    }

    function showTrackTooltip(item) {
        if (!item || !root.hoverText)
            return;
        root.hoveredPillItem = item;
        tooltipLoader.active = true;
        const anchor = computeTooltipAnchor(item);
        if (tooltipLoader.item) {
            tooltipLoader.item.show(root.hoverText, anchor.x, anchor.y, anchor.screen, anchor.isVertical && anchor.edge === "left", anchor.isVertical && anchor.edge === "right");
        }
    }

    function hideTrackTooltip() {
        root.hoveredPillItem = null;
        if (tooltipLoader.item)
            tooltipLoader.item.hide();
        tooltipLoader.active = false;
    }

    onHoverTextChanged: {
        if (root.hoveredPillItem && tooltipLoader.active && tooltipLoader.item?.visible)
            showTrackTooltip(root.hoveredPillItem);
    }

    popoutWidth: 460
    popoutHeight: 540

    horizontalBarPill: Component {
        Item {
            id: hPill
            implicitWidth: hRow.implicitWidth
            implicitHeight: root.widgetThickness
            width: implicitWidth
            height: implicitHeight

            readonly property bool pillHovered: hHover.hovered || hIconArea.containsMouse || hPlayButton.hovered
            onPillHoveredChanged: pillHovered ? root.showTrackTooltip(hPill) : root.hideTrackTooltip()

            HoverHandler {
                id: hHover
            }

            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => root.handleWheel(event)
            }

            Row {
                id: hRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                Item {
                    width: root.badgeSize
                    height: root.badgeSize
                    anchors.verticalCenter: parent.verticalCenter

                    ClippingRectangle {
                        anchors.fill: parent
                        radius: Theme.cornerRadiusXS
                        color: root.artUrl !== "" && hArtImage.status === Image.Ready ? "transparent" : Theme.secondaryContainer
                        antialiasing: true

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.statusIcon
                            size: Math.max(14, root.badgeSize - 4)
                            color: root.ok ? (root.isPlaying ? Theme.primary : Theme.onSecondaryContainer) : Theme.surfaceVariantText
                            visible: !hArtImage.visible
                        }

                        Image {
                            id: hArtImage
                            anchors.fill: parent
                            source: root.artUrl
                            asynchronous: true
                            retainWhileLoading: true
                            cache: true
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(root.badgeSize * 2, root.badgeSize * 2)
                            visible: root.artUrl !== "" && status === Image.Ready
                        }
                    }

                    MouseArea {
                        id: hIconArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: mouse => {
                            root.hideTrackTooltip();
                            if (mouse.button === Qt.RightButton) {
                                root.runPillAction(root.pillRightClickAction);
                                return;
                            }
                            root.triggerPopout();
                        }
                    }
                }

                StyledText {
                    visible: root.pluginData.showBarText === true
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, 180)
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    text: root.barText
                    font.pixelSize: root.textSize
                    color: Theme.surfaceText

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.hideTrackTooltip();
                            root.triggerPopout();
                        }
                    }
                }

                Material.DIconButton {
                    id: hPlayButton
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.badgeSize
                    height: root.badgeSize
                    buttonSize: root.badgeSize
                    iconSize: Math.max(12, Math.round(root.badgeSize * 0.65))
                    radius: pressed ? Theme.cornerRadiusXS : (checked ? Theme.cornerRadiusFull : Theme.cornerRadiusS)
                    variant: "filled"
                    round: false
                    checkable: true
                    checked: root.isPlaying
                    iconFilled: false
                    iconName: root.isPlaying ? "pause" : "play_arrow"
                    Accessible.name: root.isPlaying ? "Pause" : "Play"
                    enabled: root.canToggle
                    onClicked: root.request("toggle")
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            id: vPill
            implicitWidth: root.widgetThickness
            implicitHeight: vCol.implicitHeight
            width: implicitWidth
            height: implicitHeight

            readonly property bool pillHovered: vHover.hovered || vIconArea.containsMouse || vPlayButton.hovered
            onPillHoveredChanged: pillHovered ? root.showTrackTooltip(vPill) : root.hideTrackTooltip()

            HoverHandler {
                id: vHover
            }

            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => root.handleWheel(event)
            }

            Column {
                id: vCol
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                Item {
                    width: root.badgeSize
                    height: root.badgeSize
                    anchors.horizontalCenter: parent.horizontalCenter

                    ClippingRectangle {
                        anchors.fill: parent
                        radius: Theme.cornerRadiusXS
                        color: root.artUrl !== "" && vArtImage.status === Image.Ready ? "transparent" : Theme.secondaryContainer
                        antialiasing: true

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.statusIcon
                            size: Math.max(14, root.badgeSize - 4)
                            color: root.ok ? (root.isPlaying ? Theme.primary : Theme.onSecondaryContainer) : Theme.surfaceVariantText
                            visible: !vArtImage.visible
                        }

                        Image {
                            id: vArtImage
                            anchors.fill: parent
                            source: root.artUrl
                            asynchronous: true
                            retainWhileLoading: true
                            cache: true
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(root.badgeSize * 2, root.badgeSize * 2)
                            visible: root.artUrl !== "" && status === Image.Ready
                        }
                    }

                    MouseArea {
                        id: vIconArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: mouse => {
                            root.hideTrackTooltip();
                            if (mouse.button === Qt.RightButton) {
                                root.runPillAction(root.pillRightClickAction);
                                return;
                            }
                            root.triggerPopout();
                        }
                    }
                }

                Material.DIconButton {
                    id: vPlayButton
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: root.badgeSize
                    height: root.badgeSize
                    buttonSize: root.badgeSize
                    iconSize: Math.max(12, Math.round(root.badgeSize * 0.65))
                    radius: pressed ? Theme.cornerRadiusXS : (checked ? Theme.cornerRadiusFull : Theme.cornerRadiusS)
                    variant: "filled"
                    round: false
                    checkable: true
                    checked: root.isPlaying
                    iconFilled: false
                    iconName: root.isPlaying ? "pause" : "play_arrow"
                    Accessible.name: root.isPlaying ? "Pause" : "Play"
                    enabled: root.canToggle
                    onClicked: root.request("toggle")
                }
            }
        }
    }

    ccWidgetIcon: statusIcon
    // Dux 2.0 PluginDetailShell derives its title from ccWidgetPrimaryText.
    // It owns a separate PluginInstanceHost, so this flag only affects that view.
    property bool controlCenterDetailMounted: false
    ccWidgetPrimaryText: controlCenterDetailMounted ? "MPD" : (hasSong ? songTitle : "MPD")
    ccWidgetSecondaryText: ok ? (hasSong && songArtist ? songArtist + " · " + statusSummary : statusSummary) : "MPD unavailable"
    ccWidgetIsActive: isPlaying
    onCcWidgetToggled: {
        if (canToggle)
            request("toggle");
    }
    ccDetailContent: Component {
        Panel {
            Component.onCompleted: root.controlCenterDetailMounted = true
            Component.onDestruction: root.controlCenterDetailMounted = false
            controller: root
            width: parent.width
            height: 460
        }
    }
    ccDetailHeight: 460
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "MPD"
            detailsText: ""
            Panel {
                width: parent.width
                height: Math.max(240, root.popoutHeight - popout.headerHeight - popout.detailsHeight - 24)
                controller: root
            }
        }
    }
}
