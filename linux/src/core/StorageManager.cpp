#include "StorageManager.h"

#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>

namespace ilko {

StorageManager::StorageManager(QObject *parent)
    : QObject(parent)
    , m_converter(nullptr)
{
    QString homeDir = QStandardPaths::writableLocation(QStandardPaths::HomeLocation);
    m_storagePath = homeDir + "/.ilko/wallpapers";

    ensureStorageDir();
}

StorageManager::~StorageManager()
{
    if (m_converter) {
        m_converter->kill();
        m_converter->deleteLater();
    }
}

bool StorageManager::ensureStorageDir() const
{
    QDir dir;
    if (!dir.exists(m_storagePath)) {
        return dir.mkpath(m_storagePath);
    }
    return true;
}

QString StorageManager::getFFmpegPath() const
{
    static QString ffmpegPath = "ffmpeg";
    return ffmpegPath;
}

bool StorageManager::convertToH265(const QString &inputPath, const QString &outputName)
{
    if (!ensureStorageDir()) {
        emit error("Cannot create storage directory");
        return false;
    }

    QFileInfo inputInfo(inputPath);
    if (!inputInfo.exists()) {
        emit error("Input file does not exist: " + inputPath);
        return false;
    }

    QString outputPath = m_storagePath + "/" + outputName + ".mp4";

    if (m_converter) {
        m_converter->kill();
        m_converter->deleteLater();
    }

    m_converter = new QProcess(this);
    m_converter->setProgram(getFFmpegPath());
    // Write to a temp file first; rename to outputPath atomically on success.
    // This prevents a partial file from being loaded if the daemon is killed
    // mid-conversion. Keep .mp4 extension so ffmpeg infers the right container.
    const QString tmpPath = m_storagePath + "/." + outputName + "_tmp.mp4";

    m_converter->setArguments(QStringList{
        "-i", inputPath,
        "-c:v", "libx265",
        "-preset", "medium",
        "-crf", "28",
        "-an",          // no audio — video wallpaper never plays audio
        "-y",
        tmpPath
    });

    connect(m_converter, &QProcess::started, this, [this, inputPath]() {
        emit conversionStarted(inputPath);
    });

    connect(m_converter, &QProcess::finished, this, [this, outputPath, tmpPath, outputName](int exitCode) {
        if (exitCode == 0) {
            // Atomic replace: remove old file, rename temp into place
            QFile::remove(outputPath);
            QFile::rename(tmpPath, outputPath);
            emit conversionFinished(outputName, true);
        } else {
            QFile::remove(tmpPath);
            emit conversionFinished(outputName, false);
            emit error("Conversion failed with exit code: " + QString::number(exitCode));
        }
    });

    m_converter->start();
    return true;
}

bool StorageManager::saveVideo(const QString &sourcePath, const QString &profileId)
{
    // Do NOT pre-delete the existing file here.
    // convertToH265 writes to a .tmp file first and renames atomically on
    // success, so the old file stays intact until the new one is ready.
    return convertToH265(sourcePath, profileId);
}

QStringList StorageManager::listVideos() const
{
    QDir dir(m_storagePath);
    if (!dir.exists()) {
        return QStringList();
    }

    QStringList filters;
    filters << "*.mp4";
    dir.setNameFilters(filters);

    QStringList files = dir.entryList(QDir::Files);
    QStringList result;
    for (const QString &file : files) {
        result.append(QFileInfo(file).baseName());
    }
    return result;
}

bool StorageManager::hasVideo(const QString &name) const
{
    QString filePath = m_storagePath + "/" + name + ".mp4";
    return QFile::exists(filePath);
}

bool StorageManager::deleteVideo(const QString &name)
{
    QString filePath = m_storagePath + "/" + name + ".mp4";
    if (QFile::exists(filePath)) {
        return QFile::remove(filePath);
    }
    return false;
}

qint64 StorageManager::storageUsed() const
{
    qint64 totalSize = 0;
    QDir dir(m_storagePath);
    if (dir.exists()) {
        QList<QFileInfo> fileList = dir.entryInfoList(QDir::Files);
        for (const QFileInfo &info : fileList) {
            totalSize += info.size();
        }
    }
    return totalSize;
}

}