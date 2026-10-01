# MQL5-OpenAI：让 MT5 通过 OpenAI 大模型执行交易与终端操作

一套纯 MQL5 实现的桥接方案：MT5 内的 EA 定时把市场/账户上下文发给
OpenAI Chat Completions（function calling），模型通过工具调用请求
"各种操作"，EA 在本地风险护栏保护下执行并回传结果，循环直到模型给出
最终答复。**全部代码自包含，无 DLL、无外部库。**

本包同时提供 **JEV 决策版**：接入 OpenRouter 上的 TypeSafe JEV 决策模型
（`typesafe/jev-1.13`），作为交易动作的概率化决策闸门（见下文"JEV 决策版"）。

## 目录结构（复制到 MT5 数据目录）

```
MQL5/
├─ Experts/          <- 需要复制
│  ├─ OpenAIBot.mq5         主 EA（OpenAI 聊天 + 工具调用）
│  ├─ OpenAIBot_JEV.mq5     JEV 版 EA（聊天式，见说明）
│  ├─ JevDecisionBot.mq5    JEV 决策闸门 EA（推荐用法）
│  └─ (编译出的 .ex5 放这里)
├─ Scripts/          <- 需要复制
│  ├─ OpenAITest.mq5        OpenAI 连通性测试脚本
│  ├─ JevTest.mq5           JEV Decisions API 测试脚本
│  └─ PendingExecutor.mq5   手动执行确认队列的工具
├─ Include/          <- 需要复制
│  ├─ Json.mqh             JSON 解析/序列化（自研）
│  ├─ HttpClient.mqh       WebRequest 封装（UTF-8 / char[] 处理）
│  ├─ Config.mqh           ini 读取 + 日志
│  ├─ Timeframes.mqh       周期字符串转换
│  ├─ OpenAIClient.mqh     OpenAI chat.completions + 工具循环
│  ├─ JevClient.mqh        JEV Decisions API 客户端（choice/noul/score）
│  └─ MT5Toolbox.mqh       工具总线：20 个工具 + 8 层护栏
└─ Files/
   ├─ OpenAIBot.ini.example -> OpenAIBot.ini（配置）
   ├─ OpenAIBot_JEV.ini.example
   ├─ JevDecisionBot.ini.example
   ├─ system_prompt.txt      系统提示词（可编辑）
   └─ OpenAIBot/
      ├─ inbox.txt           给模型的指令 / JEV 候选信号
      ├─ outbox.txt          模型回复 / JEV 决策结果
      ├─ confirm.txt         确认队列（confirmMode=on 时）
      └─ log.txt             活动日志
```

## 三步启动

1. **放文件**：按上表把 `Experts/`、`Scripts/`、`Files/` 内容复制进你的
   MT5 `MQL5` 目录（Windows 下路径类似
   `C:\Users\<你>\AppData\Roaming\MetaQuotes\Terminal\<ID>\MQL5\`），
   **并把 `Include/` 里的 7 个 `.mqh` 直接放进 `MQL5\Include\` 根目录**
   （本包所有 EA/脚本用 `#include <X.mqh>` 尖括号形式，MetaEditor 只从
   `MQL5\Include\` 根解析）。
2. **开放 URL + 填 Key**：
   - MT5 菜单 `工具 -> 选项 -> EA 交易 -> 勾选"允许 WebRequest 列表中的 URL"`
     → 添加 `https://api.openai.com`（若自定义 base_url 则添加对应域名）。
   - 在 EA 输入框填入 `API Key`（`sk-...`），或复制
     `Files/OpenAIBot.ini.example` 为 `Files/OpenAIBot.ini` 并在里面填 key
     （推荐，避免 key 出现在 chart properties 里）。
3. **编译运行**：MetaEditor 里 `F7` 编译 `OpenAIBot.mq5`（本包已用
   MetaEditor64 真机验证：6 个文件全部 `0 errors, 0 warnings`）；
   先跑一遍 `Scripts/OpenAITest.mq5` 验证连通性；再把 EA 拖到图表上，
   输入框 `dry_run=true`（默认配置示例已设为 true）观察输出，确认无误后
   再开真实交易。

> **部署验证**：`experts/` 与 `scripts/` 的 `.mq5` 均已通过
> MetaTrader 5 自带 MetaEditor64 命令行编译（0 错误 0 警告），
> 生成 `.ex5` 后可直接挂载到图表运行。

## 本地 OpenAI 兼容代理（开发测试用）

本包默认配置已指向一个本地 OpenAI 兼容网关：

- `base_url`：`http://host.docker.internal:9936/v1`
- `api_key`：`100216`
- `model`：`DeepSeek-V4-Flash-Official`（该网关支持多模型，见 `/v1/models`）

该网关已用 curl 实测通过：`chat/completions`、**function calling**、
多轮工具结果回传均与 OpenAI 协议一致（`choices[].message.tool_calls`）。

**使用注意**：
1. **URL 白名单**：MT5 菜单 `工具 -> 选项 -> EA 交易 -> 允许 WebRequest`
   里需要添加 `http://host.docker.internal:9936`。
   `host.docker.internal` 只在容器内解析到宿主机；在物理 Windows 上
   改成宿主机实际 IP（如 `http://192.168.x.x:9936`）。
2. **http 明文**：MT5 的 WebRequest 官方文档要求 https，但实际对
   localhost/局域网 http 通常放行（以终端实测为准；若报 4014/连接失败，
   优先确认白名单条目是否精确匹配 URL 前缀）。
3. 改回 OpenAI 官方：把 `base_url` 改 `https://api.openai.com/v1`、
   `api_key` 改 `sk-...`、`model` 改 `gpt-4o-mini` 等即可。

## JEV 决策版（OpenRouter / TypeSafe JEV）

> **重要**：JEV（`typesafe/jev-1.13`）**不是聊天模型**，而是 TypeSafe 的
> System One **决策模型**。它不生成自然语言，而是接收 `state`（应用状态）
> + 一组**类型化问题**，返回**带概率的结构化答案**（choice / noul / score）。
> 因此 JEV 不适合套用 OpenAI 聊天+工具调用流程，本包提供两种用法：

### 用法 A：JevDecisionBot.mq5（推荐，决策闸门）

把 JEV 当作交易动作的**概率化审核闸门**：

1. 信号来源二选一：
   - `signal_mode=1`：读取 `Files\OpenAIBot\inbox.txt` 里的候选信号行
     （格式 `open|SYMBOL|BUY|LOT`，可由其它 EA/脚本写入），
   - `signal_mode=2`：内置动量规则（RSI + MA）生成候选。
2. EA 把市场快照（行情/指标/持仓/账户/护栏状态）作为 `state`，
   向 JEV 问两个问题：
   - `action`（choice）：hold / open / close
   - `proceed`（noul）：当前是否安全开仓
3. 只有当 `action=open` 且 `confidence >= min_conf`、选项概率
   `>= min_prob`、`proceed >= 0.5` 时，才经 MT5Toolbox 护栏执行开仓；
   否则拒绝并记入 outbox。

实测（本包开发时验证）：一次完整决策约 965 输入 token、$0.00004，
延迟约 1.5 秒，返回 `action=hold(0.89) conf=0.83` 等结构化结果。

配置：复制 `Files/JevDecisionBot.ini.example` 为 `Files/OpenAIBot/JevDecisionBot.ini`
（或在 EA 输入框直接填 OpenRouter key）。**URL 白名单添加 `https://openrouter.ai`**。
先用 `Scripts/JevTest.mq5` 验证连通性。

### 用法 B：OpenAIBot_JEV.mq5（兼容预览，非推荐）

把 JEV 当聊天模型用的实验版（`model=typesafe/jev-1.13`、
`base_url=https://openrouter.ai/api/v1`）。**JEV 实际拒绝
chat/completions 端点**（报错 "is a decisions model"），所以此版本
**无法工作**，仅保留用于说明 JEV 的真实能力边界。真正要聊天工具循环，
请用主 EA + OpenAI，或换 OpenRouter 上的对话模型（如 `openai/gpt-*`）。

### JEV 决策 API 要点（供参考）

- 端点：`POST https://openrouter.ai/api/alpha/decisions`
- 认证：`Authorization: Bearer <OpenRouter key>`
- 请求：`{"model":"typesafe/jev-1.13","state":{...},"questions":{...}}`
- 问题类型：
  - `choice`：`criteria` 为对象 `{"选项":"说明",...}` → 返回 `choice` +
    `probabilities` + `confidence`
  - `noul`：`criteria` 为 `{"true":"...","false":"..."}` → 返回 `noul`（0–1）
  - `score`：`criteria` 为数组 `["最低","...","最高"]` → 返回 `score`（0–N-1）
    + `legend` + `probabilities` + `confidence`
- 输出 token 免费，按输入 token 计费（`usage.cost` 返回美元）。
- 实现见 `include/JevClient.mqh`，测试见 `scripts/JevTest.mq5`。

## 安全护栏（护栏在本地强制执行，模型数字一律不直接信任）

| 层 | 规则 | 说明 |
|---|---|---|
| R1 | 交易总开关 | `trading=false` 时所有交易工具拒绝 |
| R2 | 品种白名单 | `whitelist=*` 或逗号分隔品种列表 |
| R3 | 单笔最大手数 / 最大持仓数 | `max_lot`、`max_positions` |
| R4 | 每日亏损上限 | 当日已平 P/L + 浮动 P/L 超过即拒 |
| R5 | 交易时段 | `sessions="09:00-17:00,..."` 服务器时间，支持跨夜 |
| R6 | magic 隔离 | 只操作本 EA 的仓位/挂单 |
| R7 | 确认 / 模拟模式 | `confirm_mode`（写入 confirm.txt 待人工批准）/ `dry_run`（只模拟） |
| R8 | 急停开关 | `kill=true` 立即阻断一切新订单 |

模型可通过 `set_guard` 工具请求改护栏参数（如 max_lot、daily_loss），
但**只能收紧不能放松超过输入上限**（`ToolSetGuard` 对 max_lot 有
`MathMin(1000)` 等钳制）。所有交易操作先过 `GuardNewPosition` /
`GuardManagePosition`，被拒会返回 `DENIED`。

## 可用工具（function calling → 本地执行）

- **行情**：`symbol_info`、`ticker`、`rates`、`indicators`（MA/RSI/ATR/MACD/
  Bollinger/Stoch + 最近收盘）、`symbols_list`
- **账户**：`account_info`、`open_positions`、`history_today`
- **交易**（受护栏）：`open_order`、`close_position`、`close_all`、
  `modify_position`、`trailing_stop`、`delete_pending`
- **终端/图表**：`open_chart`、`chart_object`、`popup`、`log`
- **护栏**：`status`、`set_guard`

## 对话通道（可选，多客户端并存）

- **inbox.txt**：把想对模型说的话逐行写入（UTF-8 或系统 ANSI），EA 下轮
  轮询自动读取并作为用户消息，随后清空该文件。
- **outbox.txt**：EA 追加模型最终答复与工具执行摘要。
- **confirm.txt**：`confirm_mode=on` 时交易请求排队于此，可手工编辑批准，
  或用 `PendingExecutor.mq5` 脚本按队列执行。

## 常见问题

- **错误 4014（URL 未允许）**：没勾选"允许 WebRequest"或没加域名。
- **HTTP 401/403**：API key 错误或没额度。
- **HTTP 429**：限流，调大 `poll_seconds` / 降 `max_tokens`。
- **`StringToCharArray` 报参类型错**：本包已用 `char[]` + 逐字节拷贝，
  若你的 MetaEditor 版本要求 `uchar[]`，改 `HttpClient.mqh::Utf8Encode`
  即可（文件内有注释）。
- **不自动开仓**：默认 `confirm_mode=false` + `dry_run=true`，且护栏可能
  拒绝；先看 outbox/日志里的 `DENIED` 原因。
- **JEV 报 "is a decisions model"**：JEV 不能用 chat/completions，必须走
  `/api/alpha/decisions`。本包 `JevDecisionBot.mq5` 已正确接入；
  `OpenAIBot_JEV.mq5` 仅为演示不可用。
- **JEV 用不了 function calling**：JEV 决策模型的"工具"就是类型化问题
  （choice/noul/score），不支持 OpenAI tools 协议——`JevClient.mqh`
  已按 decisions 协议实现。

## 版本历史
- v1.14 2026-10-01：**JEV 在 MT5 内真机验证通过**（需把
  `https://openrouter.ai` 加入 WebRequest 白名单）：
  - `JevClient.mqh`：真实调用 2.1s 返回，choice/noul/score 三种答案
    连同 `probabilities`、`confidence`、`legend` 全部解析正确。
  - `JevDecisionBot.mq5`：读候选信号 → 构造 state → 问 JEV → 按
    `min_conf/min_prob/noul` 阈值裁决，实测连续三轮输出
    `JEV:hold prob=0.73 conf=0.59` 并正确判定 **HOLD（不开仓）**。
  - 修复：JEV 版 EA 原先与 `OpenAIBot` **共用同一个 inbox/outbox/log
    文件会互相覆盖**，改为独立 `jev_inbox/jev_outbox/jev_log.txt`；
    并在初始化时做符号解析（`XAUUSD` → 经纪商实际 `XAUUSDm`）。
- v1.13 2026-10-01：**真机联调修复**（在 MT5 + 本地代理上跑通完整
  工具循环，模型给出 XAUUSD 实盘分析，下单请求进入护栏）：
  - `Json`：`a[0].b` 这种"对象成员 + 下标"路径原先不会进入数组元素，
    导致 `choices[0].message.content` / `tool_calls` 全部读空（表现为
    "空终答、工具从不执行"）。已修复 `Resolve`，并新增
    `IsBalanced()` 在发送前校验请求体。
  - `OpenAIClient`：加 `Connection: close`（复用被网关回收的
    keep-alive 连接会产生空 body 的异常状态码，表现为 `HTTP 1003`）、
    空响应体自动重试一次、超时 60s、`RawResponse()`、`DisableTools()`。
  - `MT5Toolbox`：**符号自动解析**（`XAUUSD` → 经纪商实际 `XAUUSDm`，
    兼容 m/.a/_i 等后缀）、`rates` 文本输出限量（原先一次回 100 根 K 线
    会把上下文撑爆）、修正 `iBands` 参数顺序（deviation/shift 写反，
    导致上中下轨相同）。
  - EA：单条工具结果截断 3000 字符；修正 `SafePath` 双重前缀（outbox
    被写到嵌套目录）；`OpenAIBot` 默认 `dry_run=true`；工具轮上限
    6 → 8，并在触顶时关闭工具再问一次以强制产出总结。
  - 环境：Wine 下 MT5 的"鼠标被隐形窗口吞掉"与 MT4 同因，已提供
    `/config/start-mt5.sh` 与常驻守护 `mt5-inputfix.sh`（只做几何缩放，
    绝不 unmap/kill）。
- v1.12 2026-10-01：接入本地 OpenAI 兼容代理
  （`http://host.docker.internal:9936/v1`，key `100216`）；默认品种改
  `XAUUSD`；curl 实测代理的 chat/function calling/多轮工具循环通过。
- v1.11 2026-10-01：真机编译验证——webtop 容器内 MetaEditor64 编译
  全部 6 个 `.mq5` 通过（0 errors, 0 warnings）；修复 MT4→MQL5 差异：
  指标句柄化（iMA/iRSI/iMACD/iBands/iStochastic + CopyBuffer）、
  `MqlTradeRequest` 改用 ZeroMemory、input 常量改为运行时配置变量、
  include 改为 `<X.mqh>` 尖括号（头文件放 `MQL5\Include\` 根）、
  `StringToUpper` 原地调用（void）。
- v1.10 2026-09-30：新增 JEV 决策版（`JevClient.mqh` + `JevDecisionBot.mq5`
  + `JevTest.mq5` + 配置/文档），实测 OpenRouter decisions API 通过；
  `OpenAIClient` 增加可选历史修剪（`maxHistoryChars`）。
- v1.00 2026-09-30：初版交付（EA + 2 脚本 + 6 头文件 + 配置/提示词 + README）。
