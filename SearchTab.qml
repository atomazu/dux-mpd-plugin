import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Widgets
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets as Material
import "Format.js" as Format

Item {
    id: searchView
    required property var controller
    readonly property int pageSize: 90
    readonly property int maxLoadedItems: 270
    readonly property int rowHeight: 54
    readonly property int rowPitch: rowHeight + Theme.groupedListGap

    property string scope: "albums"
    property string viewMode: "grid"
    property string searchQuery: ""
    property string filterGenre: ""
    property string filterArtist: ""
    property string filterAlbum: ""
    property string filterYear: ""
    property bool showFilters: false

    property int windowStart: 0
    property int windowEnd: 0
    property int libraryMatched: 0
    property bool libraryInitialized: false
    property bool libraryLoading: false
    property double lastAppliedNonce: 0
    property var availableGenres: []

    readonly property bool hasFacetFilters: filterGenre.length > 0 || filterArtist.length > 0 || filterAlbum.length > 0 || filterYear.length > 0
    readonly property bool hasActiveFilters: hasFacetFilters || searchQuery.length > 0

    ListModel {
        id: libraryModel
    }

    function ensureInitialized() {
        if (!libraryInitialized && controller.ok) {
            requestLibraryWindow(0, "replace");
        }
    }

    function currentFilterSpec() {
        return JSON.stringify({
            query: searchQuery,
            genre: filterGenre,
            artist: filterArtist,
            album: filterAlbum,
            year: filterYear
        });
    }

    function requestLibraryWindow(offset, mode) {
        if (!controller.ok)
            return;
        const resolvedMode = mode || "replace";
        if (resolvedMode !== "sync")
            libraryLoading = true;
        const resolvedOffset = Math.max(0, offset || 0);
        const resolvedLimit = resolvedMode === "sync" ? Math.max(pageSize, libraryModel.count) : pageSize;
        controller.requestLibrary({
            scope: scope,
            mode: resolvedMode,
            query: searchQuery,
            genre: filterGenre,
            artist: filterArtist,
            album: filterAlbum,
            year: filterYear,
            offset: resolvedOffset,
            limit: resolvedLimit
        });
    }

    function setModelItemsInPlace(items) {
        const count = items.length;
        const common = Math.min(libraryModel.count, count);
        for (let i = 0; i < common; i++)
            libraryModel.set(i, items[i]);
        for (let i = common; i < count; i++)
            libraryModel.append(items[i]);
        if (libraryModel.count > count)
            libraryModel.remove(count, libraryModel.count - count);
    }

    function applyLibrarySlice(slice) {
        if (!slice || !slice.ok || slice.nonce === lastAppliedNonce)
            return;
        lastAppliedNonce = slice.nonce;
        libraryLoading = false;
        libraryInitialized = true;
        libraryMatched = slice.matched || 0;
        if (slice.genres && slice.genres.length > 0)
            availableGenres = slice.genres;
        const items = slice.items || [];

        if (slice.mode === "sync") {
            const startIdx = Math.max(0, (slice.offset || 0) - windowStart);
            for (let i = 0; i < items.length; i++) {
                const targetIdx = startIdx + i;
                if (targetIdx >= 0 && targetIdx < libraryModel.count) {
                    if (items[i].artUrl && libraryModel.get(targetIdx).artUrl !== items[i].artUrl)
                        libraryModel.setProperty(targetIdx, "artUrl", items[i].artUrl);
                }
            }
            if (slice.hasUncachedArt && searchView.visible)
                lazyArtTimer.restart();
            return;
        }

        if (slice.mode === "append") {
            if (items.length === 0)
                return;
            for (let i = 0; i < items.length; i++)
                libraryModel.append(items[i]);
            windowEnd = slice.offset + items.length;
            if (libraryModel.count > maxLoadedItems) {
                const excess = libraryModel.count - maxLoadedItems;
                libraryModel.remove(0, excess);
                windowStart += excess;
            }
            if (slice.hasUncachedArt && searchView.visible)
                lazyArtTimer.restart();
            return;
        }

        if (slice.mode === "prepend") {
            if (items.length === 0)
                return;
            for (let i = items.length - 1; i >= 0; i--)
                libraryModel.insert(0, items[i]);
            windowStart = slice.offset;
            if (libraryModel.count > maxLoadedItems) {
                const excess = libraryModel.count - maxLoadedItems;
                libraryModel.remove(maxLoadedItems, excess);
                windowEnd = windowStart + maxLoadedItems;
            }
            if (slice.hasUncachedArt && searchView.visible)
                lazyArtTimer.restart();
            return;
        }

        windowStart = slice.offset || 0;
        windowEnd = windowStart + items.length;
        setModelItemsInPlace(items);
        if (slice.hasUncachedArt && searchView.visible)
            lazyArtTimer.restart();
        Qt.callLater(() => {
            if (viewMode === "grid")
                libraryGrid.positionViewAtBeginning();
            else
                libraryList.positionViewAtBeginning();
        });
    }

    function selectScope(nextScope) {
        if (scope === nextScope)
            return;
        scope = nextScope;
        if (nextScope === "tracks")
            viewMode = "list";
        else if (nextScope === "albums")
            viewMode = "grid";
        requestLibraryWindow(0, "replace");
    }

    function activateItem(item) {
        if (!item)
            return;
        if (item.kind === "genre") {
            filterGenre = item.genre || item.title;
            searchInput.text = "";
            searchQuery = "";
            scope = "albums";
            viewMode = "grid";
            requestLibraryWindow(0, "replace");
        } else if (item.kind === "artist") {
            filterArtist = item.artist || item.title;
            searchInput.text = "";
            searchQuery = "";
            scope = "albums";
            viewMode = "grid";
            requestLibraryWindow(0, "replace");
        } else if (item.kind === "album") {
            filterAlbum = item.album || item.title;
            if (item.artist)
                filterArtist = item.artist;
            searchInput.text = "";
            searchQuery = "";
            scope = "tracks";
            viewMode = "list";
            requestLibraryWindow(0, "replace");
        } else if (item.kind === "track" && item.file) {
            controller.request("play-uri", item.file);
        }
    }

    function playItemNow(item) {
        if (!item)
            return;
        if (item.kind === "track") {
            if (item.file)
                controller.request("play-uri", item.file);
            return;
        }
        const spec = {
            query: searchQuery,
            genre: item.kind === "genre" ? (item.genre || item.title) : filterGenre,
            artist: item.kind === "artist" ? (item.artist || item.title) : (item.kind === "album" && item.artist ? item.artist : filterArtist),
            album: item.kind === "album" ? (item.album || item.title) : filterAlbum,
            year: filterYear
        };
        controller.request("play-filter", JSON.stringify(spec));
    }

    function enqueueItem(item) {
        if (!item)
            return;
        if (item.kind === "track") {
            if (item.file)
                controller.request("add-uri", item.file);
            return;
        }
        const spec = {
            query: searchQuery,
            genre: item.kind === "genre" ? (item.genre || item.title) : filterGenre,
            artist: item.kind === "artist" ? (item.artist || item.title) : (item.kind === "album" && item.artist ? item.artist : filterArtist),
            album: item.kind === "album" ? (item.album || item.title) : filterAlbum,
            year: filterYear
        };
        controller.request("add-filter", JSON.stringify(spec));
    }

    function clearAllFilters() {
        searchInput.text = "";
        searchQuery = "";
        filterGenre = "";
        filterArtist = "";
        filterAlbum = "";
        filterYear = "";
        requestLibraryWindow(0, "replace");
    }

    function iconForKind(kind) {
        if (kind === "genre")
            return "category";
        if (kind === "artist")
            return "person";
        if (kind === "album")
            return "album";
        return "music_note";
    }

    Connections {
        target: searchView.controller
        function onLibrarySliceChanged() {
            searchView.applyLibrarySlice(searchView.controller.librarySlice);
        }
        function onOkChanged() {
            if (searchView.controller.ok && searchView.visible && !searchView.libraryInitialized) {
                searchView.requestLibraryWindow(0, "replace");
            }
        }
    }

    Timer {
        id: queryDebounce
        interval: 220
        repeat: false
        onTriggered: searchView.requestLibraryWindow(0, "replace")
    }

    Timer {
        id: lazyArtTimer
        interval: 120
        repeat: false
        onTriggered: {
            if (searchView.visible && !searchView.libraryLoading && searchView.controller.ok) {
                searchView.requestLibraryWindow(searchView.windowStart, "sync");
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacingS

        // Top Search & View Controls Row
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingXS

            Material.DSearchField {
                id: searchInput
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.buttonHeightS
                placeholderText: "Search library or genre:… artist:… year:…"
                onTextChanged: {
                    const next = text.trim();
                    if (next === searchView.searchQuery)
                        return;
                    searchView.searchQuery = next;
                    queryDebounce.restart();
                }
            }

            Material.DIconButton {
                iconName: "filter_list"
                variant: searchView.showFilters || searchView.hasFacetFilters || searchView.scope !== "albums" ? "filled" : "tonal"
                tooltipText: searchView.showFilters ? "Hide filters" : "Toggle filters"
                enabled: searchView.controller.ready
                onClicked: searchView.showFilters = !searchView.showFilters
            }

            Material.DIconButton {
                iconName: searchView.viewMode === "grid" ? "view_list" : "grid_view"
                variant: "tonal"
                tooltipText: searchView.viewMode === "grid" ? "Switch to list view" : "Switch to grid view"
                onClicked: searchView.viewMode = (searchView.viewMode === "grid" ? "list" : "grid")
            }

            Material.DIconButton {
                visible: searchView.libraryMatched > 0 && searchView.hasActiveFilters
                iconName: "play_arrow"
                variant: "filled"
                tooltipText: "Play matching tracks now"
                enabled: searchView.controller.ready
                onClicked: searchView.controller.request("play-filter", searchView.currentFilterSpec())
            }

            Material.DIconButton {
                visible: searchView.libraryMatched > 0 && searchView.hasActiveFilters
                iconName: "playlist_add"
                variant: "tonal"
                tooltipText: "Add all matching tracks to queue"
                enabled: searchView.controller.ready
                onClicked: searchView.controller.request("add-filter", searchView.currentFilterSpec())
            }

            Material.DIconButton {
                iconName: "sync"
                variant: "tonal"
                tooltipText: "Rescan MPD music database"
                enabled: searchView.controller.ready
                onClicked: {
                    searchView.controller.request("update");
                    searchView.requestLibraryWindow(0, "replace");
                }
            }
        }

        // Scope Selector Pills (Albums / Tracks / Artists / Genres) — toggled via Toggle Filters
        RowLayout {
            visible: searchView.showFilters
            Layout.fillWidth: true
            spacing: Theme.spacingXS

            Repeater {
                model: [
                    {
                        id: "albums",
                        label: "Albums",
                        icon: "album"
                    },
                    {
                        id: "tracks",
                        label: "Tracks",
                        icon: "music_note"
                    },
                    {
                        id: "artists",
                        label: "Artists",
                        icon: "person"
                    },
                    {
                        id: "genres",
                        label: "Genres",
                        icon: "category"
                    }
                ]
                delegate: ActionButton {
                    required property var modelData
                    text: modelData.label
                    iconName: modelData.icon
                    prominent: searchView.scope === modelData.id
                    onClicked: searchView.selectScope(modelData.id)
                }
            }

            Item {
                Layout.fillWidth: true
            }
        }

        // Active Filter Breadcrumb Chips
        Flow {
            visible: searchView.filterGenre.length > 0 || searchView.filterArtist.length > 0 || searchView.filterAlbum.length > 0 || searchView.filterYear.length > 0
            Layout.fillWidth: true
            spacing: Theme.spacingXS

            ActionButton {
                visible: searchView.filterGenre.length > 0
                iconName: "close"
                text: "Genre: " + searchView.filterGenre
                prominent: true
                onClicked: {
                    searchView.filterGenre = "";
                    searchView.requestLibraryWindow(0, "replace");
                }
            }

            ActionButton {
                visible: searchView.filterArtist.length > 0
                iconName: "close"
                text: "Artist: " + searchView.filterArtist
                prominent: true
                onClicked: {
                    searchView.filterArtist = "";
                    searchView.requestLibraryWindow(0, "replace");
                }
            }

            ActionButton {
                visible: searchView.filterAlbum.length > 0
                iconName: "close"
                text: "Album: " + searchView.filterAlbum
                prominent: true
                onClicked: {
                    searchView.filterAlbum = "";
                    if (searchView.scope === "tracks") {
                        searchView.scope = "albums";
                        searchView.viewMode = "grid";
                    }
                    searchView.requestLibraryWindow(0, "replace");
                }
            }

            ActionButton {
                visible: searchView.filterYear.length > 0
                iconName: "close"
                text: "Year: " + searchView.filterYear
                prominent: true
                onClicked: {
                    searchView.filterYear = "";
                    searchView.requestLibraryWindow(0, "replace");
                }
            }

            ActionButton {
                text: "Clear all"
                onClicked: searchView.clearAllFilters()
            }
        }

        // Results Summary & Window Pager
        RowLayout {
            visible: searchView.libraryMatched > 0
            Layout.fillWidth: true
            spacing: Theme.spacingXS

            StyledText {
                Layout.fillWidth: true
                text: {
                    const first = Math.min(searchView.libraryMatched, searchView.windowStart + 1);
                    const last = Math.min(searchView.libraryMatched, searchView.windowEnd);
                    return "Showing " + first + "–" + last + " of " + searchView.libraryMatched + " " + searchView.scope;
                }
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                elide: Text.ElideRight
            }

            Material.DIconButton {
                visible: searchView.libraryMatched > searchView.pageSize
                iconName: "first_page"
                tooltipText: "First page"
                enabled: searchView.windowStart > 0 && !searchView.libraryLoading
                onClicked: searchView.requestLibraryWindow(0, "replace")
            }

            Material.DIconButton {
                visible: searchView.libraryMatched > searchView.pageSize
                iconName: "chevron_left"
                tooltipText: "Previous " + searchView.pageSize
                enabled: searchView.windowStart > 0 && !searchView.libraryLoading
                onClicked: searchView.requestLibraryWindow(Math.max(0, searchView.windowStart - searchView.pageSize), "replace")
            }

            Material.DIconButton {
                visible: searchView.libraryMatched > searchView.pageSize
                iconName: "chevron_right"
                tooltipText: "Next " + searchView.pageSize
                enabled: searchView.windowEnd < searchView.libraryMatched && !searchView.libraryLoading
                onClicked: searchView.requestLibraryWindow(Math.min(Math.max(0, searchView.libraryMatched - searchView.pageSize), searchView.windowEnd), "replace")
            }

            Material.DIconButton {
                visible: searchView.libraryMatched > searchView.pageSize
                iconName: "last_page"
                tooltipText: "Last page"
                enabled: searchView.windowEnd < searchView.libraryMatched && !searchView.libraryLoading
                onClicked: searchView.requestLibraryWindow(Math.max(0, searchView.libraryMatched - searchView.pageSize), "replace")
            }
        }

        // GRID VIEW
        GridView {
            id: libraryGrid
            visible: searchView.viewMode === "grid"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: libraryModel
            readonly property int columns: Math.max(2, Math.floor((width - Theme.spacingM) / 145))
            cellWidth: Math.floor((width - Theme.spacingM) / columns)
            cellHeight: searchView.scope === "genres" ? 96 : 186
            cacheBuffer: cellHeight * 3
            ScrollBar.vertical: ScrollBar {}

            onContentYChanged: {
                if (!searchView.libraryLoading && searchView.windowEnd < searchView.libraryMatched && contentHeight > height && contentY + height >= contentHeight - cellHeight * 2) {
                    searchView.requestLibraryWindow(searchView.windowEnd, "append");
                }
            }

            delegate: Item {
                id: gridCell
                required property int index
                required property string kind
                required property string title
                required property string subtitle
                required property string artist
                required property string album
                required property string genre
                required property string date
                required property string file
                required property double duration
                required property int trackCount
                required property int albumCount
                required property string artUrl

                width: libraryGrid.cellWidth
                height: libraryGrid.cellHeight

                function toItemObject() {
                    return {
                        kind: gridCell.kind,
                        title: gridCell.title,
                        subtitle: gridCell.subtitle,
                        artist: gridCell.artist,
                        album: gridCell.album,
                        genre: gridCell.genre,
                        date: gridCell.date,
                        file: gridCell.file,
                        duration: gridCell.duration,
                        trackCount: gridCell.trackCount,
                        albumCount: gridCell.albumCount,
                        artUrl: gridCell.artUrl
                    };
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    radius: Theme.cornerRadiusM
                    color: cardHover.hovered ? Theme.surfaceContainerHigh : Theme.surfaceContainer

                    HoverHandler {
                        id: cardHover
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: searchView.activateItem(gridCell.toItemObject())
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingXS

                        // Cover Art / Visual Tile Header
                        ClippingRectangle {
                            visible: gridCell.kind !== "genre"
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: Theme.cornerRadiusS
                            color: Theme.secondaryContainer
                            antialiasing: true

                            DankIcon {
                                anchors.centerIn: parent
                                name: searchView.iconForKind(gridCell.kind)
                                size: Theme.iconSize + Theme.spacingM
                                color: Theme.onSecondaryContainer
                                visible: !gridArt.visible
                            }

                            Image {
                                id: gridArt
                                anchors.fill: parent
                                source: gridCell.artUrl
                                asynchronous: true
                                retainWhileLoading: true
                                cache: true
                                fillMode: Image.PreserveAspectCrop
                                sourceSize: Qt.size(220, 220)
                                visible: gridCell.artUrl !== "" && status === Image.Ready
                            }

                            // Hover Quick Play / Add Overlay
                            Row {
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: 4
                                spacing: 4
                                visible: cardHover.hovered

                                Material.DIconButton {
                                    iconName: "play_arrow"
                                    variant: "filled"
                                    buttonSize: 28
                                    width: 28
                                    height: 28
                                    iconSize: 16
                                    tooltipText: "Play now"
                                    enabled: searchView.controller.ready
                                    onClicked: searchView.playItemNow(gridCell.toItemObject())
                                }

                                Material.DIconButton {
                                    iconName: "playlist_add"
                                    variant: "tonal"
                                    buttonSize: 28
                                    width: 28
                                    height: 28
                                    iconSize: 16
                                    tooltipText: "Add to queue"
                                    enabled: searchView.controller.ready
                                    onClicked: searchView.enqueueItem(gridCell.toItemObject())
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingXS

                            DankIcon {
                                visible: gridCell.kind === "genre"
                                name: "category"
                                size: Theme.iconSizeSmall
                                color: Theme.primary
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: gridCell.title
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 4

                            StyledText {
                                Layout.fillWidth: true
                                text: {
                                    var parts = [];
                                    if (gridCell.subtitle)
                                        parts.push(gridCell.subtitle);
                                    if (gridCell.date && gridCell.kind === "album")
                                        parts.push(gridCell.date);
                                    else if (gridCell.kind === "album" && gridCell.trackCount > 0)
                                        parts.push(gridCell.trackCount + " trk");
                                    return parts.join(" · ");
                                }
                                font.pixelSize: Math.max(10, Theme.fontSizeSmall - 2)
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            Material.DIconButton {
                                visible: gridCell.kind === "genre" && cardHover.hovered
                                iconName: "play_arrow"
                                variant: "filled"
                                buttonSize: 24
                                width: 24
                                height: 24
                                iconSize: 14
                                tooltipText: "Play genre"
                                enabled: searchView.controller.ready
                                onClicked: searchView.playItemNow(gridCell.toItemObject())
                            }

                            Material.DIconButton {
                                visible: gridCell.kind === "genre" && cardHover.hovered
                                iconName: "playlist_add"
                                variant: "tonal"
                                buttonSize: 24
                                width: 24
                                height: 24
                                iconSize: 14
                                tooltipText: "Add genre to queue"
                                enabled: searchView.controller.ready
                                onClicked: searchView.enqueueItem(gridCell.toItemObject())
                            }
                        }
                    }
                }
            }
        }

        // LIST VIEW
        ListView {
            id: libraryList
            visible: searchView.viewMode === "list"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.groupedListGap
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: searchView.rowPitch * 6
            model: libraryModel
            ScrollBar.vertical: ScrollBar {}

            onContentYChanged: {
                if (!searchView.libraryLoading && searchView.windowEnd < searchView.libraryMatched && contentHeight > height && contentY + height >= contentHeight - searchView.rowPitch * 5) {
                    searchView.requestLibraryWindow(searchView.windowEnd, "append");
                }
            }

            delegate: Rectangle {
                id: listRow
                required property int index
                required property string kind
                required property string title
                required property string subtitle
                required property string artist
                required property string album
                required property string genre
                required property string date
                required property string file
                required property double duration
                required property int trackCount
                required property int albumCount
                required property string artUrl

                function toItemObject() {
                    return {
                        kind: listRow.kind,
                        title: listRow.title,
                        subtitle: listRow.subtitle,
                        artist: listRow.artist,
                        album: listRow.album,
                        genre: listRow.genre,
                        date: listRow.date,
                        file: listRow.file,
                        duration: listRow.duration,
                        trackCount: listRow.trackCount,
                        albumCount: listRow.albumCount,
                        artUrl: listRow.artUrl
                    };
                }

                width: libraryList.width - Theme.spacingM
                height: searchView.rowHeight
                color: listHover.hovered ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                topLeftRadius: index === 0 ? Theme.groupedListOuterRadius : Theme.groupedListInnerRadius
                topRightRadius: topLeftRadius
                bottomLeftRadius: index === libraryModel.count - 1 ? Theme.groupedListOuterRadius : Theme.groupedListInnerRadius
                bottomRightRadius: bottomLeftRadius

                HoverHandler {
                    id: listHover
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingS

                    ClippingRectangle {
                        implicitWidth: 38
                        implicitHeight: 38
                        radius: Theme.cornerRadiusXS
                        color: Theme.secondaryContainer
                        antialiasing: true

                        DankIcon {
                            anchors.centerIn: parent
                            name: searchView.iconForKind(listRow.kind)
                            size: Theme.iconSizeSmall
                            color: Theme.onSecondaryContainer
                            visible: !listArt.visible
                        }

                        Image {
                            id: listArt
                            anchors.fill: parent
                            source: listRow.artUrl
                            asynchronous: true
                            retainWhileLoading: true
                            cache: true
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(76, 76)
                            visible: listRow.artUrl !== "" && status === Image.Ready
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
                                text: listRow.title
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: {
                                    var parts = [];
                                    if (listRow.subtitle)
                                        parts.push(listRow.subtitle);
                                    if (listRow.genre && listRow.kind !== "genre")
                                        parts.push(listRow.genre);
                                    if (listRow.date)
                                        parts.push(listRow.date);
                                    if (listRow.duration > 0)
                                        parts.push(Format.duration(listRow.duration));
                                    return parts.join(" · ");
                                }
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                color: Theme.surfaceVariantText
                                font.pixelSize: Math.max(10, Theme.fontSizeSmall - 2)
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: searchView.activateItem(listRow.toItemObject())
                        }
                    }

                    Material.DIconButton {
                        visible: listHover.hovered || listRow.activeFocus
                        iconName: "play_arrow"
                        variant: "filled"
                        tooltipText: "Play now"
                        enabled: searchView.controller.ready
                        onClicked: searchView.playItemNow(listRow.toItemObject())
                    }

                    Material.DIconButton {
                        visible: listRow.kind === "track" && (listHover.hovered || listRow.activeFocus)
                        iconName: "queue_play_next"
                        variant: "tonal"
                        tooltipText: "Play after current track"
                        enabled: searchView.controller.ready && listRow.file.length > 0
                        onClicked: searchView.controller.request("insert-uri-next", listRow.file)
                    }

                    Material.DIconButton {
                        iconName: "playlist_add"
                        variant: "tonal"
                        tooltipText: "Add to queue"
                        enabled: searchView.controller.ready
                        onClicked: searchView.enqueueItem(listRow.toItemObject())
                    }
                }
            }
        }

        // Empty / Loading State
        Item {
            visible: libraryModel.count === 0
            Layout.fillWidth: true
            Layout.fillHeight: true

            Column {
                anchors.centerIn: parent
                width: parent.width - Theme.spacingXL * 2
                spacing: Theme.spacingM

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: !searchView.controller.ok ? "cloud_off" : (searchView.libraryLoading ? "hourglass_empty" : "library_music")
                    size: Theme.iconSize * 2
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: {
                        if (!searchView.controller.ok)
                            return "Connect to MPD in plugin settings";
                        if (searchView.libraryLoading)
                            return "Searching MPD library…";
                        if (searchView.hasActiveFilters)
                            return "No " + searchView.scope + " match your active filters";
                        return "No " + searchView.scope + " found in MPD library";
                    }
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeMedium
                    wrapMode: Text.Wrap
                }
            }
        }
    }
}
