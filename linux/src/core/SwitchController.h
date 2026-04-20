#pragma once

#include <QObject>
#include <QString>

class ProfileManager;
class NetworkWatcher;

namespace ilko {
class WallpaperDBusService;
}

class SwitchController : public QObject
{
    Q_OBJECT

public:
    explicit SwitchController(ProfileManager *profileManager,
                          NetworkWatcher *networkWatcher,
                          QObject *parent = nullptr);
    ~SwitchController();

    void start();
    void stop();

    QString currentProfileId() const { return m_currentProfileId; }

public slots:
    void setWallpaper(const QString &profileId);
    void setWallpaperByMac(const QString &mac);
    void setDefaultWallpaper();
    void reapplyCurrentProfile();
    void onConnectionChanged(bool connected);

signals:
    void wallpaperChanged(const QString &profileId);
    void error(const QString &message);

private slots:
    void onNetworkChanged(const QString &gatewayMac, const QString &ssid);

private:
    void applyWallpaper(const QString &wallpaperPath);

    ProfileManager *m_profileManager;
    NetworkWatcher *m_networkWatcher;
    QString m_currentProfileId;
    bool m_running;
    ilko::WallpaperDBusService *m_dbusService;
};