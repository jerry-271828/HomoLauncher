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
- **修复**：Python 字节码补丁给 jar 补方法。最初的一次性全量脚本位于本地未跟踪的 `.tmp_probe/patch_lwjgl.py`；当前仓库已跟踪的可复现增量补丁与 CI 校验入口是 `scripts/patch-lwjgl-runtime.py`（目前负责 GL unpack 状态与 STB stride 两项补丁，不能当作从原版 jar 重建全部历史补丁的脚本）：
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
- **教训**：手写字节码必须做加载级验证：`Class.forName(name, false, loader)`（initialize=false，走验证器但不跑 clinit）每个补丁类过一遍；提交前还要执行 `python3 scripts/patch-lwjgl-runtime.py --check`，防止 jar 与可复现补丁脚本漂移。**注意：本地 JRE 自 2026-08-07 起在本 shell 已无法启动（见 §7），加载级验证暂时跑不了**，替代手段是 `.tmp_probe/verify_struct.py` 的离线结构校验；等本地 JVM 修好后应补回加载级验证。

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

- **原生崩溃栈是最高价值证据**：`hs_err.log` 的 "Native frames" 段会把 C 帧和 Java 帧串在一起，一眼看出是谁在坑谁。§9 的定位就是靠它翻出来的：

  ```
  memcpy (ld-musl)  ←  libgallium-25.0.1 ×5  ←  GL11C.nglTexSubImage2D
                    ←  GlStateManager._texSubImage2D(...ByteBuffer)
  ```

  遇到"看起来像渲染器的问题"，先翻 `hs_err.log` 和 `/data/log/faultlog/faultlogger/cppcrash-*.log`，比凭现象推断有用得多。
- **先搞清楚底层到底是谁**：本机 GL/GLES 栈是 **Mesa 25.0.1**，不是华为私有驱动。判断方法就是直接列系统库：

  ```sh
  ls /system/lib64 | grep -iE 'gallium|mesa|^libGL|^libEGL'
  ls /system/lib64/ndk | grep -i '^libGL'
  strings -a /system/lib64/libgallium-25.0.1.so | grep -E '^(GALLIUM|MESA|mesa)_[A-Za-z_]+$' | sort -u
  ```

  最后一条能直接列出所有可用的环境变量开关（`GALLIUM_THREAD`、`mesa_glthread`、`GALLIUM_HUD`、`GALLIUM_TRACE`…）。**改渲染器行为之前先确认它在不在链路里**——三个渲染器全都复现时，责任一定在它们的公共层。
- **确认环境变量真的生效**：Mesa 覆盖 driconf 选项时会在 stderr 打印 `ATTENTION: default value of option <name> overridden by environment.`。导出的 `latest.log` 里搜这一行，就知道 `mesa_glthread` / `GALLIUM_THREAD` 有没有被吃进去，不用猜。
- **录屏逐帧取证**：设备上有 `ffmpeg`。渲染类问题**必须看原始分辨率的帧**，缩略图会把关键细节抹掉：

  ```sh
  ffmpeg -ss <秒> -i <录屏.mp4> -vframes 1 -vf "crop=W:H:X:Y" -q:v 2 out.jpg
  ```

  §9 就是靠放大后看清"长条上带着被拉伸的真实纹理"才把方向从"纹理坏了"扭回"顶点/索引坏了"。注意 Read 工具有 2000×2000 像素上限，裁剪后再放大。
- **jar 静态分析脚本**（`.tmp_probe/`，未跟踪，可重建）：`scan_gl.py` 列出某 jar 对指定包的全部方法引用；`dump_class.py` 导出类的字段/方法/字符串/整型常量；`disasm.py` 反汇编单个方法并解析常量池引用。MC 的 `com/mojang/blaze3d/**` 在 26.x **没有混淆**，可以直接读出 `BufferStorage.create` / `DirectStateAccess.create` 这类特性开关的判断条件。
- **补丁后 jar 的离线结构校验**：`.tmp_probe/verify_struct.py` 把每个被改过的类从头到尾重新解析（有多余字节就报错）、打印方法体字节与 `max_stack`/`max_locals`、确认缩短后的 `Code` 没有残留 `StackMapTable`、并验证补丁幂等。
- **JVM 异常事件直写文件**：`-Xlog:exceptions=debug:file=<下载目录>/exceptions.log`（注意 `downloadDir` 每个会话需 picker 初始化一次，`HomlViewModel.switchJre` 已处理）。注意这个日志会记录**所有**抛出的异常，`java.lang.invoke` 相关的 `NoSuchMethodError` / `IncompatibleClassChangeError` 是 MethodHandle 基础设施的正常控制流，不是 bug，别被带偏。
- **JVM 崩溃日志**：`-XX:ErrorFile=<下载目录>/hs_err.log`。
- **启动器日志导出**：导出 `logs.txt` 时会一并复制当前游戏运行目录的 `logs/latest.log` 和最新一份 `crash-reports/*.txt` 到下载目录。**游戏运行目录在应用沙箱内，从外面读不到，只能靠这个导出。**
- **链接器日志**：`hilog -x | rg MUSL-LDSO`——看 errno（ENOENT 找不到 / ns accessible failed 被命名空间拦）、裸名搜索 vs 绝对路径、namespace 名。注意 hilog 是环形缓冲，几分钟就会滚掉，必须在复现**期间**抓。
- **本地复现（当前已失效）**：原方法是解包 `jre25-ohos-arm64.tar.xz` → 全部 ELF 用 `binary-sign-tool sign -selfSign 1` 补签 → `OHOS_JAVA_HOME`/`OHOS_DL_DIR` 指向解包目录。**2026-08-07 起在本 shell 已跑不起来**：`java -version` 直接 SIGSEGV（VM 初始化阶段，SVE 向量长度探测返回 0），未打补丁的类作对照同样崩，说明是环境问题不是补丁问题。因此 §3 要求的 `Class.forName` 加载级验证暂时无法执行，只能退回离线结构校验。
- **jar 引用全量校验**：本地一次性工具 `.tmp_probe/check_refs.py`（未跟踪）可把 MC 客户端全类对 `org.lwjgl` 的引用对着补丁后 jar 逐一解析；1.21.11 应保持 0 缺失。仓库内可重复执行的基础校验为 `python3 scripts/patch-lwjgl-runtime.py --check`。
- **原生运行时校验**：`sh scripts/verify-native-runtime.sh libs/launcher.har [jre.hsp ...]` 检查 `.codesign`，并可比对最终 HSP 是否携带与 HAR 完全相同的 native payload。

### 8. 当前已验证状态与残留

- **MC 26.2 状态**：已成功进入游戏，启动主链路打通，启动黑屏/卡死不再是阻塞项。当前唯一明确阻塞项是 §9 的几何拉伸。
- **声音**：实机初步确认可以播放。反馈仍是"好像能放"，实际后端、音乐/音效覆盖、前后台切换与长时间稳定性均未确认，记为"初步可用、待完整验证"。
- **Vulkan 后端**：不可用（已被 `glfwVulkanSupported=false` 屏蔽；启用需补齐 spvc native JNI glue + vk 扩展类）。
- **IME 预编辑**：不生效（桩返回 null），输入走旧的 char 回调。
- **偶发原生崩溃（与 §9 无关，未解决）**：`/data/log/faultlog/faultlogger/cppcrash-org.xbstudio.homl-*.log` 里有多次同一签名的 SIGSEGV——栈是 JIT 帧与 `libjvm.so` 解释器帧深度交替递归，最终在低地址（如 `0x8`）挂掉。2026-08-06 上午（打任何本轮补丁之前）就已存在，**不是新引入的**，也不要和 §9 混为一谈。
- **MobileGlues 当前完全无法配置**：`JVMLauncher.initEnv` 只设了 `NGG_DIR_PATH`，**没设 `MG_DIR_PATH`**，MobileGlues 因此找不到 `config.json`；而且它会用 `FCL_VERSION_CODE` / `ZALITH_VERSION_CODE` 判断启动器，认不出就打印 `Unsupported launcher detected, force using default config.` 并强制默认配置。所以 `bufferCoherentAsFlush`、`multidrawMode`、`customGLVersion` 等开关目前一个都调不动，想调必须先解决这两点。

### 9. 高速掠过水面时几何被拉成长条（未解决，2026-08-07）

#### 现象

高速掠过水面时，画面间歇出现大量**又细又长的三角形**，从屏幕一侧斜拉到另一侧，互相交叉成网状。停下不动时不明显，移动越快、区块加载越密集越容易出现。

#### 已确认的事实（都有实证，不要再推翻重来）

1. **是顶点/索引数据错乱，不是显示层撕裂，也不是纹理坏了。** 把录屏原始帧放大后能看到长条上**带着被拉伸的真实纹理**（有一条泥土方块面被抻成细长条），说明三角形连接了本不该连在一起的顶点。
2. **静态地形完全正常。** 同一帧里近处的泥土、草、沙子、石头、水，纹理干净、边缘锐利。所以问题只出在**会被反复重写的几何**：区块流式加载时的网格上传，以及摄像机一动就重排序重传的半透明（水）索引。烘焙一次不再改的地形不受影响。
3. **三个渲染器都复现，包括无翻译层的 GLV4。** GLV4 加载的是 `/system/lib64/ndk/libGLv4.so`，纯 Mesa 桌面 GL，中间没有任何翻译层。这一条**单独就排除了所有"某个翻译层实现得不对"的假设**。
4. **底层是 Mesa 25.0.1，且它确实会越界读客户端内存。** `hs_err.log` 抓到过实证崩溃栈：

   ```
   memcpy (ld-musl)  ←  libgallium-25.0.1 ×5  ←  GL11C.nglTexSubImage2D
                     ←  GlStateManager._texSubImage2D(...ByteBuffer)
   ```

   Mesa 从应用给的客户端内存里读越界直接段错误。那次跑的还是 MobileGlues，栈里却全是 libgallium——再次印证 Mesa 在所有渲染器下面。纹理路径上越界会崩所以被抓到；同样的问题落到几何路径上通常**不崩**，只会把越界/陈旧字节当顶点索引用，正好就是长条三角形。

#### 已试过且无效（按时间，附版本号，不要重来）

| 改动 | 结果 |
| --- | --- |
| 直接上传前清零 `GL_UNPACK_IMAGE_HEIGHT` | 无效。且 `writeToTexture` 里 MC 本就把 `ROW_LENGTH` 设成上传宽度、两个 `SKIP_*` 设成 0，语义等同默认值，翻译层无从理解错 |
| XComponent 由 `TEXTURE` 改独立不透明 `SURFACE` | 无效 |
| 屏蔽 `ARB_buffer_storage`（vc1030208 / cbacbd4） | 实机验证无效，而且很可能压根没生效——MobileGlues 主扩展字符串里就没有它，MC 本来就在走 `GlTransientMemory$Fallback` |
| 同时屏蔽 `ARB_buffer_storage` / `ARB_direct_state_access` / `ARB_vertex_attrib_binding`（vc1030209 / b2c5f55） | **已回退**。前提是"这些特性由翻译层模拟所以不可靠"，但底层是 Mesa 桌面 GL，三者都是原生实现，前提不成立。回退后 `lwjgl.jar` 与 7f49570 基线逐字节一致 |
| 只关 `mesa_glthread`（vc1030210 / 7acf296） | 未实机验证就被下一版取代；它只关了 Mesa 两个异步层中的一个 |

另外两条排除项：

- **`STBImageResize` 补丁与本问题无关**：全 jar 只有 `GameRenderer` 一个调用者，走的是自动截图/缩略图路径。
- **JIT 向量化不是原因**：内核 `cpuinfo` 报了 `sve`，但 `hs_err.log` 里 **JVM 自己探测到的特性列表没有 SVE**，说明它已经禁用。`-XX:UseSVE=0` 是空操作，不用试。

#### 当前改动（vc1030211 / 69cb0b8，待实机确认）

`JVMLauncher.initEnv` 关掉 Mesa 的两个**互相独立**的异步层：

```
setenv("mesa_glthread", "false");   // glthread：把 GL 调用转投工作线程
setenv("GALLIUM_THREAD", "0");      // 驱动级 threaded context
```

推断链：Mesa 异步执行 GL 调用时，携带**客户端内存**的调用（MC 上传区块网格走 `glBufferSubData` 直传 direct ByteBuffer）如果在工作线程真正消费之前，那块内存已被 MC 回收重用，读到的就是陈旧/无关字节。上传越密集越容易撞上，而高速掠过水面正是区块流式加载 + 半透明重排序最密集的时候；只上传一次的静态地形一旦侥幸正确就永远正确——与事实 1、2 完全吻合。

**这不是凭空猜的**：§2 里 `glTexSubImage2D` 补丁的原始注释就写着「Mesa 25.0.1 在 threaded staging path 上多读直接像素缓冲」。写那条注释时就已经知道 Mesa 在这一层会多读客户端缓冲，只是当时只针对纹理打了补丁，没意识到几何路径会中同一枪。`GALLIUM_THREAD` 正对应那个 "threaded staging path"。

两个开关都是纯环境变量，只影响 CPU 侧并行，不影响正确性。**若这轮有效，需要再分别出两个构建做二分**，只保留必要的那个，并留意大量区块加载时帧率是否下降。

#### 仍存的猜测（按优先级）

1. **确认开关是否真的生效**——先看 `latest.log` 里有没有 `ATTENTION: default value of option mesa_glthread overridden by environment.`。如果没有这行，说明环境变量没被 Mesa 吃进去，上面整轮都是空操作，得先解决注入时机/命名空间问题。
2. **Mesa 的非异步路径或其下的驱动本身**。若两个异步层都关掉仍复现，问题就在 Mesa 的缓冲上传实现或 Maleoon 驱动里。可用 `GALLIUM_HUD` / `GALLIUM_TRACE` 进一步观察，但 trace 开销很大。
3. **MobileGlues 的 `bufferCoherentAsFlush`**（仅对 MobileGlues 路径有意义，解释不了 GLV4 复现，优先级因此靠后）。要调必须先解决 §8 里记的 `MG_DIR_PATH` 与启动器识别两个前置问题。
4. **MC 侧提前回收上传缓冲**。若 Mesa 的异步行为本身合法，那就是 MC/LWJGL 在 `glBufferSubData` 返回后立刻复用了 direct ByteBuffer。这种情况可以在 LWJGL 侧给缓冲上传补一次同步来验证，但代价高，放在最后。

#### 一条记下来的旁支观察（**不是**本问题，别再追）

排查过程中曾注意到**第一人称手持方块**渲染成高对比度的灰色棋盘格，物品栏图标也偏暗、草方块只画出顶面。当时误判为主问题并浪费了一轮。用户已明确指出**这不是要解决的问题**。真实原因未查明，也可能只是当时手持的方块本身就长那样。若日后要追，注意 MC 的缺失纹理占位符是**品红+黑**方格（`MissingTextureAtlasSprite` 的 `0xFF000000` / `0xFFF800F8`），灰色异常不等于贴图加载失败。

#### 后续取证

保留能稳定复现的水面高速移动场景；记录所用 MC 版本、渲染器和图形设置。复现**期间**同步抓 `hilog`（环形缓冲会滚掉，事后再抓没用），复现后立刻用启动器导出日志拿到 `latest.log`，并检查 `/data/log/faultlog/faultlogger/` 有没有新的 `cppcrash`。如能加入诊断构建，优先记录逐帧 `glGetError`、缓冲上传的 offset/size 与其 direct ByteBuffer 的生命周期。

#### 2026-08-07 取证与 vc1030211 复测

**旧构建录屏逐帧取证**（`SVID_20260807_073514_1.mp4`，3 秒 168 帧，60fps 3120×2080，录制于 vc1030211 之前的构建，仅作现象基准）：f014/f021/f078/f123/f129 等 5–6 帧出现典型异常——水面网格炸成大量细长三角形、互相交叉成网（f129 最严重）；长条上带真实水纹理与沙滩纹理（f014 右上方一条白色长带是被抻开的沙子面）；f021 有一整块沙滩/海草区块网格整体错位"漂"在水面上方。同帧近景悬崖、树、手持基岩全部完好。与事实 1、2 完全吻合，可作新旧构建对比的参照样本。其余 160+ 帧正常，符合"间歇出现"。

**vc1030211（`mesa_glthread=false` + `GALLIUM_THREAD=0`）实机复测**：用户反馈问题仍复现，但当次导出日志里**没有 `latest.log`、`logs.txt` 也是空的**（LogsView 内存日志为空数组），无法确认 Mesa 是否吃到环境变量。**按"仍存的猜测"第 1 条，注入确认是前置：当前证据不足以判定该轮修复无效。**下次复测必须拿到 `latest.log` 查 `ATTENTION: default value of option mesa_glthread overridden by environment.`。

**同次新发现问题（非 §9）**：09:37 首次启动直接崩在 `Loading library OpenGL`——`dlopen /data/storage/el1/bundle/jre25/libs/arm64/libmobileglues.so` 失败且 `error=null`（crash-2026-08-07_09.37.17-client.txt）。按 §5 经验 `error=null` 高度疑似 fs-verity 拒载（签名问题）。仓库内 `libs/launcher.har` 校验通过（14 个库全签），所以要么装的 jre25 HSP 不是同一 CI 产物/混装了旧 HSP，要么发布链路有回归——**用 `scripts/verify-native-runtime.sh` 校验实际安装的那个 HSP 再下结论**。该崩溃只在 MobileGlues 路径出现；随后会话二（09:38–09:53，约 15 分钟）正常游玩，**渲染器为 GLV4**（用户确认）——即"仍复现"的观察是在**无翻译层的纯 Mesa 桌面 GL 路径**上取得的，与翻译层实现无关；MobileGlues 崩溃不影响该结论。

**异常日志体检（会话二，20MB+）**：无新增 Java 层问题。`RunningOnDifferentThreadException`（3.6 万次，MC 把数据包从 Netty 重调度到主线程的正常控制流）、`ClassNotFoundException`（jackson/osgi/slf4j 等可选类探测）、`NoSuchMethodError`/`IncompatibleClassChangeError`（`java.lang.invoke` 基础设施，§7 已记为正常噪声）、`UnsatisfiedLinkError: VK.getVulkanDriverHandle`（Vulkan 探测的正常失败）。09:37/09:38 两次 cppcrash 均为 §8 已知的 JIT 帧与 `libjvm.so` 解释器帧交替递归、低地址 SIGSEGV 签名，不是新引入，与 §9 无关。

**导出链路缺陷（待修）**：`LogsView.saveLogs` 的 `logs.txt` 只写 bridge 推送的内存日志（本次为空 `[]`），`latest.log` 用 `copyIfExists` 静默跳过失败，崩溃报告却导成功了——说明 runDir 解析正确但 `logs/latest.log` 不存在或读取失败。需要：导出失败时显式提示而不是吞掉；并确认 26.2 实际使用的 log4j 配置写到哪个路径（`resfile/game/log4j2-*.xml` vs `security/log4j-rce-patch-*.xml` 输出路径不同）。
