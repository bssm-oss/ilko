# ILKO
<img width="1920" height="1080" alt="ilko_poster" src="https://github.com/user-attachments/assets/db536208-cdf2-4c8b-9b0a-094b4bb97597" />

> 네트워크 기반 자동 월페이퍼 전환 — 집에선 덕질, 밖에선 일코

[YOUTUBE : ILKO(일코) - 씹덕들의 일코를 위한 네트워크 기반 월페이퍼 자동 전환 서비스](https://youtu.be/oWZAOatEMrA)

(영상 내에서는 월페이퍼가 이미지처럼 보이는데, 실제로는 mp4로 재생 됩니다. 영상 녹화 시에는 사진취급 되네요.)

Wi-Fi 게이트웨이를 감지해 장소에 맞는 월페이퍼로 자동 전환하는 앱. **macOS · Windows** 지원.  
집에선 좋아하는 캐릭터 라이브 월페이퍼, 카페·회사에선 조용한 기본 배경으로

> Based on [LiveWallpaperMacOS](https://github.com/thusvill/LiveWallpaperMacOS) by thusvill, licensed under GPL v3.

---

## 주요 기능

| 기능 | macOS | Windows | Linux |
|------|:-----:|:-------:|:-----:|
| 게이트웨이 MAC 기반 자동 전환 | ✅ | ✅ | ✅ |
| 라이브 영상 월페이퍼 (mp4) | ✅ | ✅ | ✅ |
| 정적 이미지 월페이퍼 | ✅ | ✅ | ✅ |
| 멀티모니터 지원 | ✅ | ✅ | ✅ |
| Wi-Fi 단절 시 기본 프로필 자동 전환 | ✅ | ✅ | ✅ |
| 프로필별 네트워크 등록 | ✅ | ✅ | ✅ |
| 시스템 트레이 / 메뉴바 상주 | ✅ | ✅ | ✅ |
| 잠금화면 영상 | ✅ | ❌ | ❌ |

---

## macOS

### 설치 (DMG 권장)

1. [Releases](../../releases/latest)에서 `ILKO-vX.X.X.dmg` 다운로드
2. DMG 열고 `ILKO.app` → Applications 폴더로 드래그
3. **터미널에서 아래 명령 실행** (최초 1회):
   ```bash
   xattr -d com.apple.quarantine /Applications/ILKO.app
   ```
   > 이 단계를 건너뛰면 *"손상되었기 때문에 열 수 없습니다"* 오류가 발생합니다.
4. ILKO 실행 → 메뉴바 아이콘 확인

### 소스 빌드

**요구사항:** macOS 14.6+, Xcode Command Line Tools

```bash
git clone https://github.com/winshine0326/ilko.git
cd ilko
make run
```

DMG 직접 생성:

```bash
make dmg VERSION=1.0.0
# 결과물: dist/ILKO-1.0.0.dmg
```

### 사용법

#### 핵심 개념: 프로필이란?

ILKO는 **장소(네트워크)별 월페이퍼 프로필**로 동작합니다.

| 프로필 종류 | 언제 적용되나 | 용도 |
|------------|-------------|------|
| **기본 프로필** (GatewayMAC 없음) | 등록된 네트워크가 아닐 때 | 외출 시 보여줄 일반 배경화면 |
| **네트워크 프로필** | 해당 게이트웨이 MAC에 연결됐을 때 | 집/특정 장소에서 보여줄 배경화면 |

> **중요:** 오타쿠 월페이퍼는 반드시 **네트워크 프로필**에 설정해야 합니다.  
> 기본 프로필에 설정하면 어디서든 오타쿠 배경화면이 표시됩니다.

#### 초기 설정 (5분)

**1단계 — 기본(외출용) 프로필 설정**

앱을 처음 실행하면 "기본 (일코)"라는 프로필이 자동 생성됩니다.

1. 메뉴바 아이콘 클릭 → 설정 열기
   <img width="35" height="35" alt="image" src="https://github.com/user-attachments/assets/1cf2eefd-6d08-4f11-a2e1-1e5b60d33e58" />

   <img width="205" height="198" alt="image" src="https://github.com/user-attachments/assets/5a70d6c3-3c66-48a9-ad6c-217ca98c6421" />

2. 툴바 **👥** 버튼 → 프로필 관리 화면

   <img width="187" height="52" alt="image" src="https://github.com/user-attachments/assets/4949d1c9-db7e-43e4-bb49-d04348b35edb" />
   
3. "기본 (일코)" 프로필 선택 → **편집**
   <img width="1824" height="1424" alt="image" src="https://github.com/user-attachments/assets/24dc0dda-1e1d-4a92-a493-f713d6f9a070" />
   
4. 외출 시 쓸 평범한 배경화면 파일 지정 후 저장
   <img width="912" height="712" alt="image" src="https://github.com/user-attachments/assets/671537d4-0e84-4c6c-ae3e-5ef85716a26a" />

**2단계 — 집(오타쿠용) 프로필 추가**

1. 프로필 관리 화면에서 **프로필 추가**
2. 프로필 이름 입력 (예: "집")
3. **네트워크 자동 감지** 버튼 클릭 → 현재 연결된 게이트웨이 MAC이 자동 입력됨
   - 자동 감지가 안 되면: 터미널에서 `netstat -rn | grep default | awk '{print $2}'` 로 게이트웨이 IP 확인 후 `arp <IP>`로 MAC 조회
4. 오타쿠 배경화면 파일 지정 (mp4/mov/jpg/png)
   <img width="1824" height="1424" alt="image" src="https://github.com/user-attachments/assets/3a8af752-1a7d-4309-b13c-b03f61384127" />
   
5. 저장

**3단계 — 완료**

이후 집 Wi-Fi에 연결되면 오타쿠 월페이퍼로, 다른 네트워크에서는 기본 월페이퍼로 자동 전환됩니다.

> **파일명 주의:** 비디오 파일명에 `.`이 2개 이상이면 인식 불가.  
> `rem-loop.mp4` ✅ / `rem.1920x1080.mp4` ❌

#### 잠금화면 영상 (선택)

영상 프로필이 적용되면 잠금화면에서도 같은 영상이 재생되게 할 수 있습니다.

1. 설정 → **잠금화면** → **잠금화면에도 영상 적용** 켜기
2. **덮어쓸 Aerial 배경** 중 하나 선택 (지금 쓰고 있는 Aerial은 고를 수 없음)
3. (선택) **화면 보호기에도 영상 적용**을 켜면 화면 보호기에서도 같은 영상이 재생됩니다. 끄면 원래 화면 보호기 설정이 유지됩니다.
4. 영상 프로필을 저장하거나 적용하면 잠금화면용으로 변환됩니다. 프로필 저장 시에는 변환 창이 뜨며 끝날 때까지 기다립니다 (4K 기준 1분 내외, 영상마다 처음 한 번만).

<!-- 스크린샷: 설정의 잠금화면 항목 -->

동작 방식과 주의사항:

- macOS는 서드파티 앱이 잠금화면에 그리는 것을 허용하지 않아서, 선택한 Apple Aerial 영상 파일(`~/Library/Application Support/com.apple.wallpaper/aerials/videos/`)을 ILKO 영상으로 바꿔 넣고 시스템 배경을 그 Aerial로 지정합니다. 관리자 권한은 필요 없습니다.
- 그래서 선택한 Aerial은 시스템 설정의 배경화면에서도 ILKO 영상으로 재생됩니다. 데스크탑은 기존처럼 ILKO가 재생합니다.
- 기능을 끄거나 **데이터 초기화**를 누르면 원래 시스템 배경으로 돌아가고, 덮어썼던 Aerial은 macOS가 원본을 다시 받습니다.
- 시스템 설정에서 배경화면을 직접 바꾸면 기능이 자동으로 꺼집니다.
- 변환된 영상은 `~/Library/Application Support/ilko/lockscreen-cache/`에 최대 5개까지 보관됩니다.

### 시스템 요구사항

- macOS 14.6 (Sonoma) 이상

---

## Windows

### 설치

**EXE (권장)**

1. [Releases](../../releases/latest)에서 `ILKO-vX.X.X-windows-x64.exe` 다운로드
2. 다운받은 EXE 실행 — 설치 불필요, 단독 실행 파일
3. 시스템 트레이 아이콘 확인

> .NET 런타임 내장 파일이라 별도 설치 없이 바로 실행됩니다.

**소스 빌드**

요구사항: Windows 10 이상, [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)

```bash
git clone https://github.com/winshine0326/ilko.git
cd ilko/windows
"C:\Program Files\dotnet\dotnet.exe" run
```

### 사용법

macOS와 동일한 프로필 개념으로 동작합니다 — **기본 프로필**(외출용)과 **네트워크 프로필**(집용)을 분리해서 설정하세요.

**1단계 — 기본(외출용) 프로필 설정**

1. 앱 실행 → 시스템 트레이 아이콘 확인
2. 트레이 아이콘 더블클릭 또는 우클릭 → 설정 열기
3. 좌측 사이드바에서 "기본 (일코)" 프로필 선택 → **편집**
4. 외출 시 쓸 평범한 배경화면 지정 후 저장

**2단계 — 집(오타쿠용) 프로필 추가**

1. 사이드바 하단 **+** 버튼 클릭
2. 프로필 이름 입력 (예: "집")
3. **현재 네트워크 자동 감지** 버튼 클릭 → 게이트웨이 MAC 자동 입력
4. 오타쿠 배경화면 파일 선택 (mp4/mov/jpg/png 등)
5. 저장

#### 라이브 영상 월페이퍼 동작 방식

Windows 버전은 **Windows Media Foundation(MFPlay) + WorkerW** 방식으로 영상을 바탕화면에 렌더링합니다.

- `Progman`에 `0x052C` 메시지를 보내 WorkerW(바탕화면 아이콘 뒤 레이어)를 확보
- WinForms HWND를 WorkerW 자식으로 SetParent
- `MFPCreateMediaPlayer`로 EVR이 해당 HWND에 D3D9 COPY 모드로 직접 렌더링
- 영상 종료 시 자동 루프

#### 지원 형식

| 종류 | 형식 |
|------|------|
| 영상 | `.mp4`, `.mov`, `.avi`, `.mkv` 등 Windows Media Foundation 지원 형식 |
| 이미지 | `.jpg`, `.jpeg`, `.png`, `.bmp`, `.gif` |

#### 알려진 제한사항

- 영상 월페이퍼는 바탕화면 아이콘 뒤에 렌더링됩니다 (정상 동작)
- 일부 DRM이 걸린 영상 파일은 재생되지 않을 수 있습니다

### 시스템 요구사항

- Windows 10 이상
- .NET 8 Runtime
- Windows Media Foundation (기본 내장)

---

## Linux (KDE Plasma)

### 설치

**Arch Linux 패키지 (권장)**

1. [Releases](../../releases/latest)에서 `ilko-vX.X.X-x86_64.pkg.tar.zst` 다운로드
2. 설치:
   ```bash
   sudo pacman -U ilko-vX.X.X-x86_64.pkg.tar.zst
   ```
3. 앱 실행 → 시스템 트레이 아이콘 확인

**수동 빌드**

```bash
# PKGBUILD로 직접 빌드
cd linux
makepkg -sfi
```

**수동 설치**

```bash
cd linux/build
sudo ninja install
sudo cp ../data/ilko.desktop /usr/share/applications/
sudo cp ../data/ilko.png /usr/share/icons/hicolor/256x256/apps/ilko.png
```

### 소스 빌드

요구사항: Arch Linux, Qt6, KDE Frameworks

```bash
git clone https://github.com/BitByte08/ilko.git
cd ilko/linux
mkdir -p build && cd build
cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja
./src/ilko
```

### 사용법

macOS/Windows와 동일한 프로필 개념으로 동작합니다.

**1단계 — 기본(외출용) 프로필 설정**

1. 트레이 아이콘 우클릭 → 앱 열기

   <img width="51" height="48" alt="image" src="https://github.com/user-attachments/assets/0635fc87-5439-4ecd-b5e1-5f467be70d08" />
   
   <img width="198" height="164" alt="image" src="https://github.com/user-attachments/assets/c2252b0e-d7af-4bdf-be52-997076526ad4" />
   
2. 상단바 프로필 버튼 클릭 → **기본 (일코)** 프로필 선택 → 편집

   <img width="1440" height="1082" alt="image" src="https://github.com/user-attachments/assets/054ad92f-8b7e-4d53-9a2b-957a87c1f867" />

3. 외출 시 쓸 평범한 배경화면 지정 후 저장

   <img width="769" height="687" alt="image" src="https://github.com/user-attachments/assets/4a8572a9-477e-444d-a727-b50453100b2e" />

**2단계 — 집(오타쿠용) 프로필 추가**

1. 상단바 프로필 버튼 클릭 → 추가

   <img width="1437" height="1083" alt="image" src="https://github.com/user-attachments/assets/9bd9c123-d05b-4295-83c6-e871c4930f6c" />

2. 프로필 이름 입력 (예: "집")
3. **네트워크 자동 감지** 버튼 클릭 → 게이트웨이 MAC 자동 입력
4. 오타쿠 배경화면 파일 선택 (mp4/mov/jpg/png 등)

   <img width="764" height="687" alt="image" src="https://github.com/user-attachments/assets/46a03d9e-aca5-4d68-8dbe-3e07c92c922e" />

5. 저장

### 시스템 요구사항

- Arch Linux (또는 Qt6 지원 배포판)
- KDE Plasma (권장)
- Qt6 Widgets, Qt6 Multimedia

---

## 월페이퍼 영상 다운로드 링크 모음 (여러분들이 찾은 사이트를 계속해서 추가해주세요!)
- https://motionbgs.com/
- https://moewalls.com/anime

---

## 크레딧

Based on [LiveWallpaperMacOS](https://github.com/thusvill/LiveWallpaperMacOS) by thusvill — GPL v3.

---

For licensing details, see [LICENSE](LICENSE).
