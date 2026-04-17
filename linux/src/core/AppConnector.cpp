#include "AppConnector.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QThread>

namespace ilko {

AppConnector::AppConnector(QObject *parent)
    : QObject(parent)
    , m_server(new QLocalServer(this))
    , m_appSocket(nullptr)
    , m_pluginSocket(nullptr)
{
    connect(m_server, &QLocalServer::newConnection, this, &AppConnector::onNewConnection);
}

AppConnector::~AppConnector()
{
    stopServer();
}

bool AppConnector::startServer(const QString &socketName)
{
    m_socketName = socketName;

    QLocalServer::removeServer(socketName);

    if (m_server->listen(socketName)) {
        return true;
    }
    return false;
}

void AppConnector::stopServer()
{
    if (m_server->isListening()) {
        m_server->close();
    }

    if (m_appSocket) {
        m_appSocket->disconnectFromServer();
        m_appSocket->deleteLater();
        m_appSocket = nullptr;
    }

    if (m_pluginSocket) {
        m_pluginSocket->disconnectFromServer();
        m_pluginSocket->deleteLater();
        m_pluginSocket = nullptr;
    }
}

void AppConnector::onNewConnection()
{
    QLocalSocket *client = m_server->nextPendingConnection();

    if (client) {
        QByteArray name = client->serverName().toUtf8();

        if (name.contains("app")) {
            m_appSocket = client;
            connect(m_appSocket, &QLocalSocket::readyRead, this, &AppConnector::onAppReadyRead);
            connect(m_appSocket, &QLocalSocket::disconnected, this, [this]() {
                emit appDisconnected();
                m_appSocket = nullptr;
            });
            emit appConnected();
        } else if (name.contains("plugin")) {
            m_pluginSocket = client;
            connect(m_pluginSocket, &QLocalSocket::readyRead, this, &AppConnector::onPluginReadyRead);
            connect(m_pluginSocket, &QLocalSocket::disconnected, this, [this]() {
                emit pluginDisconnected();
                m_pluginSocket = nullptr;
            });
            emit pluginConnected();
        }
    }
}

void AppConnector::onAppReadyRead()
{
    if (!m_appSocket) return;
    QByteArray data = m_appSocket->readAll();
    processMessage(data, m_appSocket);
}

void AppConnector::onPluginReadyRead()
{
    if (!m_pluginSocket) return;
    QByteArray data = m_pluginSocket->readAll();
    processMessage(data, m_pluginSocket);
}

void AppConnector::processMessage(const QByteArray &data, QLocalSocket *source)
{
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (doc.isObject()) {
        QJsonObject obj = doc.object();
        Message msg;
        msg.type = static_cast<MessageType>(obj.value("type").toInt());
        msg.sender = obj.value("sender").toString();
        msg.data = obj.value("data").toObject();
        emit messageReceived(msg);
    }
}

void AppConnector::sendToApp(const Message &message)
{
    if (!m_appSocket || m_appSocket->state() != QLocalSocket::ConnectedState) {
        return;
    }

    QJsonObject obj;
    obj["type"] = message.type;
    obj["sender"] = message.sender;
    obj["data"] = message.data;

    QJsonDocument doc(obj);
    m_appSocket->write(doc.toJson(QJsonDocument::Compact));
}

void AppConnector::sendToPlugin(const Message &message)
{
    if (!m_pluginSocket || m_pluginSocket->state() != QLocalSocket::ConnectedState) {
        return;
    }

    QJsonObject obj;
    obj["type"] = message.type;
    obj["sender"] = message.sender;
    obj["data"] = message.data;

    QJsonDocument doc(obj);
    m_pluginSocket->write(doc.toJson(QJsonDocument::Compact));
}

}