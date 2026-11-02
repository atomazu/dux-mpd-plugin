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
    property string page: "player"
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

    // Virtualized, windowed queue state for thousands of entries
    readonly property int pageSize: 100
    readonly property int maxLoadedItems: 300
    readonly property int rowHeight: 52
    readonly property int rowPitch: rowHeight + Theme.groupedListGap
    property int windowStart: 0
    property int windowEnd: 0
    property int queueTotal: controller.playlistLength
    property int queueMatched: controller.playlistLength
    property int loadedQueueVersion: -1
    property bool queueInitialized: false
    property bool queueLoading: false
    property bool centerOnCurrentPending: false
    property string searchQuery: ""
    property bool confirmClear: false
    property double lastAppliedNonce: 0
    property int draggingTrackId: -1
    property int dragStartPos: -1
    property int dragTargetPos: -1

    ListModel {
        id: queueModel
    }

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

    function requestQueueWindow(offset, mode) {
        if (!controller.ok)
            return;
        queueLoading = true;
        controller.requestQueue(offset, pageSize, mode || "replace", searchQuery);
    }

    function jumpToCurrentTrack() {
        searchField.text = "";
        searchQuery = "";
        centerOnCurrentPending = true;
        requestQueueWindow(-1, "replace");
    }

    function setModelItemsInPlace(items) {
        const count = items.length;
        const common = Math.min(queueModel.count, count);
        for (let i = 0; i < common; i++)
            queueModel.set(i, items[i]);
        for (let i = common; i < count; i++)
            queueModel.append(items[i]);
        if (queueModel.count > count)
            queueModel.remove(count, queueModel.count - count);
    }

    function applyQueueSlice(slice) {
        if (!slice || !slice.ok || slice.nonce === lastAppliedNonce)
            return;
        lastAppliedNonce = slice.nonce;
        queueLoading = false;
        queueInitialized = true;
        loadedQueueVersion = slice.playlistVersion;
        queueTotal = slice.total;
        queueMatched = slice.matched;
        const items = slice.items || [];

        if (slice.mode === "append") {
            if (items.length === 0)
                return;
            for (let i = 0; i < items.length; i++)
                queueModel.append(items[i]);
            windowEnd = slice.offset + items.length;
            if (queueModel.count > maxLoadedItems) {
                const excess = queueModel.count - maxLoadedItems;
                const savedY = queueList.contentY;
                queueModel.remove(0, excess);
                windowStart += excess;
                queueList.contentY = Math.max(0, savedY - excess * rowPitch);
            }
            return;
        }

        if (slice.mode === "prepend") {
            if (items.length === 0)
                return;
            const savedY = queueList.contentY;
            for (let i = items.length - 1; i >= 0; i--)
                queueModel.insert(0, items[i]);
            windowStart = slice.offset;
            queueList.contentY = savedY + items.length * rowPitch;
            if (queueModel.count > maxLoadedItems) {
                const excess = queueModel.count - maxLoadedItems;
                queueModel.remove(maxLoadedItems, excess);
                windowEnd = windowStart + maxLoadedItems;
            }
            return;
        }

        if (slice.mode === "sync") {
            windowStart = slice.offset;
            windowEnd = slice.offset + items.length;
            setModelItemsInPlace(items);
            return;
        }

        // mode === "replace"
        windowStart = slice.offset;
        windowEnd = slice.offset + items.length;
        setModelItemsInPlace(items);

        if (centerOnCurrentPending) {
            centerOnCurrentPending = false;
            let targetIdx = -1;
            for (let i = 0; i < items.length; i++) {
                if ((controller.songId >= 0 && items[i].trackId === controller.songId) || (controller.songPosition > 0 && items[i].pos + 1 === controller.songPosition)) {
                    targetIdx = i;
                    break;
                }
            }
            if (targetIdx >= 0) {
                Qt.callLater(() => queueList.positionViewAtIndex(targetIdx, ListView.Center));
                return;
            }
        }
        Qt.callLater(() => queueList.positionViewAtBeginning());
    }

    function removeQueueRowOptimistic(index, songId) {
        if (index < 0 || index >= queueModel.count)
            return;
        const removedPos = queueModel.get(index).pos;
        queueModel.remove(index, 1);
        for (let i = index; i < queueModel.count; i++) {
            const cur = queueModel.get(i);
            if (cur.pos > removedPos)
                queueModel.setProperty(i, "pos", cur.pos - 1);
        }
        windowEnd = Math.max(windowStart, windowEnd - 1);
        queueTotal = Math.max(0, queueTotal - 1);
        queueMatched = Math.max(0, queueMatched - 1);
        controller.request("delete-id", songId);
    }

    function moveQueueRowStep(index, delta) {
        const targetIndex = index + delta;
        if (targetIndex < 0 || targetIndex >= queueModel.count)
            return;
        const itemA = queueModel.get(index);
        const itemB = queueModel.get(targetIndex);
        const songId = itemA.trackId;
        const targetPos = itemB.pos;
        const origPos = itemA.pos;
        queueModel.setProperty(index, "pos", targetPos);
        queueModel.setProperty(targetIndex, "pos", origPos);
        queueModel.move(index, targetIndex, 1);
        controller.request("move-id", songId + ":" + targetPos);
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
        function onQueueSliceChanged() {
            panel.applyQueueSlice(panel.controller.queueSlice);
        }
        function onPlaylistVersionChanged() {
            if (panel.page === "queue" && panel.draggingTrackId < 0) {
                if (!panel.queueInitialized) {
                    panel.centerOnCurrentPending = true;
                    panel.requestQueueWindow(-1, "replace");
                } else if (panel.loadedQueueVersion !== panel.controller.playlistVersion) {
                    panel.requestQueueWindow(panel.windowStart, "sync");
                }
            }
        }
    }

    Timer {
        id: searchDebounce
        interval: 200
        repeat: false
        onTriggered: {
            panel.requestQueueWindow(0, "replace");
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

        Material.DTabBar {
            Layout.fillWidth: true
            model: [
                {
                    text: "Player",
                    icon: "tune"
                },
                {
                    text: panel.controller.playlistLength > 0 ? "Queue (" + panel.controller.playlistLength + ")" : "Queue",
                    icon: "queue_music"
                }
            ]
            currentIndex: panel.page === "player" ? 0 : 1
            onTabClicked: index => {
                panel.page = index === 0 ? "player" : "queue";
                if (panel.page === "queue") {
                    if (!panel.queueInitialized) {
                        panel.centerOnCurrentPending = true;
                        panel.requestQueueWindow(-1, "replace");
                    } else if (panel.loadedQueueVersion !== panel.controller.playlistVersion) {
                        panel.requestQueueWindow(panel.windowStart, "sync");
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
            id: playerScroller
            visible: panel.page === "player"
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: playerColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            Column {
                id: playerColumn
                width: playerScroller.width - Theme.spacingM
                spacing: Theme.spacingM

                Rectangle {
                    width: playerColumn.width
                    implicitHeight: heroColumn.implicitHeight + Theme.spacingL * 2
                    height: implicitHeight
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
                    width: playerColumn.width
                    height: transportColumn.implicitHeight + Theme.spacingL * 2
                    color: Theme.surfaceContainer
                    radius: Theme.cornerRadiusL

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
                            spacing: Theme.spacingXS

                            Material.DIconButton {
                                iconName: "skip_previous"
                                widthMode: "narrow"
                                variant: "tonal"
                                tooltipText: "Previous track"
                                enabled: panel.controller.ready && panel.controller.playlistLength > 0
                                onClicked: panel.controller.request("previous")
                            }

                            Material.DIconButton {
                                iconName: panel.controller.isPlaying ? "pause" : "play_arrow"
                                variant: "filled"
                                round: false
                                checkable: true
                                checked: panel.controller.isPlaying
                                iconFilled: false
                                tooltipText: panel.controller.isPlaying ? "Pause" : "Play"
                                enabled: panel.controller.canToggle
                                onClicked: panel.controller.request("toggle")
                            }

                            Material.DIconButton {
                                iconName: "stop"
                                widthMode: "narrow"
                                variant: "tonal"
                                tooltipText: "Stop"
                                enabled: panel.controller.ready && (panel.controller.isPlaying || panel.controller.isPaused)
                                onClicked: panel.controller.request("stop")
                            }

                            Material.DIconButton {
                                iconName: "skip_next"
                                widthMode: "narrow"
                                variant: "tonal"
                                tooltipText: "Next track"
                                enabled: panel.controller.ready && panel.controller.playlistLength > 0
                                onClicked: panel.controller.request("next")
                            }

                            Rectangle {
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 20
                                Layout.leftMargin: 2
                                Layout.rightMargin: 2
                                color: Theme.outlineVariant
                            }

                            Material.DIconButton {
                                iconName: "repeat"
                                widthMode: "narrow"
                                checkable: true
                                checked: panel.controller.repeat
                                iconFilled: false
                                containerColor: Theme.primary
                                contentColor: Theme.onPrimary
                                tooltipText: panel.controller.repeat ? "Repeat: On" : "Repeat: Off"
                                enabled: panel.controller.ready
                                onClicked: panel.controller.request("repeat")
                            }

                            Material.DIconButton {
                                iconName: "shuffle"
                                widthMode: "narrow"
                                checkable: true
                                checked: panel.controller.random
                                iconFilled: false
                                containerColor: Theme.primary
                                contentColor: Theme.onPrimary
                                tooltipText: panel.controller.random ? "Random: On" : "Random: Off"
                                enabled: panel.controller.ready
                                onClicked: panel.controller.request("random")
                            }

                            Material.DIconButton {
                                iconName: "repeat_one"
                                widthMode: "narrow"
                                checkable: true
                                checked: panel.controller.single === "on" || panel.controller.single === "oneshot"
                                iconFilled: false
                                containerColor: panel.controller.single === "oneshot" ? Theme.tertiary : Theme.primary
                                contentColor: panel.controller.single === "oneshot" ? Theme.onTertiary : Theme.onPrimary
                                tooltipText: panel.controller.single === "oneshot" ? "Single: Oneshot (1×)" : (panel.controller.single === "on" ? "Single: On" : "Single: Off")
                                enabled: panel.controller.ready
                                onClicked: panel.controller.request("single")
                            }

                            Material.DIconButton {
                                iconName: "playlist_remove"
                                widthMode: "narrow"
                                checkable: true
                                checked: panel.controller.consume === "on" || panel.controller.consume === "oneshot"
                                iconFilled: false
                                containerColor: Theme.primary
                                contentColor: Theme.onPrimary
                                tooltipText: (panel.controller.consume === "on" || panel.controller.consume === "oneshot") ? "Consume: On" : "Consume: Off"
                                enabled: panel.controller.ready
                                onClicked: panel.controller.request("consume")
                            }

                            Rectangle {
                                visible: panel.controller.volume >= 0
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 20
                                Layout.leftMargin: 2
                                Layout.rightMargin: 2
                                color: Theme.outlineVariant
                            }

                            Material.DSlider {
                                id: volumeSlider
                                visible: panel.controller.volume >= 0
                                Layout.fillWidth: true
                                Layout.minimumWidth: 96
                                size: "s"
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
                        }
                    }
                }
            }
        }

        ColumnLayout {
            visible: panel.page === "queue"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.spacingS

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingXS

                Material.DSearchField {
                    id: searchField
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.buttonHeightS
                    placeholderText: "Filter queue…"
                    onTextChanged: {
                        const next = text.trim();
                        if (next === panel.searchQuery)
                            return;
                        panel.searchQuery = next;
                        searchDebounce.restart();
                    }
                }

                Material.DIconButton {
                    iconName: "my_location"
                    variant: "tonal"
                    tooltipText: "Jump to current track"
                    enabled: panel.controller.ready && panel.controller.songPosition > 0
                    onClicked: panel.jumpToCurrentTrack()
                }

                Material.DIconButton {
                    iconName: "shuffle"
                    variant: "tonal"
                    tooltipText: "Shuffle queue"
                    enabled: panel.controller.ready && panel.controller.playlistLength > 1
                    onClicked: panel.controller.request("shuffle-queue")
                }

                Material.DIconButton {
                    iconName: "delete_sweep"
                    variant: panel.confirmClear ? "filled" : "tonal"
                    tooltipText: "Clear queue"
                    enabled: panel.controller.ready && panel.controller.playlistLength > 0
                    onClicked: panel.confirmClear = !panel.confirmClear
                }
            }

            Rectangle {
                visible: panel.confirmClear && panel.controller.playlistLength > 0
                Layout.fillWidth: true
                implicitHeight: confirmRow.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadiusM
                color: Theme.errorContainer

                RowLayout {
                    id: confirmRow
                    anchors.fill: parent
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingS

                    StyledText {
                        Layout.fillWidth: true
                        text: "Clear all " + panel.controller.playlistLength + " tracks?"
                        color: Theme.onErrorContainer
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                    }

                    ActionButton {
                        text: "Cancel"
                        onClicked: panel.confirmClear = false
                    }

                    ActionButton {
                        text: "Clear all"
                        iconName: "delete_sweep"
                        prominent: true
                        onClicked: {
                            panel.confirmClear = false;
                            queueModel.clear();
                            panel.windowStart = 0;
                            panel.windowEnd = 0;
                            panel.queueTotal = 0;
                            panel.queueMatched = 0;
                            panel.controller.request("clear-queue");
                        }
                    }
                }
            }

            RowLayout {
                visible: panel.queueMatched > 0
                Layout.fillWidth: true
                spacing: Theme.spacingXS

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        const first = Math.min(panel.queueMatched, panel.windowStart + 1);
                        const last = Math.min(panel.queueMatched, panel.windowEnd);
                        if (panel.searchQuery.length > 0)
                            return first + "–" + last + " of " + panel.queueMatched + " matches";
                        return "Showing " + first + "–" + last + " of " + panel.queueTotal;
                    }
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    elide: Text.ElideRight
                }

                Material.DIconButton {
                    visible: panel.queueMatched > panel.pageSize
                    iconName: "first_page"
                    tooltipText: "First tracks (1–" + panel.pageSize + ")"
                    enabled: panel.windowStart > 0 && !panel.queueLoading
                    onClicked: panel.requestQueueWindow(0, "replace")
                }

                Material.DIconButton {
                    visible: panel.queueMatched > panel.pageSize
                    iconName: "chevron_left"
                    tooltipText: "Previous " + panel.pageSize + " tracks"
                    enabled: panel.windowStart > 0 && !panel.queueLoading
                    onClicked: panel.requestQueueWindow(Math.max(0, panel.windowStart - panel.pageSize), "replace")
                }

                Material.DIconButton {
                    visible: panel.queueMatched > panel.pageSize
                    iconName: "chevron_right"
                    tooltipText: "Next " + panel.pageSize + " tracks"
                    enabled: panel.windowEnd < panel.queueMatched && !panel.queueLoading
                    onClicked: panel.requestQueueWindow(Math.min(Math.max(0, panel.queueMatched - panel.pageSize), panel.windowEnd), "replace")
                }

                Material.DIconButton {
                    visible: panel.queueMatched > panel.pageSize
                    iconName: "last_page"
                    tooltipText: "Last " + panel.pageSize + " tracks"
                    enabled: panel.windowEnd < panel.queueMatched && !panel.queueLoading
                    onClicked: panel.requestQueueWindow(Math.max(0, panel.queueMatched - panel.pageSize), "replace")
                }
            }

            ListView {
                id: queueList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Theme.groupedListGap
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: panel.rowPitch * 6
                model: queueModel
                ScrollBar.vertical: ScrollBar {}

                onContentYChanged: {
                    if (!panel.queueLoading && panel.windowEnd < panel.queueMatched && contentHeight > height && contentY + height >= contentHeight - panel.rowPitch * 5) {
                        panel.requestQueueWindow(panel.windowEnd, "append");
                    }
                }

                header: Item {
                    width: queueList.width - Theme.spacingM
                    height: panel.windowStart > 0 ? Theme.buttonHeightS + Theme.spacingXS : 0
                    visible: panel.windowStart > 0

                    ActionButton {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "expand_less"
                        text: "Load previous " + Math.min(panel.pageSize, panel.windowStart) + " tracks (" + Math.max(1, panel.windowStart - panel.pageSize + 1) + "–" + panel.windowStart + ")"
                        enabled: !panel.queueLoading
                        onClicked: panel.requestQueueWindow(Math.max(0, panel.windowStart - panel.pageSize), "prepend")
                    }
                }

                footer: Item {
                    width: queueList.width - Theme.spacingM
                    height: panel.windowEnd < panel.queueMatched ? Theme.buttonHeightS + Theme.spacingXS : 0
                    visible: panel.windowEnd < panel.queueMatched

                    ActionButton {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "expand_more"
                        text: panel.queueLoading ? "Loading more tracks…" : "Load next " + Math.min(panel.pageSize, panel.queueMatched - panel.windowEnd) + " tracks"
                        enabled: !panel.queueLoading
                        onClicked: panel.requestQueueWindow(panel.windowEnd, "append")
                    }
                }

                delegate: Rectangle {
                    id: queueRow
                    required property int index
                    required property int trackId
                    required property int pos
                    required property string title
                    required property string artist
                    required property string album
                    required property double duration
                    required property string file

                    readonly property bool isCurrent: (panel.controller.songId >= 0 && queueRow.trackId === panel.controller.songId) || (panel.controller.songId < 0 && panel.controller.songPosition > 0 && queueRow.pos + 1 === panel.controller.songPosition)
                    readonly property bool isDraggingThis: panel.draggingTrackId === queueRow.trackId

                    width: queueList.width - Theme.spacingM
                    height: panel.rowHeight
                    z: isDraggingThis ? 10 : 1
                    color: isDraggingThis ? Theme.surfaceContainerHighest : (isCurrent ? Theme.secondaryContainer : (rowHover.hovered ? Theme.surfaceContainerHigh : Theme.surfaceContainer))
                    topLeftRadius: index === 0 ? Theme.groupedListOuterRadius : Theme.groupedListInnerRadius
                    topRightRadius: topLeftRadius
                    bottomLeftRadius: index === queueModel.count - 1 ? Theme.groupedListOuterRadius : Theme.groupedListInnerRadius
                    bottomRightRadius: bottomLeftRadius

                    HoverHandler {
                        id: rowHover
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingXS

                        Item {
                            visible: panel.searchQuery.length === 0
                            Layout.preferredWidth: 24
                            Layout.fillHeight: true

                            DankIcon {
                                anchors.centerIn: parent
                                name: "drag_indicator"
                                size: Theme.iconSizeSmall
                                color: queueRow.isCurrent ? Theme.onSecondaryContainer : Theme.surfaceVariantText
                                opacity: dragArea.containsMouse || queueRow.isDraggingThis ? 1.0 : 0.65
                            }

                            MouseArea {
                                id: dragArea
                                anchors.fill: parent
                                hoverEnabled: true
                                preventStealing: true
                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                property real pressY: 0
                                onPressed: mouse => {
                                    pressY = mouse.y;
                                    panel.draggingTrackId = queueRow.trackId;
                                    panel.dragStartPos = queueRow.pos;
                                    panel.dragTargetPos = queueRow.pos;
                                }
                                onPositionChanged: mouse => {
                                    if (!pressed || panel.draggingTrackId !== queueRow.trackId)
                                        return;
                                    const step = Math.trunc((mouse.y - pressY) / (panel.rowPitch * 0.75));
                                    if (step === 0)
                                        return;
                                    const targetIdx = Math.max(0, Math.min(queueModel.count - 1, queueRow.index + step));
                                    if (targetIdx === queueRow.index)
                                        return;
                                    const destPos = queueModel.get(targetIdx).pos;
                                    const curPos = queueRow.pos;
                                    queueModel.setProperty(queueRow.index, "pos", destPos);
                                    queueModel.setProperty(targetIdx, "pos", curPos);
                                    panel.dragTargetPos = destPos;
                                    queueModel.move(queueRow.index, targetIdx, 1);
                                }
                                onReleased: {
                                    const movedId = queueRow.trackId;
                                    const fromPos = panel.dragStartPos;
                                    const toPos = panel.dragTargetPos;
                                    panel.draggingTrackId = -1;
                                    panel.dragStartPos = -1;
                                    panel.dragTargetPos = -1;
                                    if (fromPos >= 0 && toPos >= 0 && fromPos !== toPos)
                                        panel.controller.request("move-id", movedId + ":" + toPos);
                                }
                                onCanceled: {
                                    panel.draggingTrackId = -1;
                                    panel.dragStartPos = -1;
                                    panel.dragTargetPos = -1;
                                }
                            }
                        }

                        Item {
                            Layout.preferredWidth: 36
                            Layout.fillHeight: true

                            DankIcon {
                                anchors.centerIn: parent
                                visible: queueRow.isCurrent
                                name: panel.controller.isPlaying ? "volume_up" : "pause"
                                size: Theme.iconSizeSmall
                                color: Theme.onSecondaryContainer
                            }

                            StyledText {
                                anchors.centerIn: parent
                                visible: !queueRow.isCurrent
                                text: String(queueRow.pos + 1)
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            ColumnLayout {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                spacing: 2

                                StyledText {
                                    Layout.fillWidth: true
                                    text: queueRow.title
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    color: queueRow.isCurrent ? Theme.onSecondaryContainer : Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: queueRow.isCurrent ? Font.Bold : Font.Medium
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: {
                                        var parts = [];
                                        if (queueRow.artist)
                                            parts.push(queueRow.artist);
                                        if (queueRow.album)
                                            parts.push(queueRow.album);
                                        if (queueRow.duration > 0)
                                            parts.push(Format.duration(queueRow.duration));
                                        return parts.length ? parts.join(" · ") : queueRow.file;
                                    }
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    color: queueRow.isCurrent ? Theme.onSecondaryContainer : Theme.surfaceVariantText
                                    font.pixelSize: Math.max(10, Theme.fontSizeSmall - 2)
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: panel.controller.request("play-id", queueRow.trackId)
                            }
                        }

                        Material.DIconButton {
                            visible: !queueRow.isCurrent && (rowHover.hovered || queueRow.activeFocus)
                            iconName: "queue_play_next"
                            tooltipText: "Play after current track"
                            enabled: panel.controller.ready
                            onClicked: panel.controller.request("move-next", queueRow.trackId)
                        }

                        Material.DIconButton {
                            visible: panel.searchQuery.length === 0 && (rowHover.hovered || queueRow.activeFocus) && queueRow.index > 0
                            iconName: "keyboard_arrow_up"
                            tooltipText: "Move up"
                            enabled: panel.controller.ready
                            onClicked: panel.moveQueueRowStep(queueRow.index, -1)
                        }

                        Material.DIconButton {
                            visible: panel.searchQuery.length === 0 && (rowHover.hovered || queueRow.activeFocus) && queueRow.index < queueModel.count - 1
                            iconName: "keyboard_arrow_down"
                            tooltipText: "Move down"
                            enabled: panel.controller.ready
                            onClicked: panel.moveQueueRowStep(queueRow.index, 1)
                        }

                        Material.DIconButton {
                            iconName: "close"
                            tooltipText: "Remove from queue"
                            enabled: panel.controller.ready
                            onClicked: panel.removeQueueRowOptimistic(queueRow.index, queueRow.trackId)
                        }
                    }
                }

                Column {
                    visible: queueModel.count === 0 && !panel.queueLoading
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingXL * 2
                    spacing: Theme.spacingM

                    DankIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: panel.controller.ok ? "queue_music" : "cloud_off"
                        size: Theme.iconSize * 2
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: !panel.controller.ok ? "Connect to MPD in plugin settings" : (panel.searchQuery.length > 0 ? "No tracks match \"" + panel.searchQuery + "\"" : "Queue is empty")
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeMedium
                        wrapMode: Text.Wrap
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        if (!panel.controller.ok)
                            return panel.controller.errorText || "MPD unavailable";
                        if (!panel.controller.hasSong)
                            return panel.controller.statusSummary;
                        var line = panel.controller.songTitle;
                        if (panel.controller.songArtist)
                            line += " — " + panel.controller.songArtist;
                        if (panel.controller.songAlbum)
                            line += " · " + panel.controller.songAlbum;
                        return line;
                    }
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                StyledText {
                    visible: text.length > 0
                    Layout.fillWidth: true
                    text: {
                        if (panel.queueLoading && panel.page === "queue")
                            return "Loading queue…";
                        if (!panel.controller.ok)
                            return panel.controller.hasUpdated ? "Last known state" : "";
                        return panel.queueBadge;
                    }
                    color: Theme.surfaceVariantText
                    font.pixelSize: Math.max(10, Theme.fontSizeSmall - 2)
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
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
