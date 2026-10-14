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

## 验证记录（2026-10-14）

- 环境：Windows 11 x64，微信 4.x，WeFlow 5.0.0（本仓库源码构建）
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
