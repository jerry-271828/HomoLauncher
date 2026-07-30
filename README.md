# HomoLauncher

HomoLauncher 是面向 HarmonyOS 的 Minecraft Java 版启动器。

## 本地构建

环境要求：DevEco Studio 6.0.2 Release 或兼容 `modelVersion 6.0.2` 的更新版本，并安装 HarmonyOS API 26 SDK。

```shell
git clone --recurse-submodules https://github.com/jerry-271828/HomoLauncher.git
```

用 DevEco Studio 打开仓库根目录，等待项目同步完成，然后执行 **Build > Build Hap(s)/App(s) > Build Hap(s)**。默认配置不绑定任何个人证书或 SDK 绝对路径，可直接生成未签名 HAP：

```text
entry/build/default/outputs/default/
```

首次装机时，请在 DevEco Studio 的 **Project Structure > Signing Configs** 中创建或选择你自己的调试签名。签名文件路径和密码属于本机配置，不应提交到仓库。

## 云端构建

推送到 `master` 后，GitHub Actions 会自动构建未签名 HAP，并更新 `nightly` 预发行版。工作流会拒绝包含个人签名路径的工程配置，并检查 HAP 中是否存在会导致小白调试助手解析失败的零长度资源。
