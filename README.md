# dependency-tend

**Language:** [English](#english) | [한국어](#korean)

---

<a id="english"></a>

## English

dependency-tend is a small macOS menu bar app for maintaining the packages scattered across your Mac.

dependency-tend brings Homebrew, global npm packages, Claude Code plugins/MCP servers,
Mac App Store apps, pipx/uv/Cargo tools, VS Code/Cursor extensions, and
pnpm/Yarn/Bun global packages into one menu bar surface.

It focuses on cautious maintenance:

- Shows direct dependencies by default, not every transitive package.
- Separates update checks from destructive cleanup actions.
- Classifies update risk before running commands.
- Only includes low-risk CLI/formula updates in automatic bulk updates.
- Keeps GUI apps, runtime tools, pinned packages, and major jumps behind explicit confirmation.

## Build And Run

```bash
swift test                     # Run the full test suite
swift run DependencyTend       # Development run, inherits the terminal PATH
./scripts/make-app.sh          # Build build/DependencyTend.app
open build/DependencyTend.app  # Verify behavior in the real GUI app environment
./scripts/release-qa.sh        # Non-destructive pre-release checks
```

Before a public release, run `./scripts/release-qa.sh`, then open the generated app
and manually check the main screens and update-check flow.

## Install, Update, Remove

```bash
./scripts/install-app.sh           # Build, replace /Applications/DependencyTend.app, relaunch
./scripts/install-app.sh --dry-run # Preview the install steps without copying files
rm -rf /Applications/DependencyTend.app
```

Use the same `./scripts/install-app.sh` command when updating the app. The script is
scoped to `DependencyTend.app`, quits the running app, copies the new bundle to a
staging path, validates it, replaces the installed app, and opens it again. If
validation fails during replacement, the cleanup path restores the previous app.

To validate an installed bundle without launching it:

```bash
./scripts/validate-app-bundle.sh /Applications/DependencyTend.app
```

The validator checks `Info.plist`, `CFBundleExecutable`, and whether the executable
exists, is non-empty, and is executable.

## Tool Discovery

When launched from Finder or Login Items, a `.app` does not inherit your terminal
shell `PATH`. dependency-tend does not read shell profiles. Instead, it checks known
absolute paths directly:

- Homebrew: `/opt/homebrew/bin`, `/usr/local/bin`
- User tools: `~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`
- Node managers: nvm, fnm, Volta, asdf, mise
- VS Code and Cursor app bundle CLI paths

## Project Layout

- `Sources/Engine`: UI-free core logic, adapters, risk classification, scanning, execution
- `Sources/AppCore`: testable view model and app orchestration without SwiftUI dependencies
- `Sources/DependencyTend`: SwiftUI `MenuBarExtra` app surface

## Display Policy

- The default list shows directly installed packages only. For Homebrew, this uses `brew leaves`.
- Transitive dependencies are hidden from the main list and automatic bulk updates.
- Dependency metadata is still kept for diagnostics and future advanced views.
- Badges, counts, and automatic bulk updates use direct packages only.
- The "include up-to-date" toggle can show directly installed packages that are already current.
- Row menus can ignore a package, snooze it for 30 days, or hide a source.
- Hidden packages and sources can be restored from the Sources view.

## Prune QA

Prune is destructive and intentionally separate from updates. Before release, verify at least:

```bash
swift test --filter PruneAdvisorTests
swift test --filter AppViewModelTests/testPruneSourceHealthMessagesExplainUnavailableInputs
swift test -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors --filter LivePruneIntegrationTests
TEND_LIVE_PRUNE=1 swift test --filter LivePruneIntegrationTests # Only when real npm trees are available
```

Expected behavior:

- Prune suggestions explain why an item is considered removable.
- Blocked items show a lock reason instead of a delete button.
- If npm/Homebrew data cannot be read, the app explains the limitation instead of claiming there is nothing to prune.
- After deletion, the recent-removal ledger shows a restore action.
- A successful restore removes the item from the ledger.
- Homebrew orphan cleanup via `brew autoremove` requires the separate `Run brew autoremove` confirmation.
- Hidden MCP/Claude rows still count as safety evidence for prune decisions.

## Risk Rules

| Condition | Risk | Update Policy |
|---|---|---|
| pinned / runtime | high | Disabled. Manual judgment required |
| major version jump | high | Individual confirmation required |
| cask / Mac App Store app | medium or higher | Individual confirmation required. Excluded from automatic bulk updates |
| minor version jump / unparsable version | medium | CLI/formula packages may be automatic candidates |
| patch version jump | low | CLI/formula packages may be automatic candidates |

The `Needs check` filter does not mean "high risk only." It shows anything that the
current `UpdatePolicy` requires the user to confirm before running, including casks,
Mac App Store apps, major jumps, and uncertain-risk packages.

## Launch At Login

Install the app first:

```bash
./scripts/install-app.sh
```

Then enable the login item from the app installed in `/Applications`. If you enable it
from a `build/` copy, macOS may keep pointing the login item at an old build artifact.

---

<a id="korean"></a>

## 한국어

dependency-tend는 맥에 흩어진 패키지들을 관리하는 작은 macOS 메뉴바 앱입니다.

dependency-tend는 Homebrew, npm 글로벌 패키지, Claude Code 플러그인/MCP 서버,
Mac App Store 앱, pipx/uv/Cargo 도구, VS Code/Cursor 확장, pnpm/Yarn/Bun 글로벌
패키지를 메뉴바에서 모아 보여줍니다.

핵심 방향은 조심스러운 관리입니다.

- 기본 화면은 직접 설치한 항목만 보여줍니다. 모든 하위 의존성을 늘어놓지 않습니다.
- 업데이트 확인과 파괴적인 정리 작업을 분리합니다.
- 명령을 실행하기 전에 업데이트 위험도를 분류합니다.
- 자동 일괄 업데이트에는 낮은 위험도의 CLI/formula 항목만 포함합니다.
- GUI 앱, runtime 도구, pinned 패키지, major 점프는 명시적인 확인 뒤에만 실행합니다.

## 빌드 / 실행

```bash
swift test                     # 전체 테스트
swift run DependencyTend       # 개발 실행, 터미널 PATH를 상속받음
./scripts/make-app.sh          # build/DependencyTend.app 생성
open build/DependencyTend.app  # 실제 GUI 앱 환경에서 동작 확인
./scripts/release-qa.sh        # 릴리스 전 비파괴 자동 점검
```

공개 릴리스 전에는 `./scripts/release-qa.sh`를 통과시킨 뒤, 생성된 앱을 직접 열어
주요 화면과 업데이트 확인 흐름을 점검합니다.

## 설치 / 업데이트 / 삭제

```bash
./scripts/install-app.sh           # 빌드, /Applications/DependencyTend.app 교체, 재실행
./scripts/install-app.sh --dry-run # 실제 복사 없이 수행할 작업만 확인
rm -rf /Applications/DependencyTend.app
```

앱을 갱신할 때도 같은 `./scripts/install-app.sh`를 다시 실행하면 됩니다. 스크립트는
`DependencyTend.app` 대상에만 설치하도록 범위를 제한하고, 실행 중인 앱을 종료한 뒤
새 번들을 staging 경로에 먼저 복사/검증한 다음 기존 앱을 교체하고 다시 엽니다.
교체 중 검증이 실패하면 이전 앱을 되돌리도록 rollback cleanup을 수행합니다.

설치 후 번들 형태만 확인하려면 다음 명령을 사용할 수 있습니다.

```bash
./scripts/validate-app-bundle.sh /Applications/DependencyTend.app
```

검증 스크립트는 `Info.plist`, `CFBundleExecutable` 값뿐 아니라 실제 실행 파일이
비어 있지 않고 실행 가능한지도 확인합니다.

## 도구 탐지

Finder나 로그인 항목으로 실행한 `.app`은 터미널 셸의 `PATH`를 상속받지 않습니다.
dependency-tend는 셸 프로필을 읽지 않고, 알려진 절대경로를 직접 확인합니다.

- Homebrew: `/opt/homebrew/bin`, `/usr/local/bin`
- 사용자 도구: `~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`
- Node 매니저: nvm, fnm, Volta, asdf, mise
- VS Code/Cursor 앱 번들 CLI 경로

## 구조

- `Sources/Engine`: UI 없는 코어 로직, 어댑터, 위험도, 스캐너, 실행기
- `Sources/AppCore`: SwiftUI 비의존 뷰모델과 앱 조립 로직
- `Sources/DependencyTend`: SwiftUI `MenuBarExtra` 앱 표면

## 표시 정책

- 기본 목록은 직접 설치한 패키지만 보여줍니다. Homebrew는 `brew leaves` 기준입니다.
- 하위 의존성은 기본 목록과 자동 일괄 업데이트 대상에서 숨깁니다.
- 의존성 메타데이터는 진단과 향후 고급 보기용으로 유지합니다.
- 뱃지, 카운트, 자동 일괄 업데이트는 직접 설치 항목 기준입니다.
- "최신 포함" 토글로 직접 설치된 최신 상태 항목까지 표시할 수 있습니다.
- 행 메뉴에서 패키지를 `무시`, `30일 숨김`, `소스 숨김` 처리할 수 있습니다.
- 숨긴 패키지/소스는 `소스` 화면에서 복원할 수 있습니다.

## 정리(Prune) QA

정리는 업데이트와 분리된 파괴적 동작입니다. 릴리스 전에는 최소한 아래 흐름을 확인합니다.

```bash
swift test --filter PruneAdvisorTests
swift test --filter AppViewModelTests/testPruneSourceHealthMessagesExplainUnavailableInputs
swift test -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors --filter LivePruneIntegrationTests
TEND_LIVE_PRUNE=1 swift test --filter LivePruneIntegrationTests # 실제 npm 트리 2개가 있을 때만
```

기대 동작:

- 정리 제안은 근거 문구를 보여줍니다.
- 차단 항목은 삭제 버튼 대신 잠금 사유를 보여줍니다.
- npm/Homebrew 데이터를 읽지 못하면 "잔재 없음"으로 단정하지 않고 제한 사유를 보여줍니다.
- 삭제 후 최근 삭제 장부에 복구 버튼이 생깁니다.
- 복구 성공 후 장부에서 해당 항목이 제거됩니다.
- `brew autoremove` 기반 고아 의존성 정리는 별도 확인 바에서 `brew autoremove 실행`을 눌러야 실행됩니다.
- 숨긴 MCP/Claude 항목도 정리 안전성 판단에는 계속 사용됩니다.

## 위험도 규칙

| 조건 | 위험도 | 업데이트 정책 |
|---|---|---|
| pinned / runtime | high | 버튼 비활성. 수동 판단 필요 |
| major 점프 | high | 개별 확인 필요 |
| cask / Mac App Store 앱 | medium 이상 | 개별 확인 필요. 자동 일괄 제외 |
| minor 점프 / 파싱 불가 | medium | CLI/formula는 자동 후보 |
| patch 점프 | low | CLI/formula는 자동 후보 |

상단 필터의 `확인 필요`는 단순히 high-risk만 뜻하지 않습니다. 현재 `UpdatePolicy`상
실행 전 확인이 필요한 항목, 즉 cask, Mac App Store 앱, major 점프, 위험도 불확실
항목을 보여줍니다.

## 로그인 자동 시작

먼저 설치합니다.

```bash
./scripts/install-app.sh
```

그 다음 `/Applications`에 설치된 앱에서 로그인 항목 토글을 켜야 합니다. `build/`
경로에서 켜면 macOS 로그인 항목이 빌드 산출물의 옛 경로를 가리킬 수 있습니다.
