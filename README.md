# WeFlow Community Build

WeFlow 5.0.0 的社区补丁构建版。修复了官方版本内置时间锁到期后（2026-10-01 起）出现的一连串问题，让这个优秀的本地微信聊天记录工具继续可用。


https://github.com/user-attachments/assets/f1a56061-37ff-495a-9d4f-4f97456f6010


> 本仓库不含任何修改过的官方闭源组件逻辑，全部改动均可审计（见下方"改动清单"）。仅供个人非商业使用，请遵守上游授权（CC BY-NC-SA 4.0）并负责任地使用：只读取**自己的**微信数据。

## 遇到了什么问题

WeFlow 5.0.0 的闭源原生组件里硬编码了构建过期时间 `2026-09-30 23:59:59`。到期后出现三类故障：

| # | 故障 | 现象 | 根因 |
|---|------|------|------|
| 1 | 启动/连接失败，错误码 `-101` | 界面弹窗「WeFlow 启动失败」，日志刷 `InitProtection rc=-101` | `wcdb_api.dll` 里 `InitProtection()` 的日期门 |
| 2 | 数据库初始化失败，错误码 `-1000` | 修复 -101 后仍然无法读数据 | 同一 DLL 里 `wcdb_init()` 的第二道日期门（`_mktime64` 现场构造同时间点） |
| 3 | 聊天导出失败 | 导出时报 `this build has expired` | WeFlow 内嵌的 WeLive 导出引擎（`welive.exe`，Rust CLI）自带独立的过期锁 |

上游 issue：[hicccc77/WeFlow#1220](https://github.com/hicccc77/WeFlow/issues/1220)、[#1222](https://github.com/hicccc77/WeFlow/issues/1222)、[#1227](https://github.com/hicccc77/WeFlow/issues/1227)。原作者确认时间锁是有意为之且未发布修复。

## 解决方法（两层）

### 第一层：wcdb_api.dll 的 7 字节补丁（解决 -101/-1000）

移除 `wcdb_api.dll` 里两道日期门的硬编码比较，合计 7 字节、两条跳转指令：

| 文件偏移 | 原始 | 补丁后 | 位置 |
|---------|------|--------|------|
| `0x80dc5` | `7E 0A`（jle） | `EB 0A`（jmp） | `InitProtection`：日期比较后无条件走成功分支 |
| `0xe85d7` | `0F 8E 30 01 00 00` | `E9 31 01 00 00 90` | `wcdb_init`：同上（rel32 +1 补偿指令长度差，尾部 nop 填充） |

脚本按**字节签名**搜索（`call <time import>` + `cmp` + 条件跳转的结构模式，不认固定偏移），全文件唯一命中才写入；写前自动备份 `.orig`，写后重读校验。厂商换截止日期也能匹配；结构对不上会明确报 `nomatch` 拒绝写入。

补丁脚本与详细逆向文档：<https://github.com/Dinnerb0ne2/WeFlow-WCDB-Patch>（上游：<https://github.com/AnonymousUser443/WeFlow-Community-Patch>）

### 第二层：Community Hotfix 源码补丁（解决导出失效）

WeFlow 内嵌的 WeLive 导出引擎过期后无法自动恢复，社区补丁修改 WeFlow 源码做了系统性兜底：

- WeLive 引擎报 `this build has expired` / 握手失败 / 进程异常退出时，**自动切换到内置 WCDB 导出路径**（不再依赖 welive.exe）
- 批量导出中检测到引擎不可用后，后续会话直接走 WCDB，避免逐个等待失败
- 修复私聊页冷启动后首次点「导出」卡死（一次性 `CustomEvent` → 可持久消费的 Zustand 请求）
- 导出上下文显式传递账号目录（多账号/非默认目录下不再读错路径）
- Export Worker 显式接收 `process.resourcesPath` 与 `app.getAppPath()`，修复 `silk-wasm` 在 `app.asar.unpacked` 的加载路径（`Silk 解码失败`）

补丁文件：`patches/weflow-community-hotfix.patch`（354 行，7 个文件），来源：<https://github.com/AnonymousUser443/WeFlow-Community-Patch>

## 本仓库包含什么

- WeFlow 5.0.0 完整源码（含 `resources/` 下的原生组件二进制——上游仓库删除了这些，备份自 5.0.0 完整分发的镜像）
- 已应用的 Community Hotfix 源码补丁（见 `git log`）
- 未修改的 `wcdb_api.dll`（需要按上述步骤自行打 DLL 补丁，或直接用上游补丁仓库的脚本）
- 上游原版说明：`README-upstream-mjkyleo.md`

## 自己构建

```powershell
# 1. 安装依赖（peer deps 冲突用 legacy 绕过，react 19 vs 老组件的已知问题）
npm install --legacy-peer-deps

# 2. 构建（产物在 release2\win-unpacked\，安装包在 release2\WeFlow-5.0.0-Setup.exe）
npm run build

# 3. 给产物里的 wcdb_api.dll 打时间锁补丁（自动备份、可 -Restore 回滚）
powershell -ExecutionPolicy Bypass -File <补丁脚本路径>\patch_wcdb.ps1 -AppDir "<本仓库>\release2\win-unpacked"
```

完成。正常启动 WeFlow（无需改系统时间、无需 RunAsDate），日志 `%APPDATA%\WeFlow\logs\wcdb.log` 里没有 `rc=-101` 即成功；导出走 WCDB 路径，不再报 `this build has expired`。

## 最新源码版（Upstream Build，2026-10-15 新增）

基于 [hicccc77/WeFlow](https://github.com/hicccc77/WeFlow) **main 分支最新代码**的构建（含上游新增的 AI Agent 子系统与组件外置架构），叠加本仓库全部修复。对应 Release：`v5.0.0-upstream.1`。

### 与 5.0.0 社区版的区别

| | 5.0.0 社区版（本仓库主体） | 最新源码版（upstream build） |
|---|---|---|
| 代码基线 | 5.0.0 完整分发 + Community hotfix | 上游 main 最新（AI Agent 子系统、组件外置架构） |
| 时间锁 | DLL 7 字节补丁 | 同款补丁（组件路径指向补丁 DLL） |
| 导出 | Community hotfix fallback | fallback 逻辑已移植（源码级，见 `patches/weflow-upstream-latest-fixes.patch`） |
| 图片 | Community hotfix | **新增 WXGF 支持**：微信 4.0 新格式图片（wxgf 容器）JS 兜底识别 + HEVC/ffmpeg 解码 |
| 新功能 | — | AI Agent、灵感箱（上游新增，未经充分验证） |

### 最新源码版的组件配置（首次启动前）

最新源码采用**组件外置架构**，需要在配置文件（`%APPDATA%\WeFlow\WeFlow-config.json`）中指定四个组件路径（也可在「设置 → 数据库」界面配置）：

| 字段 | 指向 | 说明 |
|------|------|------|
| `wcdbLibPath` | `resources\resources\wcdb\win32\x64\wcdb_api.dll`（**需先用补丁脚本去时间锁**） | 数据库组件 |
| `welivePath` | `resources\resources\welive\win32\x64\welive.exe` | 导出引擎（**带过期锁，导出时会自动 fallback 到内置 WCDB 引擎**，无需处理） |
| `imageNativeAddonPath` | `resources\resources\wedecrypt\win32\x64\weflow-image-native-win32-x64.node` | 图片解密插件 |
| `keyProviderPath` | 任意实现 keyProvider 协议的可执行文件（NDJSON） | 密钥提取；**Portable 版已内置桥接脚本**（DPAPI 解密 + Rust CLI 双路） |

**推荐直接使用 Portable zip**（组件路径已全部预配置，解压即用）。

### 最新源码版的构建

```powershell
# 依赖（peer 冲突 + 缺失 peer 需手动补）
npm install --legacy-peer-deps
npm install @lobehub/ui antd --legacy-peer-deps

# 构建（产物在 release2\win-unpacked\）
# 注意：必须带两个镜像变量，且构建前关闭 WeFlow
$env:ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"
$env:ELECTRON_BUILDER_BINARIES_MIRROR="https://npmmirror.com/mirrors/electron-builder-binaries/"
npm run build

# 构建后两个补丁（见 patches/ 目录）
# 1. wcdb_api.dll 去时间锁
.\patches\patch_wcdb.ps1 -AppDir "<本目录>\release2\win-unpacked"
# 2. app.asar keyProvider 支持（.cjs 脚本 provider）
node ..\patch-app-asar.cjs "<本目录>\release2\win-unpacked\resources"
```

### 已知事项（最新源码版）

- 视频：微信按需下载——**未在微信里播放过的视频只有封面**（本体不在本地），在微信里点开播放后 WeFlow 即可查看
- 部分图片若仍失败：启动日志（`logEnabled: true`）会记录 native 插件加载的真实错误，欢迎反馈
- 上游版本号未变（仍为 5.0.0），实际代码为上游 main 分支最新（含 AI Agent 子系统）



- 环境：Windows 11 x64，微信 4.x，WeFlow 5.0.0（本仓库源码构建）
## 验证记录（2026-10-14）

- **-101/-1000**：应用 wcdb 补丁后正常时间直接启动，日志零 `rc=-101`，840 联系人成功读取
- **导出**：WeLive 引擎报 expired 后自动切换 WCDB 导出路径，**聊天记录导出正常完成** ✓
- 构建过程零踩坑复现：干净目录 + `npm install --legacy-peer-deps` + `npm run build` + 补丁脚本，一次通过

## 已知限制

- 仅 Windows。时间锁只存在于 Windows 版 `wcdb_api.dll`
- WeFlow 自动更新会覆盖 DLL 补丁，更新后需重跑补丁脚本
- welive.exe 本体的过期锁未被移除（本方案让它不再被导出流程依赖）；如需 WeLive 全功能（朋友圈/语音转写等），可关注上游社区后续
- 闭源组件带遥测（`api.weflow.top`），介意可在防火墙加出站拦截规则

## 致谢

- [hicccc77/WeFlow](https://github.com/hicccc77/WeFlow) —— 原项目
- [密语 CipherTalk (miyu)](https://github.com/ILoveBingLu/miyu) —— 原项目基础框架
- [AnonymousUser443/WeFlow-Community-Patch](https://github.com/AnonymousUser443/WeFlow-Community-Patch) 与 [Dinnerb0ne2/WeFlow-WCDB-Patch](https://github.com/Dinnerb0ne2/WeFlow-WCDB-Patch) —— 补丁脚本与逆向分析
- [mjkyleo/weflow](https://github.com/mjkyleo/weflow) —— 5.0.0 完整分发备份
