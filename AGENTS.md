# HomoLauncher 排障记录（MC 26.x 支持）

> 2026-08 排障历程：从「26.2/26.1.2 无法启动、下载中断报 file exists」到逐步修通。
> 写给后续维护者：这里记录了每个坑的根因、修法、以及可复用的诊断手段。

## 运行环境背景

- 设备：HUAWEI MatePad Edge，OpenHarmony 6.1。
- 游戏运行方式：JRE 以动态 hsp 加载（jre17/jre25），LWJGL 用内置定制 `lwjgl.jar` + GLFW stub natives；渲染器 MobileGlues/GL4ES/GLV4。
- 1.21.11（Java 21，LWJGL 3.3.3）原本可玩；26.1.2/26.2（Java 25，LWJGL 3.4.1）最初完全无法启动。

## 问题与修复历程

### 1. 下载中断报 "file exists"

- **根因**：HarmonyOS `fs.rename` 在目标已存在时报 `13900015 File exists`（不覆盖）。重试下载时版本 json（`expectedSize=0`，每次必重下）rename 到已存在文件；8 并发 worker 同时 `mkdir` 同一路径也会撞。
- **修复**（`entry/src/main/ets/core/MCDownloader.ets`）：rename 前先 `unlink` 已存在目标；`ensureParentDir` 对并发创建容错；失败清理 `.tmp` 残留。

### 2. 26.x 需要 LWJGL 3.4.x 新 API（最初的 NoSuchMethodError）

- **根因**：启动器始终把 `resfile/lwjgl.jar`（旧定制版）放在 classpath 最前，版本自带 lwjgl 被屏蔽。26.x 客户端引用了内置 jar 没有的 API。
- **修复**：Python 字节码补丁给 jar 补方法（脚本在 `.tmp_probe/patch_lwjgl.py`）：
  - `GLFW`：glfwSetPreeditCallback / glfwSetIMEStatusCallback（返回 null，MC 丢弃返回值）、glfwSetPreeditCursorRectangle（空操作）、glfwPlatformSupported（false）、glfwGetMonitorName（""）
  - `MemoryUtil.memFree(ByteBuffer/IntBuffer)`：**真实转发**到已有 `memFree(Buffer)`（纹理图集/中文字体路径，不能空操作）
  - `STBImageResize.nstbir_resize_uint8_linear`（stb_image_resize2 新 API）：用 `memByteBuffer` 包装指针后转发到旧 `stbir_resize_uint8`，语义与 1.21.x 一致
  - `TinyFileDialogs.tinyfd_messageBox(...I)I`：返回 0（仅崩溃对话框路径）
  - 新增 `GLFWPreeditCallbackI`、`GLFWIMEStatusCallbackI`、`SOFTSystemEventProcI` 接口与若干占位类（SAM 签名与官方逐字节一致）

### 3. 字节码补丁自身的两个坑（重要教训）

- **手工生成类的 `this_class`/`super_class` 索引指错**（指向 Utf8 项而非 Class 项）→ `ClassFormatError`，MC 设置键盘回调时崩。验证方法：本地 JRE `Class.forName` 加载。
- **手写方法带分支但没附 `StackMapTable`** → `VerifyError: Expecting a stackmap frame at branch target 50`。`nstbir_resize_uint8_linear` 里的 `ifeq`（bci 44，目标 50）需要 `same_frame(50)`。后果：`STBImageResize` 全类校验失败 → mipmap/纹理出不来 → **黑屏但游戏逻辑活着**（Netty 线程跑了 80+ 秒）。
- **教训**：手写字节码必须做加载级验证：`Class.forName(name, false, loader)`（initialize=false，走验证器但不跑 clinit）每个补丁类过一遍。

### 4. Vulkan 后端误探活

- **根因**：内置 `GLFWVulkan.glfwVulkanSupported()` 硬编码返回 true（`04 ac`），26.2 的 `VulkanBackend.checkBackendAvailable()` 于是真去创建 VulkanInstance/枚举设备；而 spvc（shader 编译）类在精简 jar 里不存在，且 Vulkan 实例与渲染器（MobileGlues/ZINK）在驱动层打架 → 时而黑屏、时而 native 崩溃（JVM↔JIT 递归至栈溢出/空指针）。
- **修复**：jar 中该方法改恒返 false（`04`→`03`）。MC 记录 "Vulkan is not supported" 后优雅回退 OpenGL（与 1.21.x 同路径）。

### 5. 动态库加载连环坑（鸿蒙命名空间）

游戏 JVM 在 `moduleNs_org.xbstudio.homl/jre25` 命名空间，平台库受限，逐个出现：

- **libopenal.so 缺 libOpenSLES.so**：系统 `/system/lib64/libOpenSLES.so` 存在但命名空间隔离（依赖闭包 77 库/22MB 无法打包）→ 编了 18KB 空桩打进 `launcher.har`（OpenSL 后端初始化失败 → OpenAL 回退空后端 = **无声可玩**）。
- **`java.library.path` 不含 hsp natives 目录**：LWJGL 按裸名 `dlopen("libopenal.so")` 在 default/ndk 命名空间 ENOENT → `JVMLauncher.ets` 增加 `-Djava.library.path` 和 `-Dorg.lwjgl.librarypath` 指向 natives 目录。
- **spvc Java 类缺失**：26.2 引导程序（`NativeLibrariesBootstrap`）无条件执行 `loadSpvc()` → 并入官方 lwjgl-spvc 3.3.3 全部 41 个类。
- **原生库名不匹配**：官方 `Spvc.<clinit>` 加载的是 `libspirv-cross.so`，包内只有 `libspirv-cross-c-shared.so`（渲染器用）→ 把包内**真实** SPIRV-Cross 库复制改名补一个（非空桩）。
- **libshaderc.so 缺组件**：上游只给了主库，缺 `libglslang.so.13`/`libSPIRV.so.13`/`libSPIRV-Tools-shared.so`；官方 LWJGL natives 是 glibc 版（本机 musl 不可用）→ 换空桩（shaderc 仅 Vulkan 路径用；MobileGlues 只依赖 `libspirv-cross-c-shared.so`，已确认）。

### 6. 可复用的诊断手段

- **JVM 异常事件直写文件**：`-Xlog:exceptions=debug:file=<下载目录>/exceptions.log`——主异常定位神器（注意 `downloadDir` 每个会话需 picker 初始化一次，`HomlViewModel.switchJre` 已处理）。
- **JVM 崩溃日志**：`-XX:ErrorFile=<下载目录>/hs_err.log`。
- **链接器日志**：`hilog -x | rg MUSL-LDSO`——看 errno（ENOENT 找不到 / ns accessible failed 被命名空间拦）、裸名搜索 vs 绝对路径、namespace 名。
- **崩溃转储**：`/data/log/faultlog/faultlogger/cppcrash-*.log`（含寄存器、maps、全部线程栈）。
- **本地复现**：解包 `jre25-ohos-arm64.tar.xz` → 全部 ELF 用 `binary-sign-tool sign -selfSign 1` 补签 → `OHOS_JAVA_HOME`/`OHOS_DL_DIR` 指向解包目录即可跑 JVM。局限：无 surface，GL 初始化之后的事复现不了；`ffi_closure_alloc` 在此 shell 环境必失败（设备上正常），不要误判。
- **jar 引用全量校验**：`.tmp_probe/check_refs.py`——把 MC 客户端全类对 `org.lwjgl` 的引用对着补丁后 jar 逐一解析（类存在 + 成员沿父类链可解析）。1.21.11 应保持 0 缺失（防回归）。

### 7. 当前残留/未解

- **声音**：无。OpenSL 桩回退空后端。真声音候选路径：OpenSL→OHAudio shim，或上游 OpenAL 加 OHAudio 后端；但 module ns 访问不到 libohaudio 的 `.z.so` 依赖链，估计需要走 bridge（应用主命名空间）转发 PCM。用户暂不需要。
- **Vulkan 后端**：不可用（已被 `glfwVulkanSupported=false` 屏蔽；启用需补齐 spvc native JNI glue + vk 扩展类）。
- **IME 预编辑**：不生效（桩返回 null），输入走旧的 char 回调。
- **MC 26.2 状态**：迭代修复中，最新失败点以 `下载/org.xbstudio.homl/exceptions.log` 为准。
