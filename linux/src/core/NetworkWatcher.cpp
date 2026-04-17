#include "NetworkWatcher.h"

#include <QProcess>
#include <QRegularExpression>
#include <QDebug>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusReply>

NetworkWatcher::NetworkWatcher(QObject *parent)
    : QObject(parent)
    , m_nmIface(nullptr)
    , m_timer(new QTimer(this))
    , m_currentGatewayMac()
    , m_currentSsid()
    , m_isConnected(false)
    , m_running(false)
{
    connect(m_timer, &QTimer::timeout, this, &NetworkWatcher::checkNetwork);

    QDBusConnection dbus = QDBusConnection::systemBus();
    if (dbus.isConnected()) {
        m_nmIface = new QDBusInterface(
            "org.freedesktop.NetworkManager",
            "/org/freedesktop/NetworkManager",
            "org.freedesktop.DBus.Properties",
            dbus,
            this
        );

        if (m_nmIface->isValid()) {
            // PropertiesChanged: fires early, during ACTIVATING — useful for clearing stale state
            dbus.connect(
                "org.freedesktop.NetworkManager",
                "/org/freedesktop/NetworkManager",
                "org.freedesktop.DBus.Properties",
                "PropertiesChanged",
                this,
                SLOT(onNMPropertiesChanged(QString,QVariantMap,QStringList))
            );

            // StateChanged fires when NM reaches CONNECTED_LOCAL (50) / CONNECTED_GLOBAL (70)
            // — at this point DHCP is done, route is set, ARP should resolve quickly
            dbus.connect(
                "org.freedesktop.NetworkManager",
                "/org/freedesktop/NetworkManager",
                "org.freedesktop.NetworkManager",
                "StateChanged",
                this,
                SLOT(onNMStateChanged(uint))
            );
        }
    }
}

NetworkWatcher::~NetworkWatcher() = default;

void NetworkWatcher::start()
{
    if (m_running) return;
    m_running = true;
    checkNetwork();
    m_timer->start(10000);  // 10초로 늘림 (D-Bus 시그널이 주요 변경 감지)
}

void NetworkWatcher::stop()
{
    m_running = false;
    m_timer->stop();
}

void NetworkWatcher::onNMPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated)
{
    Q_UNUSED(invalidated);
    
    if (interface == "org.freedesktop.NetworkManager") {
        if (changed.contains("PrimaryConnection") || changed.contains("ActiveConnections")) {
            checkNetwork();
        }
    }
}

static QString runCommand(const QString &prog, const QStringList &args)
{
    QProcess p;
    p.start(prog, args, QIODevice::ReadOnly);
    if (!p.waitForStarted(500)) return {};
    p.closeWriteChannel();
    QString out;
    if (p.waitForReadyRead(1500)) out = p.readAllStandardOutput();
    p.kill();
    p.waitForFinished(500);
    return out.trimmed();
}

QString NetworkWatcher::getGatewayMac()
{
    // Step 1: get the default gateway IP
    // "ip route show default" → "default via 10.0.0.1 dev wlan0 ..."
    const QString routeOut = runCommand("ip", {"route", "show", "default"});
    if (routeOut.isEmpty()) return {};

    QRegularExpression gwRe(R"(default via (\d+\.\d+\.\d+\.\d+))");
    QRegularExpressionMatch gwMatch = gwRe.match(routeOut);
    if (!gwMatch.hasMatch()) return {};

    const QString gatewayIp = gwMatch.captured(1);

    // Step 2: look up the MAC for that specific IP in the neighbour table
    // "ip neigh show <ip>" → "10.0.0.1 dev wlan0 lladdr 00:11:22:33:44:55 REACHABLE"
    QString neighOut = runCommand("ip", {"neigh", "show", gatewayIp});

    // ARP entry may be absent right after connect — send one ICMP probe to
    // populate the neigh cache, then re-query immediately.
    QString mac;
    if (!parseArpOutput(neighOut, mac)) {
        runCommand("ping", {"-c", "1", "-W", "1", "-q", gatewayIp});
        neighOut = runCommand("ip", {"neigh", "show", gatewayIp});
    }

    if (parseArpOutput(neighOut, mac)) {
        return mac.toLower();
    }
    return {};
}

bool NetworkWatcher::parseArpOutput(const QString &output, QString &mac)
{
    QRegularExpression re("\\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\\b");
    QRegularExpressionMatch match = re.match(output);

    if (match.hasMatch()) {
        mac = match.captured();
        return true;
    }

    return false;
}

void NetworkWatcher::onNMStateChanged(uint state)
{
    // NM_STATE_CONNECTED_LOCAL = 50, NM_STATE_CONNECTED_GLOBAL = 70
    // Fire retries shortly after NM reports the link is up — DHCP and ARP
    // may not be fully settled yet, so stagger three attempts.
    if (state >= 50) {
        m_emptyMacStreak = 0;
        QTimer::singleShot(500,  this, &NetworkWatcher::checkNetwork);
        QTimer::singleShot(2000, this, &NetworkWatcher::checkNetwork);
        QTimer::singleShot(5000, this, &NetworkWatcher::checkNetwork);
    }
}

void NetworkWatcher::checkNetwork()
{
    const QString oldGatewayMac = m_currentGatewayMac;

    const QString gatewayMac = getGatewayMac();

    if (!gatewayMac.isEmpty()) {
        m_emptyMacStreak = 0;

        // New or changed gateway MAC → switch wallpaper
        if (gatewayMac != oldGatewayMac) {
            m_currentGatewayMac = gatewayMac;

            if (!m_isConnected) {
                m_isConnected = true;
                emit connectionStateChanged(true);
            }

            emit networkChanged(gatewayMac, m_currentSsid);
        }
    } else {
        // Empty MAC: ARP entries can disappear transiently.
        // Only declare disconnected after 2 consecutive empty polls.
        ++m_emptyMacStreak;
        if (m_emptyMacStreak >= 4 && m_isConnected) {
            m_isConnected = false;
            m_currentGatewayMac.clear();
            emit connectionStateChanged(false);
        }
    }
}