#include "SwitchController.h"

#include <QDebug>
#include <QDateTime>
#include <QDBusConnection>
#include <QDBusInterface>

#include "ProfileManager.h"
#include "NetworkWatcher.h"
#include "WallpaperDBusService.h"

// wallpaperFile과 wallpaperVersion을 단일 스크립트로 원자적으로 씀.
// 두 번의 asyncCall로 분리하면 Plasma가 version을 먼저 처리해 QML이
// 아직 갱신 안 된 경로로 리로드하는 레이스 컨디션이 발생함.
static void plasmaWriteWallpaper(const QString &path, const QString &version)
{
    QDBusInterface iface(
        QStringLiteral("org.kde.plasmashell"),
        QStringLiteral("/PlasmaShell"),
        QStringLiteral("org.kde.PlasmaShell"),
        QDBusConnection::sessionBus()
    );
    if (!iface.isValid()) return;

    auto escape = [](const QString &s) {
        QString r = s;
        r.replace(QLatin1Char('\\'), QStringLiteral("\\\\"));
        r.replace(QLatin1Char('"'),  QStringLiteral("\\\""));
        return r;
    };

    const QString script = QStringLiteral(
        "var all=desktops();"
        "for(var i=0;i<all.length;i++){"
        "var d=all[i];"
        "if(d.wallpaperPlugin===\"org.bssm.ilko.video\"){"
        "d.currentConfigGroup=[\"Wallpaper\",\"org.bssm.ilko.video\",\"General\"];"
        "d.writeConfig(\"wallpaperFile\",\"%1\");"
        "d.writeConfig(\"wallpaperVersion\",\"%2\");"
        "}}"
    ).arg(escape(path), version);

    iface.asyncCall(QStringLiteral("evaluateScript"), script);
}

SwitchController::SwitchController(ProfileManager *profileManager,
                                   NetworkWatcher *networkWatcher,
                                   QObject *parent)
    : QObject(parent)
    , m_profileManager(profileManager)
    , m_networkWatcher(networkWatcher)
    , m_currentProfileId()
    , m_running(false)
    , m_dbusService(nullptr)
{
    if (m_networkWatcher) {
        connect(m_networkWatcher, &NetworkWatcher::networkChanged,
                this, &SwitchController::onNetworkChanged);
        connect(m_networkWatcher, &NetworkWatcher::connectionStateChanged,
                this, &SwitchController::onConnectionChanged);
    }

    m_dbusService = new ilko::WallpaperDBusService(this);
}

SwitchController::~SwitchController() = default;

void SwitchController::start()
{
    if (m_running) return;
    m_running = true;

    if (m_networkWatcher->isConnected()) {
        setWallpaperByMac(m_networkWatcher->currentGatewayMac());
    } else {
        setDefaultWallpaper();
    }
}

void SwitchController::stop()
{
    m_running = false;
}

void SwitchController::onNetworkChanged(const QString &gatewayMac, const QString &ssid)
{
    Q_UNUSED(ssid);
    setWallpaperByMac(gatewayMac);
}

void SwitchController::onConnectionChanged(bool connected)
{
    if (!connected) {
        setDefaultWallpaper();
    }
    // on connect: networkChanged is always emitted alongside this signal,
    // so onNetworkChanged handles the wallpaper switch — no double-apply here.
}

void SwitchController::onLowBattery(bool low)
{
    qDebug() << "Battery low state:" << low;
}

void SwitchController::setWallpaperByMac(const QString &mac)
{
    if (!m_profileManager) return;

    m_profileManager->load();

    if (mac.isEmpty()) {
        setDefaultWallpaper();
        return;
    }

    Profile profile = m_profileManager->profileForMac(mac);
    if (profile.id.isEmpty()) {
        setDefaultWallpaper();
        return;
    }

    setWallpaper(profile.id);
}

void SwitchController::setWallpaper(const QString &profileId)
{
    if (!m_profileManager) return;

    const QList<Profile> profiles = m_profileManager->profiles();
    for (const Profile &profile : profiles) {
        if (profile.id == profileId) {
            m_currentProfileId = profileId;
            applyWallpaper(profile.wallpaperPath);
            emit wallpaperChanged(profileId);
            return;
        }
    }

    emit error(QStringLiteral("Profile not found: %1").arg(profileId));
}

void SwitchController::reapplyCurrentProfile()
{
    // Re-reads profiles from disk and re-applies whatever is current.
    // Call this after the UI saves a profile edit.
    if (!m_currentProfileId.isEmpty()) {
        setWallpaper(m_currentProfileId);
    } else if (!m_networkWatcher->isConnected()) {
        setDefaultWallpaper();
    } else {
        setWallpaperByMac(m_networkWatcher->currentGatewayMac());
    }
}

void SwitchController::setDefaultWallpaper()
{
    if (!m_profileManager) return;

    Profile profile = m_profileManager->defaultProfile();
    if (profile.wallpaperPath.isEmpty()) {
        return;
    }

    m_currentProfileId = profile.id;
    applyWallpaper(profile.wallpaperPath);
    emit wallpaperChanged(profile.id);
}

void SwitchController::applyWallpaper(const QString &wallpaperPath)
{
    if (wallpaperPath.isEmpty()) return;

    ProfileManager::setCurrentWallpaper(wallpaperPath, m_currentProfileId);

    // wallpaperFile + wallpaperVersion을 단일 D-Bus 호출로 원자적으로 씀.
    plasmaWriteWallpaper(wallpaperPath,
                         QString::number(QDateTime::currentMSecsSinceEpoch()));

    if (m_dbusService) {
        m_dbusService->emitWallpaperChanged(wallpaperPath, m_currentProfileId);
    }
    qDebug() << "Wallpaper applied:" << wallpaperPath;
}
