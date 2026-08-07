# HomoLauncher 排障记录（MC 26.x 支持）

> 2026-08 排障历程：从「26.2/26.1.2 无法启动、下载中断报 file exists」到 26.2 主启动链路已经打通；当前仍有渲染与功能残留。
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
- **修复**：Python 字节码补丁给 jar 补方法。最初的一次性全量脚本位于本地未跟踪的 `.tmp_probe/patch_lwjgl.py`；当前仓库已跟踪的可复现增量补丁与 CI 校验入口是 `scripts/patch-lwjgl-runtime.py`（目前负责 GL unpack 状态、STB stride，以及屏蔽 `ARB_buffer_storage` / `ARB_direct_state_access` / `ARB_vertex_attrib_binding` 三个现代 GL 快路径，不能当作从原版 jar 重建全部历史补丁的脚本）：
  - `GLFW`：glfwSetPreeditCallback / glfwSetIMEStatusCallback（返回 null，MC 丢弃返回值）、glfwSetPreeditCursorRectangle（空操作）、glfwPlatformSupported（false）、glfwGetMonitorName（""）
  - `GLFW.glfwGetInputMode`：恒返 0，避免 26.2 查询新增 `GLFW_IME` 键时因旧 Map 无此键而 NPE；仅表示 IME 模式不支持，不等于预编辑已实现
  - `MemoryUtil.memFree(ByteBuffer/IntBuffer)`：**真实转发**到已有 `memFree(Buffer)`（纹理图集/中文字体路径，不能空操作）
  - `STBImageResize.nstbir_resize_uint8_linear`（stb_image_resize2 新 API）：用 `memByteBuffer` 包装指针后转发到旧 `stbir_resize_uint8`，语义与 1.21.x 一致
  - `TinyFileDialogs.tinyfd_messageBox(...I)I`：返回 0（仅崩溃对话框路径）
  - 新增 `GLFWPreeditCallbackI`、`GLFWIMEStatusCallbackI`、`SOFTSystemEventProcI` 接口与若干占位类（SAM 签名与官方逐字节一致）

### 3. 字节码补丁自身的坑（重要教训）

- **手工生成类的 `this_class`/`super_class` 索引指错**（指向 Utf8 项而非 Class 项）→ `ClassFormatError`，MC 设置键盘回调时崩。验证方法：本地 JRE `Class.forName` 加载。
- **手写方法带分支但没附 `StackMapTable`** → `VerifyError: Expecting a stackmap frame at branch target 50`。`nstbir_resize_uint8_linear` 里的 `ifeq`（bci 44，目标 50）需要 `same_frame(50)`。后果：`STBImageResize` 全类校验失败 → mipmap/纹理出不来 → **黑屏但游戏逻辑活着**（Netty 线程跑了 80+ 秒）。
- **用短方法覆盖旧方法时只在 `ireturn` 后填 NOP** → 仍可能因不可达字节码触发 `VerifyError`。`glfwGetInputMode` 最终通过同步缩短 `Code` 属性到真实的 2 字节方法体修复。
- **把 STB 的 `stride=0` 当成零长度** → `memByteBuffer` 得到 0 容量并在自动截图/缩略图路径触发 `checkBuffer` IAE。0 实际表示 packed，包装大小应为 `max(stride, width * channels) * height`。
- **教训**：手写字节码必须做加载级验证：`Class.forName(name, false, loader)`（initialize=false，走验证器但不跑 clinit）每个补丁类过一遍；提交前还要执行 `python3 scripts/patch-lwjgl-runtime.py --check`，防止 jar 与可复现补丁脚本漂移。

### 4. Vulkan 后端误探活

- **根因**：内置 `GLFWVulkan.glfwVulkanSupported()` 硬编码返回 true（`04 ac`），26.2 的 `VulkanBackend.checkBackendAvailable()` 于是真去创建 VulkanInstance/枚举设备；而 spvc（shader 编译）类在精简 jar 里不存在，且 Vulkan 实例与渲染器（MobileGlues/ZINK）在驱动层打架 → 时而黑屏、时而 native 崩溃（JVM↔JIT 递归至栈溢出/空指针）。
- **修复**：jar 中该方法改恒返 false（`04`→`03`）。MC 记录 "Vulkan is not supported" 后优雅回退 OpenGL（与 1.21.x 同路径）。

### 5. 动态库加载连环坑（鸿蒙命名空间）

游戏 JVM 在 `moduleNs_org.xbstudio.homl/jre25` 命名空间，平台库受限，逐个出现：

- **libopenal.so 缺 libOpenSLES.so**：系统 `/system/lib64/libOpenSLES.so` 存在但命名空间隔离（依赖闭包 77 库/22MB 无法打包）→ 编了 18KB 空桩打进 `launcher.har`。当时按 OpenSL 后端初始化失败推断会回退空后端；最新实机反馈已经能听到声音，说明实际运行时仍选中了可输出路径。具体 OpenAL 后端、音乐/音效覆盖与长时间稳定性尚未确认，不再把“无声”视为已知结论。
- **`java.library.path` 不含 hsp natives 目录**：LWJGL 按裸名 `dlopen("libopenal.so")` 在 default/ndk 命名空间 ENOENT → `JVMLauncher.ets` 增加 `-Djava.library.path` 和 `-Dorg.lwjgl.librarypath` 指向 natives 目录。
- **spvc Java 类缺失**：26.2 引导程序（`NativeLibrariesBootstrap`）无条件执行 `loadSpvc()` → 并入官方 lwjgl-spvc 3.3.3 全部 41 个类。
- **原生库名不匹配**：官方 `Spvc.<clinit>` 加载的是 `libspirv-cross.so`，包内只有 `libspirv-cross-c-shared.so`（渲染器用）→ 把包内**真实** SPIRV-Cross 库复制改名补一个（非空桩）。
- **libshaderc.so 缺组件**：上游只给了主库，缺 `libglslang.so.13`/`libSPIRV.so.13`/`libSPIRV-Tools-shared.so`；官方 LWJGL natives 是 glibc 版（本机 musl 不可用）→ 换空桩（shaderc 仅 Vulkan 路径用；MobileGlues 只依赖 `libspirv-cross-c-shared.so`，已确认）。
- **HSP 内原生库的 `.codesign` 被 release strip 移除**：fs-verity 会拒绝 `dlopen`，Java 侧常只看到 `error=null`，表现为进入游戏页后黑屏/退出。`launcher.har` 内原生库已全部补签（当前校验为 14 个），jre17/jre25 release 配置固定 `strip: false`；CI 使用 `scripts/verify-native-runtime.sh` 同时校验 HAR 源与最终 HSP 的签名和哈希。

### 6. HSP 识别、安装与 Surface 启动链路（后续补录）

- **HAP/HSP 版本与原生运行时错配**：HSP 导出 `HOML_NATIVE_RUNTIME_REVISION=2`，HAP 在进入游戏页前核对；CI 以源码提交生成稳定 `versionCode`，并回读 HAP、jre17、jre25 的 `module.json` 校验 bundleName/versionCode 一致，发布成对 ZIP，避免混装不同 Nightly。
- **HSP 已安装却误报未安装**：旧代码通过替换 entry 的 `resourceDir` 字符串猜 HSP 路径。当前使用 `application.createModuleContext(context, moduleName)` 让 Bundle Manager 返回真实 ModuleContext，再从其 `resourceDir` 找 JRE 压缩包；失败会显示实际错误码。JRE 解压异常也不再被吞掉，而是交给统一启动错误处理。
- **安装事务顺序**：多模块 APP（App Pack）只有在安装器把 entry HAP 与 HSP 作为同一事务提交时才适合直接安装。小白调试助手 3.1 会拆开并先尝试 HSP；更新已有旧 entry 时可触发 `9568284 / install version not compatible`。**因此 CI 自 2026-08-06 起不再构建也不再发布 `.app`**，只产出 entry HAP、jre17/jre25 HSP 与成对 ZIP。安装必须用同一证书签名并按 **HAP → HSP** 顺序进行。
- **过早启动 JVM**：旧逻辑在 XComponent `onLoad` 后固定等待 1 秒，可能拿到无效 Surface/尺寸。当前改为首次有效 `onSurfaceChanged` 后传入真实宽高并启动一次；失败会退回上一页并释放 `launching` 锁，避免黑屏页或永久卡住不能重试。实机已确认 MC 26.2 能进入游戏。

### 7. 可复用的诊断手段

- **JVM 异常事件直写文件**：`-Xlog:exceptions=debug:file=<下载目录>/exceptions.log`——主异常定位神器（注意 `downloadDir` 每个会话需 picker 初始化一次，`HomlViewModel.switchJre` 已处理）。
- **JVM 崩溃日志**：`-XX:ErrorFile=<下载目录>/hs_err.log`。
- **启动器日志导出**：导出 `logs.txt` 时会一并复制当前游戏运行目录的 `logs/latest.log` 和最新一份 `crash-reports/*.txt` 到下载目录。
- **链接器日志**：`hilog -x | rg MUSL-LDSO`——看 errno（ENOENT 找不到 / ns accessible failed 被命名空间拦）、裸名搜索 vs 绝对路径、namespace 名。
- **崩溃转储**：`/data/log/faultlog/faultlogger/cppcrash-*.log`（含寄存器、maps、全部线程栈）。
- **本地复现**：解包 `jre25-ohos-arm64.tar.xz` → 全部 ELF 用 `binary-sign-tool sign -selfSign 1` 补签 → `OHOS_JAVA_HOME`/`OHOS_DL_DIR` 指向解包目录即可跑 JVM。局限：无 surface，GL 初始化之后的事复现不了；`ffi_closure_alloc` 在此 shell 环境必失败（设备上正常），不要误判。
- **jar 引用全量校验**：本地一次性工具 `.tmp_probe/check_refs.py`（未跟踪）可把 MC 客户端全类对 `org.lwjgl` 的引用对着补丁后 jar 逐一解析（类存在 + 成员沿父类链可解析）；1.21.11 应保持 0 缺失。仓库内可重复执行的基础校验为 `python3 scripts/patch-lwjgl-runtime.py --check`。
- **原生运行时校验**：`sh scripts/verify-native-runtime.sh libs/launcher.har [jre.hsp ...]` 检查 `.codesign`，并可比对最终 HSP 是否携带与 HAR 完全相同的 native payload。

### 8. 当前已验证状态与残留

- **MC 26.2 状态**：已成功进入游戏，启动主链路已经打通，原先的启动黑屏/卡死不再是当前阻塞项。现阶段主要残留为下述高速掠过水面时的几何拉伸问题（§9）；后续若再次发生 Java 异常或崩溃，仍以 `下载/org.xbstudio.homl/exceptions.log` 与 `hs_err.log` 为准。
- **声音**：实机初步确认可以播放，已不再是明确阻塞项。由于当前反馈仍为“好像能放”，尚未确认实际后端、音乐/音效覆盖、前后台切换及长时间运行稳定性，暂记为“初步可用、待完整验证”。
- **Vulkan 后端**：不可用（已被 `glfwVulkanSupported=false` 屏蔽；启用需补齐 spvc native JNI glue + vk 扩展类）。
- **IME 预编辑**：不生效（桩返回 null），输入走旧的 char 回调。

### 9. 高速掠过水面时几何被拉成长条（第二轮修改，待实机确认，2026-08-07）

- **现象**：高速掠过水面时，画面间歇出现大量**又细又长的三角形**，从屏幕一侧斜拉到另一侧，互相交叉成网状。
- **关键证据（务必先看清再动手）**：把录屏原始帧放大后可以确认——
  - 长条上**带着真实纹理并被拉伸**（能看到一条泥土面被抻成细长条），说明三角形连接了**本不该连在一起的顶点**，即顶点/索引数据错乱，不是显示层撕裂、也不是纹理内容坏了。
  - **静态地形完全正常**。近处的泥土、草、沙子、石头、水，纹理干净边缘清晰，没有任何异常。
  - 因此问题只出在**会被反复重写的几何**上：区块流式加载时的网格上传，以及摄像机一动就重排序重传的半透明（水）索引。烘焙一次就不再改的地形不受影响。
- **不要重复的弯路**：
  - 这**不是** VSync 撕裂（能进录屏），不是纹理图集问题，也不是 `GL_UNPACK_*` 状态问题（`writeToTexture` 里 MC 把 `ROW_LENGTH` 设成上传宽度、两个 `SKIP_*` 设成 0，语义等同默认值，翻译层无从理解错）。
  - 清零 `GL_UNPACK_IMAGE_HEIGHT`、XComponent 由 `TEXTURE` 改 `SURFACE`，两者都已验证无效。
  - `STBImageResize` 那条补丁只在 `GameRenderer` 的自动截图/缩略图路径上被调用（全 jar 只有这一个调用者），与游戏内贴图无关，不要再怀疑它。
  - MC 的缺失纹理占位符是**品红+黑**方格（`MissingTextureAtlasSprite` 里的 `0xFF000000` / `0xFFF800F8`）。看到灰色异常不等于贴图加载失败。
- **本轮改动**：26.x 有三个「现代 GL 快路径」开关，每个在 MC 侧都**只有一处读取**，且都有 GL 3.3 时代的回退实现。三者合起来承载了全部顶点/索引数据与属性绑定，正好是出问题的那些数据：

  | `GLCapabilities` 字段 | 快路径 | 回退路径 |
  | --- | --- | --- |
  | `GL_ARB_buffer_storage` | 不可变存储 + 常驻映射 arena | `glBufferData` + map/unmap arena |
  | `GL_ARB_direct_state_access` | `glNamedBuffer*`（不绑定） | `glBindBuffer` + `glBufferSubData` |
  | `GL_ARB_vertex_attrib_binding` | `glBindVertexBuffer`/`glVertexAttribFormat` | `glVertexAttribPointer` |

  三个都是 GL 4.3~4.5 特性，在本机全部由 GL→GLES 翻译层模拟而非驱动原生实现。`scripts/patch-lwjgl-runtime.py` 把对应的 `GLCapabilities.check_ARB_*` 三个方法一律改成恒返 false（各 2 字节 `iconst_0; ireturn`），让 MC 回到它在 4.3 以前硬件上本来就会走的路径——不是自造分支。
- **为什么一次关三个**：单独关 `buffer_storage` 已实机验证**完全无效**，而且很可能压根没生效（MobileGlues 主扩展字符串里就没有 `GL_ARB_buffer_storage`，MC 本来就在走 `Fallback`）。每轮验证都要用户重新构建安装，所以这次先一起关掉换取最大命中率；**如果这轮有效，再逐个打开做二分**，把真正的责任方钉死。
- **代价**：多一次 buffer 绑定、缓冲改用 `glBufferData`、属性用 `glVertexAttribPointer`。理论上有少量吞吐损失，需要留意帧率是否可感下降。
- **待确认**：**尚未实机验证**。本地 JRE 在当前 shell 已无法启动（`java -version` 即 SIGSEGV，SVE 向量长度探测为 0），§3 要求的 `Class.forName` 加载级验证跑不了；改用离线结构校验（`.tmp_probe/verify_struct.py`：整类重解析到字节尾、方法体确为 `03ac`、缩短后的 `Code` 未残留 `StackMapTable`、补丁幂等）。
- **若仍复现**：下一顺位是 MobileGlues 自己的 `bufferCoherentAsFlush`。注意 `JVMLauncher.initEnv` 目前**只设了 `NGG_DIR_PATH`，没设 `MG_DIR_PATH`**，所以 MobileGlues 找不到 `config.json`，一直跑默认配置；且它会用 `FCL_VERSION_CODE`/`ZALITH_VERSION_CODE` 识别启动器，认不出来就打印 "Unsupported launcher detected, force using default config." 并强制默认配置。要调这个开关得先解决这两点。
- **后续取证**：保留能稳定复现的水面高速移动场景；记录所用 MC 版本、渲染器和图形设置，并围绕异常发生时刻采集有界 `hilog`。如能加入诊断构建，优先记录逐帧 `glGetError`、FBO/纹理尺寸与绑定状态、swap interval、buffer age/damage region，以及异常前后帧的截图或帧转储。
