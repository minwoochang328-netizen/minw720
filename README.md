# minw720

## NIKKE PC 런처 해킹(공급망 공격) 감염 점검 — `nikke-check.ps1`

2026년 11월 초에 알려진 **승리의 여신: NIKKE PC 런처 공급망 공격**에 내 PC가 당했는지 확인하는 **읽기 전용** PowerShell 점검 스크립트와 대응 안내입니다. 모바일(스마트폰) 버전은 이 사건과 무관합니다.

> 비공식 자료입니다. 내용은 보안 분석가 MotherSphere 의 공개 분석과 피해자 보고, 그리고 공개된 점검 도구 두 종을 바탕으로 정리했습니다. 이 글을 쓴 2026-11-04(KST) 시점에는 Level Infinite / SHIFT UP 의 공식 발표를 확인하지 못했습니다. 공식 공지가 나오면 그것을 우선하세요.

### 무슨 일이 있었나

| 날짜(GMT) | 일어난 일 |
|---|---|
| 2026-09-27 | 공격자가 Level Infinite CDN(`playerinfinite.com`)의 공식 JavaScript 파일 4개(`aegis-fix.min.js`, `images.7fec4c32.js`, `FeedList.feb647c9.js`, `vue-bucket.min.js`)에 코드를 심음. NIKKE PC 런처가 이 파일들을 불러옴 |
| 2026-10-24 ~ 11-03 | 심긴 코드가 `insightjs.com` 의 스크립트를 불러오고, **일부 실행에서** 원격 제어 에이전트(`insight.bundle`, LuaJIT)를 내려받아 런처 안에서 실행. 런처가 켜져 있는 동안 공격자는 임의 명령 실행, 파일 열람, 화면 캡처, 브라우저 저장 비밀번호·쿠키·토큰·SSH 키·암호화폐 지갑 수집이 가능. Windows 에서는 Chrome 이 불러오는 DLL 로 지속성 설치 |
| 2026-11-03 17:04~17:21 | Level Infinite 가 변조 파일 3개를 정상 파일로 교체. `FeedList.feb647c9.js` 는 10/28 원본은 교체됐으나 일부 CDN 서버가 변조본을 계속 제공 |
| 2026-11-03 18:31 | 공격자 서버(89.127.233.127) 응답 중단 |

**누가 위험한가:** 2026-10-24 이후(늦어도) NIKKE PC 런처를 한 번이라도 켠 Windows PC(Proton/Steam Deck 포함). 에이전트는 모든 실행에서 배포되지 않았고(한 PC는 19회 실행 중 3회), 어떤 명령이 실행됐는지는 로그에 남지 않습니다.

### 지금 바로 할 일 (점검 전에)

1. **NIKKE PC 런처를 끄고**, 공식 수정 발표 전까지 다시 켜지 마세요. 트레이(알림 영역)에 남아 있는 런처도 종료하세요.
2. 아래 스크립트로 점검하세요. **점검 전에는 캐시를 지우지 마세요.** `tbs_cache` 를 지우면 감염 흔적(`k2f.agent.state`)도 함께 사라집니다.
3. 점검이 끝난 뒤 런처를 다시 켤 일이 있으면 그 전에 `%APPDATA%\nikke_launcher\tbs_cache` 폴더를 지우세요.

### 점검 스크립트 실행

**준비:** 이 저장소의 [`nikke-check.ps1`](./nikke-check.ps1) 을 내려받아 바탕화면 등에 저장합니다. (GitHub 에서 파일을 열고 `Download raw file` 아이콘을 누르면 됩니다.)

**실행:** 시작 메뉴에서 `PowerShell` 을 열고(관리자 권한이면 다른 사용자 계정까지 확인됩니다) 아래를 입력합니다.

```powershell
cd $HOME\Desktop
```

```powershell
powershell -ExecutionPolicy Bypass -File .\nikke-check.ps1
```

파일을 마우스 오른쪽 버튼으로 눌러 **"PowerShell에서 실행"** 을 골라도 됩니다. 이 경우 결과를 읽을 수 있게 끝에서 Enter 를 기다립니다.

NIKKE 가 자동으로 찾는 위치(레지스트리 기록, 각 드라이브의 4단계 깊이, 사용자 폴더 3단계)에 없다면 설치 폴더를 직접 알려주세요. 여러 개는 쉼표로 구분합니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\nikke-check.ps1 -NikkePath "D:\Games\NIKKE"
```

드라이브 전체를 끝까지 훑으려면(느림) `-DeepScan` 을 붙입니다.

**결과:** 화면에 출력되고, 같은 내용이 `바탕화면\NIKKE_점검결과_날짜_시각.txt` 로 저장됩니다. 이 파일 내용을 그대로 붙여넣어 주시면 함께 해석할 수 있습니다. 보고서에는 사용자 이름·컴퓨터 이름·파일 경로가 들어가니 공개 게시 전에 확인하세요.

이 스크립트는 **파일을 삭제·수정하지 않고, 레지스트리와 hosts 파일을 바꾸지 않으며, 네트워크에 접속하지 않습니다.** 유일하게 쓰는 파일은 보고서 텍스트 파일입니다.

### 결과 해석

| 판정 | 뜻 | 종료 코드 |
|---|---|---|
| **감염 흔적 확인** | 에이전트가 내려받아졌거나 실행됐거나, 지속성(Chrome DLL / HKCU CLSID) 흔적이 있거나, 런처가 지금 실행 중. 이 PC는 침해된 것으로 간주 | 2 |
| **노출** | 런처가 악성 스크립트(insightjs.com 로더)를 불러오거나 접속한 흔적은 있지만, 에이전트가 실행된 흔적은 없음 | 1 |
| **흔적 없음** | 찾은 NIKKE 파일에서 흔적을 찾지 못함. 깨끗함의 증명은 아님 | 0 |
| **NIKKE 미발견** | 설치 폴더와 런처 데이터 폴더를 찾지 못함. `-NikkePath` 로 지정해 다시 실행 | 3 |

판정 아래에 발견 사항이 `[CRITICAL]` / `[WARNING]` / `[INFO]` 로 나열되고, 판정별 **해야 할 일**이 번호 순서로 출력됩니다.

### 판정별 대응 요약

**감염 흔적 확인**
1. 런처 종료, 인터넷 연결 끊기.
2. 보고서 파일 보관 → `%APPDATA%\nikke_launcher\tbs_cache` 삭제.
3. hosts 파일에 `0.0.0.0 insightjs.com`, `0.0.0.0 www.insightjs.com`, `0.0.0.0 analytics.insightjs.com`, `0.0.0.0 insightjs.org` 추가, 방화벽에서 `89.127.233.127` 과 `89.126.250.172` 차단.
4. Chrome 지속성이 발견됐으면: `HKCU\Software\Classes\CLSID\{E77CC89B-7401-4C04-8CED-149DB35ADD04}` 삭제 → **재부팅** → `%LOCALAPPDATA%\Google\Chrome\User Data\PlatformExperienceHelper\` 아래 **64자리 16진수 이름의 하위 폴더만** 삭제. (`HKLM` 의 같은 CLSID 는 Windows 정상 항목이고, `PlatformExperienceHelper` 폴더 자체도 Chrome 이 만드는 정상 폴더입니다.) Defender 가 이 DLL 을 잡지 못한 사례가 있습니다.
5. 가장 확실한 복구는 Windows 재설치입니다.
6. **깨끗한 기기(스마트폰 등)에서** 비밀번호 변경: NIKKE/Level Infinite → 이메일 → Discord → 금융 → 브라우저에 저장된 모든 비밀번호. 2단계 인증 켜기. 모든 서비스에서 "모든 세션 로그아웃"(훔친 쿠키는 비밀번호 없이 쓰입니다).
7. API 토큰·SSH 키·개발 도구 자격증명 폐기 후 재발급. 암호화폐는 새 시드 구문의 지갑으로 이동.

**노출** — 1~3번을 하고, 10월 24일 이후 런처를 켠 적이 있다면 6~7번도 하세요.

**흔적 없음 / 미발견** — 공식 발표 전까지 런처를 켜지 말고, 3번(차단)을 해 두세요. 10월 24일 이후 런처를 켰다면 NIKKE 비밀번호는 바꿔 두세요.

### 스크립트 없이 손으로 확인하는 세 가지

1. `NIKKE 설치 폴더\Launcher\intl_service\debug.log` 를 메모장으로 열고 `k2f_chan` 을 검색합니다. 있으면 에이전트가 실행된 것입니다. (NIKKE 를 지웠거나 재설치했다면 이 파일은 없습니다.)
2. PowerShell 에서 아래를 실행합니다. 키가 나오면 공격자가 만든 지속성입니다. (`HKLM` 쪽은 정상입니다.)

```powershell
reg query "HKCU\Software\Classes\CLSID\{E77CC89B-7401-4C04-8CED-149DB35ADD04}" /s
```

3. 탐색기 주소창에 `%LOCALAPPDATA%\Google\Chrome\User Data\PlatformExperienceHelper` 를 넣어 열고, **64자리 16진수 이름의 폴더** 안에 `platform_experience_helper.dll` 이 있는지 봅니다. `platform_experience_helper.exe` 와 `LoadFeatures` 만 있으면 정상입니다.

### 개발자라면 특히

에이전트의 수집 목록(264개 경로)에는 `~\.ssh`, `~\.claude\.credentials.json`, `%APPDATA%\Claude\claude_desktop_config.json`, `$CODEX_HOME\auth.json`(Codex CLI), GitHub CLI `hosts.yml`, VS Code/Cursor 의 `state.vscdb` 와 `mcp.json`, AWS/GCP/Azure 자격증명, npm/pip/Docker/Kubernetes 설정, PowerShell 명령 기록, 프로젝트 폴더의 `.env` 등이 들어 있습니다. 감염이 확인되면 GitHub 토큰, OpenAI/Anthropic API 키, Codex·Claude Code 로그인, SSH 키를 모두 폐기하고 새로 만드세요. 스크립트는 이 파일들의 **존재 여부만** 알려 주며 내용은 읽지 않습니다.

### 스크립트가 보는 것 / 못 보는 것

**보는 것:** `Launcher\intl_service\debug.log` 의 `k2f_chan`, `adopted`, `agent started as`, `lua downloaded to` 줄(크기 제한 없이 끝까지 읽음) · `Launcher\log\` 아래 LuaJIT 바이트코드(`1B 4C 4A`) 파일과 `insight.bundle` 다운로드 기록, 에이전트 빌드 ETag · `%APPDATA%\nikke_launcher*` 전체(Code Cache 의 `insightjs.com/l.js?f=…` 로더 항목, Local Storage 의 `k2f.agent.state`, Network Persistent State, HTTP 캐시의 변조/정상 파일 ETag) · Chrome 및 다른 Chromium 계열(Edge, Brave, Vivaldi, Whale, Opera 등) 프로필의 `PlatformExperienceHelper` 안 64자리 16진수 폴더와 `platform_experience_helper.dll` · `HKCU\…\CLSID\{E77CC89B-…}`(WOW6432Node, 다른 로그인 사용자 포함)와 브라우저 프로필 안 DLL 을 가리키는 다른 HKCU CLSID · `%TEMP%` 의 `k2f-*` 파일 · 실행 중인 `nikke_launcher`/`tbs_browser`, 열려 있는 `k2f` 명명 파이프, 로드된 악성 DLL · DNS 캐시와 현재 TCP 연결의 공격자 도메인/IP · hosts 차단 여부 · 다른 사용자 프로필(읽을 수 있을 때).

**못 보는 것:** 공격자가 실제로 어떤 명령을 실행했는지(로그에 남지 않음) · NIKKE 를 지우거나 재설치한 뒤의 `debug.log`/tinyget 기록 · 이미 삭제된 임시 파일(`k2f-bcreds-*`, `k2f_screen_*.jpg`) · 알려지지 않은 2차 악성코드. **아무것도 없다는 것이 깨끗함을 증명하지 않습니다.**

### 참고 자료

- 전체 분석(영문, 계속 갱신): https://gist.github.com/MotherSphere/d6c049a09ba8ac3085c51ee9df24a4e5
- 같은 분석가의 GUI 점검 도구(Windows/Linux/macOS, 읽기 전용): https://github.com/MotherSphere/NIKKE-Launcher-Check
- 한글 Python 점검 도구(증거 보존 ZIP 생성): https://github.com/Sheisback/nikke_malware_scanner
- 점검 + 단계별 확인 후 제거까지 해 주는 PowerShell 스크립트(영문): https://gist.github.com/neutralnikke/b7fcab99e8b64758f699f3bb8bdd14fd
- IOC 목록, YARA/Sigma 규칙, 공격 흐름도: https://github.com/whykusanagi/nikke_malware · 페이로드 정적 분석(중문/영문): https://github.com/WormW/nikke_malware_analysis
- 뉴스: https://www.invenglobal.com/articles/28099/nikke-pc-launcher-reportedly-hit-by-supply-chain-attack-no-statement-yet-from-level-infinite
- 커뮤니티 가이드: https://nikke.gg/how-to-check-if-your-pc-is-safe-from-nikke-infection/
