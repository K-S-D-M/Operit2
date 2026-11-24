# Android V8 构建失败：只支持 Linux 主机

## 现象

`Android Flutter Build` 在 `Build and package Android app` 步骤稳定失败，
Gradle 报：

```text
Execution failed for task ':app:prepareOperitAndroidV8arm64v8a'.
> Process 'command 'D:\a\Operit2\Operit2\.venv\Scripts\python.exe'' finished with non-zero exit value 1
```

再往上翻 v8 crate 构建脚本的 stdout，真正的根因是：

```text
ERROR at //build/config/BUILDCONFIG.gn:262:3: Assertion failed.
  assert(host_os == "linux", "Android builds are only supported on Linux.")
  ^-----
Android builds are only supported on Linux.
```

随后 `prepare_android_v8.py` 打印
`Android V8 preparation failed: ... exit status 101`，v8 的 `build.rs`
在 `gn gen` 返回非零后 panic。

## 原因

- rusty_v8 不发布 Android 预编译静态库，`prepare_android_v8.py` 必须从源码构建。
- 源码构建 Android 目标时，Chromium/V8 的构建配置会编译并**在宿主上执行**
  主机侧工具（mksnapshot、torque 等），因此上游在
  `build/config/BUILDCONFIG.gn` 中硬性断言宿主必须是 Linux。
- 工作流的 `build-android` 跑在 `windows-2025` 上，`gn gen` 必然触发该断言，
  V8 无法在 Windows 宿主完成 Android 交叉构建。

不要尝试以下"修复"，它们都会在更后面失败或产出不受支持的二进制：

- 删除或放宽 `host_os == "linux"` 断言：随后会在 debian sysroot、`ld.lld`、
  宿主快照工具链等 Linux 专属路径上失败。
- 只把 NDK 的 `windows-x86_64` 预编译目录映射成 `linux-x86_64`
  （`prepare_android_v8.py` 已经在做 junction 映射）：这解决不了断言本身。

## 修复方案

`build-android` 拆成两个 job（`.github/workflows/android-flutter-build.yml`）：

1. `build-android-v8`（`ubuntu-24.04`）负责 V8 源码构建：
   - 安装 NDK `27.3.13750724`、Rust `1.95.0` + `aarch64-linux-android`；
   - 从 apt.llvm.org 安装 LLVM 21：`libclang-21-dev` 供 bindgen
     （脚本要求 libclang ≥ 21.1），`lld-21` 供 Chromium 主机工具链；
   - 执行 `tools/build_scripts/prepare_android_v8.py`；
   - 上传 `operit2-android-v8-<sha>`：`librusty_v8.a`、`src_binding.rs`、
     `args.gn`、`manifest.json`。
2. `build-android`（`windows-2025`）负责打包 APK：
   - 下载上面的 artifact，写入
     `tools/release/work/android-v8/<v8 版本>/aarch64-linux-android/`；
   - Gradle 的 `prepareOperitAndroidV8*` 任务继续调用
     `prepare_android_v8.py`，但 `cache_valid()` 校验 `manifest.json`
     的配置与 SHA-256 通过后只重写 env 文件，日志出现
     `Using verified V8 cache`，不再执行 V8 源码构建。

### 关键约束（改动前务必确认）

- 两个 job 的 `OPERIT_ANDROID_V8_NDK` 必须指向**同名 NDK 目录**，
  且两边都要设置 `OPERIT_ANDROID_V8_NDK_VERSION`（当前 `27.3.13750724`）。
  `manifest.json` 记录 `android_ndk_version`，两侧不一致会让 Windows 端判定
  缓存失效并重新构建，从而再次撞上断言。
  该环境变量是必需的：runner 镜像会不断新增 NDK 目录（例如 29.0/30.0），
  Gradle 还会额外安装 Flutter SDK 自己的 NDK；只靠目录探测会让两个 job
  取到不同版本。`prepare_android_v8.py` 优先使用这个显式声明值。
- 运行时脚本会打印 `Android V8 NDK: <路径> (android_ndk_version=...)`，
  两个 job 的该行必须一致，排查缓存问题时先看它。
- Linux 端必须存在形如 `libclang.so.<major>` 的文件名：
  Debian 的 `libclang-21-dev` 实际提供 `libclang-21.so.1`，
  工作流补了 `/usr/lib/llvm-21/lib/libclang.so.21` 符号链接。
- 升级 `v8` 版本只需改 `Cargo.lock`：缓存键、artifact 内容路径都从
  `apps/flutter/native/operit-flutter-bridge/Cargo.lock` 推导，无需改工作流。
- V8 产物约为数百 MB 到 1 GB 级，`build-android-v8` 首次构建耗时较长
  （已完成一次后由 `actions/cache` 命中，通常数分钟内完成）。

## 验证方式

1. 手动触发 `Android Flutter Build`（`workflow_dispatch`）。
2. `build-android-v8` 成功，artifact `operit2-android-v8-<sha>` 存在。
3. `build-android` 日志中 `Install prebuilt Android V8 into the source-build cache`
   列出了 4 个文件；Gradle 输出包含 `Using verified V8 cache`，
   且不再出现 `gn gen`。
4. `Build and package Android app` 产出
   `operit2-app-android-arm64-v8a-<版本>.apk`。

## 排查清单

| 症状 | 可能原因 | 处理 |
| --- | --- | --- |
| Windows 端仍出现 `gn gen` / `BUILDCONFIG.gn` 断言 | 未下载到 artifact，或 manifest 配置不匹配 | 检查 `Download prebuilt Android V8` 是否执行、两侧 NDK 声明值是否一致 |
| 两端脚本打印的 `android_ndk_version` 不同 | runner 新增了 NDK 目录 / Gradle 装了别的 NDK | 两边都设 `OPERIT_ANDROID_V8_NDK_VERSION` |
| `Cannot find path ...\.v8-artifact\.version` | `upload-artifact` v4 默认跳过隐藏文件 | 版本文件命名为 `v8-version.txt`，不要用 `.version` |
| `V8 configuration mismatch: android_ndk_version=...` | 两侧 NDK 版本不同 | 把 `OPERIT_ANDROID_V8_NDK` 对齐到同一版本 |
| Linux 端 `V8 source bindings require LLVM/libclang 21.1 or newer` | 只有 libclang-21.so.1，脚本按 libclang.so.<major> 探测 | 建立 `libclang.so.21` 符号链接 |
| `No usable Android NDK found` | NDK 未安装或缺少 API 24 的 clang++ | 用 sdkmanager 安装对应 NDK |
| V8 构建因磁盘不足中断 | 工作区剩余空间不足 | 保留 `Free disk space` 步骤 |
