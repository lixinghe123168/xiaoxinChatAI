# xiaoxinChatAI — AI 微信机器人（移动端）

**基于 Flutter 的 AI 微信机器人移动客户端，配合微信 iLink Bot 协议实现智能对话。**

本仓库是 xiaoxinChatAI 的 **Flutter 移动端**（Android），包含完整的 AI 对话、表情包回复、长期记忆、背景服务等功能。Python 后端版本请见 [父仓库](https://github.com/lixinghe123168/xiaoxinChatAI)。

***

## 功能特性

### AI 对话

- 集成 OpenAI 兼容 API（支持 DeepSeek、GPT、Qwen 等多种模型）
- 自定义 **Persona 人设系统**（Skill 配置，含 config.yaml / persona.md / memories.md）
- "正在输入" 打字状态指示
- 消息自动分片发送，模拟自然聊天

### 表情包回复

- AI 自动根据对话情绪输出 `[EMOJI:关键词]`，自动调用第三方 API 获取并发送表情包
- 可配置发送概率、开启/关闭
- 默认支持 **接口盒子** 表情包 API，也可替换为其他兼容 API

### 记忆系统

- **短期记忆**：内存缓存最近 N 轮对话（默认 20 轮）
- **长期记忆**：SQLite 持久化存储，支持全文检索
- **智能判断**：仅存储有价值的信息（偏好、经历等），过滤日常问候

### 主动消息

- AI 在用户长时间不聊天时主动发起对话
- 多种风格可选：延续话题、询问近况、分享日常、主动关心
- 可配置检查间隔、空闲阈值、触发概率

### 背景服务（Android）

- 利用 `flutter_background_service` 实现 Android 前台服务
- 应用进入后台后仍能自动接收并回复微信消息
- 前台通知，防止系统杀进程

### 多模态支持

- 图片消息可配置为"发送给 AI 理解"或"友好回复"
- 语音消息自动提取文字（微信已转文字）
- 文件/视频消息的智能回复处理

### 配置管理

- 图形化配置界面，无需手动编辑 JSON
- 模型参数、人设、记忆、功能开关等均可实时配置
- 通过 `SharedPreferences` 实现配置持久化，无需重启即时生效

***

## 快速开始

### 获取代码

```bash
git clone https://github.com/lixinghe123168/xiaoxinChatAI.git
cd xiaoxin-chat-ai/xiaoxin_chat_app
```

### 环境要求

- Flutter SDK >= 3.11.5
- Dart SDK >= 3.11.5
- Android Studio / Visual Studio Code
- 微信 iLink Bot 账号（需在微信开放平台申请）

### 构建与运行

```bash
# 获取依赖
flutter pub get

# 运行（连接设备或模拟器）
flutter run

# 构建 APK
flutter build apk --release
```

### 首次使用

1. 安装 APK 后打开应用，进入引导页面
2. 配置 **模型 API**（名称、地址、密钥）
3. 导入 **Skill 人设文件**（可从微信中收到文件后用"其他应用打开"导入）
4. 配置 **表情包 API**（可选，默认使用接口盒子）
5. 连接微信：获取登录链接，在微信 iLink Bot 环境中扫码绑定
6. 开始聊天！

***

## 项目架构

```
xiaoxin_chat_app/
├── lib/
│   ├── main.dart                    # 应用入口
│   ├── app_theme.dart               # 主题配置（亮色/暗色）
│   │
│   ├── core/                        # 核心逻辑层
│   │   ├── bot_service.dart         # 机器人主服务（消息处理、系统Prompt、表情包逻辑）
│   │   ├── wechat_client.dart       # 微信 iLink Bot 客户端（登录、收发消息）
│   │   ├── llm_client.dart          # LLM API 调用客户端
│   │   ├── memory_service.dart      # 记忆服务（短期+长期）
│   │   ├── skill_loader.dart        # Skill 人设加载器
│   │   ├── skill_storage.dart       # Skill 文件存储管理
│   │   ├── skill_storage_native.dart
│   │   └── skill_storage_web.dart
│   │
│   ├── models/                      # 数据模型
│   │   ├── app_config.dart          # 配置模型（ModelConfig, FeaturesConfig, ...）
│   │   └── chat_models.dart         # 聊天消息模型
│   │
│   ├── pages/                       # 页面
│   │   ├── main_page.dart           # 主页面（微信连接、状态、发送消息）
│   │   ├── settings_page.dart       # 设置页面（所有配置项）
│   │   └── onboarding_page.dart     # 引导页面（首次使用配置向导）
│   │
│   ├── providers/
│   │   └── app_provider.dart        # 全局状态管理（Provider）
│   │
│   ├── services/
│   │   └── api_service.dart         # 通用 API 服务
│   │
│   └── utils/
│       ├── background_service.dart  # Android 背景前台服务
│       └── crypto_utils.dart        # 加密工具
│
├── android/                         # Android 原生配置
├── test/                            # 单元测试
├── pubspec.yaml                     # 项目依赖配置
└── README.md                        # 本文件
```

### 核心模块说明

| 模块 | 职责 |
|------|------|
| `core/bot_service.dart` | 消息处理中枢：接收消息 → 去重 → 调用 LLM → 发送回复 → 表情包判定 → 记忆存储 |
| `core/wechat_client.dart` | 微信协议客户端：QR 登录、长轮询收消息、发送文本/图片、打字状态控制 |
| `core/llm_client.dart` | LLM API 调用：OpenAI 兼容格式，支持流式/非流式，自动重试 |
| `core/memory_service.dart` | 记忆系统：短期历史缓存 + SQLite 长期持久化 + 全文检索 |
| `core/skill_loader.dart` | 人设加载：解析 YAML/Markdown 文件，构建 System Prompt |
| `utils/background_service.dart` | 背景常驻服务：Android 前台 Service，独立 Isolate 运行 |
| `providers/app_provider.dart` | 全局状态：Provider 模式管理所有状态，通知 UI 更新 |

### 消息处理流程

```
用户发送消息
    │
    ├─ 1. 微信长轮询收到消息
    ├─ 2. 去重检测（10秒窗口）
    ├─ 3. 显示"正在输入..."
    ├─ 4. 调用 LLM API（含 System Prompt + 历史 + 记忆）
    ├─ 5. 解析 AI 回复
    │   ├─ 提取文本回复 → 分片发送
    │   └─ 提取 [EMOJI:关键词] → 概率判定 → 调用表情包 API → 发送图片
    ├─ 6. 存储到短期记忆 + 长期记忆
    └─ 7. 隐藏"正在输入..."
```

***

## 配置说明

### 模型配置

| 参数 | 说明 |
|------|------|
| `name` | 模型名称（如 `deepseek-chat`、`qwen-vl-plus`） |
| `api_key` | API 密钥 |
| `base_url` | API 地址（支持 OpenAI 兼容格式） |

### 记忆配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `short_term_max` | 20 | 短期记忆最大轮数 |
| `long_term_max` | 200 | 每用户最大长期记忆条数 |
| `expire_days` | 90 | 记忆过期天数 |
| `retrieval_top_k` | 5 | 检索返回的记忆条数 |
| `retrieval_min_score` | 0.2 | 记忆检索最低匹配分数 |

### 功能开关

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `emoji` | true | 表情包回复开关 |
| `emoji_probability` | 0.5 | 表情包发送概率 |
| `emoji_api` | — | 表情包 API 配置（api_id / api_key / api_url） |
| `proactive_message.enabled` | true | 主动消息推送开关 |
| `proactive_message.interval_minutes` | 5 | 检查间隔（分钟） |
| `proactive_message.max_idle_minutes` | 10 | 空闲触发阈值（分钟） |
| `typing_indicator` | true | "正在输入"状态指示 |
| `image_handling.send_to_ai` | false | 图片是否发送给 AI 处理 |

### 系统参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `temperature` | 0.7 | LLM 温度参数 |
| `max_tokens` | 2000 | 最大生成 Token 数 |
| `timeout` | 120 | API 超时时间（秒） |

***

## 表情包 API 配置

默认使用 **接口盒子**（免费），申请步骤：

1. 访问 [接口盒子](https://www.apihz.com/) 注册账号
2. 进入控制台 → API 管理 → 找到「表情包」接口
3. 获取 `api_id` 和 `api_key`
4. 在应用设置中填入 API 信息

> 也可使用其他兼容的表情包 API，只需替换 `api_url` 为对应接口地址即可。

***

## Skill 人设系统

Skill 是 AI 人设的配置文件包，定义机器人的性格、说话风格和背景知识。一个完整的 Skill 包含三个文件：

| 文件 | 必填 | 说明 |
|------|------|------|
| `config.yaml` | ✅ | 人设配置（名称、描述、系统提示词、回复风格） |
| `persona.md` | ❌ | 详细人设设定（性格、习惯、兴趣、价值观） |
| `memories.md` | ❌ | 背景记忆库（与用户的共同记忆、个人信息） |

可通过微信收到这三个文件后用 **"其他应用打开"** 选择 xiaoxinChatAI 快速导入。

***

## 构建发布

```bash
# 清理构建
flutter clean

# 获取依赖
flutter pub get

# 构建 Release APK
flutter build apk --release

# 构建 App Bundle（Google Play）
flutter build appbundle --release
```

生成的 APK 位于 `build/app/outputs/flutter-apk/app-release.apk`。

***

## 技术栈

| 技术 | 用途 |
|------|------|
| **Flutter** | 跨平台移动 UI 框架 |
| **Provider** | 状态管理 |
| **flutter_background_service** | Android 前台 Service 支持 |
| **http** | HTTP 网络请求 |
| **shared_preferences** | 配置持久化 |
| **sqflite** | 本地 SQLite 数据库（长期记忆） |
| **crypto** | AES 加密（微信 CDN 上传） |
| **wakelock_plus** | 唤醒锁（防止后台休眠） |
| **file_picker** | 文件选择（导入 Skill） |
| **receive_sharing_intent** | 接收分享文件 |

***

## License

MIT License
