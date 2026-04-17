#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QDir>
#include <QFile>
#include <QStandardPaths>

namespace ilko {

class StorageManager : public QObject
{
    Q_OBJECT

public:
    explicit StorageManager(QObject *parent = nullptr);
    ~StorageManager();

    QString storagePath() const { return m_storagePath; }

    bool convertToH265(const QString &inputPath, const QString &outputName);
    bool saveVideo(const QString &sourcePath, const QString &profileId);

    QStringList listVideos() const;
    bool hasVideo(const QString &name) const;
    bool deleteVideo(const QString &name);

    qint64 storageUsed() const;

signals:
    void conversionStarted(const QString &input);
    void conversionProgress(int percent);
    void conversionFinished(const QString &output, bool success);
    void error(const QString &message);

private:
    QString getFFmpegPath() const;
    bool ensureStorageDir() const;

    QString m_storagePath;
    QProcess *m_converter;
};

}