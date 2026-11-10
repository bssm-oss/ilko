import Combine
import Foundation

// MARK: - Language Manager
class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var currentLanguage: String {
        didSet {
            UserDefaults.standard.set(currentLanguage, forKey: UserDefaultsKeys.appLanguage)
            UserDefaults.standard.set([currentLanguage], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
    }

    var availableLanguages: [(code: String, name: String)] {
        [
            ("auto", "system_language".localized),
            ("zh-Hans", "简体中文"),
            ("en", "English"),
        ]
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: UserDefaultsKeys.appLanguage) ?? "auto"
        self.currentLanguage = saved
    }

    func localizedString(_ key: String) -> String {
        let language =
            currentLanguage == "auto" ? Locale.preferredLanguages.first ?? "en" : currentLanguage
        guard
            let path = Bundle.main.path(forResource: language, ofType: "lproj")
                ?? Bundle.main.path(
                    forResource: language.components(separatedBy: "-").first, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return NSLocalizedString(key, comment: "")
        }
        return NSLocalizedString(key, tableName: nil, bundle: bundle, comment: "")
    }
}

// MARK: - Localization
enum L {
    static let selectWallpaperFolder = "📁"
    static let generating = "생성 중..."
    static let retry = "재시도"
    static let cloudFolderNotice = "클라우드 폴더 — 썸네일만 로컬에 캐시됩니다. 첫 생성·재생 시 드라이브에서 다운로드하느라 잠시 느릴 수 있어요."
    static let settings = "설정"
    static let wallpaperFolder = "월페이퍼 폴더"
    static let selectFolderEmoji = "📁"
    static let showInFinder = "📂"
    static let videoScalingMode = "비디오 크기 조절"
    static let scaleFill = "채우기"
    static let scaleFit = "맞추기"
    static let scaleStretch = "늘리기"
    static let scaleCenter = "가운데"
    static let scaleHeightFill = "높이 채우기"
    static let randomOnStartup = "시작 시 랜덤 월페이퍼"
    static let randomOnLid = "화면 켤 때 랜덤 월페이퍼"
    static let pauseWhenActive = "앱 포커스 시 일시정지"
    static let videoVolume = "비디오 볼륨"
    static let optimizeCodecs = "코덱 최적화"
    static let optimize = "최적화"
    static let clearCache = "캐시 삭제"
    static let clearCacheButton = "삭제"
    static let resetUserData = "데이터 초기화"
    static let reset = "초기화"
    static let selectFolderTitle = "폴더 선택"
    static let choose = "선택"
    static let selectFolderOrType = "경로를 입력하거나 선택하세요"
    static let wallpaperRotation = "월페이퍼 자동 전환"
    static let rotationType = "전환 방식"
    static let vinttageBar = "비네트 바 (변경 후 월페이퍼 재적용)"
    static let rotationDelay = "전환 간격"
    static let lockScreenSection = "잠금화면"
    static let lockScreenVideo = "잠금화면에도 영상 적용"
    static let lockScreenSlot = "덮어쓸 Aerial 배경"
    static let lockScreenSlotHint = "선택한 Aerial은 시스템 설정에서 원래 영상 대신 ILKO 영상으로 재생됩니다."
    static let lockScreenEncoding = "잠금화면용 영상 변환 중…"
    static let lockScreenUnsupported = "이 macOS 버전은 지원하지 않습니다"
    static let lockScreenDisabledNotice = "시스템 배경이 변경되어 잠금화면 영상을 껐습니다"
}

// MARK: - UserDefaults Keys
enum UserDefaultsKeys {
    static let wallpaperFolder = "WallpaperFolder"
    static let scaleMode = "scale_mode"
    static let randomOnStartup = "random"
    static let randomOnLid = "random_lid"
    static let pauseOnAppFocus = "pauseOnAppFocus"
    static let volumePercentage = "wallpapervolumeprecentage"
    static let launchAtLogin = "LaunchAtLogin"
    static let appLanguage = "app_language"
    static let vignetteBar = "vinttage_bar"
    static let rotation = "rotation"
    static let rdelay = "rdelay"
    static let rtype = "rtype"
}
