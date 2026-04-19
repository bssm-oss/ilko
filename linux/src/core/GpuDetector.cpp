#include "GpuDetector.h"

#include <QDir>
#include <QFile>
#include <QTextStream>

static QString envDir()  { return QDir::homePath() + "/.config/plasma-workspace/env"; }
static QString envFile() { return envDir() + "/ilko-decode.sh"; }

QString GpuDetector::envFilePath() { return envFile(); }

bool GpuDetector::isPowerSavingActive()
{
    return QFile::exists(envFile());
}

// ── 내부 헬퍼 ──────────────────────────────────────────────────────────────

struct IgpuInfo {
    QString renderNode;  // e.g. "/dev/dri/renderD129"
    QString libvaDriver; // e.g. "radeonsi" or "iHD"
};

static IgpuInfo detectIgpu()
{
    const QStringList entries =
        QDir("/sys/bus/pci/devices").entryList(QDir::Dirs | QDir::NoDotAndDotDot);

    for (const QString &entry : entries) {
        const QString base = "/sys/bus/pci/devices/" + entry;

        QFile classFile(base + "/class");
        QFile vendorFile(base + "/vendor");
        if (!classFile.open(QIODevice::ReadOnly) || !vendorFile.open(QIODevice::ReadOnly))
            continue;

        const QString pciClass = classFile.readAll().trimmed();
        const QString vendor   = vendorFile.readAll().trimmed();

        if (!pciClass.startsWith("0x0300") && !pciClass.startsWith("0x0302"))
            continue;
        if (vendor != "0x8086" && vendor != "0x1002")
            continue;

        // DRM 렌더 노드 찾기: /sys/bus/pci/devices/<id>/drm/renderD*
        QDir drmDir(base + "/drm");
        const QStringList renderNodes =
            drmDir.entryList(QStringList{"renderD*"}, QDir::Dirs);
        if (renderNodes.isEmpty())
            continue;

        const QString libvaDriver =
            (vendor == "0x1002") ? QStringLiteral("radeonsi") : QStringLiteral("iHD");

        return { "/dev/dri/" + renderNodes.first(), libvaDriver };
    }
    return {};
}

// ── 공개 API ───────────────────────────────────────────────────────────────

bool GpuDetector::isHybridNvidiaPlusIgpu()
{
    bool hasNvidia = false;
    bool hasIgpu   = false;

    const QStringList entries =
        QDir("/sys/bus/pci/devices").entryList(QDir::Dirs | QDir::NoDotAndDotDot);

    for (const QString &entry : entries) {
        const QString base = "/sys/bus/pci/devices/" + entry;

        QFile classFile(base + "/class");
        QFile vendorFile(base + "/vendor");
        if (!classFile.open(QIODevice::ReadOnly) || !vendorFile.open(QIODevice::ReadOnly))
            continue;

        const QString pciClass = classFile.readAll().trimmed();
        const QString vendor   = vendorFile.readAll().trimmed();

        if (!pciClass.startsWith("0x0300") && !pciClass.startsWith("0x0302"))
            continue;

        if (vendor == "0x10de")                        hasNvidia = true;
        if (vendor == "0x8086" || vendor == "0x1002")  hasIgpu   = true;
    }

    return hasNvidia && hasIgpu;
}

GpuDetector::ConfigResult GpuDetector::autoConfigureIfNeeded()
{
    if (!isHybridNvidiaPlusIgpu())
        return ConfigResult::NotHybrid;

    // 파일이 없거나, LIBVA_DRM_DEVICE 줄이 없으면(구버전) 재작성
    bool needsWrite = !isPowerSavingActive();
    if (!needsWrite) {
        QFile f(envFile());
        if (f.open(QIODevice::ReadOnly)) {
            needsWrite = !QString(f.readAll()).contains("LIBVA_DRM_DEVICE");
        }
    }

    if (!needsWrite)
        return ConfigResult::AlreadyActive;

    setEnabled(true);
    return ConfigResult::Applied;
}

void GpuDetector::setEnabled(bool enabled)
{
    if (enabled) {
        const IgpuInfo igpu = detectIgpu();

        QDir().mkpath(envDir());
        QFile f(envFile());
        if (f.open(QIODevice::WriteOnly | QIODevice::Text)) {
            QTextStream s(&f);
            s << "#!/bin/sh\n";
            s << "# ilko: NVIDIA 하드웨어 비디오 디코딩 비활성화 (하이브리드 GPU 절전)\n";
            s << "# ILKO 설정에서 관리됩니다 — 직접 수정하지 마세요\n";
            s << "export GST_PLUGIN_FEATURE_RANK=nvcodec:NONE\n";
            if (!igpu.renderNode.isEmpty())
                s << "export LIBVA_DRM_DEVICE=" << igpu.renderNode << "\n";
            if (!igpu.libvaDriver.isEmpty())
                s << "export LIBVA_DRIVER_NAME=" << igpu.libvaDriver << "\n";
        }
    } else {
        QFile::remove(envFile());
    }
}
