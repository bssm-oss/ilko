#include "ProfileManager.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QFile>
#include <QDir>
#include <QStandardPaths>
#include <QUuid>
#include <QFileInfo>
#include <QDateTime>
#include <QProcess>

ProfileManager::ProfileManager(QObject *parent)
    : QObject(parent)
    , m_configPath(QDir::homePath() + "/.ilko/profiles.json")
{
}

ProfileManager::~ProfileManager() = default;

void ProfileManager::load()
{
    m_profiles.clear();

    if (!QFile::exists(m_configPath)) {
        Profile defaultProfile;
        defaultProfile.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        defaultProfile.name = QStringLiteral("기본 (일코)");
        defaultProfile.gatewayMac.clear();
        defaultProfile.wallpaperPath.clear();
        defaultProfile.thumbnailPath.clear();
        defaultProfile.isDefault = true;
        m_profiles.append(defaultProfile);
        
        QDir().mkpath(QDir::homePath() + "/.ilko");
        save();
        return;
    }

    QFile file(m_configPath);
    if (!file.open(QIODevice::ReadOnly)) {
        return;
    }

    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    file.close();

    if (!doc.isObject()) {
        return;
    }

    QJsonObject obj = doc.object();
    m_activeProfileId = obj.value("activeProfile").toString();

    QJsonArray profilesArray = obj.value("profiles").toArray();
    for (const auto &item : profilesArray) {
        if (!item.isObject()) continue;

        QJsonObject p = item.toObject();
        Profile profile;
        profile.id = p.value("id").toString();
        profile.name = p.value("name").toString();
        profile.gatewayMac = p.value("gatewayMac").toString();
        profile.wallpaperPath = p.value("wallpaperPath").toString();
        profile.thumbnailPath = p.value("thumbnailPath").toString();
        profile.isDefault = p.value("isDefault").toBool(false);
        profile.targetFps = p.value("targetFps").toInt(30);
        profile.batteryPause = p.value("batteryPause").toBool(true);
        m_profiles.append(profile);
    }
}

void ProfileManager::save()
{
    QJsonObject obj;
    obj.insert("activeProfile", m_activeProfileId);

    QJsonArray profilesArray;
    for (const Profile &p : m_profiles) {
        QJsonObject profile;
        profile.insert("id", p.id);
        profile.insert("name", p.name);
        profile.insert("gatewayMac", p.gatewayMac);
        profile.insert("wallpaperPath", p.wallpaperPath);
        profile.insert("thumbnailPath", p.thumbnailPath);
        profile.insert("isDefault", p.isDefault);
        profile.insert("targetFps", p.targetFps);
        profile.insert("batteryPause", p.batteryPause);
        profilesArray.append(profile);
    }
    obj.insert("profiles", profilesArray);

    QDir().mkpath(QDir::homePath() + "/.ilko");
    
    QFile file(m_configPath);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(obj).toJson(QJsonDocument::Indented));
        file.close();
    }
}

Profile ProfileManager::defaultProfile() const
{
    for (const Profile &p : m_profiles) {
        if (p.isDefault) return p;
    }
    return Profile{};
}

Profile ProfileManager::profileForMac(const QString &mac) const
{
    for (const Profile &p : m_profiles) {
        if (!p.isDefault && p.gatewayMac.toLower() == mac.toLower()) {
            return p;
        }
    }
    return defaultProfile();
}

void ProfileManager::addProfile(const Profile &profile)
{
    m_profiles.append(profile);
    save();
    emit profilesChanged();
}

void ProfileManager::updateProfile(const Profile &profile)
{
    for (int i = 0; i < m_profiles.size(); ++i) {
        if (m_profiles[i].id == profile.id) {
            m_profiles[i] = profile;
            break;
        }
    }
    save();
    emit profilesChanged();
}

void ProfileManager::removeProfile(const QString &id)
{
    QList<Profile> newList;
    for (const Profile &p : m_profiles) {
        if (p.id != id) {
            newList.append(p);
        }
    }
    m_profiles = newList;
    save();
    emit profilesChanged();
}

QString ProfileManager::importWallpaper(const QString &sourcePath)
{
    if (sourcePath.isEmpty()) return {};

    QDir().mkpath(wallpapersDir());

    QFileInfo fi(sourcePath);
    QString ext = fi.suffix();
    if (ext.isEmpty()) ext = "dat";

    QString baseName = fi.completeBaseName();
    QString destPath = wallpapersDir() + "/" + baseName + "." + ext;

    if (QFile::exists(destPath)) {
        if (fi.absoluteFilePath() == QFileInfo(destPath).absoluteFilePath()) {
            return destPath;
        }
        QString uniqueName = baseName + "_" + QUuid::createUuid().toString(QUuid::Id128).left(8) + "." + ext;
        destPath = wallpapersDir() + "/" + uniqueName;
    }

    if (QFile::copy(sourcePath, destPath)) {
        QFile::setPermissions(destPath, QFile::ReadOwner | QFile::WriteOwner | QFile::ReadGroup | QFile::ReadOther);
        return destPath;
    }

    return sourcePath;
}

void ProfileManager::setCurrentWallpaper(const QString &wallpaperPath, const QString &profileId)
{
    QDir().mkpath(ilkoDir());

    QJsonObject obj;
    obj["wallpaperFile"] = wallpaperPath;
    obj["profileId"] = profileId;
    obj["timestamp"] = QDateTime::currentDateTime().toSecsSinceEpoch();

    QFile file(ilkoDir() + "/current_wallpaper.json");
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(obj).toJson(QJsonDocument::Indented));
        file.close();
    }
}

QString ProfileManager::currentWallpaperPath()
{
    QFile file(ilkoDir() + "/current_wallpaper.json");
    if (!file.open(QIODevice::ReadOnly)) return {};

    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    file.close();

    if (!doc.isObject()) return {};
    return doc.object().value("wallpaperFile").toString();
}

void ProfileManager::writePlayerControl(bool paused, double playbackRate, const QString &reason)
{
    QDir().mkpath(ilkoDir());

    QJsonObject obj;
    obj["paused"] = paused;
    obj["playbackRate"] = playbackRate;
    if (!reason.isEmpty()) obj["reason"] = reason;

    QFile file(ilkoDir() + "/player_control.json");
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(obj).toJson());
        file.close();
    }
}