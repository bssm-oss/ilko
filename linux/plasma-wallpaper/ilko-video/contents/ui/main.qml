import QtQuick
import QtMultimedia
import org.kde.plasma.plasmoid

WallpaperItem {
    id: root

    // 시작 시 Plasma config에서 초기값 읽기 (반응형 업데이트 안 됨)
    property string wallpaperSource: {
        var f = root.configuration.wallpaperFile || ""
        if (!f) return ""
        return f.startsWith("file://") ? f : encodeURI("file://" + f)
    }

    property bool   playerPaused: root.configuration.playerPaused || false
    property double playerRate:   root.configuration.playerRate   || 1.0

    // current_wallpaper.json 폴링으로 런타임 변경 감지
    // root.configuration은 외부 writeConfig에 반응하지 않아서 XHR 폴링이 필요함.
    property string _homePath: {
        var f = root.configuration.wallpaperFile || ""
        var idx = f.indexOf("/.ilko/")
        return idx >= 0 ? f.substring(0, idx) : ""
    }
    property string _appliedSource: ""
    property int    _appliedTimestamp: 0

    Timer {
        id: pollTimer
        interval: 1500
        running: root._homePath !== ""
        repeat: true
        onTriggered: {
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== 4 || xhr.status !== 200) return
                try {
                    var data = JSON.parse(xhr.responseText)
                    var rawPath = data.wallpaperFile  || ""
                    var ts      = data.timestamp      || 0
                    if (!rawPath) return
                    // 경로도 같고 타임스탬프도 같으면 변경 없음
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
        if (!f || f === "") return false
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
        console.log("ILKO wallpaper plugin started, source:", wallpaperSource)
        // 초기 적용 경로 기록 — 첫 폴링에서 불필요한 리로드 방지
        _appliedSource = root.configuration.wallpaperFile || ""
    }
}
