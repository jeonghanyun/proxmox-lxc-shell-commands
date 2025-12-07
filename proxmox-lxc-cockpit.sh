#!/bin/bash
# CT 10006 - plobin-cockpit 생성 스크립트
# 생성일: 2025-12-07

set -e

CT_ID=10006
CT_HOSTNAME="plobin-cockpit"
CT_CORES=2
CT_MEMORY=1024
CT_SWAP=512
CT_DISK_SIZE=8
CT_IP="dhcp"
CT_STORAGE="local-lvm"
TEMPLATE_STORAGE="local"

# 사용자 계정 설정
CT_USER="devops"
CT_PASSWORD="changeme123"

# 사용 가능한 Debian 템플릿 찾기
TEMPLATE=$(pveam list $TEMPLATE_STORAGE | grep -E "debian-12.*standard" | tail -1 | awk '{print $1}')

if [ -z "$TEMPLATE" ]; then
    echo "Debian 12 템플릿을 찾을 수 없습니다. 다운로드합니다..."
    pveam download $TEMPLATE_STORAGE debian-12-standard_12.7-1_amd64.tar.zst
    TEMPLATE="$TEMPLATE_STORAGE:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
fi

echo "=== CT $CT_ID ($CT_HOSTNAME) 생성 시작 ==="
echo "템플릿: $TEMPLATE"

# 컨테이너 생성
pct create $CT_ID $TEMPLATE \
    --hostname $CT_HOSTNAME \
    --cores $CT_CORES \
    --memory $CT_MEMORY \
    --swap $CT_SWAP \
    --storage $CT_STORAGE \
    --rootfs ${CT_STORAGE}:${CT_DISK_SIZE} \
    --net0 name=eth0,bridge=vmbr0,ip=$CT_IP \
    --ostype debian \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1

echo "=== CT $CT_ID 생성 완료 ==="

# 컨테이너 시작
echo "컨테이너 시작 중..."
pct start $CT_ID

# 시작 대기
sleep 5

# 사용자 계정 생성 및 sudo 권한 설정
echo "=== 사용자 계정 설정 중 ==="

# sudo 설치
pct exec $CT_ID -- apt update
pct exec $CT_ID -- apt install -y sudo

# 사용자 생성
pct exec $CT_ID -- useradd -m -s /bin/bash $CT_USER

# 비밀번호 설정
pct exec $CT_ID -- bash -c "echo '$CT_USER:$CT_PASSWORD' | chpasswd"

# sudo 그룹에 추가 (비밀번호 없이 sudo 사용 가능)
pct exec $CT_ID -- usermod -aG sudo $CT_USER
pct exec $CT_ID -- bash -c "echo '$CT_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$CT_USER"
pct exec $CT_ID -- chmod 440 /etc/sudoers.d/$CT_USER

# root 직접 로그인 비활성화 (선택사항 - 주석 해제시 적용)
# pct exec $CT_ID -- passwd -l root

echo "=== CT $CT_ID ($CT_HOSTNAME) 준비 완료 ==="
echo "사용자: $CT_USER"
echo "비밀번호: $CT_PASSWORD"
pct status $CT_ID
