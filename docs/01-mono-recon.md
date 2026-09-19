# Mono 内核 API 探索修改法：从零摸清一个 Unity 游戏的数据结构

> **本文解决什么**：拿到一个从没碰过的 Unity Mono 游戏，不知道数值在哪、界面也不显示数字时，
> 怎么**有条理地**把"哪个类的哪个字段是 HP"这件事查清楚。
>
> **定位**：这是 **方法层**文档。
> 上游是"怎么把地址固定下来"→ `CE稳定地址方法.md`；
> 下游是"怎么打包成修改器"→ `CE独立修改器方法.md`。
>
> 建立：2026-09-19；基于两个真实项目：
> `パンドラメイズ260427`（静态字段型）与 `淫白の御供`（实例字段型）。

---

## 0. 为什么不要一上来就扫内存

传统 CE 玩法是"扫值 → 筛 → 找指针"。**在 Unity Mono 游戏上这经常是最慢的路**，原因：

| 现象 | 原因 |
|---|---|
| 扫出来的地址重启就变 | 托管堆对象会被 GC 移动；静态字段区每次启动重新分配 |
| 找不到指向它的指针 | 数据在 Mono 的托管堆里，CE 的指针扫描扫不到托管引用链 |
| 界面不显示数值时**根本无从扫起** | 不知道目标值是多少（比如只有一根进度条） |
| 命中几十万个 | 靠"值看起来像什么"去猜（血泪教训见下） |

**Mono 游戏的正解**：**先问游戏自己**——用 `mono_*` API 把类结构 dump 出来，字段名往往直接就叫
`currentHp` / `maxHp` / `day`。**两个项目的实际对比**：

| | パンドラメイズ | 淫白の御供 |
|---|---|---|
| 做法 | 扫值 → 断点 → 反查静态字段 | **直接 dump 类结构 → 读字段偏移** |
| 轮次 | 十几轮 | **3 轮** |
| 耗时 | 1~2 小时 | 几分钟 |

---

## 1. 前置：让 CE 具备 Mono 能力

CE 自带 Mono 接口（`<CE_DIR>\autorun\monoscript.lua`，约 200 KB），但 **CE 7.x 不执行 `autorun` 目录**，
必须手动加载：

```lua
dofile(getCheatEngineDir() .. 'autorun\\monoscript.lua')   -- 加载 mono_* API
LaunchMonoDataCollector()                                   -- 注入采集器到目标进程
-- 之后 mono_AttachedProcess = 目标 pid
```

**检查清单**（每次新开 CE 会话都要走一遍）：

```lua
local out = {}
out[#out+1] = 'openedPid      = ' .. tostring(getOpenedProcessID())
out[#out+1] = 'mono_Attached  = ' .. tostring(mono_AttachedProcess)
out[#out+1] = 'mono_isValid   = ' .. tostring(mono_isValid and mono_isValid() or 'no-fn')
local mods = enumModules()
for k, m in pairs(mods) do
  if tostring(m.Name):find('MonoDataCollector') then
    out[#out+1] = 'MonoDataCollector: ' .. tostring(m.Name)
  end
end
return table.concat(out, '\n')
```

**判断后端**（决定用哪套 API）：

| 模块特征 | 后端 | 可行性 |
|---|---|---|
| `mono-2.0-bdwgc.dll` | Unity **Mono** | ✅ 本文全部适用 |
| `GameAssembly.dll` + `il2cpp` | Unity **IL2CPP** | ⚠️ API 不同，`mono_*` 多数不可用，得用 CE 的 IL2CPP 支持或走断点 |

> ⚠️ **游戏重启后采集器会掉线**（`mono_AttachedProcess = nil`）：切场景、读档、重启都会。
> **只重新 `openProcess` 是不够的**，必须重新 `LaunchMonoDataCollector()` 并等约 5 秒。

---

## 2. 核心探索流程（5 步）

```
①列游戏程序集 → ②dump 类清单 → ③按名字锁定候选类
→ ④dump 字段偏移 → ⑤沿引用链找到实例并验证
```

### 2.1 ① 列出游戏自己的程序集

一个 Unity 游戏通常只有 1~3 个自己写的程序集（其余是 Unity 引擎和 .NET 框架）：

```lua
local asms = mono_enumAssemblies() or {}
for i = 1, #asms do
  local img = mono_getImageFromAssembly(asms[i])
  if img and img ~= 0 then
    local nm = tostring(mono_image_get_name(img))
    if nm:find('Assembly%-CSharp') then          -- 游戏自己的代码
      print(nm, 'classes =', #(mono_image_enumClasses(img) or {}))
    end
  end
end
```

实测规模：`パンドラメイズ` 13495 个类（含框架）、`淫白の御供` 的 `Assembly-CSharp` 只有 **123 个类**。

**类少就是最大的优势** —— 123 个类可以直接全列出来肉眼找。

### 2.2 ② dump 类清单

```lua
local img = -- 上一步拿到的那张 image
local cs = mono_image_enumClasses(img)
local names = {}
for i = 1, #cs do
  local r = cs[i]
  names[#names+1] = ((r.namespace or '') ~= '' and (r.namespace .. '.') or '') .. (r.classname or '?')
end
table.sort(names)
```

> ⚠️ `mono_image_enumClasses` 返回的是 **table**，元素形如
> `{class=<裸指针>, classname=<字符串>, namespace=<字符串>}` —— **类名是现成的**，不用额外查询。
> 把元素直接丢给 `mono_class_getName` 只会拿到空串（这是高频坑）。

### 2.3 ③ 按名字锁定候选类

拿 `淫白の御供` 的真实类清单举例，信号一目了然：

```
GameData          ← 数据容器（首选目标）
GameManager       ← 单例管理器（通常是入口）
GameUI / SkillUI  ← UI（不要改这里，改了界面不会动数据）
GrowthDataSlot / MaxStatFlower / HealItem   ← 成长/道具
SaveFile / SaveManager / SaveSlotInfo       ← 存档
StatType / SkillType                        ← 枚举（看有哪些属性）
```

**经验法则**：

| 类名特征 | 判断 |
|---|---|
| `GameData` / `PlayerData` / `SaveData` / `Variable*` | **数据容器** → 数值就在字段里 |
| `*Manager` / `*Controller` | **入口/单例** → 从这里顺着引用找数据容器 |
| `*UI` / `*View` / `*Text` / `*Icon` | UI 层，**是副本不是源** |
| `*Type` / `*Slot` / `*Kind` | 枚举，用来理解字段语义 |

### 2.4 ④ dump 字段偏移

```lua
local c = mono_findClass('', 'GameData')        -- 有命名空间就 mono_findClass('Ns', 'Class')
local fds = mono_class_enumFields(c)
for i = 1, #fds do
  local f = fds[i]
  if f.name ~= 'value__' then                    -- value__ 是枚举的内部字段，跳过
    local kind = f.isConst and 'const' or (f.isStatic and 'static' or 'inst')
    print(string.format('%-36s off=%-6s %s', tostring(f.name), tostring(f.offset), kind))
  end
end
```

**实测输出（`淫白の御供` 的 `GameData`）** —— 字段名完全没混淆：

```
currentHp      off=24    inst      ← HP
maxHp          off=28    inst      ← HP 上限
currentMp      off=32    inst
maxMp          off=36    inst
reachedStage   off=40    inst
remainingDays  off=44    inst
day            off=48    inst      ← 天数
deathCount     off=52    inst
playTimeSeconds off=56   inst
homeVineGrown  off=64    inst      ← 一堆进度标志
...
unlockedSkills off=16    inst      ← 引用类型
```

**这一步做完，数值基本就到手了。**

### 2.5 ⑤ 找到实例并验证

字段偏移有了，还差"对象在哪"。分两种情况：

#### 情况 A：静态字段型（数据直接挂在静态字段上）

`パンドラメイズ` 就是这种。

```lua
local domain = mono_enumDomains()[1]
local c = mono_findClass('', 'VariableF')
local base = mono_class_getStaticFieldAddress(domain, c)   -- 静态数据区基址
local fields = mono_class_enumFields(c)
for i = 1, #fields do
  local f = fields[i]
  if f.isStatic and f.name == 'currentSAN' then
    print(string.format('SAN 地址 = %X', base + f.offset))
  end
end
```

**识别特征**：JIT 把静态字段的**绝对地址内联进机器码** —— 在反汇编里看到
`mov rcx, 000001AFE3EABEF8`（把一个高地址直接搬进寄存器）基本就能判定。

#### 情况 B：实例字段型（数据挂在对象上）

`淫白の御供` 是这种：`GameData` 没有静态数据区，得从单例走。

```lua
-- 第 1 跳：Manager 的静态 Instance
local mgr = mono_findClass('', 'GameManager')
local sbase = mono_class_getStaticFieldAddress(mono_enumDomains()[1], mgr)
local inst = nil
for _, f in ipairs(mono_class_enumFields(mgr)) do
  if f.isStatic and f.name:find('Instance', 1, true) then   -- 注意用模糊匹配
    inst = readPointer(sbase + f.offset)
    break
  end
end

-- 第 2 跳：实例里的 Data 引用
local data = nil
for _, f in ipairs(mono_class_enumFields(mgr)) do
  if (not f.isStatic) and f.name:find('Data', 1, true) then
    data = readPointer(inst + f.offset)
    break
  end
end

-- 读数值
print(string.format('HP = %d / %d', readInteger(data + 0x18), readInteger(data + 0x1C)))
```

**⚠️ 最高频的坑**：编译器给 C# property 生成的字段名是 **`<Data>k__BackingField`** 这种形式，
所以**必须用 `f.name:find('Data', 1, true)` 模糊匹配**，写 `f.name == 'Data'` 会永远匹配不上。
（我第一次就是精确匹配失败，报 `GameData is null`。）

---

## 3. 验证：怎么确认"找对了"

**不要**凭"字段名像"就下结论。按这个顺序验证：

| 步骤 | 做法 | 说明 |
|---|---|---|
| ① 数值自洽 | 读出的值是否落在合理范围 | 例：`HP=86 / MaxHP=103` → 83.5%，与界面进度条目测吻合 |
| ② 旁证 | 其它字段是否也说得通 | 例：`MP=50/MaxMP=50`（满的，符合"只有 HP 低于上限"）、`Deaths=0` |
| ③ **写入测试** | 改一个值，看界面是否跟着变 | **决定性**。改 `maxHp 103→200` → 血条应掉到 43% |
| ④ 跨进程验证 | 重启游戏，链条是否仍能解析出新地址 | 排除"碰巧命中" |

**写入测试的选值技巧**：改**分母**（`maxHp`）比改分子更直观 —— 进度条会明显缩短，
而且容易还原（记下原值）。

```lua
-- 写入并回读
writeInteger(data + 0x1C, 200)
print(readInteger(data + 0x1C))   -- 必须回读确认
```

**验证完立刻还原**，不要把游戏留在异常状态。

---

## 4. 字段偏移要动态取，不要硬编码

虽然 dump 一次就知道 `currentHp` 在 `0x18`，但**脚本里应该写成"按名字查偏移"**：

```lua
local function resolveField(data, classname, fieldname)
  local cls = mono_findClass('', classname)
  for _, f in ipairs(mono_class_enumFields(cls)) do
    if (not f.isStatic) and f.name == fieldname then
      return data + f.offset
    end
  end
end
```

**理由**：

- 游戏小版本更新可能调整字段顺序 → 硬编码偏移**静默失效**（读到垃圾值，不报错）
- 动态解析在字段消失时会**明确失败**，容易发现
- 换游戏时脚本只需改字段名列表

---

## 5. 常见坑速查（全部实测）

| 坑 | 现象 | 正解 |
|---|---|---|
| **property backing field 名** | `GameData is null`（精确匹配 `Data` 失败） | 字段真名是 `<Data>k__BackingField`，用 `find(..., 1, true)` 模糊匹配 |
| `mono_image_enumClasses` 当裸指针用 | `mono_class_getName(元素)` 返回空串 | 元素是 table：取 `.class` / `.classname` / `.namespace` |
| 重启游戏后采集器掉线 | `mono_enumDomains()` 返回 nil | 重新 `LaunchMonoDataCollector()` + 等 5 秒 |
| 类名带命名空间 | `mono_findClass('', 'Foo')` 找不到 | 用 `mono_findClass('My.Ns', 'Foo')`（或先整体试、失败再拆分） |
| 枚举类里有个 `value__` 字段 | 列表里混进无意义项 | `if f.name ~= 'value__' then` 过滤掉 |
| `mono_method_getSignature` 返回空 | 拿不到方法签名/IL | 方法可能**还没被 JIT 编译**，`address=0`。可先 `mono_compile_method(m)` |
| 直接扫内存找数值 | 命中几十万个，收敛不了 | 先 dump 结构；确实要扫时用**两次筛选法**（见 `CE稳定地址方法.md` §3） |
| 用"值像什么"去猜 | 把 `214/255 = 0.839216` 的颜色分量当成 HP 比例 | **不要模式猜测**。实测中这种"特征"命中的全是无关数据 |
| 改 UI 类的字段 | 数值改了没反应 | UI 是副本，要改**数据容器**里的源字段 |

---

## 6. 完整实战记录：`淫白の御供`

**背景**：界面只有进度条，看不到任何数字；HP 是唯一低于上限的数值。

| 轮次 | 动作 | 结果 |
|---|---|---|
| 1 | 检查 CE 附加 + Mono 状态 | 发现采集器未附加 → 加载 monoscript + `LaunchMonoDataCollector()` |
| 2 | 列 `Assembly-CSharp` 类清单 | **只有 123 个类**，肉眼可见 `GameData` / `GameManager` |
| 3 | dump `GameData` 字段 | **直接看到 `currentHp` / `maxHp` / `day`** |
| 4 | dump `GameManager` 找单例 | 拿到静态 `Instance` 和实例字段 `Data` |
| 5 | 沿链读取 | `HP=86 / MaxHP=103` → **83.5%，与进度条目测一致** |
| 6 | 写入测试 | `maxHp 103→200` → 血条掉到 43% → **用户确认** |
| 7 | 重启游戏后再解析 | 新 `GameData = 20E3B426A20`（旧的 `25AAFEDFAE0`），**链条照常成立** |

**最终定位链**：

```
GameManager.Instance (静态单例)
  → +0x20  GameData
  → +0x18  currentHp     +0x1C maxHp
  → +0x20  currentMp     +0x24 maxMp
  → +0x30  day           +0x2C remainingDays
  → +0x28  reachedStage  +0x34 deathCount
```

**一个"陷阱字段"的教训**：游戏里有个"技能点"，用户描述为"角色持有的、达到次数就解锁技能"。
我按 `skill/point` 搜遍全程序集，只找到 `SaveSlotInfo.skillCount` —— 那是**存档界面的只读快照**，
不是数据源。**真正的机制**藏在方法名里：

```
GameManager.CheckSkillUnlocksByMaxMP     ← 按 maxMP 判定
GameManager.IsSkillUnlocked
GameManager.UnlockSkill
```

**结论：这个游戏没有独立的"技能点"数值，技能解锁的判据就是 `maxMP`。**

> 教训：**字段找不到时，去 dump 方法名**。方法名（`CheckXxxByYyy`、`UnlockXxx`、
> `UpdateXxxState`）常常比字段名更能说明业务逻辑，而且不会被编译器重命名成 backing field。

---

## 7. 附：常用 API 速查

| 用途 | API |
|---|---|
| 域 / 程序集 / 映像 | `mono_enumDomains()` / `mono_enumAssemblies()` / `mono_getImageFromAssembly(asm)` |
| 类 | `mono_image_enumClasses(img)` / `mono_findClass(ns, name)` / `mono_class_getName(c)` |
| 字段 | `mono_class_enumFields(c)` → `{name, offset, isStatic, isConst, monotype}` |
| 静态数据区 | `mono_class_getStaticFieldAddress(domain, class)` |
| 方法 | `mono_class_enumMethods(c)` / `mono_method_getSignature(m)` / `mono_compile_method(m)` |
| 对象 | `mono_object_getClass(addr)`（**只接受对象起始地址**，字段地址返回 nil） |
| 有效性 | `mono_isValid()` / `mono_AttachedProcess` |
| 实例枚举 | `mono_class_findInstancesOfClass(domain, klass, ...)`（较慢，慎用） |

**读内存**（CE 通用）：`readPointer` / `readInteger` / `readQword` / `readFloat` / `writeInteger`

---

## 8. 与其它文档的关系

| 想做什么 | 看哪 |
|---|---|
| 摸清一个 Mono 游戏的数据结构 | **本文** |
| 把找到的地址固定成重启后仍有效的条目 | `CE稳定地址方法.md` |
| 把条目打包成双击即用的独立修改器 | `CE独立修改器方法.md` |
| CE 通道怎么用（DSH 怎么驱动 CE） | `CE工具用法.md` |
