import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Widgets
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets as Material
import "Format.js" as Format

Item {
    id: panel
    required property var controller
    readonly property bool hasError: !controller.ok || controller.playbackError.length > 0
    readonly property string audioDetails: Format.audioFormat(controller.audio, controller.bitrate)
    readonly property string queueBadge: {
        var parts = [];
        if (controller.songPosition > 0 && controller.playlistLength > 0)
            parts.push("Track " + controller.songPosition + " of " + controller.playlistLength);
        else if (controller.playlistLength > 0)
            parts.push(controller.playlistLength + " tracks in queue");
        if (audioDetails.length > 0)
            parts.push(audioDetails);
        return parts.join(" · ");
    }

    property double liveElapsed: controller.elapsed

    function syncLiveElapsed() {
        if (!controller.ok) {
            liveElapsed = controller.elapsed;
            return;
        }
        if (controller.isPlaying && controller.syncedAt > 0) {
            const delta = Math.max(0, (Date.now() - controller.syncedAt) / 1000);
            const dur = controller.duration;
            liveElapsed = dur > 0 ? Math.min(dur, controller.elapsed + delta) : (controller.elapsed + delta);
        } else {
            liveElapsed = controller.elapsed;
        }
    }

    Connections {
        target: panel.controller
        function onElapsedChanged() {
            panel.syncLiveElapsed();
        }
        function onSyncedAtChanged() {
            panel.syncLiveElapsed();
        }
        function onPlayerStateChanged() {
            panel.syncLiveElapsed();
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: panel.visible && panel.controller.isPlaying && !seekSlider.isDragging
        onTriggered: {
            panel.syncLiveElapsed();
            if (panel.controller.duration > 0 && panel.liveElapsed >= panel.controller.duration)
                panel.controller.request("snapshot");
        }
    }

    Component.onCompleted: syncLiveElapsed()

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacingM

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: heroColumn.implicitHeight + Theme.spacingL * 2
            radius: Theme.cornerRadiusL
            color: panel.hasError ? Theme.errorContainer : Theme.secondaryContainer
            ColumnLayout {
                id: heroColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingM

                    ClippingRectangle {
                        implicitWidth: 68
                        implicitHeight: 68
                        radius: Theme.cornerRadiusM
                        color: panel.hasError ? Theme.error : Theme.surfaceContainerHigh
                        antialiasing: true

                        DankIcon {
                            anchors.centerIn: parent
                            name: panel.controller.statusIcon
                            size: Theme.iconSize + Theme.spacingS
                            color: panel.hasError ? Theme.onError : Theme.onSecondaryContainer
                            visible: !artImage.visible
                        }

                        Image {
                            id: artImage
                            anchors.fill: parent
                            source: panel.controller.artUrl
                            asynchronous: true
                            retainWhileLoading: true
                            cache: true
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(136, 136)
                            visible: panel.controller.artUrl !== "" && status === Image.Ready
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingXS
                        StyledText {
                            Layout.fillWidth: true
                            text: panel.controller.hasSong ? panel.controller.songTitle : panel.controller.statusSummary
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: panel.hasError ? Theme.onErrorContainer : Theme.onSecondaryContainer
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            wrapMode: Text.Wrap
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: panel.controller.ok ? panel.controller.statusSubtitle : panel.controller.errorText + (panel.controller.hasUpdated ? " · Last known state" : "")
                            color: panel.hasError ? Theme.onErrorContainer : Theme.onSecondaryContainer
                            font.pixelSize: Theme.fontSizeSmall
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            wrapMode: Text.Wrap
                        }
                        StyledText {
                            visible: panel.controller.ok && panel.queueBadge.length > 0
                            Layout.fillWidth: true
                            text: panel.queueBadge
                            color: panel.hasError ? Theme.onErrorContainer : Theme.onSecondaryContainer
                            font.pixelSize: Theme.fontSizeSmall
                            elide: Text.ElideRight
                        }
                    }

                    Material.DIconButton {
                        iconName: "refresh"
                        tooltipText: "Refresh status"
                        onClicked: panel.controller.request("snapshot")
                    }
                }

                RowLayout {
                    visible: panel.controller.playbackError.length > 0
                    Layout.fillWidth: true
                    spacing: Theme.spacingS
                    DankIcon {
                        name: "error_outline"
                        size: Theme.iconSizeSmall
                        color: Theme.onErrorContainer
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: panel.controller.playbackError
                        color: Theme.onErrorContainer
                        font.pixelSize: Theme.fontSizeSmall
                        wrapMode: Text.Wrap
                    }
                    ActionButton {
                        text: "Clear"
                        iconName: "close"
                        enabled: panel.controller.ready
                        onClicked: panel.controller.request("clearerror")
                    }
                }
            }
        }

        Rectangle {
            visible: panel.controller.actionError.length > 0
            Layout.fillWidth: true
            implicitHeight: actionErrorText.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadiusM
            color: Theme.errorContainer
            StyledText {
                id: actionErrorText
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                text: panel.controller.actionError
                color: Theme.onErrorContainer
                wrapMode: Text.Wrap
                font.pixelSize: Theme.fontSizeSmall
            }
        }

        Flickable {
            id: scroller
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: cards.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            Column {
                id: cards
                width: scroller.width - Theme.spacingM
                spacing: Theme.groupedListGap

                Rectangle {
                    width: cards.width
                    height: transportColumn.implicitHeight + Theme.spacingL * 2
                    color: Theme.surfaceContainer
                    topLeftRadius: Theme.groupedListOuterRadius
                    topRightRadius: Theme.groupedListOuterRadius
                    bottomLeftRadius: Theme.groupedListInnerRadius
                    bottomRightRadius: Theme.groupedListInnerRadius

                    ColumnLayout {
                        id: transportColumn
                        x: Theme.spacingL
                        y: Theme.spacingL
                        width: parent.width - Theme.spacingL * 2
                        spacing: Theme.spacingM

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingXS

                            Material.DSlider {
                                id: seekSlider
                                Layout.fillWidth: true
                                size: "s"
                                showValue: false
                                minimum: 0
                                maximum: Math.max(1, Math.round(panel.controller.duration))
                                enabled: panel.controller.ready && panel.controller.duration > 0 && (panel.controller.isPlaying || panel.controller.isPaused)
                                value: isDragging ? value : Math.min(maximum, Math.round(panel.liveElapsed))
                                onSliderDragFinished: finalValue => {
                                    panel.liveElapsed = finalValue;
                                    panel.controller.request("seek", finalValue);
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                StyledText {
                                    text: Format.duration(seekSlider.isDragging ? seekSlider.value : panel.liveElapsed)
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                                Item {
                                    Layout.fillWidth: true
                                }
                                StyledText {
                                    text: Format.duration(panel.controller.duration)
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingM
                            Item {
                                Layout.fillWidth: true
                            }
                            Material.DIconButton {
                                iconName: "skip_previous"
                                variant: "tonal"
                                tooltipText: "Previous track"
                                enabled: panel.controller.ready && panel.controller.playlistLength > 0
                                onClicked: panel.controller.request("previous")
                            }
                            Material.DIconButton {
                                iconName: panel.controller.isPlaying ? "pause" : "play_arrow"
                                size: "m"
                                widthMode: "wide"
                                variant: "filled"
                                tooltipText: panel.controller.isPlaying ? "Pause" : "Play"
                                enabled: panel.controller.canToggle
                                onClicked: panel.controller.request("toggle")
                            }
                            Material.DIconButton {
                                iconName: "stop"
                                variant: "tonal"
                                tooltipText: "Stop"
                                enabled: panel.controller.ready && (panel.controller.isPlaying || panel.controller.isPaused)
                                onClicked: panel.controller.request("stop")
                            }
                            Material.DIconButton {
                                iconName: "skip_next"
                                variant: "tonal"
                                tooltipText: "Next track"
                                enabled: panel.controller.ready && panel.controller.playlistLength > 0
                                onClicked: panel.controller.request("next")
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                        }
                    }
                }

                Rectangle {
                    width: cards.width
                    height: modesColumn.implicitHeight + Theme.spacingL * 2
                    color: Theme.surfaceContainer
                    topLeftRadius: Theme.groupedListInnerRadius
                    topRightRadius: Theme.groupedListInnerRadius
                    bottomLeftRadius: Theme.groupedListInnerRadius
                    bottomRightRadius: Theme.groupedListInnerRadius

                    ColumnLayout {
                        id: modesColumn
                        x: Theme.spacingL
                        y: Theme.spacingL
                        width: parent.width - Theme.spacingL * 2
                        spacing: Theme.spacingS

                        StyledText {
                            Layout.fillWidth: true
                            text: "Playback modes"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }

                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.spacingS

                            ActionButton {
                                text: "Repeat"
                                iconName: "repeat"
                                prominent: panel.controller.repeat
                                enabled: panel.controller.ready
                                onClicked: panel.controller.request("repeat")
                            }
                            ActionButton {
                                text: "Random"
                                iconName: "shuffle"
                                prominent: panel.controller.random
                                enabled: panel.controller.ready
                                onClicked: panel.controller.request("random")
                            }
                            ActionButton {
                                text: Format.singleLabel(panel.controller.single)
                                iconName: "repeat_one"
                                prominent: panel.controller.single === "on" || panel.controller.single === "oneshot"
                                enabled: panel.controller.ready
                                onClicked: panel.controller.request("single")
                            }
                            ActionButton {
                                text: "Consume"
                                iconName: "playlist_remove"
                                prominent: panel.controller.consume === "on" || panel.controller.consume === "oneshot"
                                enabled: panel.controller.ready
                                onClicked: panel.controller.request("consume")
                            }
                        }
                    }
                }

                Rectangle {
                    width: cards.width
                    height: volumeColumn.implicitHeight + Theme.spacingL * 2
                    color: Theme.surfaceContainer
                    topLeftRadius: Theme.groupedListInnerRadius
                    topRightRadius: Theme.groupedListInnerRadius
                    bottomLeftRadius: Theme.groupedListOuterRadius
                    bottomRightRadius: Theme.groupedListOuterRadius

                    ColumnLayout {
                        id: volumeColumn
                        x: Theme.spacingL
                        y: Theme.spacingL
                        width: parent.width - Theme.spacingL * 2
                        spacing: Theme.spacingS

                        RowLayout {
                            Layout.fillWidth: true
                            StyledText {
                                Layout.fillWidth: true
                                text: "Volume"
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }
                            StyledText {
                                visible: panel.controller.volume >= 0
                                text: (volumeSlider.isDragging ? volumeSlider.value : Math.max(0, panel.controller.volume)) + "%"
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                            }
                        }

                        Material.DSlider {
                            id: volumeSlider
                            visible: panel.controller.volume >= 0
                            Layout.fillWidth: true
                            size: "m"
                            minimum: 0
                            maximum: 100
                            unit: "%"
                            insetIcon: {
                                const current = volumeSlider.isDragging ? volumeSlider.value : Math.max(0, panel.controller.volume);
                                if (current <= 0)
                                    return "volume_off";
                                if (current < 50)
                                    return "volume_down";
                                return "volume_up";
                            }
                            enabled: panel.controller.ready && panel.controller.volume >= 0
                            value: isDragging ? value : Math.max(0, panel.controller.volume)
                            onSliderDragFinished: finalValue => panel.controller.request("volume", finalValue)
                        }

                        StyledText {
                            visible: panel.controller.volume < 0
                            Layout.fillWidth: true
                            text: panel.controller.ok ? "Mixer control is disabled on this MPD output" : "Connect to MPD to adjust volume"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            StyledText {
                text: "MPD Control"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                Layout.fillWidth: true
            }
            ActionButton {
                text: panel.controller.isPlaying ? "Pause" : "Play"
                iconName: panel.controller.isPlaying ? "pause" : "play_arrow"
                prominent: !panel.controller.isPlaying
                enabled: panel.controller.canToggle
                onClicked: panel.controller.request("toggle")
            }
        }
    }
}
