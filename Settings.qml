import QtQuick
import qs.Modules.Plugins

PluginSettings {
    pluginId: "mpdControl"
    StringSetting {
        settingKey: "address"
        label: "MPD address or socket path"
        description: "Leave empty to auto-detect ($XDG_RUNTIME_DIR/mpd/socket, /run/mpd/socket, or 127.0.0.1:6600). Accepts host:port or an absolute Unix socket path."
        defaultValue: ""
    }
    StringSetting {
        settingKey: "passwordPath"
        label: "Password file path (optional)"
        description: "A private file containing only the MPD password. Refused for non-loopback TCP connections. The password is never saved in plugin settings."
        defaultValue: ""
    }
    ToggleSetting {
        settingKey: "showArt"
        label: "Fetch album art from MPD"
        defaultValue: true
    }
    ToggleSetting {
        settingKey: "showBarText"
        label: "Show track title inline in the horizontal bar"
        defaultValue: false
    }
    ToggleSetting {
        settingKey: "showArtist"
        label: "Include artist in inline horizontal bar text"
        defaultValue: true
    }
    ListSettingWithInput {
        settingKey: "quickSearches"
        label: "Quick Action Searches"
        description: "Define saved search strings (e.g. genre:Electronic, artist:Nujabes, or free text) for one-click queue replacement on the Track tab."
        defaultValue: []
        fields: [
            {
                id: "name",
                label: "Label",
                placeholder: "e.g. Chill Hip Hop",
                width: 150,
                required: false
            },
            {
                id: "query",
                label: "Search / Filter String",
                placeholder: "e.g. genre:\"Hip Hop\" artist:Nujabes",
                width: 240,
                required: true
            }
        ]
    }
}
