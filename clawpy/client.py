"""
wxclaw.client - Bot 客户端模块

提供面向用户的高级 API，封装了长轮询、消息分发、
上下文管理、自动重连等复杂逻辑。

这是 SDK 的核心入口，用户主要通过 WxClawBot 类与微信交互。

设计规范参考：
- Telegram Bot API 的客户端设计模式
- discord.py 的事件驱动架构
- Python asyncio 最佳实践

主要功能:
    - 消息接收: 长轮询 + 自动重连 + 会话过期恢复
    - 消息发送: 文本/图片/表情包/语音/文件/视频
    - 状态管理: 打字状态显示/取消
    - 事件系统: @bot.on_message 装饰器注册处理器

使用示例:
    >>> from clawpy import WxClawBot
    >>>
    >>> bot = WxClawBot()
    >>>
    >>> @bot.on_message
    ... async def handle(msg):
    ...     await bot.reply(msg, "收到你的消息!")
    ...     # 发送图片
    ...     await bot.reply_image(msg, "https://example.com/photo.jpg")
    ...     # 发送表情包
    ...     await bot.reply_image(msg, "https://example.com/emoji.gif")
    >>>
    >>> bot.login()
    >>> bot.run()
"""

import asyncio
import inspect
import json
import aiohttp
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .auth import login as do_login, clear_credentials_async
from clawpy.core import (
    ILinkError,
    DEFAULT_BASE_URL,
    build_text_msg,
    build_image_msg,
    build_voice_msg,
    build_file_msg,
    build_video_msg,
    get_config,
    get_updates,
    send_message,
    send_typing,
    send_image_complete,
    send_image_from_file,
    send_voice_from_file,
    send_file_from_file,
    send_video_from_file,
)
from .types import Credentials, IncomingMessage


# ============================================================================
# 类型定义
# ============================================================================

MessageHandler = Callable[[IncomingMessage], Any]
"""消息处理器的类型签名

处理器可以是同步或异步函数，SDK 会自动适配。
"""


# ============================================================================
# 常量定义
# ============================================================================

TEXT_CHUNK_SIZE: int = 2000
"""文本分片大小（字符数）

微信单条消息限制约 2000 字符，
超过此长度的文本会被自动分割为多条消息。
"""

POLL_TIMEOUT_MS: int = 35_000
"""长轮询超时时间（毫秒）

服务端最长保持连接的时间（官方协议规定为 35 秒）。
超时后即使没有新消息也会返回空结果。
"""

SEND_TIMEOUT_MS: int = 15_000
"""发送消息超时时间（毫秒）"""

MAX_RETRY_DELAY: float = 10.0
"""最大重试延迟（秒）

指数退避的上限值，防止无限增长。"""

INITIAL_RETRY_DELAY: float = 1.0
"""初始重试延迟（秒）"""


class WxClawBot:
    """微信 iLink Bot 客户端
    
    这是 SDK 的主类，封装了所有与微信交互的高级操作。
    
    Attributes:
        _base_url: iLink API 基础 URL
        _credentials: 当前登录凭证
        _handlers: 已注册的消息处理器列表
        _context_tokens: 用户 ID → context_token 映射缓存
        _cursor: 长轮询游标，用于增量拉取消息
        _stopped: 是否已请求停止运行
        
    Example:
        基础用法:
        
        >>> bot = WxClawBot()
        >>> 
        >>> @bot.on_message
        ... async def handle(msg):
        ...     if msg.msg_type == "text":
        ...         await bot.reply(msg, f"你说: {msg.text}")
        >>>
        >>> bot.login()
        >>> bot.run()
        
        发送图片:
        
        >>> @bot.on_message
        ... async def handle(msg):
        ...     # 回复图片
        ...     await bot.reply_image(msg, "https://example.com/image.jpg")
        ...     
        ...     # 发送表情包 (GIF)
        ...     await bot.reply_image(msg, "https://example.com/emoji.gif")
        ...     
        ...     # 图文混排
        ...     await bot.reply_mixed(
        ...         msg,
        ...         text="看这张图：",
        ...         image_url="https://example.com/photo.jpg"
        ...     )
        
        主动发送（需先有用户消息建立上下文）:
        
        >>> @bot.on_message
        ... async def handle(msg):
        ...     # 先回复当前消息
        ...     await bot.reply(msg, "稍后给你发张图")
        ...     
        ...     # 之后可以主动发送给该用户（24h内有效）
        ...     await bot.send_image(msg.user_id, "https://example.com/later.jpg")
    """
    
    def __init__(
        self,
        base_url: str | None = None,
    ) -> None:
        """初始化 Bot 客户端
        
        Args:
            base_url: 自定义 iLink API 地址。
                     为 None 时使用默认官方地址。
                     当使用代理或私有部署时需要指定。
        """
        self._base_url: str = base_url or DEFAULT_BASE_URL
        self._credentials: Credentials | None = None
        self._handlers: list[MessageHandler] = []
        self._context_tokens: dict[str, str] = {}
        self._cursor: str = ""
        self._stopped: bool = False
    
    # =========================================================================
    # 认证方法
    # =========================================================================
    
    def login(self, force: bool = False) -> Credentials:
        """执行登录（同步包装）
        
        在主线程调用，内部通过 asyncio.run() 执行异步登录流程。
        
        Args:
            force: True=强制重新扫码登录，False=优先使用缓存的凭证
            
        Returns:
            登录成功后的 Credentials 对象
            
        Example:
            >>> bot = WxClawBot()
            >>> creds = bot.login()           # 使用缓存
            >>> creds = bot.login(force=True) # 强制重新登录
        """
        self._credentials = asyncio.run(
            do_login(base_url=self._base_url, force=force)
        )
        return self._credentials
    
    def logout(self) -> None:
        """清除本地凭证（登出/切换账号）
        
        删除保存的登录凭证文件，下次 login() 时会要求重新扫码。
        
        适用场景：
        - 切换到另一个微信号
        - 凭证过期或失效
        - 安全考虑需要清除敏感信息
        
        Example:
            >>> bot = WxClawBot()
            >>> bot.logout()  # 清除凭证
            >>> bot.login()   # 下次启动时会重新扫码
        """
        from .auth import clear_credentials

        clear_credentials()
        self._credentials = None
        self._cursor = ""
        self._context_tokens.clear()
        print("[wxclaw] ✓ 已清除登录凭证，下次启动将重新扫码")
    
    # =========================================================================
    # 处理器注册
    # =========================================================================
    
    def on_message(self, handler: MessageHandler) -> MessageHandler:
        """注册消息处理器装饰器
        
        可以注册多个处理器，所有处理器都会收到每条消息。
        处理器可以是同步函数或异步函数。
        
        Args:
            handler: 消息处理函数，签名为 async/sync func(msg: IncomingMessage)
            
        Returns:
            原始 handler（支持装饰器链式调用）
            
        Example:
            >>> @bot.on_message
            ... async def log_handler(msg):
            ...     print(f"[{msg.timestamp}] {msg.user_id}: {msg.text}")
            >>>
            >>> @bot.on_message
            ... async def ai_handler(msg):
            ...     reply = await generate_ai_reply(msg.text)
            ...     await bot.reply(msg, reply)
        """
        self._handlers.append(handler)
        return handler
    
    # =========================================================================
    # 消息回复方法 ★ 核心功能
    # =========================================================================
    
    async def reply(self, msg: IncomingMessage, text: str) -> None:
        """回复文本消息
        
        向发送者回复一条文本消息。
        超过 2000 字符的文本会自动分片发送。
        
        Args:
            msg: 要回复的原始消息对象
            text: 要发送的文本内容
            
        Raises:
            ValueError: 文本内容为空时抛出
            ILinkError: 发送失败时抛出
            
        Note:
            此方法会自动携带正确的 context_token，
            确保回复出现在正确的对话上下文中。
        """
        if not text or not text.strip():
            raise ValueError("回复内容不能为空")
        
        creds = await self._ensure_creds()
        
        for chunk in self._chunk_text(text):
            msg_body = build_text_msg(
                to_user_id=msg.user_id,
                context_token=msg.context_token,
                text=chunk,
            )
            await send_message(creds.base_url, creds.token, msg_body)
    
    async def reply_image(
        self,
        msg: IncomingMessage,
        image_url: str,
        *,
        thumb_url: str | None = None,
    ) -> None:
        """回复图片/表情包消息 ★★ 核心功能（已修复）
        
        向发送者回复一张图片或 GIF 表情包。
        
        ✅ 修复说明 (v1.1):
            旧版本直接传 URL 给微信，但微信服务器无法访问外部 URL。
            新版本实现完整的三步流程：
            ① 下载图片到本地临时文件
            ② 构建 CDN 媒体对象（含加密参数）
            ③ 使用 media 对象发送消息
            
            参考 OpenClaw 的 openclaw-weixin 插件实现。
        
        Args:
            msg: 要回复的原始消息对象
            image_url: 图片 URL（网络地址，SDK 会自动下载）
                      支持格式: JPEG/PNG/GIF/WebP
            thumb_url: 缩略图 URL（可选，暂未使用）
            
        Supported Formats:
            - JPEG/PNG 静态图片
            - GIF 动图（表情包）★★
            - WebP 格式
            
        Example:
            >>> # 发送普通图片
            >>> await bot.reply_image(msg, "https://example.com/photo.jpg")
            >>>
            >>> # 发送 GIF 表情包
            >>> await bot.reply_image(msg, "https://example.com/funny.gif")
            
        Raises:
            ILinkError: 下载失败或发送失败时抛出
        """
        import logging
        
        logger = logging.getLogger("wxclaw.client")

        
        try:
            creds = await self._ensure_creds()

            
            result = await send_image_complete(
                base_url=creds.base_url,
                token=creds.token,
                to_user_id=msg.user_id,
                context_token=msg.context_token,
                image_url=image_url,
            )
            
        except ILinkError as e:
            logger.error(f"❌ [reply_image] 发送失败! 错误码: {e.code}")
            logger.error(f"   错误信息: {e.message}")
            raise
            
        except Exception as e:
            logger.error(f"❌ [reply_image] 未预期异常: {type(e).__name__}: {e}")
            import traceback
            logger.error(f"   堆栈:\n{traceback.format_exc()}")
            raise

    async def reply_emoji(
        self,
        msg: IncomingMessage,
        *,
        keyword: str | None = None,
        api_id: str | None = None,
        api_key: str | None = None,
        api_url: str | None = None,
    ) -> str | None:
        """回复表情包（随机发送一张）

        Args:
            msg: 消息对象
            keyword: 表情关键词
            api_id: 表情 API ID（不传则使用内置默认）
            api_key: 表情 API Key（不传则使用内置默认）
            api_url: 表情 API URL（不传则使用内置默认）
        """
        import logging
        _log = logging.getLogger("wxclaw.client")

        _log.info(f"[reply_emoji] 调用 API, keyword={keyword or 'random'}")

        url = await self._fetch_emoji_url(keyword=keyword, limit=100, api_id=api_id, api_key=api_key, api_url=api_url)
        if not url:
            return None

        try:
            _log.info(f"[reply_emoji] 发送图片到微信...")
            await self.reply_image(msg, url)
            _log.info(f"[reply_emoji] ✓ 完成")
            return url
        except Exception as e:
            _log.error(f"[reply_emoji] ✗ 发送失败: {e}")
            return None

    async def _fetch_emoji_url(
        self,
        *,
        keyword: str | None = None,
        limit: int = 1,
        api_id: str | None = None,
        api_key: str | None = None,
        api_url: str | None = None,
    ) -> str | None:
        """调用表情包 API 获取图片 URL（带频率限制）

        Args:
            keyword: 表情关键词
            limit: 返回数量上限
            api_id: API ID（不传则使用内置默认）
            api_key: API Key（不传则使用内置默认）
            api_url: API URL（不传则使用内置默认）
        """
        import logging
        import time
        import random

        logger = logging.getLogger("wxclaw.client")
        now = time.time()

        if not hasattr(self, '_emoji_rate_limit'):
            self._emoji_rate_limit = []

        self._emoji_rate_limit = [t for t in self._emoji_rate_limit if now - t < 60]
        remaining = 10 - len(self._emoji_rate_limit)

        logger.info(f"[emoji API] 频率限制: 本分钟已用 {len(self._emoji_rate_limit)}/10, 剩余 {remaining}")

        if len(self._emoji_rate_limit) >= 10:
            wait_time = 60 - (now - self._emoji_rate_limit[0])
            logger.warning(f"[emoji API] ⚠️ 频率超限! 等待 {wait_time:.0f}s...")
            await asyncio.sleep(max(wait_time, 2))

        self._emoji_rate_limit.append(time.time())

        final_api_id = api_id or ""
        final_api_key = api_key or ""
        final_api_url = api_url or ""

        if not final_api_id or not final_api_key or not final_api_url:
            return None

        params = {
            "id": final_api_id,
            "key": final_api_key,
            "limit": min(limit, 100),
        }
        if keyword:
            params["words"] = keyword

        try:
            async with aiohttp.ClientSession() as session:
                logger.info(f"[emoji API] >>> 请求中 (keyword={keyword or 'random'}, limit={limit})...")

                async with session.get(
                    final_api_url,
                    params=params,
                    timeout=aiohttp.ClientTimeout(total=15),
                ) as resp:
                    text = await resp.text()
                    data = json.loads(text)

                    code = data.get("code")
                    count = len(data.get("res", []))

                    logger.info(f"[emoji API] <<< 响应: code={code}, 返回{count}张图片")

                    if code != 200:
                        logger.error(f"[emoji API] error: {data.get('msg')}")
                        return None

                    urls = data.get("res", [])
                    if not urls:
                        logger.warning("[emoji API] no results")
                        return None

                    url = random.choice(urls)
                    logger.info(f"[emoji API] ✓ got image, keyword={keyword or 'random'}")
                    return url

        except Exception as e:
            logger.error(f"[emoji API] exception: {e}")
            return None

    async def reply_image_file(
        self,
        msg: IncomingMessage,
        file_path: str | Path,
    ) -> None:
        """回复本地图片文件

        Args:
            msg: 要回复的原始消息对象
            file_path: 本地图片路径（支持 jpg/png/gif/webp）

        Example:
            >>> await bot.reply_image_file(msg, "C:/Users/xxx/photo.jpg")
            >>> await bot.reply_image_file(msg, "./images/sticker.gif")
        """
        creds = await self._ensure_creds()

        await send_image_from_file(
            base_url=creds.base_url,
            token=creds.token,
            to_user_id=msg.user_id,
            context_token=msg.context_token,
            file_path=file_path,
        )

    async def reply_voice_file(
        self,
        msg: IncomingMessage,
        file_path: str | Path,
        encode_type: int | None = None,
    ) -> None:
        """回复本地语音文件

        Args:
            msg: 要回复的原始消息对象
            file_path: 本地语音文件路径（MP3/SILK/OGG）
            encode_type: 编码类型，可选，不传则根据扩展名自动判断

        Example:
            >>> await bot.reply_voice_file(msg, "C:/Users/xxx/hello.mp3")
        """
        creds = await self._ensure_creds()

        await send_voice_from_file(
            base_url=creds.base_url,
            token=creds.token,
            to_user_id=msg.user_id,
            context_token=msg.context_token,
            file_path=file_path,
            encode_type=encode_type,
        )

    async def reply_voice(
        self,
        msg: IncomingMessage,
        voice_url: str,
        duration: int | None = None,
    ) -> None:
        """回复语音消息
        
        Args:
            msg: 要回复的原始消息对象
            voice_url: 语音文件 URL（SILK/AMR 格式）
            duration: 语音时长（秒），可选
        """
        creds = await self._ensure_creds()
        
        msg_body = build_voice_msg(
            to_user_id=msg.user_id,
            context_token=msg.context_token,
            voice_url=voice_url,
            duration=duration,
        )
        await send_message(creds.base_url, creds.token, msg_body)
    
    async def reply_file(
        self,
        msg: IncomingMessage,
        file_url: str,
        file_name: str,
    ) -> None:
        """回复文件消息
        
        Args:
            msg: 要回复的原始消息对象
            file_url: 文件下载 URL
            file_name: 显示给用户的文件名
        """
        creds = await self._ensure_creds()
        
        msg_body = build_file_msg(
            to_user_id=msg.user_id,
            context_token=msg.context_token,
            file_url=file_url,
            file_name=file_name,
        )
        await send_message(creds.base_url, creds.token, msg_body)
    
    async def reply_video(
        self,
        msg: IncomingMessage,
        video_url: str,
        *,
        duration: int | None = None,
        thumb_url: str | None = None,
    ) -> None:
        """回复视频消息
        
        Args:
            msg: 要回复的原始消息对象
            video_url: 视频文件 URL
            duration: 视频时长（秒），可选
            thumb_url: 封面缩略图 URL，可选
        """
        creds = await self._ensure_creds()
        
        msg_body = build_video_msg(
            to_user_id=msg.user_id,
            context_token=msg.context_token,
            video_url=video_url,
            duration=duration,
            thumb_url=thumb_url,
        )
        await send_message(creds.base_url, creds.token, msg_body)

    async def reply_file_from_file(
        self,
        msg: IncomingMessage,
        file_source: str | Path,
        file_name: str | None = None,
    ) -> dict[str, Any]:
        """回复文件消息（支持本地路径或网络URL）

        智能处理两种输入方式：
        - 本地文件路径 → 直接上传到微信CDN
        - 网络URL → 先下载到临时目录，再上传到微信CDN

        Args:
            msg: 要回复的原始消息对象
            file_source: 文件路径或URL（自动识别）
                - 本地路径: r"E:\\path\\to\\file.pdf"
                - 网络URL: "https://example.com/file.pdf"
            file_name: 自定义文件名（可选）

        Returns:
            API响应结果

        Example:
            # 发送本地文件
            await bot.reply_file_from_file(msg, "E:/docs/report.pdf")

            # 发送网络文件（自动下载）
            await bot.reply_file_from_file(msg, "https://example.com/document.pdf")
        """
        creds = await self._ensure_creds()

        result = await send_file_from_file(
            base_url=creds.base_url,
            token=creds.token,
            to_user_id=msg.user_id,
            context_token=msg.context_token,
            file_source=file_source,
            file_name=file_name,
        )
        return result

    async def reply_video_from_file(
        self,
        msg: IncomingMessage,
        video_source: str | Path,
        *,
        duration: int | None = None,
    ) -> dict[str, Any]:
        """回复视频消息（支持本地路径或网络URL）

        智能处理两种输入方式：
        - 本地视频路径 → 直接上传到微信CDN
        - 网络URL → 先下载到临时目录，再上传到微信CDN

        Args:
            msg: 要回复的原始消息对象
            video_source: 视频文件路径或URL（自动识别）
                - 本地路径: r"E:\\path\\to\\video.mp4"
                - 网络URL: "https://example.com/video.mp4"
            duration: 视频时长（秒），可选

        Returns:
            API响应结果

        Example:
            # 发送本地视频
            await bot.reply_video_from_file(msg, "E:/videos/demo.mp4", duration=10)

            # 发送网络视频（自动下载）
            await bot.reply_video_from_file(msg, "https://example.com/video.mp4")
        """
        creds = await self._ensure_creds()

        result = await send_video_from_file(
            base_url=creds.base_url,
            token=creds.token,
            to_user_id=msg.user_id,
            context_token=msg.context_token,
            video_source=video_source,
            duration=duration,
        )
        return result

    async def reply_mixed(
        self,
        msg: IncomingMessage,
        *,
        text: str | None = None,
        image_url: str | None = None,
        **kwargs,
    ) -> None:
        """回复混合类型消息（图文混排等）
        
        在一条消息中组合多种内容类型。
        目前支持最常见的「文字+图片」组合。
        
        Args:
            msg: 要回复的原始消息对象
            text: 文本内容（可选）
            image_url: 图片 URL（可选）
            **kwargs: 预留扩展参数
            
        Example:
            >>> # 文字+图片
            >>> await bot.reply_mixed(
            ...     msg,
            ...     text="这是今天的天气情况：",
            ...     image_url="https://example.com/weather.png"
            ... )
        """
        from .types import ItemType
        
        items = []
        
        if text:
            items.append((ItemType.TEXT, {"text": text}))
        if image_url:
            items.append((ItemType.IMAGE, {"url": image_url}))
        
        if not items:
            raise ValueError("至少需要一种内容类型（text 或 image_url）")
        
        from .core import build_mixed_msg
        
        creds = await self._ensure_creds()
        msg_body = build_mixed_msg(
            to_user_id=msg.user_id,
            context_token=msg.context_token,
            *items,
        )
        await send_message(creds.base_url, creds.token, msg_body)
    
    # =========================================================================
    # 主动发送方法（需先有上下文）
    # =========================================================================
    
    async def send(self, user_id: str, text: str) -> None:
        """主动向用户发送文本消息
        
        注意：仅在最近 24 小时内收到过该用户消息时可用，
        且受每日 10 条主动消息限制。
        
        Args:
            user_id: 目标用户 ID
            text: 文本内容
            
        Raises:
            RuntimeError: 该用户无缓存上下文时抛出
        """
        ctx = self._context_tokens.get(user_id)
        if not ctx:
            raise RuntimeError(
                f"无法主动发送给用户 {user_id}："
                "需要先收到该用户的消息以建立上下文"
            )
        
        creds = await self._ensure_creds()
        
        for chunk in self._chunk_text(text):
            msg_body = build_text_msg(user_id, ctx, chunk)
            await send_message(creds.base_url, creds.token, msg_body)
    
    async def send_image(
        self,
        user_id: str,
        image_url: str,
        *,
        thumb_url: str | None = None,
    ) -> None:
        """主动向用户发送图片/表情包（网络 URL）

        Args:
            user_id: 目标用户 ID
            image_url: 图片/GIF URL
            thumb_url: 缩略图 URL（可选）

        Raises:
            RuntimeError: 该用户无缓存上下文时抛出
        """
        ctx = self._context_tokens.get(user_id)
        if not ctx:
            raise RuntimeError(f"无法主动发送给用户 {user_id}：缺少上下文")

        creds = await self._ensure_creds()
        msg_body = build_image_msg(user_id, ctx, image_url, thumb_url=thumb_url)
        await send_message(creds.base_url, creds.token, msg_body)

    async def send_image_file(
        self,
        user_id: str,
        file_path: str | Path,
    ) -> None:
        """主动向用户发送本地图片文件

        Args:
            user_id: 目标用户 ID
            file_path: 本地图片路径（支持 jpg/png/gif/webp）

        Raises:
            RuntimeError: 该用户无缓存上下文时抛出
        """
        ctx = self._context_tokens.get(user_id)
        if not ctx:
            raise RuntimeError(f"无法主动发送给用户 {user_id}：缺少上下文")

        creds = await self._ensure_creds()

        await send_image_from_file(
            base_url=creds.base_url,
            token=creds.token,
            to_user_id=user_id,
            context_token=ctx,
            file_path=file_path,
        )
    
    # =========================================================================
    # 状态管理方法
    # =========================================================================
    
    async def show_typing(self, user_id: str) -> None:
        """显示「对方正在输入...」状态
        
        Args:
            user_id: 目标用户 ID
            
        Raises:
            RuntimeError: 该用户无缓存上下文时抛出
        """
        ctx = self._context_tokens.get(user_id)
        if not ctx:
            raise RuntimeError(f"无法设置打字状态：用户 {user_id} 缺少上下文")
        
        try:
            creds = await self._ensure_creds()
            config = await get_config(
                creds.base_url, creds.token, user_id, ctx
            )
            ticket = config.get("typing_ticket")
            if ticket:
                await send_typing(
                    creds.base_url, creds.token, user_id, ticket, status=1
                )
        except Exception as e:
            print(f"[wxclaw] 设置打字状态失败: {e}")
    
    async def hide_typing(self, user_id: str) -> None:
        """取消「正在输入...」状态
        
        Args:
            user_id: 目标用户 ID
        """
        ctx = self._context_tokens.get(user_id)
        if not ctx:
            return
        
        try:
            creds = await self._ensure_creds()
            config = await get_config(
                creds.base_url, creds.token, user_id, ctx
            )
            ticket = config.get("typing_ticket")
            if ticket:
                await send_typing(
                    creds.base_url, creds.token, user_id, ticket, status=2
                )
        except Exception:
            pass
    
    # =========================================================================
    # 运行控制方法
    # =========================================================================
    
    def run(self) -> None:
        """启动 Bot 主循环（阻塞）
        
        开始长轮询监听消息，直到调用 stop() 或发生致命错误。
        此方法会阻塞当前线程。
        
        内部实现：
        1. 确保凭证有效（必要时触发登录）
        2. 进入长轮询循环
        3. 收到消息后分发到所有处理器
        4. 异常时自动重连（指数退避）
        5. 会话过期时自动重新登录
        """
        self._stopped = False
        asyncio.run(self._run_loop())
    
    def stop(self) -> None:
        """请求停止 Bot 主循环
        
        通常在信号处理中调用：
        
        >>> import signal
        >>> signal.signal(signal.SIGINT, lambda s, f: bot.stop())
        """
        self._stopped = True
    
    # =========================================================================
    # 内部方法
    # =========================================================================
    
    async def _ensure_creds(self) -> Credentials:
        """确保凭证可用，必要时自动登录
        
        Returns:
            有效的 Credentials 对象
        """
        if self._credentials is not None:
            return self._credentials
        
        self._credentials = await do_login(base_url=self._base_url)
        return self._credentials
    
    async def _run_loop(self) -> None:
        """长轮询主循环
        
        核心逻辑：
        1. 调用 get_updates() 长轮询获取消息
        2. 解析并分发消息到处理器
        3. 处理异常（普通错误重连 / 会话过期重登录）
        4. 指数退避避免频繁重试
        """
        print("[wxclaw] 长轮询启动...")
        retry_delay = INITIAL_RETRY_DELAY
        
        while not self._stopped:
            try:
                creds = await self._ensure_creds()
                
                result = await get_updates(
                    creds.base_url, creds.token, self._cursor
                )
                
                self._cursor = result.get("get_updates_buf", "") or self._cursor
                retry_delay = INITIAL_RETRY_DELAY
                
                for raw_msg in result.get("msgs", []):
                    self._cache_context(raw_msg)
                    
                    incoming = self._parse_incoming(raw_msg)
                    if incoming is None:
                        continue
                    
                    await self._dispatch(incoming)
                    
            except asyncio.CancelledError:
                break
                
            except ILinkError as err:
                if err.is_session_expired:
                    print("[wxclaw] ⚠️  会话过期，正在重新登录...")
                    self._credentials = None
                    self._cursor = ""
                    self._context_tokens.clear()
                    
                    try:
                        await clear_credentials_async()
                        self._credentials = await do_login(
                            base_url=self._base_url, force=True
                        )
                        retry_delay = INITIAL_RETRY_DELAY
                        continue
                    except Exception as login_err:
                        print(f"[wxclaw] ❌ 重新登录失败: {login_err}")
                        
                else:
                    print(f"[wxclaw] ❌ API 错误: {err}")
                    
                await asyncio.sleep(retry_delay)
                retry_delay = min(retry_delay * 2, MAX_RETRY_DELAY)
                
            except Exception as err:
                print(f"[wxclaw] ❌ 未预期异常: {err}")
                await asyncio.sleep(retry_delay)
                retry_delay = min(retry_delay * 2, MAX_RETRY_DELAY)
        
        print("[wxclaw] 🔴 长轮询已停止")
    
    def _cache_context(self, raw_msg: dict) -> None:
        """缓存消息中的 context_token
        
        用于后续主动发送消息时使用。
        
        Args:
            raw_msg: 原始消息字典
        """
        from .types import MessageType
        
        uid = (
            raw_msg.get("from_user_id", "")
            if raw_msg.get("message_type") == MessageType.USER
            else raw_msg.get("to_user_id", "")
        )
        ctx = raw_msg.get("context_token", "")
        
        if uid and ctx:
            self._context_tokens[uid] = ctx
    
    def _parse_incoming(self, raw_msg: dict) -> IncomingMessage | None:
        """将原始消息字典解析为 IncomingMessage 对象
        
        只处理用户发送的消息（message_type==1），
        忽略 Bot 自己发出的消息。
        
        Args:
            raw_msg: 从 API 收到的原始消息字典
            
        Returns:
            解析后的 IncomingMessage，非用户消息返回 None
        """
        from .types import MessageType, ItemType
        
        if raw_msg.get("message_type") != MessageType.USER:
            return None
        
        ts_ms = raw_msg.get("create_time_ms", 0)
        timestamp = datetime.fromtimestamp(
            ts_ms / 1000, tz=timezone.utc
        ).astimezone()
        
        texts: list[str] = []
        msg_type = "text"
        
        for item in raw_msg.get("item_list", []):
            item_type = item.get("type")
            
            match item_type:
                case ItemType.TEXT:
                    texts.append(item.get("text_item", {}).get("text", ""))
                case ItemType.IMAGE:
                    msg_type = "image"
                    texts.append("[图片]")
                case ItemType.VOICE:
                    msg_type = "voice"
                    voice_text = item.get("voice_item", {}).get("text", "")
                    if voice_text and voice_text.strip():
                        texts.append(voice_text.strip())
                    else:
                        texts.append("[语音]")
                case ItemType.FILE:
                    msg_type = "file"
                    texts.append(f"[文件: {item.get('file_item', {}).get('file_name', '')}]")
                case ItemType.VIDEO:
                    msg_type = "video"
                    texts.append("[视频]")
                case _:
                    pass
        
        return IncomingMessage(
            user_id=raw_msg.get("from_user_id", ""),
            text="\n".join(texts),
            msg_type=msg_type,
            raw=raw_msg,
            context_token=raw_msg.get("context_token", ""),
            timestamp=timestamp,
        )
    
    async def _dispatch(self, msg: IncomingMessage) -> None:
        """分发消息到所有已注册的处理器
        
        并发执行所有处理器，任一处理器异常不影响其他处理器。
        
        Args:
            msg: 待分发的消息对象
        """
        if not self._handlers:
            return
        
        results = await asyncio.gather(
            *(self._call_handler(h, msg) for h in self._handlers),
            return_exceptions=True,
        )
        
        for result in results:
            if isinstance(result, Exception):
                print(f"[wxclaw] 处理器异常: {result}")
    
    async def _call_handler(
        self,
        handler: MessageHandler,
        msg: IncomingMessage,
    ) -> None:
        """调用单个处理器，自动适配同步/异步
        
        Args:
            handler: 处理器函数
            msg: 消息对象
        """
        result = handler(msg)
        if inspect.isawaitable(result):
            await result
    
    def _chunk_text(self, text: str) -> list[str]:
        """将长文本按字符数分片
        
        Args:
            text: 原始文本
            
        Returns:
            分片后的文本列表，每片最多 TEXT_CHUNK_SIZE 字符
        """
        if len(text) <= TEXT_CHUNK_SIZE:
            return [text]
        
        return [
            text[i:i + TEXT_CHUNK_SIZE]
            for i in range(0, len(text), TEXT_CHUNK_SIZE)
        ]


__all__ = ["WxClawBot"]