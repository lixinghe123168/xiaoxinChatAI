"""
wxclaw.auth - 认证与凭证管理模块

处理微信 iLink Bot 的登录流程和凭证持久化。
这是 SDK 的安全层，负责：
1. QR 码获取与扫码状态轮询
2. 凭证（token/base_url/user_id）的本地存储
3. 会话过期后的自动重新登录

设计规范参考：
- OAuth 2.0 的 token 管理模式
- 安全凭证存储最佳实践
- Python pathlib 文件操作规范

凭证存储位置:
    默认: ~/.wxclaw/credentials.json
    权限: 0o600 (仅所有者可读写)

登录流程:
    1. 调用 fetch_qrcode() → 获取二维码 URL
    2. 展示给用户扫描
    3. 循环调用 poll_qr_status() → 等待确认
    4. 收到 confirmed → 提取 token 并保存
    5. 后续 API 调用使用保存的 token
"""

import asyncio
import json
from pathlib import Path
from typing import Literal

from .core import DEFAULT_BASE_URL, fetch_qrcode, poll_qr_status
from .types import Credentials


# ============================================================================
# 常量定义
# ============================================================================

CREDENTIALS_DIR: Path = Path.home() / ".wxclaw"
"""凭证存储目录，位于用户主目录下"""

CREDENTIALS_FILE: Path = CREDENTIALS_DIR / "credentials.json"
"""凭证文件完整路径"""

QR_POLL_INTERVAL: float = 2.0
"""二维码状态轮询间隔（秒）"""


# ============================================================================
# 凭证持久化（同步方法，在异步上下文中通过 asyncio.to_thread 调用）
# ============================================================================

def save_credentials(creds: Credentials) -> None:
    """将凭证保存到本地文件
    
    以 JSON 格式写入 ~/.wxclaw/credentials.json，
    目录权限设为 0o700，文件权限设为 0o600。
    
    Args:
        creds: 要保存的 Credentials 对象
        
    Raises:
        OSError: 文件写入失败时抛出
        
    Security:
        - 使用 0o600 权限限制文件访问
        - 仅当前用户可读写
        - 不记录到日志或打印输出
        
    Note:
        此方法是同步的，在异步上下文中应通过 save_credentials_async() 调用。
    """
    CREDENTIALS_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    
    payload = {
        "token": creds.token,
        "base_url": creds.base_url,
        "bot_id": creds.bot_id,
        "user_id": creds.user_id,
    }
    
    CREDENTIALS_FILE.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    CREDENTIALS_FILE.chmod(0o600)


def load_credentials() -> Credentials | None:
    """从本地文件加载凭证
    
    尝试读取 ~/.wxclaw/credentials.json 并解析为 Credentials 对象。
    
    Returns:
        成功时返回 Credentials 对象，文件不存在或格式错误返回 None
        
    Example:
        >>> creds = load_credentials()
        >>> if creds:
        ...     print(f"已登录用户: {creds.user_id}")
        ... else:
        ...     print("需要先登录")
        
    Note:
        此方法是同步的，在异步上下文中应通过 load_credentials_async() 调用。
    """
    try:
        raw = CREDENTIALS_FILE.read_text(encoding="utf-8")
        data = json.loads(raw)
        
        return Credentials(
            token=data["token"],
            base_url=data["base_url"],
            bot_id=data.get("bot_id", ""),
            user_id=data.get("user_id", ""),
        )
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        return None


def clear_credentials() -> None:
    """清除本地存储的凭证
    
    删除凭证文件。通常在会话过期后调用，
    强制下次启动时重新扫码登录。
    
    Note:
        使用 missing_ok=True 忽略文件不存在的错误。
    """
    CREDENTIALS_FILE.unlink(missing_ok=True)


# ============================================================================
# 异步包装器
# ============================================================================

async def save_credentials_async(creds: Credentials) -> None:
    """异步保存凭证（线程池执行）
    
    将同步的 save_credentials 包装为异步接口，
    避免阻塞事件循环。
    """
    await asyncio.to_thread(save_credentials, creds)


async def load_credentials_async() -> Credentials | None:
    """异步加载凭证（线程池执行）
    
    将同步的 load_credentials 包装为异步接口。
    """
    return await asyncio.to_thread(load_credentials)


async def clear_credentials_async() -> None:
    """异步清除凭证（线程池执行）
    """
    await asyncio.to_thread(clear_credentials)


# ============================================================================
# 登录流程
# ============================================================================

def _print_qr_instructions(url: str) -> None:
    """打印二维码使用说明
    
    Args:
        url: 二维码图片URL或数据内容
    """
    import sys
    
    print("\n" + "=" * 50)
    print("[wxclaw] 请在微信中打开以下链接完成登录:")
    print("=" * 50)
    print(url)
    print("=" * 50 + "\n")


async def login(
    base_url: str = DEFAULT_BASE_URL,
    force: bool = False,
) -> Credentials:
    """执行完整的登录流程
    
    这是认证模块的核心函数，处理整个 QR 码登录过程：
    
    1. 如果 force=False 且存在有效凭证，直接返回缓存的凭证
    2. 否则进入 QR 码登录流程：
       a. 获取二维码并展示给用户
       b. 轮询等待用户扫码
       c. 用户确认后提取 token
       d. 保存凭证到本地
    
    Args:
        base_url: iLink API 基础 URL，默认使用官方地址
        force: 是否强制重新登录（忽略已有凭证）
            
    Returns:
        包含认证信息的 Credentials 对象
        
    Raises:
        ILinkError: API 调用失败
        RuntimeError: 二维码确认但未返回有效凭证
        
    Example:
        >>> # 正常登录（有缓存时跳过）
        >>> creds = await login()
        >>> 
        >>> # 强制重新登录
        >>> creds = await login(force=True)
        >>>
        >>> # 指定自定义 base_url
        >>> creds = await login(base_url="https://custom.api.com")
        
    Lifecycle:
        登录成功后，Credentials 会自动保存到本地。
        下次调用 login() 时会优先使用缓存。
        当收到 errcode=-14 (会话过期) 时，应调用 login(force=True) 重新登录。
    """
    if not force:
        existing = await load_credentials_async()
        if existing is not None:
            print(f"[wxclaw] 使用已缓存的凭证 (user_id={existing.user_id})")
            return existing
    
    while True:
        # Step 1: 获取二维码
        qr_result = await fetch_qrcode(base_url)
        qrcode_key = qr_result["qrcode"]
        qrcode_content = qr_result["qrcode_img_content"]
        
        _print_qr_instructions(qrcode_content)
        
        # Step 2: 轮询等待扫码
        last_status: Literal["wait", "scaned", "confirmed", "expired"] | None = None
        
        while True:
            status_result = await poll_qr_status(base_url, qrcode_key)
            current_status: str = status_result["status"]
            
            # 状态变化时输出提示
            if current_status != last_status:
                match current_status:
                    case "scaned":
                        print("[wxclaw] ✓ 已检测到扫码，请在微信中确认登录...")
                    case "confirmed":
                        print("[wxclaw] ✓✓ 登录确认成功!")
                    case "expired":
                        print("[wxclaw] ✗ 二维码已过期，正在重新获取...")
                    case _:
                        pass
                last_status = current_status
            
            # Step 3: 处理确认结果
            if current_status == "confirmed":
                bot_token = status_result.get("bot_token")
                ilink_bot_id = status_result.get("ilink_bot_id")
                ilink_user_id = status_result.get("ilink_user_id")
                
                if not all([bot_token, ilink_bot_id, ilink_user_id]):
                    raise RuntimeError(
                        "登录已确认，但服务端未返回完整的凭证信息。"
                        f"收到的数据: {list(status_result.keys())}"
                    )
                
                credentials = Credentials(
                    token=bot_token,
                    base_url=status_result.get("baseurl") or base_url,
                    bot_id=ilink_bot_id,
                    user_id=ilink_user_id,
                )
                
                await save_credentials_async(credentials)
                print(f"[wxclaw] ✓✓✓ 凭证已保存 (user_id={ilink_user_id})")
                return credentials
            
            # 二维码过期，重新获取
            if current_status == "expired":
                break
            
            # 继续轮询
            await asyncio.sleep(QR_POLL_INTERVAL)


__all__ = [
    "CREDENTIALS_DIR",
    "CREDENTIALS_FILE",
    "Credentials",
    "login",
    "load_credentials",
    "load_credentials_async",
    "save_credentials",
    "save_credentials_async",
    "clear_credentials",
    "clear_credentials_async",
]