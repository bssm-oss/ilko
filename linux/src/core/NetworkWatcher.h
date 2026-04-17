#pragma once

#include <QObject>
#include <QString>
#include <QTimer>
#include <QDBusInterface>

class NetworkWatcher : public QObject
{
    Q_OBJECT

public:
    explicit NetworkWatcher(QObject *parent = nullptr);
    ~NetworkWatcher();

    void start();
    void stop();

    QString currentGatewayMac() const { return m_currentGatewayMac; }
    QString currentSsid() const { return m_currentSsid; }
    bool isConnected() const { return m_isConnected; }

signals:
    void networkChanged(const QString &gatewayMac, const QString &ssid);
    void connectionStateChanged(bool connected);

private slots:
    void onNMPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);
    void onNMStateChanged(uint state);
    void checkNetwork();

private:
    QString getGatewayMac();
    bool parseArpOutput(const QString &output, QString &mac);

    QDBusInterface *m_nmIface;
    QTimer *m_timer;
    QString m_currentGatewayMac;
    QString m_currentSsid;
    bool m_isConnected;
    bool m_running;
    int m_emptyMacStreak = 0;  // consecutive polls with no MAC — need 4 before declaring disconnected
};