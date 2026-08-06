# HomoLauncher

HomoLauncher 是面向 HarmonyOS 的 Minecraft Java 版启动器。

## 快速开始

### 直接下载

不想配置本地构建环境时，可以直接前往 [Nightly Release](https://github.com/jerry-271828/HomoLauncher/releases/tag/nightly)。Nightly 同时提供完整 `*.app.zip`，以及 `HomoLauncher-jre17-*.zip`、`HomoLauncher-jre25-*.zip` 两种成对安装包：

- `*.app.zip` 解压后是包含 entry、jre17、jre25 的完整 App Pack，**只适用于能以同一证书签名所有内嵌模块，并把它们作为同一安装事务提交的工具**。
- 成对 ZIP 含同一次构建、同一 `versionCode` 的 entry HAP 与一个 JRE HSP。小白调试助手 3.1 应使用这种包；分别签名/安装时必须使用同一证书，并按 **HAP → HSP** 顺序操作。

Nightly 提供的 APP/HAP/HSP 均为**未签名**。已确认小白调试助手 3.1 会把 APP 拆开并先尝试安装 HSP；更新已有旧 entry 时会触发 `9568284 / install version not compatible`，因此不要在该工具中直接安装 APP，也无需为此重置证书/Profile。源码已改用 Bundle Manager 的 `createModuleContext` 获取已安装 HSP 的真实资源目录，安装或解压异常会返回实际错误，而不会再笼统误报“请安装 HSP”。

### 从源码构建

环境要求：

- DevEco Studio 6.0.2 Release，或兼容 `modelVersion 6.0.2` 的更新版本
- HarmonyOS compile SDK 26.0.0；target/compatible SDK 为 HarmonyOS 6.0.2（API 22）
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

需要生成包含 entry、jre17、jre25 的完整 APP 时执行：

```shell
hvigorw --mode project -p product=default -p buildMode=release assembleApp --no-daemon
```

如果更新过 `libs/launcher.har`，应先清理工程根目录的 `oh_modules` 以及 `libs/jre17`、`libs/jre25` 的 `oh_modules` 和 `build`，再重新同步依赖。`file:` 依赖的旧缓存可能继续把未签名 `.so` 打进 HSP。

仓库中的默认配置不包含个人证书、密码或本机 SDK 绝对路径，无需修改 `build-profile.json5` 即可生成未签名产物。主要输出位置为：

```text
entry/build/default/outputs/default/       # entry HAP
libs/jre17/build/default/outputs/default/  # jre17 HSP
libs/jre25/build/default/outputs/default/  # jre25 HSP
build/                                     # assembleApp 的 APP（递归查找 *.app）
```

## 本地签名

需要安装签名包时，请在 DevEco Studio 的 **Project Structure > Signing Configs** 中创建或选择自己的调试签名，再重新构建。entry HAP 与所选 JRE HSP 必须使用同一证书/Profile，并保持相同 `bundleName`、`versionCode`、`versionName` 与 API release type。

证书路径、密码和签名配置属于本机私有信息，请勿提交到仓库。仓库默认保留空的 `signingConfigs`，以保证不同开发环境可以直接打开和构建。

## 云端构建

推送到 `master` 后，[GitHub Actions](https://github.com/jerry-271828/HomoLauncher/actions/workflows/build-hap.yml) 会自动：

1. 拉取全部子模块并安装依赖。
2. 使用仓库中的可移植配置构建 release HAP、JRE HSP 和完整 APP。
3. 拒绝包含个人签名或本机绝对路径的工程配置。
4. 检查 LWJGL 增量补丁，以及 HAR 与最终 HSP 中的原生库签名和内容，拒绝陈旧依赖缓存。
5. 回读最终 HAP/HSP/APP，确认 bundle 身份、`versionCode` 和 entry/jre17/jre25 模块完整一致。
6. 检查 HAP 中是否存在会导致小白调试助手解析失败的零长度资源。
7. 生成按 JRE 配对的安装 ZIP，并更新 [`nightly` 预发行版](https://github.com/jerry-271828/HomoLauncher/releases/tag/nightly)。

## 小白调试助手兼容性

旧的云端构建包可能在选择文件时提示：

```text
RangeError (length): Invalid value: Valid value range is empty: -1
```

该问题与 HAP 文件名中的 `unsigned` 无关，原因是包内存在零长度资源值。当前源码已经修复，云端工作流也会在发布前自动检查这类资源；建议直接使用最新 Nightly 构建。

小白调试助手 3.1 对多模块 APP 的处理不是原子安装：它生成的模块队列会把 HSP 放在 entry HAP 前。设备已有较低版本 entry 时，先装较高版本 HSP 会报：

```text
code:9568284 error: install version not compatible
```

这不表示下载的 HAP/HSP 不是最新版本。请选择同一个 `HomoLauncher-jre*-*.zip` 中的两个文件，用同一证书/Profile 签名，先安装 HAP，成功后再安装 HSP。只有确认安装器会把所有模块作为同一事务提交时，才直接使用 APP。
