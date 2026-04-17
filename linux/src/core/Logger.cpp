#include "Logger.h"

#include <QDateTime>

namespace ilko {

Logger *Logger::s_instance = nullptr;

Logger::Logger(QObject *parent)
    : QObject(parent)
    , m_level(Info)
{
    QString logDir = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    QDir().mkpath(logDir);

    m_file.setFileName(logDir + "/ilko.log");
    if (m_file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        m_stream.setDevice(&m_file);
    }
}

Logger::~Logger()
{
    m_file.close();
}

Logger *Logger::instance()
{
    if (!s_instance) {
        s_instance = new Logger();
    }
    return s_instance;
}

void Logger::log(Level level, const QString &tag, const QString &message)
{
    if (level < m_level) return;

    QMutexLocker locker(&m_mutex);

    QString timestamp = QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss.zzz");
    QString levelStr;
    switch (level) {
        case Debug:   levelStr = "DEBUG"; break;
        case Info:    levelStr = "INFO"; break;
        case Warning: levelStr = "WARN"; break;
        case Error:   levelStr = "ERROR"; break;
    }

    QString fullMsg = QString("[%1] [%2] [%3] %4").arg(timestamp, levelStr, tag, message);
    writeToFile(fullMsg);
}

void Logger::writeToFile(const QString &msg)
{
    m_stream << msg << "\n";
    m_stream.flush();
}

void Logger::debug(const QString &tag, const QString &message)
{
    log(Debug, tag, message);
}

void Logger::info(const QString &tag, const QString &message)
{
    log(Info, tag, message);
}

void Logger::warning(const QString &tag, const QString &message)
{
    log(Warning, tag, message);
}

void Logger::error(const QString &tag, const QString &message)
{
    log(Error, tag, message);
}

void Logger::setLevel(Level level)
{
    m_level = level;
}

}