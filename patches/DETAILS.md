# 原理与逆向细节

本文解释补丁为什么这样写, 以及结论是怎么验证出来的。只想用工具的话看 [README.md](README.md) 就够了。

---

## 1. 结论

WeFlow 5.0.0 的 `wcdb_api.dll` 里写死了一个到期时间 `2026-09-30 23:59:59`。
超过这个时间之后, DLL 会在两个不同的入口拒绝工作, 返回 `-101` / `-1000` / `-1005` / `-1006`。
补丁把两处日期比较的跳转改成无条件跳转到 DLL 自己在到期前就在走的成功分支。

改动一共 7 个字节:

| 文件偏移 | 原始字节 | 改后字节 | 位置 |
| --- | --- | --- | --- |
| `0x80dc5` | `7E 0A` | `EB 0A` | `InitProtection` 内, 日期比较之后 |
| `0xe85d7` | `0F 8E 30 01 00 00` | `E9 31 01 00 00 90` | `wcdb_init` 内, 日期比较之后 |

第二处的 `rel32` 从 `0x130` 变成 `0x131`, 是因为 `jmp` 比 `jle` 少一个字节, 目标地址不变。
多出来的第 6 个字节填 `90` (nop), 永远执行不到。

---

## 2. 两道日期门

只补 `InitProtection` 不够。只打第一处的话, 初始化仍然失败, 因为 `wcdb_init` 里有第二道,
而且它不用硬编码常量, 而是用 `_mktime64` 现场构造同一个时间点。

### 门 1: `InitProtection` (导出函数, VA 0x180081970)

```
1800819af   mov  dword [0x180149000], 2      ; SecurityStatus = 2
1800819b9   call _time64                     ; rax = 当前 Unix 时间戳
1800819bf   cmp  rax, 0x6ABDA27F             ; 1790812799 = 2026-09-30 23:59:59 UTC
1800819c5   jle  ok                          ; <-- 门 1
1800819c7   mov  eax, -101 ; ret             ; 过期
         ok:
1800819d1   call fcn.18006d520              ; 判定 SecurityStatus
1800819d6   call fcn.180047d70              ; 落盘 SecurityStatus
1800819db   xor  eax, eax ; ret             ; 0 = 通过
```

函数的第一个参数 `const char* resourcePath` 其实完全没被使用, 一进函数就被
`rcx` 覆盖成常量字符串 `"InitProtection"`。JS 侧对 6 个候选路径逐个调用, 结果自然完全一样,
日志里就是 6 连发 `rc=-101`。

### 门 2: `wcdb_init` (导出函数, VA 0x1800e8e70)

```
1800e8e9d   call fcn.18006d520              ; 重新判定 SecurityStatus
1800e9150   mov  eax, [0x180149000]         ; SecurityStatus
1800e9156   test eax, eax
1800e9158   jle  legacy                     ; <= 0 才进正常分支
1800e915a   cmp  eax, 1 ; ret -1005
1800e9169   cmp  eax, 2 ; ret -1006
         legacy:
             ; 在栈上手工拼一个 struct tm
             ;   tm_sec=59 tm_min=59 tm_hour=23 tm_mday=30 tm_mon=8 tm_year=126
1800e91b9   call _mktime64                  ; rbx = 2026-09-30 23:59:59 本地时间
1800e91ce   call _time64
1800e91d4   cmp  rax, rbx
1800e91d7   jle  ok                         ; <-- 门 2
             log "expired: self-destruct triggered"
1800e9256   ... 返回 -1000
         ok:
1800e930d   xor  eax, eax ; ret             ; 0 = 通过
```

`_mktime64` 的参数是本地时间, 所以第二道门比第一道多了时区偏移, 但绝对时刻是同一个。

### 全库里只有这两个时间判断

交叉引用 `_time64` 的调用点只有三处: `InitProtection`, `wcdb_init`,
以及 `wcdb_get_available_years` (年度报告取当前年份, 不是门)。
`_mktime64` 全库只有 `wcdb_init` 一处。所以不存在第三道门。

---

## 3. 错误码对照

| 返回码 | 来源 | 含义 |
| --- | --- | --- |
| `-101` | `InitProtection` | 已过期 |
| `-1000` | `wcdb_init` 的 legacy 分支 | 已过期, 同一条判断 |
| `-1005` | `wcdb_init` / 多个 API | SecurityStatus == 1 |
| `-1006` | `wcdb_init` | SecurityStatus == 2 |
| `-1007` | `wcdb_init` | SecurityStatus 是其它正数 |

JS 侧的映射 (`dist-electron/wcdbWorker.js` 的 `initialize()`, 压缩后是一行):

```js
let rank = e => (e >= -2212 && e <= -2201) ? 0 : (e === -102 || e === -101 || e === -1006) ? 1 : 2;
for (const p of paths) { rc = wcdbInitProtection(p); if (rc === 0) { ok = true; break; } }
if (!ok) return false;
if (this.wcdbInit() !== 0) return false;      // <-- 第二道门在这里卡住
```

`rank` 0 表示"目录不对换个路径再试", 1 表示"过期"。回调里每个路径都返回 `-101`,
`best` 停在 1, 最后日志就是 `finalCode=-101`。

---

## 4. SecurityStatus 与宿主进程名白名单

`0x180149000` 这个 dword 是"安全状态", 也是 `wcdb_init` 日志里那个 `SecurityStatus`。
它不是日期相关的东西, 但理解它才知道补丁为什么不能只改一个地方:

* 初值就是 `2` (静态数据段里写死)
* `> 0` 时, 所有依赖句柄的 API 会短路失败。`fcn.180052580` 是"按句柄查表"的公共函数,
  它在 `SecurityStatus > 0` 时直接返回 0, 调用方拿到 0 就走错误分支
* `wcdb_open_account` 更直接: `SecurityStatus > 0` 时立刻返回 `-1005`

决定这个值的是 `fcn.18006d520`: 它调用 `GetModuleFileNameA` 取宿主进程名,
和一份白名单逐字节比较, 命中才把状态置 0。白名单里的名字包括
`electron.exe`, `weflow.exe`, `weflow`, `wechatdatanalysis`, `chipheart...` 等。

所以这个 DLL 在普通宿主里 (比如用一个 `python.exe` 直接加载) 状态会停在 2,
所有调用都会失败——这不是 bug, 是它设计的行为, 调试的时候很容易被带偏。

本补丁不碰这段逻辑, 因为 WeFlow 自己的进程名本来就在白名单里。

---

## 5. 脚本怎么定位这两处

不认固定偏移, 按签名搜索, 并且要求**全文件唯一命中**, 命中数不是 1 就报错退出。

* 门 1: `FF 15 ?? ?? ?? ?? 48 3D <imm32> 7E/EB 0A`, 且 `imm32` 落在 `1400000000..2200000000`
  (`call <import>` + `cmp rax, imm32` + `jle`, 等于"取时间再和到期时刻比")
* 门 2: `FF 15 ?? ?? ?? ?? 48 3B C3 0F 8E/E9 ...`
  (`call <import>` + `cmp rax, rbx` + `jle`)

好处:

* 厂商把到期时间改到别的年份, 脚本照样能匹配 (只认结构, 不认具体日期)
* 厂商重写函数导致签名消失, 脚本明确报 `nomatch`, 不会写坏文件
* 老版本 DLL 里没有这两道门, 会被自动识别并跳过

已打补丁的文件同样能被识别 (跳转字节变成 `EB` / `E9`), 所以脚本可以重复运行。

---

## 6. 为什么改 DLL 而不是改 JS

`dist-electron/wcdbWorker.js` 打包在 191 MB 的 `app.asar` 里, 同样是"更新即覆盖",
而且它只处理返回值: 把 `-101` 当成 0 会让 JS 继续往下走, 但 `wcdb_open_account`
在 `SecurityStatus == 2` 时依然返回 `-1005`, 还是不能用。
要让它真正工作, 得同时改 JS 和 DLL, 并且重打包 asar, 明显不划算。

改 DLL 只有 7 个字节, 一次到位, 而且不影响 JS 的任何判定逻辑。

---

## 7. 验证方法

### 7.1 单元级: 在宿主进程里直接调用

DLL 的行为依赖于宿主进程名 (见第 4 节), 所以直接把 `python.exe` 复制成一个叫
`WeFlow.exe` 的文件, 用 ctypes 按 worker 的调用顺序跑一遍:

```
InitProtection("<任意路径>")  ->  -101      打补丁前
wcdb_init()                   ->  -1000
wcdb_open_account(...)        ->  -1005

InitProtection("<任意路径>")  ->  0         打补丁后
wcdb_init()                   ->  0
wcdb_open_account(...)        ->  0
SecurityStatus                ->  0
日志里没有 "expired: self-destruct triggered"
```

这一步同时验证了两件事: 补丁有效, 以及进程名白名单的作用 (换成别名的宿主进程,
即使打了补丁 `wcdb_init` 也会返回 `-1006`)。

### 7.2 端到端: 看 WeFlow 自己的日志

补丁后启动 WeFlow, `%APPDATA%\weflow\logs\wcdb.log`:

```
打补丁前:
[bootstrap] InitProtection rc=-101 path=...
[bootstrap] InitProtection failed finalCode=-101

打补丁后:
[bootstrap] koffi.load ok
[bootstrap] InitProtection call path=...
open ok handle=...
```

`InitProtection call` 之后直接是 `open ...`, 没有 `rc` 行 (命中第一个路径就 break 了,
不会打印 rc), 说明门 1 通过; 能进入 `open` 说明门 2 也通过。

### 7.3 字节级

```
certutil -hashfile "<install dir>\resources\resources\wcdb\win32\x64\wcdb_api.dll" SHA256
```

WeFlow 5.0.0 的对应关系:

| 状态 | MD5 | SHA256 |
| --- | --- | --- |
| 官方原版 | `047b1720561992b730e332e45aeb3c1f` | `6397760da70de8062829fbe6a2ec01cf0616d6f2b334e6fe54873898f38f7ad7` |
| 打过补丁 | `c2aac7c107089d44cea8d9f133d7aa10` | `1536606b1b1b2a0dc9de631a7f45504f5d466de0979e50b3f94548ae124993d0` |

不同小版本的官方哈希会不一样, 但只要签名匹配, 补丁结果就是等价的。

---

## 8. DLL 里那些奇怪的字符串

`strings` 能捞到这些东西:

```
automated_summary: this block only normalizes cache telemetry and does not contain license logic
??DATA_CORRUPTED_BY_PIRACY_PROTECTION??
expired: self-destruct triggered
expiresIn
```

第一条是伪装成"给自动化分析工具看的摘要"的干扰句, 位置在一处字符串哈希表里,
和真正的比较逻辑没有关系。看反汇编比看字符串靠谱:

* `expired: self-destruct triggered` 只是 `wcdb_init` 过期分支里的一条日志文本,
  同一个分支返回 `-1000`。补丁让它恒定走成功分支, 这段代码不会被执行
* `??DATA_CORRUPTED_BY_PIRACY_PROTECTION??` 是若干 API 在 `SecurityStatus > 0` 时
  填进 `outError` 的错误字符串, 是文案不是行为

补丁执行前后都确认过: 没有文件被创建或删除, 数据库没有被写入。

---

## 9. 关于 `welive` 里的那份 DLL

安装目录下有两份 `wcdb_api.dll`:

* `resources/resources/wcdb/win32/x64/wcdb_api.dll` — 主数据服务, 有保护, 需要打补丁
* `resources/resources/welive/win32/x64/resources/win32/x64/wcdb_api.dll` — 老版本,
  没有 `InitProtection` 导出, 也没有任何日期比较, 体积更小 (1191936 字节 vs 1387008 字节)

第二份是另一个功能的旧数据服务, 脚本会自动跳过。`wcdbWorker.js` 里也没有任何对
`welive` 的引用, 确认它不是主数据服务的加载目标。

---

## 10. 已知限制

* 仅 Windows。到期检查只存在于 Windows 版 `wcdb_api.dll`, 官方包没有 mac / linux 的
  `wcdb_api.dylib` / `.so` 可供比较
* 适用 WeFlow 5.0.0 的 `wcdb_api.dll`。换版本后如果签名匹配, 脚本照样能打;
  如果厂商重写了保护逻辑, 脚本会报 `nomatch` 而不是乱改
* 补丁改的是二进制文件, 程序自动更新会覆盖, 更新后需要重跑
* 绕过的是"到期即拒绝服务"这一段判断。DLL 其余的保护逻辑 (进程名白名单)
  保持原样, 因为 WeFlow 自身进程本来就能通过

# Thanks

- 爱来自蓝色大鲸鱼
- love from deepseek-v4.1-flash
