# Wi-Fi Switch

macOS 에서 Wi-Fi 네트워크에 따라 **고정 IP / DHCP** 를 자동 전환하는 도구.
연결된 네트워크가 등록된 항목이면 정해진 고정 IP 를 적용하고, 그 외 네트워크에서는 DHCP 로 동작합니다.

---

## 서비스 소개

### 무엇을 해결하는가
- **사무실에서는 고정 IP, 카페에선 DHCP** 같은 환경 전환을 매번 수동으로 하지 않아도 됨
- 네트워크가 바뀔 때마다 자동으로 적절한 IP 설정이 적용됨
- macOS 26 의 SSID 비식별화(redaction) 정책을 **라우터 MAC 매칭**으로 우회

### 특징
| 항목 | 내용 |
|---|---|
| 매칭 키 | 게이트웨이의 MAC 주소 (ARP 로 조회) |
| 트리거 | LaunchAgent + WatchPaths (`com.apple.airport.preferences.plist`, `preferences.plist`, `NetworkInterfaces.plist`, `/etc/resolv.conf`, `/var/run/resolv.conf`) |
| 적용 명령 | `networksetup -setmanual` / `-setdhcp` / `-setdnsservers` |
| Sudo 필요 | ❌ 콘솔 admin 사용자라면 불필요 |
| 의존성 | macOS 기본 `bash 3.2`, `python3`, `networksetup`, `route`, `arp` 만 사용 |

### 왜 라우터 MAC 매칭인가
macOS Sonoma 14.4+ (현재 26 포함) 부터 `networksetup -getairportnetwork` 와
`ipconfig getsummary` 모두 SSID 를 `<redacted>` 로 마스킹합니다.
Location Services 토글을 켜도 CLI 도구에는 풀리지 않습니다.

반면 **default gateway 의 MAC** 은 ARP 로 항상 조회 가능하며,
물리적으로 다른 라우터를 명확하게 구분할 수 있어 SSID 보다 오히려 신뢰성이 높습니다.

---

## 사용 방법

### 설치
```bash
cd wifi_switch
./install.sh
```

설치 스크립트가:
1. `~/.wifi/` 디렉토리 생성 + 스위치 스크립트 배포
2. `~/Library/LaunchAgents/com.user.wifi-switch.plist` 등록
3. 메인 TUI 진입

### 메인 화면
```
── 현재 노트북 네트워크 상태 ──
  Mode: DHCP Configuration
  MAC : bc:d0:74:14:75:8b
  IP  : 192.168.0.143
  GW  : 192.168.0.1  (router MAC: 84:78:48:80:70:68)
  DNS : (none)
────────────────────────────────

Wi-Fi switch — 등록된 네트워크 (↑↓ 이동, Enter 선택, Ctrl+R 새로고침, ESC/Ctrl+C 종료):
  ▶ Home  @ 84:78:48:80:70:68  192.168.0.77/255.255.255.0  gw=192.168.0.1  dns=8.8.8.8
    Office @ aa:bb:cc:dd:ee:ff  10.0.0.50/255.255.255.0  gw=10.0.0.1  dns=-
    + 새 네트워크 추가
    ↺ DHCP 로 초기화 (DNS 비움)
    종료
```

### 단축키 (모든 화면 공통)
| 키 | 동작 |
|---|---|
| ↑ ↓ | 항목 이동 |
| PgUp / PgDn | 페이지 이동 |
| Home / End | 처음 / 끝으로 |
| Enter | 확정 |
| **ESC** | 한 단계 뒤로 |
| **Ctrl+R** / Ctrl+L | 헤더 새로고침 |
| Ctrl+C | 전체 취소 (한 번 더 누르면 종료) |
| Backspace | 입력 행에서 한 글자 지움 |

### 새 네트워크 추가 (6 단계 마법사)
1. **Label** — 표시용 이름 (자유 입력, 예: `Home`)
2. **라우터 MAC 선택** — 최근 본 라우터 목록에서 선택하거나 직접 입력
   - 현재 연결된 네트워크는 `◀ 현재` 마커로 표시
   - 직접 입력 시 `xx:xx:xx:xx:xx:xx` 형식
3. **IP** — default 는 게이트웨이의 첫 3 옥텟 + `.100` (예: gw `192.168.0.1` → `192.168.0.100`)
4. **Subnet mask** — default `255.255.255.0`
5. **Router/Gateway** — picker 에서 선택했다면 그 게이트웨이, 직접 입력 시 `192.168.1.1`
6. **DNS** — default `8.8.8.8`. `-` 입력 시 비움

각 단계에서 **ESC = 이전 단계로**, **Ctrl+C = 전체 취소**.
Enter 만 누르면 default 값을 그대로 저장.

### 등록된 항목에 대한 동작
메인 TUI 에서 등록된 항목을 Enter 누르면 동작 메뉴:
- **이 설정 적용 (Wi-Fi 에 IP 반영)** — 현재 Wi-Fi 에 즉시 적용
- **수정 (IP 설정 변경)** — IP/Subnet/Router/DNS 4 단계 마법사 (현재값이 default 로 채워짐)
- **삭제** — 확인 다이얼로그 후 제거
- **취소**

### 메인 메뉴 특수 항목
- `+ 새 네트워크 추가` — 위 6 단계 마법사
- `↺ DHCP 로 초기화 (DNS 비움)` — 현재 Wi-Fi 를 DHCP 로 되돌리고 DNS 비움. 일시적으로 manual 설정에서 벗어나고 싶을 때 사용
- `종료` — 설치 완료, LaunchAgent 활성 상태로 셸 복귀

### 제거
```bash
./uninstall.sh
```
LaunchAgent 를 unload + 제거하고 Wi-Fi 를 DHCP 로 복원합니다.
`~/.wifi/` 의 config 와 로그는 그대로 보존 (완전 제거하려면 직접 `rm -rf ~/.wifi`).

---

## 동작 원리

### 자동 트리거 흐름
```
[Wi-Fi 변경 (join/leave/IP 갱신)]
        │
        ▼
  LaunchAgent (~/Library/LaunchAgents/com.user.wifi-switch.plist)
        │  WatchPaths 가 /etc/resolv.conf 등의 변경 감지
        ▼
  ~/.wifi/wifi-switch.sh
        │
        ▼
  default gateway 조회 (route get default)
  게이트웨이 MAC 조회 (ping + arp)
        │
        ▼
  config.json 의 networks_by_router_mac 에서 해당 MAC 조회
        │
   ┌────┴────┐
   ▼         ▼
 등록됨    미등록
   │         │
   ▼         ▼
 Manual    DHCP
 IP 적용   유지
```

### 파일 레이아웃
```
~/.wifi/
├── config.json              # 등록된 네트워크 매핑
├── seen.json                # 거쳐온 게이트웨이 학습 기록 (UI 후보용)
├── wifi-switch.sh           # 자동 전환 스크립트 (LaunchAgent 가 호출)
└── logs/
    └── wifi-switch.log      # 적용 이력

~/Library/LaunchAgents/
└── com.user.wifi-switch.plist
```

### `config.json` 스키마
```json
{
  "version": 2,
  "wifi_service": "Wi-Fi",
  "networks_by_router_mac": {
    "84:78:48:80:70:68": {
      "label":  "Home",
      "ip":     "192.168.0.77",
      "subnet": "255.255.255.0",
      "router": "192.168.0.1",
      "dns":    ["8.8.8.8", "1.1.1.1"]
    }
  }
}
```
키는 **소문자 정규화된 라우터 MAC**. 값의 키 순서는 `label → ip → subnet → router → dns`.

### `seen.json` (자동 누적)
`wifi-switch.sh` 가 실행될 때마다 현재 게이트웨이 MAC + IP + 시각이 누적됩니다.
설치 TUI 의 라우터 MAC picker 가 이 목록을 후보로 보여주기 때문에,
한 번이라도 거쳐간 네트워크는 다음 번에 직접 입력 없이 선택할 수 있습니다.

### Stale Manual 복구
이전 SSID 에서 Manual IP 가 적용된 채 다른 네트워크로 옮기면,
laptop 의 IP 가 새 네트워크의 서브넷과 안 맞아서 게이트웨이에 도달하지 못합니다.
이 경우 `wifi-switch.sh` 는:
1. `route get default` 와 ARP 로 게이트웨이 검출 시도
2. 실패하면 **DHCP 로 한 번 바운스**해서 새 네트워크의 게이트웨이를 학습
3. 새 라우터 MAC 으로 config 조회 → 등록되어 있으면 Manual 재적용, 없으면 DHCP 유지

### 핵심 명령
| 용도 | 명령 |
|---|---|
| Wi-Fi service MAC | `networksetup -getmacaddress "Wi-Fi"` |
| 현재 IP | `ifconfig en0` |
| 기본 게이트웨이 | `route -n get default` |
| 라우터 MAC | `arp -n <gateway>` |
| 현재 DNS | `networksetup -getdnsservers "Wi-Fi"` |
| 적용 모드 | `networksetup -getinfo "Wi-Fi"` (`DHCP Configuration` / `Manual Configuration`) |
| 고정 IP 적용 | `networksetup -setmanual "Wi-Fi" <ip> <mask> <router>` |
| DHCP 복원 | `networksetup -setdhcp "Wi-Fi"` |
| DNS 설정 | `networksetup -setdnsservers "Wi-Fi" <dns1> <dns2> ...` 또는 `empty` |

### LaunchAgent 정의
주요 키:
- `Label`: `com.user.wifi-switch`
- `ProgramArguments`: `/bin/bash ~/.wifi/wifi-switch.sh`
- `WatchPaths`: 네트워크 상태가 바뀔 때 갱신되는 5 개 파일 감시
- `RunAtLoad`: `true` — 부팅/로그인 직후 1 회 동기화
- `ThrottleInterval`: `5` — 연속 이벤트 폭주 방지
- 표준 출력/에러를 `~/.wifi/logs/wifi-switch.log` 로 리다이렉트

### TUI 설계
- **alt screen buffer** (`\033[?1049h/l`) 로 메인 셸 스크롤백 오염 방지
- **`stty -icanon -echo`** 로 control 문자(Ctrl+R/Ctrl+L) 가 tty line discipline 에 가로채이지 않고 read 까지 도달
- 모든 화면에 **현재 노트북 네트워크 상태 헤더** 자동 prepend → 변경 사항 즉시 확인 가능
- **WINCH (SIGWINCH)** 트랩으로 터미널 리사이즈 시 재계산/재그리기
- 콤보 입력 행 (`▶ Label > <typed>`) — 리스트와 직접 입력을 한 화면에서 전환

### 트러블슈팅
- **로그 확인**: `tail -f ~/.wifi/logs/wifi-switch.log`
- **수동 실행**: `bash ~/.wifi/wifi-switch.sh`
- **현재 적용된 모드 확인**: `networksetup -getinfo "Wi-Fi"`
- **LaunchAgent 상태**: `launchctl list | grep wifi-switch`
- **재설치**: 그냥 `./install.sh` 다시 실행 (idempotent)
