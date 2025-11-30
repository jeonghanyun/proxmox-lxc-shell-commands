# LXC 스크립트 생성 프롬프트 작성 가이드

이 문서는 AI에게 Proxmox LXC 설치 스크립트를 만들어달라고 요청할 때 효과적인 프롬프트 작성 방법을 설명합니다.

## 📋 기본 프롬프트 템플릿

```
[프로젝트 GitHub URL 또는 이름]에 대한 Proxmox LXC 자동 설치 스크립트를 만들어줘.

필수 정보:
- 포트: [포트 번호들]
- 설치 방법: [공식 설치 방법 또는 URL]
- 리소스 요구사항: [CPU/메모리/디스크]

추가 요구사항:
- [특별한 설정이 있다면 명시]
```

## ✅ 좋은 프롬프트 예제

### 예제 1: Taskosaur (간단한 경우)

```
https://github.com/Taskosaur/Taskosaur 이 프로젝트에 대한 Proxmox LXC 설치 스크립트 만들어줘.

필수 정보:
- GitHub에서 프로젝트 정보 확인해서 포트랑 설치 방법 파악해줘
- Debian 12 기반으로 만들어줘
- 이 저장소 스타일 (proxmox-lxc-mailpit.sh)처럼 만들어줘

추가 요구사항:
- Container Notes에 접속 정보 자동 추가
- Systemd 서비스로 자동 시작되게
```

### 예제 2: 상세 정보를 알고 있는 경우

```
Grafana에 대한 Proxmox LXC 설치 스크립트 만들어줘.

필수 정보:
- 포트: Web UI 3000
- 설치 방법: 공식 APT 저장소 사용
- 리소스: CPU 2코어, 메모리 2GB, 디스크 10GB

추가 요구사항:
- Admin 초기 비밀번호는 환경 변수로 설정 가능하게
- SQLite 기본 DB 사용
- Container Notes에 초기 로그인 정보 포함
```

### 예제 3: 복잡한 서비스 (여러 컴포넌트)

```
GitLab CE에 대한 Proxmox LXC 설치 스크립트 만들어줘.

필수 정보:
- 포트: HTTP 80, HTTPS 443, SSH 22
- 설치 방법: https://about.gitlab.com/install/#debian
- 리소스: CPU 4코어, 메모리 8GB, 디스크 50GB

추가 요구사항:
- 외부 URL 환경 변수로 설정 (GITLAB_EXTERNAL_URL)
- SMTP 설정은 선택사항으로
- 초기 root 비밀번호 표시
- Container Notes에 GitLab 설정 파일 위치 포함
```

### 예제 4: Docker 기반 애플리케이션

```
Portainer에 대한 Proxmox LXC 설치 스크립트 만들어줘.

필수 정보:
- 포트: Web UI 9443 (HTTPS), Agent 8000
- 설치 방법: Docker 컨테이너로 실행
- 리소스: CPU 1코어, 메모리 512MB, 디스크 4GB

추가 요구사항:
- Docker와 Docker Compose 먼저 설치
- Portainer는 Docker 컨테이너로 실행
- 데이터 볼륨은 /var/lib/portainer에 마운트
- Container Notes에 초기 admin 설정 방법 포함
```

## ❌ 나쁜 프롬프트 예제

### 나쁜 예제 1: 정보 부족

```
Taskosaur 설치 스크립트 만들어줘
```

**문제점:**
- 어떤 플랫폼인지 불명확 (LXC? VM? Docker?)
- GitHub URL 없음
- 요구사항 없음
- 스타일 가이드 없음

### 나쁜 예제 2: 너무 모호함

```
좋은 모니터링 도구 추천하고 설치 스크립트 만들어줘
```

**문제점:**
- 구체적인 도구 명시 안됨
- 요구사항 불명확
- 용도가 애매함

### 나쁜 예제 3: 불가능한 요구

```
모든 프로그래밍 언어 지원하는 개발 환경 LXC 스크립트 만들어줘
```

**문제점:**
- 범위가 너무 광범위
- 현실적이지 않음
- 구체성 없음

## 🎯 프롬프트 작성 체크리스트

스크립트를 요청하기 전에 다음을 확인하세요:

### 필수 정보
- [ ] 프로젝트 이름 또는 GitHub URL
- [ ] 사용할 포트 번호들
- [ ] 공식 설치 방법 (또는 문서 링크)
- [ ] 기본 리소스 요구사항

### 선택 정보 (있으면 더 좋음)
- [ ] 환경 변수 설정이 필요한 항목
- [ ] 초기 설정 방법
- [ ] 데이터 저장 위치
- [ ] 보안 설정 (비밀번호, 키 등)
- [ ] 특별한 네트워크 요구사항

### 스타일 지정
- [ ] 기존 스크립트 스타일 따르기 원하는지
- [ ] Container Notes에 포함할 정보
- [ ] 특별한 출력 형식 요구사항

## 📝 실전 프롬프트 예제

### 1. Taskosaur 완전한 프롬프트

```
https://github.com/Taskosaur/Taskosaur 프로젝트의 Proxmox LXC 자동 설치 스크립트를 만들어줘.

먼저 해야 할 일:
1. GitHub 저장소 확인해서 다음 정보 파악:
   - 프로젝트가 무엇인지
   - 어떤 기술 스택 사용하는지 (Node.js, Python, Go 등)
   - 공식 설치 방법
   - 필요한 포트 번호
   - 의존성 및 요구사항

스크립트 요구사항:
- Debian 12 기반 LXC 컨테이너
- 이 저장소의 proxmox-lxc-mailpit.sh 스타일 따르기
- 템플릿 자동 감지 (하드코딩 금지)
- Systemd 서비스로 자동 시작 설정
- Container Notes에 다음 정보 포함:
  * 접속 URL 및 포트
  * 서비스 관리 명령어
  * 초기 설정 방법 (있다면)
  * 기본 사용 예제

리소스 기본값:
- CPU: 1-2 코어 (프로젝트 요구사항에 따라)
- Memory: 512MB-1GB (프로젝트 요구사항에 따라)
- Disk: 4-8GB (프로젝트 요구사항에 따라)

환경 변수로 커스터마이징 가능하게:
- CT_ID, CT_HOSTNAME
- CT_MEMORY, CT_CORES, CT_DISK_SIZE
- 애플리케이션별 포트 및 설정

파일명: proxmox-lxc-taskosaur.sh
```

### 2. 단계별 대화형 접근

```
Step 1: 정보 수집
-------------------
https://github.com/Taskosaur/Taskosaur 이 프로젝트 정보 먼저 조사해줘.
다음 정보를 찾아서 알려줘:
- 프로젝트 설명
- 사용 기술 (언어, 프레임워크)
- 설치 방법 (README 확인)
- 필요한 포트
- 의존성

[AI 응답 대기]

Step 2: 스크립트 생성
--------------------
알려준 정보 기반으로 Proxmox LXC 설치 스크립트 만들어줘.
- 이 저장소의 proxmox-lxc-mailpit.sh 참고해서
- Debian 12 기반으로
- Container Notes도 포함해서

[AI 응답 대기]

Step 3: 테스트 및 수정
--------------------
[실제 테스트 후 문제 발생 시]
이런 에러가 나는데 수정해줘: [에러 메시지]
```

## 🔍 프로젝트별 특성 파악 팁

### Node.js 프로젝트
```
확인 사항:
- package.json의 scripts 섹션
- 필요한 Node.js 버전
- npm start 또는 node 실행 명령어
- 환경 변수 (.env.example)
```

### Python 프로젝트
```
확인 사항:
- requirements.txt 또는 pyproject.toml
- 실행 명령어 (python app.py, uvicorn 등)
- 필요한 Python 버전
- 환경 변수
```

### Go 프로젝트
```
확인 사항:
- 바이너리 다운로드 URL (releases)
- 실행 파일 이름
- 설정 파일 위치
- 플래그 또는 환경 변수
```

### Docker 기반 프로젝트
```
확인 사항:
- docker-compose.yml 또는 docker run 명령어
- 볼륨 마운트 경로
- 포트 매핑
- 환경 변수
```

## 📚 추가 프롬프트 예제

### Home Assistant

```
Home Assistant에 대한 Proxmox LXC 설치 스크립트 만들어줘.

필수 정보:
- 포트: Web UI 8123
- 설치 방법: Python venv + pip install
- 공식 문서: https://www.home-assistant.io/installation/linux
- 리소스: CPU 2코어, 메모리 2GB, 디스크 16GB

추가 요구사항:
- Python 3.11+ 설치
- venv 환경에서 실행
- Systemd 서비스 user mode로 실행
- 설정 디렉토리: /home/homeassistant/.homeassistant
- Container Notes에 초기 접속 정보와 통합 방법 포함
- 자동 업데이트 명령어 포함
```

### n8n (Workflow Automation)

```
n8n에 대한 Proxmox LXC 설치 스크립트 만들어줘.

필수 정보:
- GitHub: https://github.com/n8n-io/n8n
- 포트: Web UI 5678
- 설치 방법: npm install -g n8n
- 리소스: CPU 2코어, 메모리 1GB, 디스크 8GB

추가 요구사항:
- Node.js LTS 버전 설치
- 데이터 디렉토리: /var/lib/n8n
- 환경 변수로 설정 가능:
  * N8N_BASIC_AUTH_USER
  * N8N_BASIC_AUTH_PASSWORD
  * N8N_HOST (기본: 0.0.0.0)
  * N8N_PORT (기본: 5678)
- Systemd 서비스로 실행
- Container Notes에 웹훅 URL 예제 포함
```

### Uptime Kuma (Monitoring)

```
Uptime Kuma에 대한 Proxmox LXC 설치 스크립트 만들어줘.

필수 정보:
- GitHub: https://github.com/louislam/uptime-kuma
- 포트: Web UI 3001
- 설치 방법: Node.js + npm run setup
- 리소스: CPU 1코어, 메모리 512MB, 디스크 4GB

추가 요구사항:
- Node.js 18+ 및 npm 설치
- Git으로 소스 클론
- /opt/uptime-kuma에 설치
- Systemd 서비스로 실행
- 데이터베이스: 내장 SQLite
- Container Notes에:
  * 초기 admin 계정 생성 방법
  * 모니터링 추가 방법
  * 알림 설정 예제
```

## 💡 프로 팁

### 1. 공식 문서 링크 제공
```
✅ 좋음: 공식 설치 문서: https://docs.example.com/install
❌ 나쁨: 어떻게든 설치해줘
```

### 2. 유사 프로젝트 참조
```
✅ 좋음: Mailpit 스크립트처럼 만들어줘 (같은 저장소에 있음)
❌ 나쁨: 그냥 스크립트 만들어줘
```

### 3. 단계별 확인
```
✅ 좋음: 먼저 GitHub 확인하고, 설치 방법 파악한 다음, 스크립트 만들어줘
❌ 나쁨: 바로 스크립트 만들어줘
```

### 4. 테스트 결과 공유
```
✅ 좋음: 이 에러 나는데: [전체 에러 로그]
❌ 나쁨: 안되는데?
```

## 🎓 학습 곡선

### 초급 (처음 사용)
```
1. 간단한 프로젝트 선택 (단일 바이너리, 포트 하나)
2. 완전한 정보 제공
3. 기존 스크립트 스타일 명시
4. 예제: Mailpit, Caddy, simple HTTP server
```

### 중급 (익숙해진 후)
```
1. 복잡한 설정이 있는 프로젝트
2. 여러 포트, 환경 변수 다수
3. 커스터마이징 요구
4. 예제: Grafana, n8n, Ghost
```

### 고급 (숙련자)
```
1. 다중 컴포넌트 프로젝트
2. 데이터베이스 통합
3. 보안 설정 복잡
4. 예제: GitLab, NextCloud, Keycloak
```

## 📖 추가 리소스

- [GUIDE.md](GUIDE.md) - LXC 스크립트 작성 가이드
- [template-script.sh](template-script.sh) - 템플릿 스크립트
- [proxmox-lxc-mailpit.sh](proxmox-lxc-mailpit.sh) - 완전한 예제

---

**작성 팁 요약:**

1. **명확한 정보 제공** - URL, 포트, 설치 방법
2. **기존 스타일 참조** - 저장소의 다른 스크립트 스타일 따르기
3. **단계별 접근** - 정보 수집 → 스크립트 생성 → 테스트
4. **구체적 요구사항** - 환경 변수, Notes 내용, 리소스
5. **에러 공유** - 문제 발생 시 전체 로그 제공

이 가이드를 따르면 AI가 정확하고 완전한 LXC 설치 스크립트를 만들어줄 수 있습니다! 🚀
