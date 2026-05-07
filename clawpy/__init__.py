"""
wxclaw - 微信 iLink Bot 原生 Python SDK

完全自主实现的微信机器人开发工具包，
基于 iLink 协议，无需依赖第三方 SDK 包。

主要特性:
    ✅ 完整的消息类型支持（文本/图片/表情包/语音/文件/视频）
    ✅ QR 码扫码登录 + 凭证自动缓存
    ✅ 长轮询消息接收 + 自动重连
    ✅ 会话过期自动恢复
    ✅ 打字状态管理
    ✅ 图文混排消息
    ✅ 详细的文档注释和类型提示
    ✅ 零外部依赖（仅需 aiohttp）

快速开始:
    >>> from clawpy import WxClawBot
    >>>
    >>> bot = WxClawBot()
    >>>
    >>> @bot.on_message
    ... async def handle(msg):
    ...     if msg.msg_type == "text":
    ...         await bot.reply(msg, "收到!")
    ...     # 发送图片/表情包
    ...     await bot.reply_image(msg, "https://example.com/photo.jpg")
    >>>
    >>> bot.login()
    >>> bot.run()

模块结构:
    wxclaw.client  - WxClawBot 主类，面向用户的高级 API
    wxclaw.core    - iLink 协议底层封装，HTTP 调用与消息构建
    wxclaw.auth    - 认证流程，QR 码登录与凭证管理
    wxclaw.types   - 数据类型定义，枚举与数据类

版本: 1.0.0
协议: iLink v1.0
作者: wxclaw team
"""

from .client import WxClawBot
from .types import IncomingMessage, Credentials
from .core import ILinkError

__version__ = "1.0.0"
__author__ = "wxclaw team"

__all__ = [
    # 核心类
    "WxClawBot",
    # 数据类型
    "IncomingMessage",
    "Credentials",
    # 异常
    "ILinkError",
]