#pragma once

#include <QObject>
#include <QFile>
#include <QTextStream>
#include <QMutex>
#include <QDir>
#include <QStandardPaths>

namespace ilko {

class Logger : public QObject
{
    Q_OBJECT

public:
    enum Level {
        Debug = 0,
        Info,
        Warning,
        Error
    };

    static Logger *instance();

    void log(Level level, const QString &tag, const QString &message);

    void debug(const QString &tag, const QString &message);
    void info(const QString &tag, const QString &message);
    void warning(const QString &tag, const QString &message);
    void error(const QString &tag, const QString &message);

    void setLevel(Level level);

private:
    explicit Logger(QObject *parent = nullptr);
    ~Logger();

    void writeToFile(const QString &msg);

    static Logger *s_instance;
    QFile m_file;
    QTextStream m_stream;
    QMutex m_mutex;
    Level m_level;
};

}