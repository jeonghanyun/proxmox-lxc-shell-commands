# Helpful AI Settings

AI 코딩 도구 설정 스크립트 모음

## Claude Code YOLO Mode

### 설치
```bash
bash claude-yolo-enable.sh
source ~/.bashrc
```

### 사용법
```bash
claude "린트 오류 수정해줘"
claude "테스트 실행하고 실패하면 고쳐줘"
claude -c  # 대화형 모드
```

## Claude Code 프롬프트 예제

### 기본 작업
```
파일 정리해줘
테스트 돌려봐
빌드해봐
```

### 코드 수정
```
이 함수 리팩토링해줘
타입 에러 고쳐줘
주석 추가해줘
```

### Git 작업
```
변경사항 커밋해줘
PR 만들어줘
브랜치 정리해줘
```

### 분석/탐색
```
이 코드베이스 구조 설명해줘
에러 원인 찾아줘
성능 문제 분석해줘
```

### Proxmox LXC 스크립트 작업
```
[GitHub URL] LXC 스크립트 만들어줘. mailpit.sh 스타일로.
n8n 스크립트 업데이트해줘
포트 설정 바꿔줘
```

## 팁

- YOLO 모드는 권한 확인 없이 실행되므로 주의
- 중요 작업 전 백업 권장
- LXC 컨테이너 환경에서 사용 시 비교적 안전
