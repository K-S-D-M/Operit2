# 云端优先构建与本地加速资产

## 1. 原则

- **所有产物一律云端产出**：APK、Windows EXE、其它平台包都由 GitHub Actions 在 runner 上编译打包。本地机器不参与编译，也不作为「构建成功」的判断依据。
- **唯一权威状态是云端**：仓库 `K-S-D-M/Operit2` 的 `origin/main` 与云端 workflow run。本地工作区只是镜像，随时可能落后；任何判断前先取云端 head：

  ```bash
  gh api repos/K-S-D-M/Operit2/git/ref/heads/main --jq '.object.sha'
  ```

- **可能在别的设备提交构建**：修复必须通过 GitHub API 或 `git push` 落到 `main`，只改本地文件等于没改。触发构建用 `workflow_dispatch`，不要用本地结果代替。
- **本地只放加速与应急资产**：运维脚本、预下载缓存、产物归档、安装备份。这些不入库，仅在本机保留，并在本文档登记用途。

## 2. 云端构建入口

| 产物 | Workflow | 触发命令 |
| --- | --- | --- |
| Android APK | `Android Flutter Build` | `gh workflow run "Android Flutter Build" --ref main` |
| Windows EXE / ZIP | `Windows Release Build` | `gh workflow run "Windows Release Build" --ref main` |
| APK 自动发布 | `Android Auto Release` | Android 构建成功时由 `workflow_run` 自动触发 |
| 协议一致性检查 | `Peer Protocol Compatibility` | push 到 main / PR 自动触发 |

常用运维命令：

```bash
gh run list --limit 10                       # 看全部任务
gh run watch <run-id> --exit-status          # 等到结束
gh run view <run-id> --log-failed            # 只看失败日志
gh run rerun <run-id> --failed               # 只重跑失败的 job
gh release view v2.0.0-YYYYMMDD --json assets
```

同步上游（`merge-upstream` 会保留 fork 自己的提交）：

```bash
gh api -X POST repos/K-S-D-M/Operit2/merge-upstream -f branch=main
gh api "repos/K-S-D-M/Operit2/compare/AAswordman:main...K-S-D-M:main" \
  --jq '"ahead=\(.ahead_by) behind=\(.behind_by)"'
```

## 3. 本地加速 / 应急资产（不入库）

存放在工作区的 `build-acceleration/` 目录，仅本机使用：

| 文件 | 用途 |
| --- | --- |
| `cloud-build.sh` | 一键触发云端 Android / Windows 构建，或查询任务状态；本机不编译 |
| `prefetch-flutter-assets.sh` | 当 `github.com/.../releases/download/...` 返回 504 时，改走 `api.github.com` 通道把 `AAswordman/flutter-ohos` 的 SDK artifacts 拉到本地缓存，供应急排查用 |
| `flutter-assets-cache/<tag>/` | 上一步的下载结果，含 `SHA256SUMS`，可校验；纯缓存，可随时删除 |

示例：

```bash
bash build-acceleration/cloud-build.sh all       # 触发双端构建
bash build-acceleration/cloud-build.sh status    # 查看云端任务
bash build-acceleration/prefetch-flutter-assets.sh 3.41.10-ohos-0.0.2-beta.operit.2
```

> 说明：`api.github.com` 与 `github.com/.../releases/download` 是两条独立通道。2026-11-09 出现过后者整体 504、前者仍返回 200 的情况；此时**重试云端构建**比在本地补文件更有效，本地缓存只用于排查与加速。

## 4. 故障速查表

| 现象 | 根因 | 处理 |
| --- | --- | --- |
| `Peer protocol changed. Append a revision with version greater than N and hash <sha>` | 上游改动了协议源码却没登记新修订，`operit-node-runtime` 的 build.rs 主动 panic | 在 `core/peer-protocol.json` 末尾**追加**（不要改旧项）`version=N+1` + 报错给出的 hash；`tools/check_peer_protocol.py` 会校验旧修订不可变 |
| `package ... has no embedded archive` / `cargo check ... exit code 101` | `assets/plugins/{buildin,external}` 被 .gitignore 忽略，build.rs 读不到内嵌 ToolPkg | 构建前执行 `python plugins/tools/sync_plugin_packages.py --source runtime --no-hot-reload`；两个 workflow 均已内置该步骤 |
| `Server returned HTTP response code: 504 ... gradle-8.14-all.zip` | Gradle Wrapper 首次运行从 GitHub Releases 下载分发包，通道瞬时故障 | 仓库不带 `gradlew.bat`（wrapper 由 Flutter 生成），无法单独预取；已在打包步骤做 3 次重试 |
| `Exception: 504` + `flutter-web-sdk.zip` / `windows-x64-*.zip` | 自定义 Flutter SDK（`flutter-ohos`）从 GitHub Releases 下载 artifacts，通道故障 | 同样用打包步骤的 3 次重试；通道整体恢复后 `gh run rerun <run-id> --failed` 即可，不要改代码 |
| `fatal: unable to access 'https://gitee.com/...'` / `exit code 69` | `flutter pub get` 拉 gitee 依赖超时 | 重试打包步骤；`CARGO_NET_RETRY=10`、`CARGO_HTTP_TIMEOUT=120` 已写入两个 workflow 降低同类抖动影响 |
| `Android Auto Release` 报 `Artifact not found` | `actions/download-artifact@v4` 参数名写成 `run_id`，被忽略 | 使用 `run-id: ${{ github.event.workflow_run.id }}` |
| `Android builds are only supported on Linux.` | Android V8 源码构建跑在 Windows runner | 由 `build-android-v8`（ubuntu）预构建并上传 artifact，Windows job 下载复用；NDK 固定 `27.3.13750724` |

## 5. 提交修复到云端的两种方式

1. 常规：`git add / commit / push origin main`（可能遇到本机代理 `CONNECT tunnel 502`）。
2. 兜底：GitHub Contents API（已验证可用）。修改 `.github/workflows/*` 需要 `workflow` scope 的 classic PAT；`gh` 的 OAuth token 通常没有该 scope，会报 403。本机凭据可取：

   ```bash
   PAT=$(printf "protocol=https\nhost=github.com\n\n" | GCM_INTERACTIVE=Never git credential fill \
         | sed -n 's/^password=//p')
   ```

   然后 `GH_TOKEN="$PAT" gh api -X PUT repos/K-S-D-M/Operit2/contents/<path> --input -`。
   注意：`POST /git/trees` 配合 `base_tree` 更新 `.github/workflows/*` 这类深层路径会返回 404，用 Contents API 逐文件提交更稳。

## 6. 每次构建的检查清单

1. `merge-upstream` 同步上游，确认 `behind_by=0`。
2. 若上游改了协议源码，确认 `Peer Protocol Compatibility` 为 success；否则补 revision。
3. 用 `workflow_dispatch` 触发 Android / Windows，记录 run id 与 head sha（两者必须一致）。
4. 失败时先看 `--log-failed`，区分代码问题与下载通道故障：前者改仓库，后者直接 `rerun --failed`。
5. 产物以 Release Assets / Actions Artifacts 为准；本地只做归档与安装，不参与判定。
