# Proxmox LXC 자동 설치 스크립트 작성 가이드

이 문서는 Proxmox VE에서 LXC 컨테이너 자동 설치 스크립트를 작성하는 방법을 다룹니다.
실제 Mailpit 스크립트 개발 과정에서 겪은 문제와 해결 방법을 기반으로 작성되었습니다.

## 📋 목차

1. [기본 구조](#기본-구조)
2. [템플릿 관리](#템플릿-관리)
3. [컨테이너 생성](#컨테이너-생성)
4. [소프트웨어 설치](#소프트웨어-설치)
5. [컨테이너 Notes 추가](#컨테이너-notes-추가)
6. [에러 처리](#에러-처리)
7. [베스트 프랙티스](#베스트-프랙티스)

---

## 기본 구조

### 스크립트 헤더

```bash
#!/usr/bin/env bash

# [서비스명] LXC Installation Script
# Description: [설명]
# OS: Debian 12 (Bookworm) - Auto-detected latest version
# Ports: [포트 목록]
# Repository: [GitHub URL]
# Last Updated: [날짜]

set -euo pipefail  # 에러 발생 시 즉시 종료
```

**중요 설정:**
- `set -e`: 에러 발생 시 스크립트 중단
- `set -u`: 미정의 변수 사용 시 에러
- `set -o pipefail`: 파이프라인 중 하나라도 실패하면 에러

### 환경 변수 설정

```bash
#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-200}                    # 기본값 200, 환경변수로 오버라이드 가능
CT_HOSTNAME=${CT_HOSTNAME:-"myapp"}
CT_CORES=${CT_CORES:-1}
CT_MEMORY=${CT_MEMORY:-512}            # MB 단위
CT_SWAP=${CT_SWAP:-512}
CT_DISK_SIZE=${CT_DISK_SIZE:-4}        # GB 단위

# Network Configuration
CT_IP=${CT_IP:-"dhcp"}                 # "dhcp" 또는 "192.168.1.100/24"
CT_GATEWAY=${CT_GATEWAY:-""}
CT_BRIDGE=${CT_BRIDGE:-"vmbr0"}
CT_NAMESERVER=${CT_NAMESERVER:-"8.8.8.8"}

# Storage Configuration
CT_STORAGE=${CT_STORAGE:-"local-lvm"}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-"local"}

# Debian Template (auto-detected)
DEBIAN_VERSION="12"
TEMPLATE_NAME=""                       # 자동 감지됨

# Application Configuration
APP_PORT=${APP_PORT:-8080}

# Container Options
CT_ONBOOT=${CT_ONBOOT:-1}
CT_UNPRIVILEGED=${CT_UNPRIVILEGED:-1}
CT_FEATURES=${CT_FEATURES:-"keyctl=1,nesting=1"}
```

### 컬러 출력 함수

```bash
#################################################################
# Color Output Functions
#################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}
```

---

## 템플릿 관리

### ❌ 잘못된 방법 (하드코딩)

```bash
# 이렇게 하면 안 됩니다!
TEMPLATE_NAME="debian-12-standard_12.7-1_amd64.tar.zst"

# 문제점:
# - 템플릿 버전이 업데이트되면 작동하지 않음
# - 12.7에서 12.8, 12.12 등으로 변경되면 실패
# - 에러: "400 Parameter verification failed. template: no such template"
```

### ✅ 올바른 방법 (자동 감지)

```bash
detect_and_download_template() {
    info "Updating template database..."

    # 1. 템플릿 데이터베이스 업데이트 (필수!)
    if ! pveam update 2>&1 | grep -q "update successful\|already up to date"; then
        warn "Template database update encountered issues, continuing anyway..."
    fi

    info "Detecting available Debian ${DEBIAN_VERSION} template..."

    # 2. 사용 가능한 최신 템플릿 자동 감지
    local available_template
    available_template=$(pveam available --section system 2>/dev/null | \
                        grep "debian-${DEBIAN_VERSION}" | \
                        grep "standard" | \
                        tail -1 | \
                        awk '{print $2}')

    if [[ -z "$available_template" ]]; then
        error "No Debian ${DEBIAN_VERSION} template found"
        info "Troubleshooting steps:"
        info "  1. Check DNS: cat /etc/resolv.conf"
        info "  2. Test connectivity: ping -c 3 download.proxmox.com"
        info "  3. Manual check: pveam available --section system | grep debian"
        exit 1
    fi

    TEMPLATE_NAME="$available_template"
    info "Found template: $TEMPLATE_NAME"

    # 3. 이미 다운로드되어 있는지 확인
    if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
        success "Template already downloaded"
        return 0
    fi

    # 4. 템플릿 다운로드
    warn "Downloading Debian template (this may take a few minutes)..."
    if pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" 2>&1; then
        success "Template downloaded successfully"
    else
        error "Failed to download template"
        info "Common fixes:"
        info "  1. Add DNS: echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
        info "  2. Check internet: curl -I https://download.proxmox.com"
        info "  3. Check storage: df -h"
        exit 1
    fi
}
```

### 핵심 포인트

1. **`pveam update` 필수**: 템플릿 목록을 최신화
2. **`--section system`**: 시스템 템플릿만 필터링
3. **자동 감지**: 하드코딩된 버전 번호 사용 금지
4. **에러 처리**: 각 단계마다 실패 시 유용한 메시지 제공

---

## 컨테이너 생성

### 기본 컨테이너 생성

```bash
create_container() {
    info "Creating LXC container $CT_ID ($CT_HOSTNAME)..."

    # 네트워크 설정 구성
    local net_config="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"

    # Static IP인 경우 게이트웨이 추가
    if [[ "$CT_IP" != "dhcp" ]] && [[ -n "$CT_GATEWAY" ]]; then
        net_config="${net_config},gw=${CT_GATEWAY}"
    fi

    # 컨테이너 생성
    pct create "$CT_ID" \
        "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_DISK_SIZE}" \
        --net0 "$net_config" \
        --nameserver "$CT_NAMESERVER" \
        --onboot "$CT_ONBOOT" \
        --unprivileged "$CT_UNPRIVILEGED" \
        --features "$CT_FEATURES" \
        --ostype debian || {
            error "Failed to create container"
            exit 1
        }

    success "Container $CT_ID created successfully"
}
```

### 컨테이너 시작

```bash
start_container() {
    info "Starting container $CT_ID..."

    pct start "$CT_ID" || {
        error "Failed to start container"
        exit 1
    }

    # 컨테이너가 완전히 시작될 때까지 대기
    info "Waiting for container to boot..."
    sleep 5

    success "Container started successfully"
}
```

### pct create 주요 옵션

| 옵션 | 설명 | 예시 |
|------|------|------|
| `--hostname` | 컨테이너 호스트명 | `myapp` |
| `--cores` | CPU 코어 수 | `1`, `2`, `4` |
| `--memory` | RAM (MB) | `512`, `1024`, `2048` |
| `--swap` | Swap (MB) | `512` |
| `--rootfs` | 루트 파일시스템 크기 | `local-lvm:4` (4GB) |
| `--net0` | 네트워크 설정 | `name=eth0,bridge=vmbr0,ip=dhcp` |
| `--nameserver` | DNS 서버 | `8.8.8.8` |
| `--onboot` | 부팅 시 자동 시작 | `1` (yes), `0` (no) |
| `--unprivileged` | 비특권 컨테이너 | `1` (권장) |
| `--features` | 추가 기능 | `keyctl=1,nesting=1` |
| `--ostype` | OS 타입 | `debian`, `ubuntu` |

---

## 소프트웨어 설치

### 패키지 설치 (apt)

```bash
install_application() {
    info "Installing [application] in container $CT_ID..."

    # 1. 패키지 목록 업데이트
    info "Updating package list..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"

    # 2. 필수 패키지 설치
    info "Installing required packages..."
    pct exec "$CT_ID" -- bash -c \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates wget"

    success "Packages installed successfully"
}
```

### 바이너리 설치 (curl/wget)

```bash
install_binary() {
    info "Downloading and installing binary..."

    # curl을 통한 설치 스크립트 실행
    pct exec "$CT_ID" -- bash -c \
        "curl -sL https://example.com/install.sh | bash" || {
        error "Failed to install binary"
        exit 1
    }

    success "Binary installed successfully"
}
```

### Systemd 서비스 설정

```bash
configure_service() {
    info "Configuring systemd service..."

    # 서비스 파일 생성
    pct exec "$CT_ID" -- bash -c "cat > /etc/systemd/system/myapp.service <<'EOF'
[Unit]
Description=My Application
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/myapp --port ${APP_PORT}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF"

    # Systemd 재로드 및 서비스 활성화
    pct exec "$CT_ID" -- bash -c "systemctl daemon-reload"
    pct exec "$CT_ID" -- bash -c "systemctl enable myapp"
    pct exec "$CT_ID" -- bash -c "systemctl start myapp"

    # 서비스 시작 대기
    sleep 3

    # 서비스 상태 확인
    if pct exec "$CT_ID" -- bash -c "systemctl is-active --quiet myapp"; then
        success "Service configured and started"
    else
        error "Service failed to start"
        pct exec "$CT_ID" -- bash -c "systemctl status myapp"
        exit 1
    fi
}
```

---

## 컨테이너 Notes 추가

### Notes에 접속 정보 자동 저장

```bash
add_container_notes() {
    info "Adding container notes with access information..."

    # IP 주소 가져오기
    local container_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        sleep 3
        container_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
        if [[ -z "$container_ip" ]]; then
            container_ip="[DHCP - check after boot]"
        fi
    else
        container_ip="${CT_IP%/*}"  # CIDR 표기 제거
    fi

    # Notes 내용 생성
    local notes="[APPLICATION NAME]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

🌐 APPLICATION ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Web UI:          http://${container_ip}:${APP_PORT}
API Endpoint:    http://${container_ip}:${API_PORT}

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status:          pct exec ${CT_ID} -- systemctl status myapp
Start:           pct exec ${CT_ID} -- systemctl start myapp
Stop:            pct exec ${CT_ID} -- systemctl stop myapp
Restart:         pct exec ${CT_ID} -- systemctl restart myapp
Logs:            pct exec ${CT_ID} -- journalctl -u myapp -f

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

ℹ️  AUTO-GENERATED BY: [GitHub Repository URL]"

    # Notes 설정
    if pct set "$CT_ID" -description "$notes" 2>/dev/null; then
        success "Container notes added successfully"
    else
        warn "Failed to add container notes (not critical)"
    fi
}
```

### Notes 설정의 이점

- ✅ Proxmox UI에서 바로 접속 정보 확인 가능
- ✅ 복사-붙여넣기로 명령어 실행 가능
- ✅ 팀원들과 정보 공유 용이
- ✅ 나중에 다시 찾아보기 쉬움

---

## 에러 처리

### 사전 검증 함수

```bash
#################################################################
# Validation Functions
#################################################################

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

check_proxmox() {
    if ! command -v pct &> /dev/null; then
        error "This script must be run on a Proxmox VE host"
        exit 1
    fi
}

check_container_exists() {
    if pct status "$CT_ID" &> /dev/null; then
        error "Container ID $CT_ID already exists"
        info "Please choose a different CT_ID or remove the existing container"
        info "To remove: pct destroy $CT_ID"
        exit 1
    fi
}

check_network() {
    info "Checking network connectivity..."

    if ! ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        warn "No internet connectivity detected"
        info "This may cause template download to fail"
    fi
}
```

### 에러 메시지 Best Practice

```bash
# ❌ 나쁜 예
error "Failed"

# ✅ 좋은 예
error "Failed to download template"
info "Common fixes:"
info "  1. Check DNS configuration: cat /etc/resolv.conf"
info "  2. Test connectivity: ping -c 3 download.proxmox.com"
info "  3. Check storage: df -h"
```

---

## 베스트 프랙티스

### 1. Main 함수 구조

```bash
#################################################################
# Main Execution
#################################################################

main() {
    info "Starting [Application] LXC container creation..."
    echo ""

    # Pre-flight checks
    check_root
    check_proxmox
    check_container_exists
    check_network
    detect_and_download_template

    # Create and configure container
    create_container
    start_container

    # Install and configure application
    install_application
    configure_service

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
```

### 2. 정보 출력

```bash
display_info() {
    local container_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        container_ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
    else
        container_ip="${CT_IP%/*}"
    fi

    echo ""
    echo "================================================================="
    success "[Application] LXC Container Setup Complete!"
    echo "================================================================="
    echo ""
    info "💡 All access information has been saved to container Notes"
    info "   View in Proxmox UI: Select container → Summary → Notes"
    echo ""
    echo "Quick Access:"
    echo "  • Web UI:     http://${container_ip}:${APP_PORT}"
    echo "  • SSH:        ssh root@${container_ip}"
    echo "  • Console:    pct enter ${CT_ID}"
    echo ""
    echo "================================================================="
}
```

### 3. 환경 변수 사용

```bash
# 기본값 설정
CT_ID=${CT_ID:-200}
CT_MEMORY=${CT_MEMORY:-512}

# 사용자가 환경 변수로 오버라이드 가능
# CT_ID=300 CT_MEMORY=1024 bash script.sh
```

### 4. stderr 리다이렉션

```bash
# 불필요한 에러 메시지 숨기기
pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"

# 중요한 명령어는 에러도 표시
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" 2>&1
```

### 5. 대기 시간

```bash
# 컨테이너 부팅 대기
sleep 5

# DHCP IP 할당 대기
sleep 3

# 서비스 시작 대기
sleep 3
```

---

## 일반적인 문제 해결

### 문제 1: 템플릿 다운로드 실패

**증상:**
```
400 Parameter verification failed.
template: no such template
```

**원인:**
1. 템플릿 데이터베이스가 업데이트되지 않음
2. 하드코딩된 템플릿 버전이 더 이상 존재하지 않음
3. DNS 문제

**해결:**
```bash
# 1. 템플릿 DB 업데이트
pveam update

# 2. 사용 가능한 템플릿 확인
pveam available --section system | grep debian-12

# 3. DNS 설정 확인
cat /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
```

### 문제 2: GitHub Raw 캐시

**증상:**
- 스크립트를 수정했는데 이전 버전이 실행됨

**해결:**
```bash
# 타임스탬프를 쿼리 파라미터로 추가
wget -O /tmp/script.sh "https://raw.githubusercontent.com/user/repo/master/script.sh?$(date +%s)"
bash /tmp/script.sh
```

### 문제 3: 컨테이너 IP 가져오기 실패

**증상:**
- DHCP 사용 시 IP 주소를 가져오지 못함

**해결:**
```bash
# 충분한 대기 시간 추가
sleep 3

# 여러 방법 시도
container_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$container_ip" ]]; then
    container_ip=$(pct exec "$CT_ID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
fi
```

---

## 템플릿 스크립트

완전한 템플릿은 `template-script.sh`를 참고하세요.

### 빠른 시작

1. **템플릿 복사**
   ```bash
   cp template-script.sh my-app-lxc.sh
   ```

2. **변수 수정**
   - Container configuration
   - Application configuration
   - Port numbers

3. **함수 구현**
   - `install_application()`
   - `configure_service()`
   - `add_container_notes()`

4. **테스트**
   ```bash
   bash my-app-lxc.sh
   ```

---

## 참고 자료

### Proxmox 문서
- [Linux Container](https://pve.proxmox.com/wiki/Linux_Container)
- [pct 매뉴얼](https://pve.proxmox.com/pve-docs/pct.1.html)
- [pveam 매뉴얼](https://pve.proxmox.com/pve-docs/pveam.1.html)

### 예제 스크립트
- [Mailpit LXC Script](./proxmox-lxc-mailpit.sh) - 완전한 구현 예제

### 커뮤니티
- [Proxmox Forum](https://forum.proxmox.com/)
- [Proxmox Reddit](https://www.reddit.com/r/Proxmox/)

---

## 기여하기

이 가이드를 개선하는 데 도움을 주세요:

1. Fork the repository
2. 가이드 업데이트
3. Pull request 생성

---

**작성자**: Based on real-world experience developing Mailpit LXC script
**최종 업데이트**: 2025-11-30
**라이센스**: MIT
