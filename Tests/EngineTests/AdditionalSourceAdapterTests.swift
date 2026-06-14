import XCTest
@testable import Engine

final class AdditionalSourceAdapterTests: XCTestCase {
    func testMacAppStoreParsesInstalledAndOutdatedApps() async throws {
        let runner = MockCommandRunner()
        runner.stub("mas list", CommandOutput(stdout: """
        409201541 Pages (14.2)
        497799835 Xcode (15.4)
        """, stderr: "", exitCode: 0))
        runner.stub("mas outdated", CommandOutput(stdout: """
        497799835 Xcode (15.4 -> 15.4.1)
        """, stderr: "", exitCode: 0))
        let adapter = MacAppStoreAdapter(masURL: URL(fileURLWithPath: "/usr/local/bin/mas"), runner: runner)

        let scan = try await adapter.scan(now: Date())

        XCTAssertEqual(scan.packages.map(\.name), ["Pages", "Xcode"])
        let xcode = try XCTUnwrap(scan.packages.first { $0.name == "Xcode" })
        XCTAssertEqual(xcode.manager, .macAppStore)
        XCTAssertEqual(xcode.current, "15.4")
        XCTAssertEqual(xcode.latest, "15.4.1")
        XCTAssertEqual(xcode.status, .outdated)
        XCTAssertEqual(xcode.metadata["appID"], "497799835")
        XCTAssertEqual(xcode.metadata["packageURL"], "https://apps.apple.com/app/id497799835")
        XCTAssertEqual(adapter.updateCommand(for: xcode)?.arguments, ["upgrade", "497799835"])

        let pages = try XCTUnwrap(scan.packages.first { $0.name == "Pages" })
        XCTAssertEqual(pages.status, .upToDate)
    }

    func testPipxParsesInstalledPackagesAndOutdatedVersions() async throws {
        let runner = MockCommandRunner()
        runner.stub("pipx list --json", CommandOutput(stdout: """
        {
          "venvs": {
            "black": {
              "metadata": {
                "main_package": {
                  "package": "black",
                  "package_version": "24.4.2"
                }
              }
            },
            "httpie": {
              "metadata": {
                "main_package": {
                  "package": "httpie",
                  "package_version": "3.2.2"
                }
              }
            }
          }
        }
        """, stderr: "", exitCode: 0))
        runner.stub("pipx list --outdated --json", CommandOutput(stdout: """
        {
          "venvs": {
            "black": {
              "metadata": {
                "main_package": {
                  "package": "black",
                  "package_version": "24.4.2",
                  "latest_version": "24.8.0"
                }
              }
            }
          }
        }
        """, stderr: "", exitCode: 0))
        let adapter = PipxAdapter(pipxURL: URL(fileURLWithPath: "/usr/local/bin/pipx"), runner: runner)

        let scan = try await adapter.scan(now: Date())

        let black = try XCTUnwrap(scan.packages.first { $0.name == "black" })
        XCTAssertEqual(black.manager, .pipx)
        XCTAssertEqual(black.current, "24.4.2")
        XCTAssertEqual(black.latest, "24.8.0")
        XCTAssertEqual(black.status, .outdated)
        XCTAssertEqual(black.metadata["packageURL"], "https://pypi.org/project/black/")
        XCTAssertEqual(black.metadata["releaseNotesURL"], "https://pypi.org/project/black/#history")
        XCTAssertEqual(adapter.updateCommand(for: black)?.arguments, ["upgrade", "black"])
        XCTAssertEqual(scan.packages.first { $0.name == "httpie" }?.status, .upToDate)
    }

    func testUvToolParsesToolListAsUnknownUpdateCheckTargets() async throws {
        let runner = MockCommandRunner()
        runner.stub("uv tool list --show-paths", CommandOutput(stdout: """
        ruff v0.6.9
        - ruff
        black v24.8.0
        - black
        """, stderr: "", exitCode: 0))
        let adapter = UvToolAdapter(uvURL: URL(fileURLWithPath: "/usr/local/bin/uv"), runner: runner)

        let scan = try await adapter.scan(now: Date())

        XCTAssertEqual(scan.packages.map(\.name), ["black", "ruff"])
        let ruff = try XCTUnwrap(scan.packages.first { $0.name == "ruff" })
        XCTAssertEqual(ruff.manager, .uvTool)
        XCTAssertEqual(ruff.current, "0.6.9")
        XCTAssertEqual(ruff.status, .unknown)
        XCTAssertEqual(ruff.statusReason, .latestUnavailable)
        XCTAssertEqual(ruff.metadata["packageURL"], "https://pypi.org/project/ruff/")
        XCTAssertEqual(ruff.metadata["releaseNotesURL"], "https://pypi.org/project/ruff/#history")
        XCTAssertEqual(adapter.updateCommand(for: ruff)?.arguments, ["tool", "upgrade", "ruff"])
    }

    func testCargoInstallParsesInstalledCrates() async throws {
        let runner = MockCommandRunner()
        runner.stub("cargo install --list", CommandOutput(stdout: """
        ripgrep v14.1.1:
            rg
        cargo-edit v0.13.0:
            cargo-add
        """, stderr: "", exitCode: 0))
        let adapter = CargoInstallAdapter(cargoURL: URL(fileURLWithPath: "/usr/local/bin/cargo"), runner: runner)

        let scan = try await adapter.scan(now: Date())

        XCTAssertEqual(scan.packages.map(\.name), ["cargo-edit", "ripgrep"])
        let ripgrep = try XCTUnwrap(scan.packages.first { $0.name == "ripgrep" })
        XCTAssertEqual(ripgrep.manager, .cargoInstall)
        XCTAssertEqual(ripgrep.current, "14.1.1")
        XCTAssertEqual(ripgrep.status, .unknown)
        XCTAssertEqual(ripgrep.statusReason, .latestUnavailable)
        XCTAssertEqual(ripgrep.metadata["packageURL"], "https://crates.io/crates/ripgrep")
        XCTAssertEqual(ripgrep.metadata["docsURL"], "https://docs.rs/ripgrep")
        XCTAssertEqual(adapter.updateCommand(for: ripgrep)?.arguments, ["install", "ripgrep"])
    }

    func testEditorExtensionAdapterParsesExtensionsWithVersions() async throws {
        let runner = MockCommandRunner()
        runner.stub("code --list-extensions --show-versions", CommandOutput(stdout: """
        ms-python.python@2026.1.0
        esbenp.prettier-vscode@11.0.0
        """, stderr: "", exitCode: 0))
        let adapter = EditorExtensionAdapter(
            id: .vscodeExtensions,
            cliURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
            runner: runner)

        let scan = try await adapter.scan(now: Date())

        XCTAssertEqual(scan.packages.map(\.name), ["esbenp.prettier-vscode", "ms-python.python"])
        let python = try XCTUnwrap(scan.packages.first { $0.name == "ms-python.python" })
        XCTAssertEqual(python.current, "2026.1.0")
        XCTAssertEqual(python.status, .unknown)
        XCTAssertEqual(python.statusReason, .latestUnavailable)
        XCTAssertEqual(python.metadata["packageURL"],
                       "https://marketplace.visualstudio.com/items?itemName=ms-python.python")
        XCTAssertEqual(adapter.updateCommand(for: python)?.arguments,
                       ["--install-extension", "ms-python.python", "--force"])
    }

    func testCursorExtensionAdapterDoesNotAssumeVisualStudioMarketplace() async throws {
        let runner = MockCommandRunner()
        runner.stub("cursor --list-extensions --show-versions", CommandOutput(stdout: """
        open-vsx.only-extension@1.0.0
        """, stderr: "", exitCode: 0))
        let adapter = EditorExtensionAdapter(
            id: .cursorExtensions,
            cliURL: URL(fileURLWithPath: "/usr/local/bin/cursor"),
            runner: runner)

        let scan = try await adapter.scan(now: Date())

        let item = try XCTUnwrap(scan.packages.first)
        XCTAssertEqual(item.name, "open-vsx.only-extension")
        XCTAssertNil(item.metadata["packageURL"])
    }

    func testPnpmGlobalParsesDependencyJSON() async throws {
        let runner = MockCommandRunner()
        runner.stub("pnpm list -g --depth=0 --json", CommandOutput(stdout: """
        [{
          "dependencies": {
            "tsx": {"version": "4.20.6"},
            "@scope/tool": {"version": "1.2.3"}
          }
        }]
        """, stderr: "", exitCode: 0))
        let adapter = PnpmGlobalAdapter(pnpmURL: URL(fileURLWithPath: "/usr/local/bin/pnpm"), runner: runner)

        let scan = try await adapter.scan(now: Date())

        XCTAssertEqual(scan.packages.map(\.name), ["@scope/tool", "tsx"])
        let tsx = try XCTUnwrap(scan.packages.first { $0.name == "tsx" })
        XCTAssertEqual(tsx.current, "4.20.6")
        XCTAssertEqual(tsx.status, .unknown)
        XCTAssertEqual(tsx.statusReason, .latestUnavailable)
        XCTAssertEqual(tsx.metadata["packageURL"], "https://www.npmjs.com/package/tsx")
        XCTAssertEqual(adapter.updateCommand(for: tsx)?.arguments, ["add", "-g", "tsx@latest"])
    }

    func testYarnGlobalParsesClassicListOutput() async throws {
        let runner = MockCommandRunner()
        runner.stub("yarn global list --json", CommandOutput(stdout: """
        {"type":"info","data":"\\"typescript@5.9.3\\" has binaries:"}
        {"type":"info","data":"\\"@scope/tool@1.2.3\\" has binaries:"}
        """, stderr: "", exitCode: 0))
        let adapter = YarnGlobalAdapter(yarnURL: URL(fileURLWithPath: "/usr/local/bin/yarn"), runner: runner)

        let scan = try await adapter.scan(now: Date())

        XCTAssertEqual(scan.packages.map(\.name), ["@scope/tool", "typescript"])
        let typescript = try XCTUnwrap(scan.packages.first { $0.name == "typescript" })
        XCTAssertEqual(typescript.current, "5.9.3")
        XCTAssertEqual(typescript.status, .unknown)
        XCTAssertEqual(typescript.statusReason, .latestUnavailable)
        XCTAssertEqual(typescript.metadata["packageURL"], "https://www.npmjs.com/package/typescript")
        XCTAssertEqual(adapter.updateCommand(for: typescript)?.arguments, ["global", "add", "typescript@latest"])
    }

    func testBunGlobalReadsGlobalProjectManifest() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tend-bun-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let manifest = dir.appendingPathComponent("package.json")
        try Data("""
        {
          "dependencies": {
            "serve": "14.2.4",
            "@scope/tool": "1.0.0"
          }
        }
        """.utf8).write(to: manifest)
        let adapter = BunGlobalAdapter(bunURL: URL(fileURLWithPath: "/usr/local/bin/bun"),
                                       globalPackageJSON: manifest)

        let scan = try await adapter.scan(now: Date())

        XCTAssertEqual(scan.packages.map(\.name), ["@scope/tool", "serve"])
        let serve = try XCTUnwrap(scan.packages.first { $0.name == "serve" })
        XCTAssertEqual(serve.current, "14.2.4")
        XCTAssertEqual(serve.status, .unknown)
        XCTAssertEqual(serve.statusReason, .latestUnavailable)
        XCTAssertEqual(serve.metadata["packageURL"], "https://www.npmjs.com/package/serve")
        XCTAssertEqual(adapter.updateCommand(for: serve)?.arguments, ["add", "-g", "serve@latest"])
    }
}
