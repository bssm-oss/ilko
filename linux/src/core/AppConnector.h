#pragma once

#include <QObject>
#include <QLocalSocket>
#include <QJsonDocument>
#include <QLocalServer>
#include <QJsonObject>

namespace ilko {

class AppConnector : public QObject
{
    Q_OBJECT

public:
    enum MessageType {
        Register,
        GetStatus,
        SetProfile,
        BatteryInfo,
        NetworkInfo,
        SaveVideo,
        ConvertVideo
    };

    struct Message {
        MessageType type;
        QString sender;
        QJsonObject data;
    };

    explicit AppConnector(QObject *parent = nullptr);
    ~AppConnector();

    bool startServer(const QString &socketName = "ilko-app");
    void stopServer();

    void sendToApp(const Message &message);
    void sendToPlugin(const Message &message);

    bool isAppConnected() const { return m_appSocket && m_appSocket->state() == QLocalSocket::ConnectedState; }
    bool isPluginConnected() const { return m_pluginSocket && m_pluginSocket->state() == QLocalSocket::ConnectedState; }

signals:
    void appConnected();
    void appDisconnected();
    void pluginConnected();
    void pluginDisconnected();
    void messageReceived(const Message &message);

private slots:
    void onAppReadyRead();
    void onPluginReadyRead();
    void onNewConnection();

private:
    void processMessage(const QByteArray &data, QLocalSocket *source);

    QLocalServer *m_server;
    QLocalSocket *m_appSocket;
    QLocalSocket *m_pluginSocket;
    QString m_socketName;
};

}