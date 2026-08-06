# HomoLauncher

HomoLauncher 是面向 HarmonyOS 的 Minecraft Java 版启动器。

## 快速开始

### 直接下载

不想配置本地构建环境时，可以直接前往 [Nightly Release](https://github.com/jerry-271828/HomoLauncher/releases/tag/nightly) 下载 GitHub Actions 自动生成的 `.app`。APP 是包含 entry、jre17、jre25 的完整 App Pack，支持 APP 的安装工具可以在同一事务中完成签名和安装，避免分步安装时 HSP 模块丢失。

Nightly 提供的是**未签名 APP/HAP/HSP**。优先让安装工具直接处理 APP；对应 JRE 的成对 ZIP 仅用于不支持 APP 的工具。源码不再通过字符串替换猜测 HSP 资源目录，而是使用 Bundle Manager 的 `createModuleContext` 获取已安装模块，因此安装异常会返回实际错误码，不会再误报简单的“请安装 HSP”。

### 从源码构建

环境要求：

- DevEco Studio 6.0.2 Release，或兼容 `modelVersion 6.0.2` 的更新版本
- HarmonyOS API 26 SDK
- Git

克隆仓库及其子模块：

```shell
git clone --recurse-submodules https://github.com/jerry-271828/HomoLauncher.git
```

如果已经克隆过仓库，请补充初始化子模块：

```shell
git submodule update --init --recursive
```

随后用 DevEco Studio 打开仓库根目录，等待项目同步完成，然后执行：

**Build > Build Hap(s)/App(s) > Build Hap(s)**

JRE 是动态 HSP，还需要构建实际使用的模块（推荐 `jre25`）：

```shell
hvigorw --mode module -p module=jre25@default -p product=default -p buildMode=release assembleHsp --no-daemon
```

如果更新过 `libs/launcher.har`，应先清理工程根目录的 `oh_modules` 以及 `libs/jre17`、`libs/jre25` 的 `oh_modules` 和 `build`，再重新同步依赖。`file:` 依赖的旧缓存可能继续把未签名 `.so` 打进 HSP。

仓库中的默认配置不包含个人证书、密码或本机 SDK 绝对路径，无需修改 `build-profile.json5` 即可生成未签名 HAP。输出目录为：

```text
entry/build/default/outputs/default/
```

## 本地签名

需要安装签名包时，请在 DevEco Studio 的 **Project Structure > Signing Configs** 中创建或选择自己的调试签名，再重新构建。

证书路径、密码和签名配置属于本机私有信息，请勿提交到仓库。仓库默认保留空的 `signingConfigs`，以保证不同开发环境可以直接打开和构建。

## 云端构建

推送到 `master` 后，[GitHub Actions](https://github.com/jerry-271828/HomoLauncher/actions/workflows/build-hap.yml) 会自动：

1. 拉取全部子模块并安装依赖。
2. 使用仓库中的可移植配置构建 release HAP 和 JRE HSP。
3. 拒绝包含个人签名或本机绝对路径的工程配置。
4. 检查 HAR 与最终 HSP 中的原生库签名和内容是否一致，拒绝陈旧依赖缓存。
5. 检查 HAP 中是否存在会导致小白调试助手解析失败的零长度资源。
6. 更新 [`nightly` 预发行版](https://github.com/jerry-271828/HomoLauncher/releases/tag/nightly)。

## 小白调试助手兼容性

旧的云端构建包可能在选择文件时提示：

```text
RangeError (length): Invalid value: Valid value range is empty: -1
```

该问题与 HAP 文件名中的 `unsigned` 无关，原因是包内存在零长度资源值。当前源码已经修复，云端工作流也会在发布前自动检查这类资源；建议直接使用最新 Nightly 构建。
