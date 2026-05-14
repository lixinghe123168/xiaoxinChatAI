# xiaoxinChatAI Flutter App — 后台服务架构文档

## 概述

Flutter App 作为 AI 微信机器人的移动端，核心功能是通过 WeChat iLink API 轮询消息、调用 LLM 生成回复并发送回微信。**所有消息处理由 Android 后台服务（BackgroundService）负责**，前台仅提供微信登录和配置界面。

---

## 架构分层

```
┌──────────────────────────────────────────────────┐
│                  前台 Flutter UI                   │
│  MainPage / SettingsPage / OnboardingPage          │
│  用途: 微信扫码登录、配置管理、状态显示             │
│  NOTICE: 不参与消息轮询和回复                      │
└──────────────────────┬───────────────────────────┘
                       │ 通过 AppProvider 交互
┌──────────────────────▼───────────────────────────┐
│                  BotService                        │
│  用途: 配置管理、凭证存储、前台无关业务             │
│  - loadConfig / saveConfig                        │
│  - loginWechat / loginWithCredentials              │
│  - 保存后台配置到 SharedPreferences               │
└──────────────────────┬───────────────────────────┘
                       │ 不启动前台轮询
┌──────────────────────▼───────────────────────────┐
│            BackgroundService (独立 Isolate)         │
│  基于 flutter_background_service                  │
│  Android 前台服务 + 持久通知                       │
│  Wakelock 保活                                    │
│                                                    │
│  ┌──────────────┐  ┌──────────────┐               │
│  │ WeChatClient  │  │ LlmApiClient │              │
│  │ iLink API 封装│  │ LLM API 调用 │               │
│  └──────┬───────┘  └──────┬───────┘               │
│         │                 │                        │
│  ┌──────▼─────────────────▼───────┐               │
│  │    MemoryService (SQLite)      │               │
│  │    长期记忆存储与检索           │               │
│  └────────────────────────────────┘               │
└──────────────────────────────────────────────────┘
```

---

## 消息处理流程

```
用户发微信消息
      │
      ▼
BackgroundService._backgroundEntry()
      │  while(true) 循环，每 3 秒轮询
      ▼
wechat.getUpdates()  ← HTTP long polling
      │
      ▼
解析消息 → 去重 → 加入 chatHistory
      │
      ▼
_handleTextMessage()  /  _handleNonTextMessage()
      │
      ├── showTyping()  ← 显示"对方正在输入..."
      │
      ├── 检索长期记忆 (MemoryService.searchMemories)
      │       ↓
      │   注入 prompt "## 相关记忆"
      │
      ├── 加入 chatHistory (短期记忆)
      │       ↓
      │   超限时压缩为摘要 (Python 同款逻辑)
      │
      ├── 构建 System Prompt
      │       ↓
      │   包含: 当前时间、Persona、记忆库、摘要、
      │         Emoji规则、联网说明、多样性要求
      │
      ├── llm.chat()  ← 调用 LLM API
      │
      ├── 解析回复
      │       ↓
      │   - 提取 [EMOJI:xxx] 关键词
      │   - 过滤 Emoji 标记行
      │   - 乱码检测 (_isGarbled)
      │
      ├── 并发发送:
      │   ├── _sendReply()       ← 文字消息
      │   │       ↓
      │   │   - 空格拆分多段
      │   │   - 每段前 showTyping
      │   │   - 按字数 × 0.08s 延迟 (模拟打字)
      │   │   - 段间按字数 × 0.03s 间隔
      │   │
      │   └── _sendEmojiSticker() ← 表情包图片
      │           ↓
      │       - 限频 10次/分钟
      │       - 调 emoji API 获取图片 URL
      │       - 下载 → AES 加密 → 上传 CDN → 发送
      │
      ├── hideTyping()
      │
      ├── 加入 chatHistory (AI 回复)
      │
      └── 保存到长期记忆 (MemoryService.addMemory)
           + 提取关键词
```

---

## 关键组件

### 1. BackgroundService (`utils/background_service.dart`)

**独立 Isolate**，与前台互不干扰。

| 特性 | 实现 |
|------|------|
| 保活机制 | `isForegroundMode: true` + `WakelockPlus.enable()` |
| 自启动 | `autoStart: true, autoStartOnBoot: true` |
| 轮询间隔 | 3 秒 |
| 对话持久化 | `chatHistory` 存 `SharedPreferences`，重启恢复 |

### 2. 短期记忆

与 Python 后端一致的**摘要压缩**策略：

```
RECENT_ROUNDS_KEEP = 5 (保留最近 5 轮完整对话)
当 chatHistory 超过 shortTermMax × 2 时:
  old_rounds → 压缩为摘要格式:
    "用户「...」→ 回复「...」"
  摘要追加到 chatSummary (上限 2000 字)
  chatHistory 仅保留最近 5 轮
```

摘要注入 prompt 的 `## 之前对话摘要` 区域，AI 可参考早期对话内容。

### 3. 长期记忆 (`core/memory_service.dart`)

| 特性 | 实现 |
|------|------|
| 存储引擎 | SQLite + FTS5 全文检索 |
| 容量 | 2000 条（按分数+时间淘汰） |
| 新鲜度衰减 | <7 天 ×1.0, <30 天 ×0.8, ≥30 天 ×0.6 |
| 关键词提取 | 分词 + 停用词过滤 + 词频 Top10 |
| 过期 | 按配置 expire_days 自动清理 |

### 4. Emoji 表情包

| 特性 | 实现 |
|------|------|
| 触发 | AI 回复中 `[EMOJI:xxx]` 或 `[xxx]` |
| 限频 | 每分钟最多 10 次 API 调用 |
| 流程 | 调 emoji API → 下载图片 → AES-ECB 加密 → 上传 WeChat CDN → 发送 |
| 并发 | 与文字消息同时发送 (Future.wait) |

### 5. 编码处理

**核心修复**：所有 HTTP 响应统一使用 `utf8.decode(response.bodyBytes)`，避免 Dart `http` 包默认 Latin-1 解码导致中文乱码。

涉及文件：
- `core/llm_client.dart` — LLM API 响应
- `core/wechat_client.dart` — WeChat API 响应（消息、登录、图片上传等）

### 6. 消息拆分

与 Python 后端一致的空格拆分策略：

```
1. 合并多行为一句（空格连接）
2. 按空格拆分为段
3. 过滤 --- 分隔线、[EMOJI]、单字符
4. [...] 标记合并到相邻段（避免 [捂脸] 单独发送）
5. 最多 10 段
```

---

## 配置文件 (SharedPreferences Keys)

| Key | 类型 | 说明 |
|-----|------|------|
| `app_config` | JSON | 完整配置（模型/Skill/记忆/功能/系统） |
| `wechat_credentials` | JSON | WeChat 登录凭证 |
| `_bg_bot_name` | String | Bot 名称 |
| `_bg_system_instruction` | String | 系统指令 |
| `_bg_persona` | String | 人设 |
| `_bg_memories` | String | 记忆库 |
| `_bg_emoji_enabled` | bool | 表情包开关 |
| `_bg_emoji_api_id/key/url` | String | 表情包 API 配置 |
| `_bg_emoji_probability` | double | 表情包概率 |
| `_bg_web_search` | bool | 联网搜索开关 |
| `_bg_short_term_max` | int | 短期记忆轮数 |
| `_bg_long_term_enabled` | bool | 长期记忆开关 |
| `_bg_retrieval_top_k` | int | 检索条数 |
| `_bg_retrieval_min_score` | double | 最低匹配分 |
| `_bg_expire_days` | int | 记忆过期天数 |
| `_bg_chat_history` | JSON | 对话历史（服务重启恢复） |
| `_bg_chat_summary` | String | 对话摘要 |

---

## 与 Python 后端的关键差异

| 功能 | Python | Flutter |
|------|--------|---------|
| 消息拆分 | 空格 | 空格 ✅ |
| 短期记忆 | 摘要压缩 | 摘要压缩 ✅ |
| 长期记忆 | SQLite+FTS5+关键词+RRF | SQLite+FTS5+关键词 |
| 新鲜度衰减 | 层级衰减 | 层级衰减 ✅ |
| 用户隔离 | 按 user_id | 单用户 |
| 表情包 | 有限频 | 有限频 ✅ |
| 打字状态 | getConfig→sendTyping | getConfig→sendTyping ✅ |
| 编码修复 | UTF-8 自动 | utf8.decode(bytes) ✅ |
| 乱码检测 | 无 | _isGarbled() |
| 消息持久化 | 进程内 | SharedPreferences |
