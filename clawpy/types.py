"""
wxclaw.types - 数据类型定义模块

定义微信 iLink 协议中使用的所有数据结构。
遵循 TypedDict + dataclass 混合模式，兼顾类型安全和易用性。

设计规范参考：
- OpenAI Python SDK 的类型定义风格
- PEP 484 / 589 类型注解规范
- dataclass 用于运行时对象，TypedDict 用于 JSON 映射
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import IntEnum
from typing import Literal, NotRequired, TypeAlias, TypedDict


# ============================================================================
# 枚举类型
# ============================================================================

class MessageType(IntEnum):
    """消息发送方类型
    
    Attributes:
        USER: 用户发送的消息 (value=1)
        BOT: 机器人发送的消息 (value=2)
    """
    USER = 1
    BOT = 2


class MessageState(IntEnum):
    """消息状态（用于流式回复场景）
    
    Attributes:
        NEW: 新消息，开始生成 (value=0)
        GENERATING: 正在生成中 (value=1)  
        FINISH: 生成完成 (value=2)
    """
    NEW = 0
    GENERATING = 1
    FINISH = 2


class ItemType(IntEnum):
    """消息内容项类型
    
    对应 iLink 协议中的 item_list[].type 字段
    
    Attributes:
        TEXT: 文本消息 (value=1)
        IMAGE: 图片消息 (value=2)
        VOICE: 语音消息 (value=3)
        FILE: 文件消息 (value=4)
        VIDEO: 视频消息 (value=5)
    """
    TEXT = 1
    IMAGE = 2
    VOICE = 3
    FILE = 4
    VIDEO = 5


# ============================================================================
# 类型别名（提前定义，供后续数据类使用）
# ============================================================================

MessageKind: TypeAlias = Literal["text", "image", "voice", "file", "video"]
"""消息类型的字面量联合类型"""


# ============================================================================
# 运行时数据类（用于业务逻辑）
# ============================================================================

@dataclass(frozen=True)
class Credentials:
    """登录凭证数据类
    
    存储登录后获取的认证信息，用于后续 API 调用。
    
    Attributes:
        token: Bot 认证令牌，每次 API 调用必须携带
        base_url: iLink API 基础 URL（可能动态变化）
        bot_id: Bot 在微信侧的虚拟身份 ID（每次登录会变化）
        user_id: 微信用户唯一标识（同一微信号不变）
    
    Example:
        >>> creds = Credentials(
        ...     token="abc123",
        ...     base_url="https://ilinkai.weixin.qq.com",
        ...     bot_id="bot_xxx",
        ...     user_id="user_yyy"
        ... )
    """
    token: str
    base_url: str
    bot_id: str
    user_id: str


@dataclass
class IncomingMessage:
    """接收到的消息对象
    
    当用户向 Bot 发送消息时，SDK 会将原始 JSON 解析为此对象，
    并传递给通过 @bot.on_message 注册的处理器。
    
    Attributes:
        user_id: 发送者用户 ID
        text: 消息文本内容（纯文本提取）
        msg_type: 消息类型 ("text" | "image" | "voice" | "file" | "video")
        raw: 原始完整消息字典（用于高级用法）
        context_token: 上下文令牌，回复此消息时需要携带
        timestamp: 消息时间戳（已转换为本地 datetime）
    
    Example:
        >>> @bot.on_message
        ... async def handle(msg: IncomingMessage):
        ...     print(f"[{msg.timestamp}] {msg.user_id}: {msg.text}")
        ...     await bot.reply(msg, "收到!")
    """
    user_id: str
    text: str
    msg_type: MessageKind
    raw: dict
    context_token: str
    timestamp: datetime


@dataclass
class MediaOptions:
    """多媒体消息选项
    
    用于构建图片、视频等富媒体消息时的可选参数。
    
    Attributes:
        url: 媒体文件 URL（必填）
        thumb_url: 缩略图 URL（可选）
        file_name: 文件名（仅文件类型使用）
        duration: 时长/播放时长秒数（语音/视频）
        encrypt_key: 加密密钥（CDN 媒体加密参数）
    """
    url: str
    thumb_url: str | None = None
    file_name: str | None = None
    duration: int | None = None
    encrypt_key: str | None = None


# ============================================================================
# JSON 协议映射类型（TypedDict）
# ============================================================================

class BaseInfo(TypedDict):
    """基础信息头"""
    channel_version: str


class TextItem(TypedDict):
    """文本内容项"""
    text: str


class ImageItem(TypedDict):
    """图片内容项"""
    media: NotRequired[dict]
    url: NotRequired[str]
    aeskey: NotRequired[str]


class VoiceItem(TypedDict):
    """语音内容项"""
    media: NotRequired[dict]
    text: NotRequired[str]
    playtime: NotRequired[int]


class FileItem(TypedDict):
    """文件内容项"""
    media: NotRequired[dict]
    file_name: NotRequired[str]


class VideoItem(TypedDict):
    """视频内容项"""
    media: NotRequired[dict]
    video_size: NotRequired[int]
    play_length: NotRequired[int]


class MsgItem(TypedDict):
    """通用消息内容项"""
    type: int
    text_item: NotRequired[TextItem]
    image_item: NotRequired[ImageItem]
    voice_item: NotRequired[VoiceItem]
    file_item: NotRequired[FileItem]
    video_item: NotRequired[VideoItem]


class WeixinMessage(TypedDict):
    """完整的微信消息协议结构"""
    message_id: int
    from_user_id: str
    to_user_id: str
    client_id: str
    create_time_ms: int
    message_type: int
    message_state: int
    context_token: str
    item_list: list[MsgItem]