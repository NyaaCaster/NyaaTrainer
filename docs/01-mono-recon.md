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

#### 情况 C：**没有任何静态单例**时，走 UI 管理器兜底（✅ 2026-09-20 实测）

`Nurtale Nesche` 是这种：全程序集扫描确认 **`Player` / `Health` 都没有任何静态字段持有**
（扫 `NurtaleNesche.Runtime` 全部类，0 命中）。这时**不要**急着去做指针扫描或 AOB 猜值。

**更快的路：找 UI 管理器**。HUD 要显示数值，就必然持有数据对象的引用，
而管理器本身往往是**静态单例**：

```lua
-- GUIHUDManager.instance（静态字段 @ offset 0）
--   +0x28  healthGUI → HealthCanvasManager
--            +0x20  health → Health        ← 数据对象到手
--   +0x50  arouseGaugeManager → ArouseGaugeManager
```

**为什么这条比指针扫描好**：

| 手段 | 稳定性来源 | 问题 |
|---|---|---|
| AOB 特征扫描 | 游戏数据里的**具体数值** | ⚠️ 玩家一升级（`maxHealth` 35→39）就失配 |
| UI 管理器单例 | **类名 + 字段偏移** | ✅ 与数值无关，跨重启有效 |

**排查顺序建议**：① 静态单例持有数据 → ② 全程序集扫静态字段（确认确实没有）→
③ **UI 管理器单例 → 子管理器 → 数据对象** → ④ 指针反查 → ⑤ 才考虑 AOB。

**补充技巧：反查指针拿"上层对象"**

数据对象拿到后，若还需要它的**持有者**（例如 `Player`），可以**搜指向它的指针**：

```lua
-- 搜哪些位置存着这个地址（8 字节小端模式）
local function findPtrTo(addr)
  local b = {}
  local v = addr
  for i = 0, 7 do
    b[#b+1] = string.format('%02X', v % 256)   -- 用取模而非位运算，见下方坑位
    v = math.floor(v / 256)
  end
  return AOBScan(table.concat(b, ' '))
end
-- 对每个命中位置，用候选偏移试 mono_object_getClass，类名对得上就是它
--   实测：Health ← PlayerHealthManager(+0x20) ← Player(+0xD8)
```

> ⚠️ `mono_object_getClass` 对**任意地址**都会返回字符串（不是 nil），
> 所以**必须严格校验类名**（过滤不可打印字符），否则全是假阳性。
> 实测教训：靠"向上扫偏移找对象基址"得到一堆垃圾类名，白费很多轮。

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
| 改 UI 类的字段 | 数值改了没反应 | UI 是副本，要改**数据容器**里的源字段；详见下方"只写字段界面不动" |
| **只写字段界面不动** | 回读值确实变了，但**界面不刷新**，且游戏下次更新就覆盖回来 | 字段是**显示副本**，UI 靠**事件通知**刷新 → 必须**调方法**（如 `Set()`），见 §8.6 |
| **以为 CE 调不了托管方法** | 探测 `mono_runtime_invoke` 得到 `nil` | 那是 Mono 原生名；CE 的封装叫 **`mono_invoke_method`**，在 `autorun\monoscript.lua` 里，见 §8 |
| **`mono_class_enumMethods` 看不到父类方法** | 在子类上找不到 `Set` / `ForceActivate` 等 | `enumMethods` **只列本类声明的方法**；去**父类**（`mono_class_getParent`）找，再对子类实例调用 |
| **`enumFields` 看不到父类字段** | 明明有数据的 `+0x40` 不在字段表里 | 同上：只列本类声明。继承来的字段要查父类的 `enumFields` |
| **手工改托管容器内部结构** | 数据层验证全对，但**游戏崩溃** | **绝不能写**托管 `Dictionary` / `List` 的内部结构（entries/buckets/count）。要改就调游戏自己的方法，见 §8.5 |
| **管道失效时继续调托管方法** | 偶发**游戏崩溃** | 调用前必须 `pipeOK()` 自检（见 §8.4）；一次只做一个操作，循环时每步复查 |
| **Lua `local` 作用域** | 日志显示解析成功，实际逻辑却报"未解析" | `local` 是**词法作用域**：函数定义时不可见的 local，在函数体里会退化成**读全局**。共享变量统一声明在**文件最前面** |
| **`mono_object_getClass` 假阳性** | 对任意地址都返回字符串（不是 nil），"向上扫偏移找对象基址"得到一堆垃圾类名 | 必须**严格校验类名**（过滤不可打印字符 `[\0-\31]`），否则全是假阳性 |
| **`mono_class_findInstancesOfClass` 返回 nil** | 静默失败，以为是 API 不可用 | CE 内部依赖 `mono_method_get_parameters` 拿到参数；采集器状态不健康时它返回 0 个参数 → 静默退出。**重新注入采集器**后再试 |
| **AOB 特征依赖具体数值** | 用 `maxHealth/healthCap/...` 的绝对值做特征，玩家一升级（35→39）就失配 | 优先用**类名 + 字段偏移**；必须用 AOB 时挑与玩家进度无关的稳定字节 |
| **`getScreenWidth()` / `MainForm.Width` 当屏幕宽度** | 面板被压到标签截断（实测一个返回物理像素、一个是 CE 主窗口尺寸，跨会话还不同） | 面板宽度**由内容决定 + 固定上限**，并给名字列设**保底宽度**；详见 `CE独立修改器方法.md` |
| **Lua 脚本里写裸 `<` 或 `&`** | `.CT` 加载成功但 LuaScript **静默不执行**；或 XML 解析器报 `invalid token` | 条件写成 `>` 形式；位运算改取模/取整（`v % 256; v = floor(v/256)`）。**注释里的裸字符同样会坏事** |

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
| **调用方法** | **`mono_invoke_method(domain, method, object, args)`** ← 见 §8 |
| 构造字符串参数 | `mono_new_string(domain, utf8str)` |
| 取方法签名 | `mono_method_get_parameters(method)` → `{parameters = {{name=, type=, monotype=}}}` |
| 对象 | `mono_object_getClass(addr)`（**只接受对象起始地址**，字段地址返回 nil） |
| 有效性 | `mono_isValid()` / `mono_AttachedProcess` |
| 实例枚举 | `mono_class_findInstancesOfClass(domain, klass, ...)`（较慢，慎用） |

**读内存**（CE 通用）：`readPointer` / `readInteger` / `readQword` / `readFloat` / `writeInteger`

---

## 8. 调用托管方法（`mono_invoke_method`）— ✅ 2026-09-20 实测跑通

> **这一节纠正一个容易犯的错**：CE **能**调用托管方法。
> 我一度探测全局函数名 `mono_runtime_invoke` 得到 `nil`，就下结论"CE 调不了托管方法" ——
> **那是 Mono 的原生导出名，CE 没暴露它**。CE 自己的封装在
> `<CE_DIR>\autorun\monoscript.lua` 里，名字是 **`mono_invoke_method`**。
> **教训：探测 API 时不要只试原生名，要去读 monoscript.lua。**

### 8.1 签名（源码 `monoscript.lua` 确认）

```lua
mono_invoke_method(domain, method, object, args)   -- 完整版
mono_invoke(methodname, instance, arguments)        -- 简化版（domain 传 nil）
```

- `method` 既可以是**方法指针**，也可以是**方法名字符串**（内部走 `mono_findMethod`）
- `object` 是实例指针；静态方法传 `nil`
- `args` 是数组表，元素可传**裸值**（CE 按参数类型自动推导），也可传 `{type=, value=}`
- 返回值：`result, vtype, exception`（异常是**读出来的**，不抛）

### 8.2 拿方法指针 + 确认签名

```lua
-- 取方法指针（enumMethods 返回 {method=, name=, flags=}）
local function findMethod(clsName, mName)
  local c = mono_findClass('', clsName)
  for i = 1, #mono_class_enumMethods(c) do
    local m = mono_class_enumMethods(c)[i]
    if m.name == mName then return m.method end
  end
  return nil, 'not found: ' .. mName
end

-- 确认参数（构造 args 前建议先看一遍）
local ok, params = pcall(mono_method_get_parameters, m)
-- params.parameters[i].name / .type / .monotype
```

### 8.3 调用示例

```lua
local dom = mono_enumDomains()[1]
local m   = findMethod('SomeManager', 'SetValue')

-- 需要字符串参数时，先造托管字符串
local s = mono_new_string(dom, 'some_id')

-- 单参数
local ok, r = pcall(mono_invoke_method, dom, m, instanceAddr, { s })
-- 多参数（字符串 + 整数）
local ok2, r2 = pcall(mono_invoke_method, dom, m, instanceAddr, { s, 3 })
```

### 8.4 ⚠️ 硬规矩：调用前必须检查管道健康

**这是拿两次游戏崩溃换来的。**

`mono_invoke_method` 走 **每线程命名管道** 通信。管道失效时若继续调用，
会把垃圾写进管道 → 采集器解析出错 → **目标进程崩溃**。

源码（`monoscript.lua` 的 `getMonoPipe`）：

```lua
local tid = getCurrentThreadID()
local result = libmono.monopipes[tid]        -- ★ 管道按【线程 ID】缓存
if result and (result.Connected == false) then
  result.destroy(); libmono.monopipes[tid] = nil; result = nil
end
-- 开头还有：
if readInteger(libmono.MDC_ShuttingDownAddress) ~= 0 then return nil end
```

所以调用前必须自检：

```lua
local function pipeOK()
  if type(libmono) ~= 'table' then return false, 'libmono missing' end
  if libmono.abort then return false, 'libmono.abort' end
  if readInteger(libmono.MDC_ShuttingDownAddress) ~= 0 then return false, 'shutting down' end
  local p = libmono.monopipes[getCurrentThreadID()]
  if p == nil then return false, 'no pipe for thread' end
  if p.Connected == false then return false, 'pipe disconnected' end
  if libmono.monopipe == nil then return false, 'monopipe nil' end
  return true
end

-- 用法：不健康就拒绝调用，宁可失败也不带病操作
local pk, why = pipeOK()
if not pk then return false, 'pipe not healthy: ' .. tostring(why) end
```

**配套的保守设计**：

1. **一次只做一个操作** —— 不在一个脚本里连续调用多个托管方法
2. 需要循环时（如逐级降级），**每一步之间重新检查管道**
3. 周期性调用（如锁定数值）**间隔不要低于 200ms**，并做**同值限流**
4. 调用后若 `mono_AttachedProcess` 变 nil，重新 `LaunchMonoDataCollector()` 再继续

### 8.5 ⚠️ 硬规矩：不要手工改托管容器的内部结构

**另一个拿崩溃换来的教训。**

为了让一个未激活的状态"看起来激活"，我曾手工往 `Dictionary` 的 entries 空闲槽位写条目、
改 `_count` / `_version`、还修 `buckets` 链表。**数据层验证全对**（模拟 `ContainsKey` 能命中），
但**游戏崩溃** —— 破坏了哈希表与游戏内部状态的一致性。

**正解：能调方法就调方法**（`ForceActivate` / `Set` / `TrySetLevel`…），
方法内部会一并处理好事件通知与 UI 刷新。**手工改容器只能读，不能写。**

### 8.6 判据：什么时候"必须"调方法而不能只写字段

| 现象 | 结论 |
|---|---|
| 写字段后**回读正确**，但**界面不动** | 字段是**显示副本**，值的变更靠**事件通知**驱动 UI |
| 写字段后游戏下一次更新就**覆盖回来** | 字段是副本，真源在别处（往往在父类的字段里） |
| 找真源的办法 | 看**继承链**（`mono_class_getParent`）——`enumFields` 只列**本类声明**的字段，继承来的看不到 |

**实战案例**：`ArouseGaugeManager.currentarouse` 写不动界面 → 真源是父类
`SexualHeatManager._heat`（在 `PlayerSexualArousalManager` 的 `+0x40`，继承而得）→
调 `SexualHeatManager.Set(value)` 后**数据与 UI 同时同步**。

### 8.7 调用后 Mono "掉线"是正常现象

独立 CE 里调用托管方法后，`mono_AttachedProcess` 常变成 nil。
**这不是崩溃**，重新 `LaunchMonoDataCollector()` 即可恢复。
（打包成 trainer 后由 CE 自己管理，不受此影响。）

---

## 9. 与其它文档的关系

| 想做什么 | 看哪 |
|---|---|
| 摸清一个 Mono 游戏的数据结构 | **本文** |
| **调用游戏自己的方法改状态** | **本文 §8** |
| 把找到的地址固定成重启后仍有效的条目 | `CE稳定地址方法.md` |
| 把条目打包成双击即用的独立修改器 | `CE独立修改器方法.md` |
| CE 通道怎么用（DSH 怎么驱动 CE） | `CE工具用法.md` |
