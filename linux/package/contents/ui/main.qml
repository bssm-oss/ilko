import QtQuick
import QtMultimedia
import org.kde.plasma.plasmoid

WallpaperItem {
    id: root

    // 초기값은 Plasma config에서 읽음 (시작 시 1회)
    // 런타임 변경은 아래 Timer가 current_wallpaper.json 폴링으로 처리
    property string wallpaperSource: {
        var f = root.configuration.wallpaperFile || ""
        if (!f) return ""
        return f.startsWith("file://") ? f : encodeURI("file://" + f)
    }

    property bool   playerPaused: root.configuration.playerPaused || false
    property double playerRate:   root.configuration.playerRate   || 1.0

    // wallpaperFile 경로에서 홈 디렉토리 추출 (Plasma config엔 항상 원본 경로가 들어옴)
    property string _homePath: {
        var f = root.configuration.wallpaperFile || ""
        var idx = f.indexOf("/.ilko/")
        return idx >= 0 ? f.substring(0, idx) : ""
    }
    property string _appliedSource:    ""
    property int    _appliedTimestamp: 0

    // player_control.json 폴링 — 배터리/화면 잠금 시 재생 제어
    Timer {
        interval: 1000
        running: root._homePath !== ""
        repeat: true
        onTriggered: {
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== 4 || xhr.status !== 200) return
                try {
                    var data = JSON.parse(xhr.responseText)
                    root.playerPaused = data.paused || false
                    root.playerRate = data.playbackRate || 1.0
                    if (root.playerPaused) {
                        mediaPlayer.pause()
                    } else if (mediaPlayer.playbackState === MediaPlayer.PausedState) {
                        mediaPlayer.play()
                    }
                } catch(e) {}
            }
            xhr.open("GET", "file://" + root._homePath + "/.ilko/player_control.json")
            xhr.send()
        }
    }

    // current_wallpaper.json 폴링 — Plasma config 변경 알림이 런타임에 동작 안 해서 필요
    Timer {
        interval: 1500
        running: root._homePath !== ""
        repeat: true
        onTriggered: {
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== 4 || xhr.status !== 200) return
                try {
                    var data = JSON.parse(xhr.responseText)
                    var rawPath = data.wallpaperFile || ""
                    var ts      = data.timestamp     || 0
                    if (!rawPath) return
                    if (rawPath === root._appliedSource && ts === root._appliedTimestamp) return
                    root._appliedSource    = rawPath
                    root._appliedTimestamp = ts
                    var encoded = rawPath.startsWith("file://") ? rawPath : encodeURI("file://" + rawPath)
                    root.wallpaperSource = encoded
                    mediaPlayer.source = ""
                    mediaPlayer.source = encoded
                    if (!root.playerPaused) mediaPlayer.play()
                } catch(e) {}
            }
            xhr.open("GET", "file://" + root._homePath + "/.ilko/current_wallpaper.json")
            xhr.send()
        }
    }

    property bool isVideo: {
        var f = wallpaperSource
        if (!f) return false
        var ext = f.split('.').pop().toLowerCase()
        return ["mp4", "webm", "mov", "avi", "mkv"].indexOf(ext) !== -1
    }

    property var fillModeMap: ({
        "preserveAspectFit": VideoOutput.PreserveAspectFit,
        "stretch": VideoOutput.Stretch,
        "preserveAspectCrop": VideoOutput.PreserveAspectCrop
    })

    property var imageFillModeMap: ({
        "preserveAspectFit": Image.PreserveAspectFit,
        "stretch": Image.Stretch,
        "preserveAspectCrop": Image.PreserveAspectCrop
    })

    onPlayerPausedChanged: applyPlayerState()
    onPlayerRateChanged:   applyPlayerState()

    function applyPlayerState() {
        if (!isVideo) return
        mediaPlayer.playbackRate = root.playerRate
        if (root.playerPaused) {
            mediaPlayer.pause()
        } else if (mediaPlayer.playbackState !== MediaPlayer.PlayingState) {
            mediaPlayer.play()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.configuration.backgroundColor || "#000000"
    }

    VideoOutput {
        id: videoOutput
        anchors.fill: parent
        fillMode: root.fillModeMap[root.configuration.fillMode] || VideoOutput.PreserveAspectCrop
        visible: isVideo
    }

    MediaPlayer {
        id: mediaPlayer
        videoOutput: videoOutput
        source: isVideo ? wallpaperSource : ""
        loops: MediaPlayer.Infinite
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.LoadedMedia && !root.playerPaused) {
                mediaPlayer.playbackRate = root.playerRate
                mediaPlayer.play()
            }
        }
        onErrorOccurred: function(e, msg) {
            console.log("ILKO MediaPlayer error:", msg)
            mediaPlayer.stop()
        }
    }

    Image {
        anchors.fill: parent
        source: !isVideo && wallpaperSource ? wallpaperSource : ""
        fillMode: root.imageFillModeMap[root.configuration.fillMode] || Image.PreserveAspectCrop
        visible: !isVideo && wallpaperSource !== ""
    }

    Component.onCompleted: {
        _appliedSource = root.configuration.wallpaperFile || ""
        console.log("ILKO wallpaper plugin started, source:", wallpaperSource)
    }
}
