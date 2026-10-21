# Local Debug signing / 本地 Debug 签名

The project already names a local certificate, but did not include a creation workflow.
Use that same persistent self-signed identity. No paid Apple Developer account is needed.
The script does not create keys, change keychain trust, unlock keychains, or install apps.

工程已有本地证书名称，但原仓库没有创建流程。使用下列一次性设置，后续反复使用同一张证书；不需要付费 Apple Developer 账号。脚本不会替你创建私钥、修改信任或处理系统授权。

## 一次性创建证书

先运行 `security find-identity -v -p codesigning`。如果已有有效的 `macos-dock-cc Local Code Signing`，直接复用，**不要每次重新创建，也不要创建重名证书**。

1. 用 Spotlight 打开「钥匙串访问」(Keychain Access)，选择「登录」(login) 钥匙串。
2. 菜单「钥匙串访问 → 证书助理 → 创建证书…」。
3. 名称填写 **`macos-dock-cc Local Code Signing`**，身份类型选「自签名根证书」(Self Signed Root)，证书类型选「代码签名」(Code Signing)。
4. 勾选「让我覆盖默认值」。设置适合本机开发的有效期（例如 3650 天），密钥选择 RSA、至少 2048 位；其余保持代码签名用途的默认值，保存到 login 钥匙串。系统若要求密码或确认，由你手动完成。
5. 在「我的证书」中确认该证书可以展开，下面有对应的私钥。只有证书、没有私钥无法签名。
6. 双击证书，展开「信任」，将「代码签名」设为「始终信任」；其他用途保持默认。关闭窗口，并手动完成 macOS 要求的授权。不要将所有用途都设为信任，也不要关闭 Gatekeeper 或 SIP。
7. 再运行下面的检查。应看到证书列在有效身份中。如果没有，检查有效期、代码签名信任、私钥和 login 钥匙串是否已解锁；不要通过反复重建证书解决。

```bash
security find-identity -v -p codesigning
./Scripts/build_and_run.sh --check-signing
```

首次签名时钥匙串可能询问是否允许 `codesign` 使用私钥；请核对请求程序后手动允许。不使用允许任意程序访问私钥的设置。证书与私钥只留在本机钥匙串，不导出或提交进 Git。

## Build and run / 构建运行

需要完整 Xcode（含首次启动组件和已接受的许可），不是只有 Command Line Tools。
`xcodebuild -version` 应打印 Xcode 版本。如果选择了错误的开发目录，可仅对本次命令设置：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build_and_run.sh --build
```

```bash
./Scripts/build_and_run.sh --build     # 编译、签名和校验；不启动应用
./Scripts/build_and_run.sh             # 编译、签名，然后打开工作区中的 Debug 应用
./Scripts/build_and_run.sh --verify    # 同上，并检查该路径的进程是否出现
./Scripts/build_and_run.sh --debug     # 编译、签名后进入 LLDB；在 LLDB 中 run
```

产物：`build/DerivedData/Build/Products/Debug/macos-dock-cc-v2.app`。
构建日志：`/tmp/macos-dock-cc-v2-build.log`；签名日志：`/tmp/macos-dock-cc-v2-codesign.log`。
证书缺失时提前退出并给出指引，不静默退回 ad-hoc 签名。可通过 `LOCAL_SIGNING_IDENTITY="已有的本地证书名称"` 选择另一个持久身份；该覆盖同时用于 Xcode 和嵌套代码签名。直接从 Xcode 编译时，默认使用上述标准名称。

Debug 的 bundle ID 是 `com.caye.macosdockcc.v2.debug`；Release 保持 `com.caye.macosdockcc.v2`。
Debug 偏好设置使用独立的 defaults 域，因此首次运行会使用默认设置（包括任务条常驻）；验证自动隐藏前需在 Debug 应用中开启它。这个区分并不承诺所有 Application Support 文件也隔离。
脚本只停止当前 checkout 的 Debug 进程，不会停止正式安装版；为避免两条任务栏争用快捷键，验证前请自己退出正式版。
脚本不复制到 `/Applications`，不要为了验证 Debug 运行 `install_local_release.sh` 或 `package_release.sh`。正式发布签名、公证配置保持原样。

## 辅助功能权限

首次运行此 Debug 身份需要单独授权：「系统设置 → 隐私与安全性 → 辅助功能」，点 `+` 后使用 `⌘⇧G` 输入上述 `.app` 的完整路径，添加并开启，再退出重开 Debug 应用。按应用路径区分正式版和 Debug，显示名称可能相同。
同一证书、bundle ID 和产物路径下继续构建通常无需每次重新授权。换证书（即使名称一样）、更改 bundle ID 或移动应用后可能需要重新添加 Debug 记录；不要重置所有应用的 TCC 权限。正式安装版不复用这个 Debug 授权。

## 无证书时只验证编译

下面的命令**只用于编译验证**，不证明签名或辅助功能可用，也不启动应用。它使用独立产物目录，避免覆盖日常签名构建。

```bash
xcodebuild -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2 \
  -configuration Debug -derivedDataPath build/UnsignedValidation \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## English quick start

In Keychain Access, select the login keychain, then Certificate Assistant → Create a Certificate.
Use the exact name `macos-dock-cc Local Code Signing`, identity type **Self Signed Root**,
and certificate type **Code Signing**. Override defaults for a suitable lifetime (e.g. 3650 days),
use RSA with at least 2048 bits, and keep the code-signing defaults. Store it in login.
Confirm its private key is present under My Certificates. Set only its Code Signing trust to
Always Trust and complete any macOS authorization yourself. Reuse this identity; do not recreate
it each build or grant arbitrary programs private-key access.

Run `./Scripts/build_and_run.sh --check-signing`, then `--build` for build/sign/verify only,
or no arguments to open the Debug app. The script never installs into `/Applications`.
Debug has its own bundle ID/defaults and needs its own Accessibility grant: add the generated
`.app` in System Settings → Privacy & Security → Accessibility, enable it, and restart Debug.
Quit the official app manually before testing to avoid competing taskbars/hotkeys.
Release settings are unchanged. Without the certificate, use the unsigned command above only
for compilation; it does not verify signing, launch, or Accessibility.

References: [Apple: create self-signed certificates](https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac),
[Apple: code signing identity and self-signed development certificates](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html).
