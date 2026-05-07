"""
wxclaw.core - iLink 协议核心封装层

提供微信 iLink Bot API 的底层 HTTP 调用接口。
"""

import asyncio
import base64
import hashlib
import json
import os
import tempfile
import uuid
from pathlib import Path
from typing import Any

import aiohttp
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding


DEFAULT_BASE_URL: str = "https://ilinkai.weixin.qq.com"
CHANNEL_VERSION: str = "1.0.3"
TEMP_DIR: Path = Path(tempfile.gettempdir()) / "clawpy"
MAX_IMAGE_SIZE: int = 10 * 1024 * 1024

SUPPORTED_IMAGE_TYPES: dict[str, str] = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".gif": "image/gif",
    ".webp": "image/webp",
}

UploadMediaType: dict[int, str] = {
    1: "image",
    2: "video",
    3: "file",
    4: "voice",
}

CDN_FALLBACK_HOSTS: list[str] = [
    "https://novac2c.cdn.weixin.qq.com/c2c",
]


class ILinkError(Exception):
    def __init__(self, message: str, *, code: int | None = None, payload: dict | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.payload = payload

    @property
    def is_session_expired(self) -> bool:
        return self.code == -14

    def __str__(self) -> str:
        if self.code is not None:
            return f"[ILinkError:{self.code}] {self.message}"
        return f"[ILinkError] {self.message}"


def mp3_to_silk(mp3_path: str | Path, silk_path: str | Path | None = None) -> tuple[Path, int]:
    """
    音频转 SILK 格式（微信语音编码）
    
    Args:
        mp3_path: 音频文件路径（支持 MP3/WAV/AAC/OGG 等，也支持已转换的 .silk）
        silk_path: 输出 SILK 文件路径（可选），默认同目录下同名.silk
        
    Returns:
        (silk_path, duration_ms): 输出文件路径和音频时长（毫秒）
    """
    import logging
    import subprocess
    from pydub import AudioSegment
    
    logger = logging.getLogger("wxclaw.core")
    
    mp3_path = Path(mp3_path)
    
    if not mp3_path.exists():
        raise FileNotFoundError(f"文件不存在: {mp3_path}")
    
    if silk_path is None:
        silk_path = mp3_path.parent / (mp3_path.stem + ".silk")
    silk_path = Path(silk_path)
    
    if mp3_path.suffix.lower() == ".silk":
        logger.info(f"[mp3_to_silk] 已是 SILK 格式，跳过转换: {mp3_path}")
        duration_ms = int(mp3_path.stat().st_size / 160 * 20)
        return (mp3_path, max(duration_ms, 1000))
    
    # 1. 读取音频真实时长
    logger.info(f"[mp3_to_silk] 读取音频时长: {mp3_path}")
    audio = AudioSegment.from_file(mp3_path)
    duration_ms = len(audio)
    logger.info(f"[mp3_to_silk] 音频时长: {duration_ms}ms")
    
    # 2. 转成 PCM (24kHz, 16bit, mono)
    temp_pcm = mp3_path.parent / (mp3_path.stem + ".temp.pcm")
    logger.info(f"[mp3_to_silk] 转 PCM: {mp3_path} -> {temp_pcm}")
    
    try:
        ffmpeg_cmd = [
            "ffmpeg", "-y", "-i", str(mp3_path),
            "-f", "s16le", "-ar", "24000", "-ac", "1", str(temp_pcm)
        ]
        result = subprocess.run(
            ffmpeg_cmd, 
            capture_output=True, 
            text=True, 
            check=True
        )
    except subprocess.CalledProcessError as e:
        logger.error(f"[mp3_to_silk] FFmpeg 失败: {e.stderr}")
        raise Exception(f"FFmpeg 转换失败: {e}") from e
    
    # 3. 用 silk-python (pysilk) 转成 SILK
    logger.info(f"[mp3_to_silk] PCM 转 SILK: {temp_pcm} -> {silk_path}")

    try:
        import pysilk
        with open(temp_pcm, "rb") as f_pcm, open(silk_path, "wb") as f_silk:
            pysilk.encode(f_pcm, f_silk, 24000, 24000)
        logger.info(f"[mp3_to_silk] pysilk 编码完成")

    except ImportError:
        logger.error("[mp3_to_silk] 请先安装: pip install silk-python")
        if temp_pcm.exists():
            temp_pcm.unlink(missing_ok=True)
        raise Exception("需要安装 silk-python 库: pip install silk-python") from None
    except Exception as e:
        logger.error(f"[mp3_to_silk] silk 编码失败: {e}")
        if temp_pcm.exists():
            temp_pcm.unlink(missing_ok=True)
        raise Exception(f"SILK 编码失败: {e}") from e
    finally:
        if temp_pcm.exists():
            temp_pcm.unlink(missing_ok=True)

    logger.info(f"[mp3_to_silk] ✓ 转换完成: {silk_path}")
    logger.info(f"[mp3_to_silk]   文件大小: {silk_path.stat().st_size} bytes")
    return (silk_path, duration_ms)


def _generate_uin() -> str:
    raw = int.from_bytes(os.urandom(4), byteorder="big")
    return base64.b64encode(str(raw).encode("ascii")).decode("ascii")


def _build_headers(token: str) -> dict[str, str]:
    return {
        "Content-Type": "application/json",
        "AuthorizationType": "ilink_bot_token",
        "Authorization": f"Bearer {token}",
        "X-WECHAT-UIN": _generate_uin(),
    }


def _build_base_info() -> dict[str, str]:
    return {"channel_version": CHANNEL_VERSION}


async def _post(
    base_url: str,
    endpoint: str,
    token: str,
    body: dict[str, Any],
    timeout_ms: int = 35_000,
) -> dict[str, Any]:
    import logging

    logger = logging.getLogger("wxclaw.core.http")

    url = f"{base_url.rstrip('/')}/{endpoint.lstrip('/')}"

    async with aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=timeout_ms / 1000)
    ) as session:
        async with session.post(
            url,
            headers=_build_headers(token),
            json=body,
        ) as response:
            raw_text = await response.text()

            if not raw_text:
                raise ILinkError("空响应", code=response.status)

            data = json.loads(raw_text)

            if response.status >= 400:
                errmsg = data.get("errmsg", f"HTTP {response.status}")
                errcode = data.get("errcode")
                raise ILinkError(errmsg, code=errcode, payload=data)

            ret = data.get("ret", 0)
            if isinstance(ret, int) and ret != 0:
                errmsg = data.get("errmsg", f"业务错误 ret={ret}")
                errcode = data.get("errcode", ret)
                raise ILinkError(errmsg, code=errcode, payload=data)

            return data


async def _get(
    base_url: str,
    path: str,
    extra_headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    url = f"{base_url.rstrip('/')}/{path.lstrip('/')}"

    async with aiohttp.ClientSession() as session:
        async with session.get(url, headers=extra_headers or {}) as response:
            raw_text = await response.text()
            if response.status >= 400:
                raise ILinkError(f"HTTP {response.status}", code=response.status)
            return json.loads(raw_text)


async def fetch_qrcode(base_url: str = DEFAULT_BASE_URL) -> dict[str, str]:
    return await _get(
        base_url,
        "/ilink/bot/get_bot_qrcode?bot_type=3"
    )


async def poll_qr_status(
    base_url: str,
    qrcode: str,
) -> dict[str, Any]:
    from urllib.parse import quote

    return await _get(
        base_url,
        f"/ilink/bot/get_qrcode_status?qrcode={quote(qrcode, safe='')}",
        extra_headers={"iLink-App-ClientVersion": "1"},
    )


async def get_updates(
    base_url: str,
    token: str,
    buf: str = "",
) -> dict[str, Any]:
    body = {
        "get_updates_buf": buf,
        "base_info": _build_base_info(),
    }
    return await _post(base_url, "/ilink/bot/getupdates", token, body)


async def send_message(
    base_url: str,
    token: str,
    message_body: dict[str, Any],
) -> dict[str, Any]:
    import logging

    logger = logging.getLogger("wxclaw.core")

    payload = {
        "msg": message_body,
        "base_info": _build_base_info(),
    }

    msg_type = message_body.get("item_list", [{}])[0].get("type", "unknown")
    type_names = {1: "TEXT", 2: "IMAGE", 3: "VOICE", 4: "FILE", 5: "VIDEO"}
    type_name = type_names.get(msg_type, f"UNKNOWN({msg_type})")

    try:
        result = await _post(
            base_url,
            "/ilink/bot/sendmessage",
            token,
            payload,
            timeout_ms=15_000,
        )

        return result

    except ILinkError as e:
        raise


async def get_config(
    base_url: str,
    token: str,
    user_id: str,
    context_token: str,
) -> dict[str, Any]:
    body = {
        "ilink_user_id": user_id,
        "context_token": context_token,
        "base_info": _build_base_info(),
    }
    return await _post(base_url, "/ilink/bot/getconfig", token, body)


async def send_typing(
    base_url: str,
    token: str,
    user_id: str,
    ticket: str,
    status: int,
) -> dict[str, Any]:
    body = {
        "ilink_user_id": user_id,
        "typing_ticket": ticket,
        "status": status,
        "base_info": _build_base_info(),
    }
    return await _post(base_url, "/ilink/bot/sendtyping", token, body)


async def get_upload_url(
    base_url: str,
    token: str,
    to_user_id: str,
    filekey: str,
    media_type: int,
    rawsize: int,
    rawfilemd5: str,
    filesize: int,
    aeskey_hex: str,
) -> dict[str, Any]:
    import logging

    logger = logging.getLogger("wxclaw.core")

    body = {
        "filekey": filekey,
        "media_type": media_type,
        "to_user_id": to_user_id,
        "rawsize": rawsize,
        "rawfilemd5": rawfilemd5,
        "filesize": filesize,
        "no_need_thumb": True,
        "aeskey": aeskey_hex,
        "base_info": _build_base_info(),
    }

    result = await _post(
        base_url,
        "/ilink/bot/getuploadurl",
        token,
        body,
        timeout_ms=15_000,
    )

    upload_param = result.get("upload_param")

    if not upload_param:
        raise ILinkError(
            f"getuploadurl 返回的 upload_param 为空! 完整响应: {json.dumps(result, ensure_ascii=False)[:200]}"
        )

    return result


def _aes_ecb_encrypt(plaintext: bytes, key: bytes) -> bytes:
    padder = padding.PKCS7(128).padder()
    padded_data = padder.update(plaintext) + padder.finalize()

    cipher = Cipher(algorithms.AES(key), modes.ECB())
    encryptor = cipher.encryptor()
    ciphertext = encryptor.update(padded_data) + encryptor.finalize()

    return ciphertext


def _aes_ecb_padded_size(plaintext_size: int) -> int:
    return ((plaintext_size // 16) + 1) * 16


async def upload_to_cdn(
    cdn_base_url: str,
    upload_param: str,
    filekey: str,
    encrypted_data: bytes,
) -> str:
    import logging
    from urllib.parse import urlencode

    logger = logging.getLogger("wxclaw.core")

    candidate_urls = []

    if cdn_base_url and cdn_base_url.strip():
        base = cdn_base_url.rstrip("/")
        if not base.startswith(("http://", "https://")):
            base = f"https://{base}"
        query_params = urlencode({
            "encrypted_query_param": upload_param,
            "filekey": filekey,
        })
        candidate_urls.append((f"{base}/upload?{query_params}", "来自 getuploadurl 响应"))
    elif upload_param.startswith("http://") or upload_param.startswith("https://"):
        candidate_urls.append((f"{upload_param}&filekey={filekey}", "upload_param 本身是完整 URL"))

    for fallback_host in CDN_FALLBACK_HOSTS:
        url = f"{fallback_host}/upload?{urlencode({'encrypted_query_param': upload_param, 'filekey': filekey})}"
        candidate_urls.append((url, f"备选节点: {fallback_host}"))

    last_error = None

    for idx, (upload_url, source) in enumerate(candidate_urls, 1):
        try:
            timeout = aiohttp.ClientTimeout(total=15)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(
                    upload_url,
                    headers={"Content-Type": "application/octet-stream"},
                    data=encrypted_data,
                ) as response:

                    if 400 <= response.status < 500:
                        err_msg = response.headers.get("x-error-message", await response.text())
                        raise ILinkError(
                            f"CDN 客户端错误: HTTP {response.status} - {err_msg}",
                            code=response.status
                        )

                    if response.status != 200:
                        err_msg = response.headers.get("x-error-message", f"HTTP {response.status}")
                        raise ILinkError(
                            f"CDN 服务器错误: {err_msg}",
                            code=response.status
                        )

                    download_param = response.headers.get("x-encrypted-param")

                    if not download_param:
                        raise ILinkError(
                            "CDN 上传响应缺少 x-encrypted-param 头"
                        )

                    return download_param

        except ILinkError as e:
            if e.code and 400 <= e.code < 500:
                raise
            last_error = e

        except Exception as e:
            last_error = e

    raise last_error or ILinkError(
        f"CDN 上传失败! 已尝试全部 {len(candidate_urls)} 个节点"
    )


def _new_client_id() -> str:
    from uuid import uuid4
    return str(uuid4())


def _new_message_envelope(
    to_user_id: str,
    context_token: str,
    items: list[dict],
) -> dict[str, Any]:
    from .types import MessageType, MessageState

    return {
        "from_user_id": "",
        "to_user_id": to_user_id,
        "client_id": _new_client_id(),
        "message_type": MessageType.BOT,
        "message_state": MessageState.FINISH,
        "context_token": context_token,
        "item_list": items,
    }


def build_text_msg(
    to_user_id: str,
    context_token: str,
    text: str,
) -> dict[str, Any]:
    from .types import ItemType

    return _new_message_envelope(to_user_id, context_token, [
        {
            "type": ItemType.TEXT,
            "text_item": {"text": text},
        }
    ])


def build_image_msg(
    to_user_id: str,
    context_token: str,
    image_url: str,
    *,
    thumb_url: str | None = None,
    aes_key: str | None = None,
) -> dict[str, Any]:
    from .types import ItemType

    image_item: dict[str, Any] = {"url": image_url}

    if aes_key:
        image_item["aeskey"] = aes_key
    if thumb_url:
        image_item["thumb_url"] = thumb_url

    return _new_message_envelope(to_user_id, context_token, [
        {
            "type": ItemType.IMAGE,
            "image_item": image_item,
        }
    ])


def build_voice_msg(
    to_user_id: str,
    context_token: str,
    voice_url: str,
    duration: int | None = None,
) -> dict[str, Any]:
    from .types import ItemType

    voice_item: dict[str, Any] = {}
    if voice_url:
        voice_item["url"] = voice_url
    if duration is not None:
        voice_item["playtime"] = duration

    return _new_message_envelope(to_user_id, context_token, [
        {
            "type": ItemType.VOICE,
            "voice_item": voice_item,
        }
    ])


def build_file_msg(
    to_user_id: str,
    context_token: str,
    file_url: str,
    file_name: str,
) -> dict[str, Any]:
    from .types import ItemType

    return _new_message_envelope(to_user_id, context_token, [
        {
            "type": ItemType.FILE,
            "file_item": {
                "url": file_url,
                "file_name": file_name,
            },
        }
    ])


def build_video_msg(
    to_user_id: str,
    context_token: str,
    video_url: str,
    duration: int | None = None,
    thumb_url: str | None = None,
) -> dict[str, Any]:
    from .types import ItemType

    video_item: dict[str, Any] = {"url": video_url}
    if duration is not None:
        video_item["play_length"] = duration
    if thumb_url:
        video_item["thumb_url"] = thumb_url

    return _new_message_envelope(to_user_id, context_token, [
        {
            "type": ItemType.VIDEO,
            "video_item": video_item,
        }
    ])


def build_mixed_msg(
    to_user_id: str,
    context_token: str,
    *items: tuple[int, dict],
) -> dict[str, Any]:
    item_list = []
    for item_type, content in items:
        type_map = {
            1: "text_item",
            2: "image_item",
            3: "voice_item",
            4: "file_item",
            5: "video_item",
        }
        key = type_map.get(item_type)
        if key:
            item_list.append({"type": item_type, key: content})

    return _new_message_envelope(to_user_id, context_token, item_list)


def _get_image_ext(url: str, content_type: str | None = None) -> str:
    path = url.split("?")[0].split("#")[0].lower()
    for ext in SUPPORTED_IMAGE_TYPES:
        if path.endswith(ext):
            return ext

    if content_type:
        ct_map = {
            "image/jpeg": ".jpg",
            "image/png": ".png",
            "image/gif": ".gif",
            "image/webp": ".webp",
        }
        for ct, ext in ct_map.items():
            if ct in content_type:
                return ext

    return ".jpg"


async def download_image(image_url: str) -> tuple[Path, str, int]:
    import logging

    logger = logging.getLogger("wxclaw.core")

    TEMP_DIR.mkdir(parents=True, exist_ok=True)

    try:
        timeout = aiohttp.ClientTimeout(total=30)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(image_url) as response:
                if response.status != 200:
                    raise ILinkError(
                        f"图片下载失败: HTTP {response.status}",
                        code=response.status
                    )

                content_type = response.headers.get("Content-Type", "")
                data = await response.read()
                file_size = len(data)

                if file_size > MAX_IMAGE_SIZE:
                    raise ILinkError(
                        f"图片过大: {file_size / 1024 / 1024:.1f}MB > {MAX_IMAGE_SIZE / 1024 / 1024:.0f}MB"
                    )

                if file_size == 0:
                    raise ILinkError("下载的图片为空文件")

                ext = _get_image_ext(image_url, content_type)
                mime_type = SUPPORTED_IMAGE_TYPES.get(ext, "image/jpeg")

                file_name = f"{uuid.uuid4().hex}{ext}"
                temp_path = TEMP_DIR / file_name

                temp_path.write_bytes(data)

                return temp_path, mime_type, file_size

    except ILinkError:
        raise
    except asyncio.TimeoutError:
        raise ILinkError("图片下载超时 (>30s)")
    except Exception as e:
        raise ILinkError(f"图片下载异常: {type(e).__name__}: {e}")


def load_local_image(file_path: str | Path) -> tuple[Path, str, int]:
    """加载本地图片文件

    Args:
        file_path: 本地图片文件路径

    Returns:
        元组 (temp_path, mime_type, file_size)

    Raises:
        ILinkError: 文件不存在、格式不支持或文件过大时抛出
    """
    path = Path(file_path)

    if not path.exists():
        raise ILinkError(f"本地图片不存在: {path}")

    if not path.is_file():
        raise ILinkError(f"路径不是文件: {path}")

    data = path.read_bytes()
    file_size = len(data)

    if file_size > MAX_IMAGE_SIZE:
        raise ILinkError(
            f"图片过大: {file_size / 1024 / 1024:.1f}MB > {MAX_IMAGE_SIZE / 1024 / 1024:.0f}MB"
        )

    if file_size == 0:
        raise ILinkError("图片为空文件")

    ext = _get_image_ext(str(path))
    mime_type = SUPPORTED_IMAGE_TYPES.get(ext, "image/jpeg")

    return path, mime_type, file_size


async def send_image_complete(
    base_url: str,
    token: str,
    to_user_id: str,
    context_token: str,
    image_url: str,
) -> dict[str, Any]:
    import logging

    logger = logging.getLogger("wxclaw.core")

    try:
        temp_path, mime_type, rawsize = await download_image(image_url)
        return await _do_send_image(base_url, token, to_user_id, context_token, temp_path, rawsize)

    except Exception as e:
        raise


async def send_image_from_file(
    base_url: str,
    token: str,
    to_user_id: str,
    context_token: str,
    file_path: str | Path,
) -> dict[str, Any]:
    """发送本地图片文件

    Args:
        base_url: API 基础 URL
        token: 认证令牌
        to_user_id: 目标用户 ID
        context_token: 会话上下文令牌
        file_path: 本地图片文件路径 (支持 jpg/png/gif/webp)

    Returns:
        服务端响应字典
    """
    import logging

    logger = logging.getLogger("wxclaw.core")

    try:
        temp_path, mime_type, rawsize = load_local_image(file_path)
        return await _do_send_image(base_url, token, to_user_id, context_token, temp_path, rawsize)

    except Exception as e:
        raise


async def _do_send_image(
    base_url: str,
    token: str,
    to_user_id: str,
    context_token: str,
    image_path: Path,
    rawsize: int,
) -> dict[str, Any]:
    """执行图片发送的通用流程（加密→上传→发送）

    Args:
        base_url: API 基础 URL
        token: 认证令牌
        to_user_id: 目标用户 ID
        context_token: 会话上下文令牌
        image_path: 图片文件路径（本地）
        rawsize: 原始文件大小

    Returns:
        服务端响应字典
    """
    plaintext_data = image_path.read_bytes()
    rawfilemd5 = hashlib.md5(plaintext_data).hexdigest().upper()
    filesize = _aes_ecb_padded_size(rawsize)

    filekey = os.urandom(16).hex()
    aeskey_bytes = os.urandom(16)
    aeskey_hex = aeskey_bytes.hex()

    upload_result = await get_upload_url(
        base_url=base_url,
        token=token,
        to_user_id=to_user_id,
        filekey=filekey,
        media_type=1,
        rawsize=rawsize,
        rawfilemd5=rawfilemd5,
        filesize=filesize,
        aeskey_hex=aeskey_hex,
    )

    upload_param = upload_result["upload_param"]
    cdn_base_url = upload_result.get("cdn_base_url", "")

    encrypted_data = _aes_ecb_encrypt(plaintext_data, aeskey_bytes)

    download_encrypted_query_param = await upload_to_cdn(
        cdn_base_url=cdn_base_url,
        upload_param=upload_param,
        filekey=filekey,
        encrypted_data=encrypted_data,
    )

    aeskey_base64 = base64.b64encode(aeskey_hex.encode("ascii")).decode("ascii")

    media_obj = {
        "encrypt_query_param": download_encrypted_query_param,
        "aes_key": aeskey_base64,
        "encrypt_type": 1,
    }

    msg_body = build_image_msg_with_media(
        to_user_id=to_user_id,
        context_token=context_token,
        media=media_obj,
        mid_size=rawsize,
    )

    result = await send_message(base_url, token, msg_body)

    try:
        if str(image_path).startswith(str(TEMP_DIR)):
            image_path.unlink(missing_ok=True)
    except Exception:
        pass

    return result


def build_image_msg_with_media(
    to_user_id: str,
    context_token: str,
    *,
    media: dict[str, Any] | None = None,
    mid_size: int | None = None,
) -> dict[str, Any]:
    from .types import ItemType

    if not media:
        raise ValueError("必须提供 media 参数 (CDN 媒体对象)")

    if "encrypt_query_param" not in media:
        raise ValueError("media 缺少 encrypt_query_param 字段")
    if "aes_key" not in media:
        raise ValueError("media 缺少 aes_key 字段")

    if "encrypt_type" not in media:
        media["encrypt_type"] = 1

    image_item: dict[str, Any] = {
        "media": media,
    }

    if mid_size is not None:
        image_item["mid_size"] = mid_size

    return _new_message_envelope(to_user_id, context_token, [
        {
            "type": ItemType.IMAGE,
            "image_item": image_item,
        }
    ])


def build_voice_msg_with_media(
    to_user_id: str,
    context_token: str,
    *,
    media: dict[str, Any] | None = None,
    playtime_ms: int | None = None,
    text: str | None = None,
    encode_type: int = 7,
    rawsize: int | None = None,
) -> dict[str, Any]:
    from .types import ItemType

    if not media:
        raise ValueError("必须提供 media 参数 (CDN 媒体对象)")

    if "encrypt_query_param" not in media:
        raise ValueError("media 缺少 encrypt_query_param 字段")
    if "aes_key" not in media:
        raise ValueError("media 缺少 aes_key 字段")

    voice_item: dict[str, Any] = {
        "media": media,
        "encode_type": encode_type,
    }

    if playtime_ms is not None:
        voice_item["playtime"] = playtime_ms

    if rawsize is not None:
        voice_item["size"] = rawsize

    if text is not None:
        voice_item["text"] = text

    if encode_type in (4, 6):
        voice_item["bits_per_sample"] = 16
        if encode_type == 4:
            voice_item["sample_rate"] = 16000
        elif encode_type == 6:
            voice_item["sample_rate"] = 24000

    return _new_message_envelope(to_user_id, context_token, [
        {
            "type": ItemType.VOICE,
            "voice_item": voice_item,
        }
    ])


async def _do_send_voice(
    base_url: str,
    token: str,
    to_user_id: str,
    context_token: str,
    voice_path: Path,
    rawsize: int,
    duration_ms: int | None = None,
    encode_type: int = 7,
) -> dict[str, Any]:
    """执行语音发送的通用流程（加密→上传→发送）

    Args:
        base_url: API 基础 URL
        token: 认证令牌
        to_user_id: 目标用户 ID
        context_token: 会话上下文令牌
        voice_path: 语音文件路径（本地）
        rawsize: 原始文件大小
        duration_ms: 语音时长（毫秒），可选
        encode_type: 编码类型，默认 7 (MP3)

    Returns:
        服务端响应字典
    """
    import logging

    logger = logging.getLogger("wxclaw.core")

    logger.info(f"[_do_send_voice] 1/5 开始处理: {voice_path}, size={rawsize} bytes, duration={duration_ms}ms, encode_type={encode_type}")
    
    plaintext_data = voice_path.read_bytes()
    rawfilemd5 = hashlib.md5(plaintext_data).hexdigest().upper()
    filesize = _aes_ecb_padded_size(rawsize)
    logger.info(f"[_do_send_voice] 2/5 读取文件完成, MD5={rawfilemd5}, padded_size={filesize}")

    filekey = os.urandom(16).hex()
    aeskey_bytes = os.urandom(16)
    aeskey_hex = aeskey_bytes.hex()
    logger.info(f"[_do_send_voice] 生成密钥: filekey={filekey[:16]}..., aeskey={aeskey_hex[:16]}...")

    logger.info(f"[_do_send_voice] 3/5 调用 get_upload_url...")
    upload_result = await get_upload_url(
        base_url=base_url,
        token=token,
        to_user_id=to_user_id,
        filekey=filekey,
        media_type=4,
        rawsize=rawsize,
        rawfilemd5=rawfilemd5,
        filesize=filesize,
        aeskey_hex=aeskey_hex,
    )
    logger.info(f"[_do_send_voice] get_upload_url 响应: {upload_result!r}")

    upload_param = upload_result["upload_param"]
    cdn_base_url = upload_result.get("cdn_base_url", "")

    encrypted_data = _aes_ecb_encrypt(plaintext_data, aeskey_bytes)
    logger.info(f"[_do_send_voice] 4/5 AES 加密完成, encrypted_size={len(encrypted_data)}")

    logger.info(f"[_do_send_voice] 上传到 CDN: cdn_base_url={cdn_base_url}")
    download_encrypted_query_param = await upload_to_cdn(
        cdn_base_url=cdn_base_url,
        upload_param=upload_param,
        filekey=filekey,
        encrypted_data=encrypted_data,
    )
    logger.info(f"[_do_send_voice] CDN 上传完成, download_param={download_encrypted_query_param[:50]}...")

    aeskey_base64 = base64.b64encode(aeskey_hex.encode("ascii")).decode("ascii")

    media_obj = {
        "encrypt_query_param": download_encrypted_query_param,
        "aes_key": aeskey_base64,
    }

    logger.info(f"[_do_send_voice] 5/5 构建消息并发送...")
    playtime_ms = duration_ms if duration_ms is not None else 5000
    msg_body = build_voice_msg_with_media(
        to_user_id=to_user_id,
        context_token=context_token,
        media=media_obj,
        playtime_ms=playtime_ms,
        encode_type=encode_type,
        rawsize=rawsize,
    )
    
    logger.info(f"[_do_send_voice] 消息体: {msg_body!r}")

    result = await send_message(base_url, token, msg_body)
    logger.info(f"[_do_send_voice] ✓ 发送完成, 响应: {result!r}")

    try:
        if str(voice_path).startswith(str(TEMP_DIR)):
            voice_path.unlink(missing_ok=True)
    except Exception:
        pass

    return result


async def send_voice_from_file(
    base_url: str,
    token: str,
    to_user_id: str,
    context_token: str,
    file_path: str | Path,
    encode_type: int | None = None,
) -> dict[str, Any]:
    """发送本地语音文件

    Args:
        base_url: API 基础 URL
        token: 认证令牌
        to_user_id: 目标用户 ID
        context_token: 会话上下文令牌
        file_path: 本地语音文件路径 (MP3/SILK/OGG)
        encode_type: 编码类型，可选，不传则根据扩展名自动判断

    Returns:
        服务端响应字典
    """
    import logging
    from pydub import AudioSegment

    logger = logging.getLogger("wxclaw.core")

    logger.info(f"[send_voice_from_file] 开始处理: file_path={file_path}")
    
    path = Path(file_path)

    if not path.exists():
        raise ILinkError(f"本地语音不存在: {path}")

    if not path.is_file():
        raise ILinkError(f"路径不是文件: {path}")

    data = path.read_bytes()
    rawsize = len(data)

    if rawsize == 0:
        raise ILinkError("语音为空文件")

    logger.info(f"[send_voice_from_file] 文件检查通过, size={rawsize} bytes")
    
    # 根据扩展名确定 encode_type
    if encode_type is None:
        ext = path.suffix.lower()
        if ext == ".silk":
            encode_type = 6
        elif ext == ".mp3":
            encode_type = 7
        elif ext == ".ogg":
            encode_type = 8
        else:
            # 默认用 MP3
            encode_type =7
        logger.info(f"[send_voice_from_file] 自动确定 encode_type: {encode_type}")
    
    # 读取音频时长（毫秒）
    ext = path.suffix.lower()
    if ext == ".silk":
        duration_ms = int(rawsize / 160 * 20)
        logger.info(f"[send_voice_from_file] SILK 文件, 估算时长: {duration_ms} ms (size={rawsize})")
    else:
        try:
            audio = AudioSegment.from_file(path)
            duration_ms = len(audio)
            logger.info(f"[send_voice_from_file] 音频真实时长: {duration_ms} ms")
        except Exception as e:
            logger.warning(f"[send_voice_from_file] 无法读取音频时长，使用默认值 5000ms: {e}")
            duration_ms = 5000
    
    return await _do_send_voice(base_url, token, to_user_id, context_token, path, rawsize, duration_ms, encode_type)


def build_file_msg_with_media(
    to_user_id: str,
    context_token: str,
    *,
    media: dict[str, Any] | None = None,
    file_name: str | None = None,
) -> dict[str, Any]:
    from .types import ItemType

    if not media:
        raise ValueError("必须提供 media 参数 (CDN 媒体对象)")

    if "encrypt_query_param" not in media:
        raise ValueError("media 缺少 encrypt_query_param 字段")
    if "aes_key" not in media:
        raise ValueError("media 缺少 aes_key 字段")

    file_item: dict[str, Any] = {
        "media": media,
    }

    if file_name:
        file_item["file_name"] = file_name

    return _new_message_envelope(to_user_id, context_token, [
        {
            "type": ItemType.FILE,
            "file_item": file_item,
        }
    ])


def build_video_msg_with_media(
    to_user_id: str,
    context_token: str,
    *,
    media: dict[str, Any] | None = None,
    duration: int | None = None,
) -> dict[str, Any]:
    from .types import ItemType

    if not media:
        raise ValueError("必须提供 media 参数 (CDN 媒体对象)")

    if "encrypt_query_param" not in media:
        raise ValueError("media 缺少 encrypt_query_param 字段")
    if "aes_key" not in media:
        raise ValueError("media 缺少 aes_key 字段")

    video_item: dict[str, Any] = {
        "media": media,
    }

    if duration is not None:
        video_item["play_length"] = duration

    return _new_message_envelope(to_user_id, context_token, [
        {
            "type": ItemType.VIDEO,
            "video_item": video_item,
        }
    ])


async def _do_send_file(
    base_url: str,
    token: str,
    to_user_id: str,
    context_token: str,
    file_path: Path,
    file_name: str | None = None,
) -> dict[str, Any]:
    """执行文件发送的通用流程（加密→上传→发送）"""

    plaintext_data = file_path.read_bytes()
    rawsize = len(plaintext_data)

    if rawsize == 0:
        raise ILinkError(f"文件为空: {file_path}")

    rawfilemd5 = hashlib.md5(plaintext_data).hexdigest().upper()
    filesize = _aes_ecb_padded_size(rawsize)

    filekey = os.urandom(16).hex()
    aeskey_bytes = os.urandom(16)
    aeskey_hex = aeskey_bytes.hex()

    upload_result = await get_upload_url(
        base_url=base_url,
        token=token,
        to_user_id=to_user_id,
        filekey=filekey,
        media_type=3,
        rawsize=rawsize,
        rawfilemd5=rawfilemd5,
        filesize=filesize,
        aeskey_hex=aeskey_hex,
    )

    upload_param = upload_result["upload_param"]
    cdn_base_url = upload_result.get("cdn_base_url", "")

    encrypted_data = _aes_ecb_encrypt(plaintext_data, aeskey_bytes)

    download_encrypted_query_param = await upload_to_cdn(
        cdn_base_url=cdn_base_url,
        upload_param=upload_param,
        filekey=filekey,
        encrypted_data=encrypted_data,
    )

    aeskey_base64 = base64.b64encode(aeskey_hex.encode("ascii")).decode("ascii")

    media_obj = {
        "encrypt_query_param": download_encrypted_query_param,
        "aes_key": aeskey_base64,
        "encrypt_type": 1,
    }

    msg_body = build_file_msg_with_media(
        to_user_id=to_user_id,
        context_token=context_token,
        media=media_obj,
        file_name=file_name or file_path.name,
    )

    result = await send_message(base_url, token, msg_body)
    return result


async def _do_send_video(
    base_url: str,
    token: str,
    to_user_id: str,
    context_token: str,
    video_path: Path,
    duration: int | None = None,
) -> dict[str, Any]:
    """执行视频发送的通用流程（加密→上传→发送）"""

    plaintext_data = video_path.read_bytes()
    rawsize = len(plaintext_data)

    if rawsize == 0:
        raise ILinkError(f"视频文件为空: {video_path}")

    rawfilemd5 = hashlib.md5(plaintext_data).hexdigest().upper()
    filesize = _aes_ecb_padded_size(rawsize)

    filekey = os.urandom(16).hex()
    aeskey_bytes = os.urandom(16)
    aeskey_hex = aeskey_bytes.hex()

    upload_result = await get_upload_url(
        base_url=base_url,
        token=token,
        to_user_id=to_user_id,
        filekey=filekey,
        media_type=2,
        rawsize=rawsize,
        rawfilemd5=rawfilemd5,
        filesize=filesize,
        aeskey_hex=aeskey_hex,
    )

    upload_param = upload_result["upload_param"]
    cdn_base_url = upload_result.get("cdn_base_url", "")

    encrypted_data = _aes_ecb_encrypt(plaintext_data, aeskey_bytes)

    download_encrypted_query_param = await upload_to_cdn(
        cdn_base_url=cdn_base_url,
        upload_param=upload_param,
        filekey=filekey,
        encrypted_data=encrypted_data,
    )

    aeskey_base64 = base64.b64encode(aeskey_hex.encode("ascii")).decode("ascii")

    media_obj = {
        "encrypt_query_param": download_encrypted_query_param,
        "aes_key": aeskey_base64,
        "encrypt_type": 1,
    }

    msg_body = build_video_msg_with_media(
        to_user_id=to_user_id,
        context_token=context_token,
        media=media_obj,
        duration=duration,
    )

    result = await send_message(base_url, token, msg_body)
    return result


def _is_url(path: str) -> bool:
    """判断路径是否为网络 URL

    Args:
        path: 文件路径或 URL

    Returns:
        True 如果是 URL，False 如果是本地路径
    """
    return path.startswith(("http://", "https://"))


def _get_filename_from_url(url: str) -> str:
    """从 URL 中提取文件名

    Args:
        url: 文件 URL

    Returns:
        文件名字符串
    """
    from urllib.parse import urlparse, unquote

    parsed = urlparse(url)
    path = unquote(parsed.path)
    filename = Path(path).name

    if not filename or "." not in filename:
        filename = f"download_{uuid.uuid4().hex[:8]}"

    return filename


async def download_to_temp(
    url: str,
    max_size: int | None = None,
) -> tuple[Path, int]:
    """下载任意文件到临时目录（通用版本）

    Args:
        url: 文件下载 URL
        max_size: 最大允许文件大小（字节），None 表示不限制

    Returns:
        元组 (临时文件路径, 文件大小)

    Raises:
        ILinkError: 下载失败、超时、文件过大等
    """
    import logging
    logger = logging.getLogger("wxclaw.core")

    TEMP_DIR.mkdir(parents=True, exist_ok=True)

    try:
        timeout = aiohttp.ClientTimeout(total=60)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            logger.info(f"[download] 开始下载: {url[:80]}...")
            async with session.get(url) as response:
                if response.status != 200:
                    raise ILinkError(
                        f"文件下载失败: HTTP {response.status}",
                        code=response.status
                    )

                data = await response.read()
                file_size = len(data)

                if max_size and file_size > max_size:
                    raise ILinkError(
                        f"文件过大: {file_size / 1024 / 1024:.1f}MB > {max_size / 1024 / 1024:.0f}MB"
                    )

                if file_size == 0:
                    raise ILinkError("下载的文件为空")

                filename = _get_filename_from_url(url)
                temp_path = TEMP_DIR / f"{uuid.uuid4().hex}_{filename}"

                temp_path.write_bytes(data)

                logger.info(f"[download] 下载完成: {temp_path.name} ({file_size/1024/1024:.2f} MB)")
                return temp_path, file_size

    except ILinkError:
        raise
    except asyncio.TimeoutError:
        raise ILinkError("文件下载超时 (>60s)")
    except Exception as e:
        raise ILinkError(f"文件下载异常: {type(e).__name__}: {e}")


async def _resolve_file_source(source: str | Path) -> tuple[Path, bool]:
    """解析文件来源（统一处理 URL 和本地路径）

    智能判断输入是网络 URL 还是本地路径：
    - URL → 下载到临时目录 → 返回 (临时路径, is_temp=True)
    - 本地路径 → 直接使用 → 返回 (本地路径, is_temp=False)

    Args:
        source: 文件路径或 URL

    Returns:
        元组 (实际文件路径, 是否为临时文件)
    """
    source_str = str(source)

    if _is_url(source_str):
        temp_path, _ = await download_to_temp(source_str)
        return temp_path, True
    else:
        path = Path(source)
        if not path.exists():
            raise ILinkError(f"文件不存在: {path}")
        return path, False


async def send_file_from_file(
    base_url: str,
    token: str,
    to_user_id: str,
    context_token: str,
    file_source: str | Path,
    file_name: str | None = None,
) -> dict[str, Any]:
    """发送文件（支持本地路径或网络URL）

    智能处理两种输入方式：
    - 本地文件路径 → 直接上传到微信CDN
    - 网络URL → 先下载到临时目录，再上传到微信CDN

    Args:
        base_url: API 基础 URL
        token: 认证令牌
        to_user_id: 目标用户 ID
        context_token: 会话上下文令牌
        file_source: 文件路径或URL（自动识别）
            - 本地路径: "E:\\path\\to\\file.pdf"
            - 网络URL: "https://example.com/file.pdf"
        file_name: 自定义文件名（可选）

    Returns:
        服务端响应字典

    Example:
        # 发送本地文件
        await send_file_from_file(base_url, token, uid, ctx, "E:/docs/report.pdf")

        # 发送网络文件（自动下载）
        await send_file_from_file(base_url, token, uid, ctx, "https://example.com/file.pdf")
    """
    import logging
    logger = logging.getLogger("wxclaw.core")

    source_str = str(file_source)

    if _is_url(source_str):
        logger.info(f"[send_file] 检测到URL，开始下载: {source_str[:60]}...")
        actual_path, is_temp = await _resolve_file_source(file_source)
        if not file_name:
            file_name = _get_filename_from_url(source_str)
    else:
        path = Path(file_source)
        if not path.exists():
            raise ILinkError(f"本地文件不存在: {path}")
        if not path.is_file():
            raise ILinkError(f"路径不是文件: {path}")
        actual_path = path
        is_temp = False

    logger.info(f"[send_file] 开始发送: {actual_path.name} ({actual_path.stat().st_size} bytes)")

    try:
        result = await _do_send_file(
            base_url=base_url,
            token=token,
            to_user_id=to_user_id,
            context_token=context_token,
            file_path=actual_path,
            file_name=file_name or actual_path.name,
        )
        return result
    finally:
        if is_temp and str(actual_path).startswith(str(TEMP_DIR)):
            try:
                actual_path.unlink(missing_ok=True)
                logger.info(f"[send_file] 已清理临时文件: {actual_path.name}")
            except Exception:
                pass


async def send_video_from_file(
    base_url: str,
    token: str,
    to_user_id: str,
    context_token: str,
    video_source: str | Path,
    duration: int | None = None,
) -> dict[str, Any]:
    """发送视频（支持本地路径或网络URL）

    智能处理两种输入方式：
    - 本地视频路径 → 直接上传到微信CDN
    - 网络URL → 先下载到临时目录，再上传到微信CDN

    Args:
        base_url: API 基础 URL
        token: 认证令牌
        to_user_id: 目标用户 ID
        context_token: 会话上下文令牌
        video_source: 视频文件路径或URL（自动识别）
            - 本地路径: "E:\\path\\to\\video.mp4"
            - 网络URL: "https://example.com/video.mp4"
        duration: 视频时长（秒），可选

    Returns:
        服务端响应字典

    Example:
        # 发送本地视频
        await send_video_from_file(base_url, token, uid, ctx, "E:/videos/demo.mp4", duration=10)

        # 发送网络视频（自动下载）
        await send_video_from_file(base_url, token, uid, ctx, "https://example.com/video.mp4")
    """
    import logging
    logger = logging.getLogger("wxclaw.core")

    source_str = str(video_source)

    if _is_url(source_str):
        logger.info(f"[send_video] 检测到URL，开始下载: {source_str[:60]}...")
        actual_path, is_temp = await _resolve_file_source(video_source)
    else:
        path = Path(video_source)
        if not path.exists():
            raise ILinkError(f"本地视频不存在: {path}")
        if not path.is_file():
            raise ILinkError(f"路径不是文件: {path}")
        actual_path = path
        is_temp = False

    logger.info(f"[send_video] 开始发送: {actual_path.name} ({actual_path.stat().st_size} bytes)")

    try:
        result = await _do_send_video(
            base_url=base_url,
            token=token,
            to_user_id=to_user_id,
            context_token=context_token,
            video_path=actual_path,
            duration=duration,
        )
        return result
    finally:
        if is_temp and str(actual_path).startswith(str(TEMP_DIR)):
            try:
                actual_path.unlink(missing_ok=True)
                logger.info(f"[send_video] 已清理临时文件: {actual_path.name}")
            except Exception:
                pass


__all__ = [
    "DEFAULT_BASE_URL",
    "CHANNEL_VERSION",
    "ILinkError",
    "fetch_qrcode",
    "poll_qr_status",
    "get_updates",
    "send_message",
    "get_config",
    "send_typing",
    "get_upload_url",
    "upload_to_cdn",
    "_aes_ecb_encrypt",
    "_is_url",
    "download_to_temp",
    "_resolve_file_source",
    "build_text_msg",
    "build_image_msg",
    "build_image_msg_with_media",
    "build_voice_msg",
    "build_voice_msg_with_media",
    "build_file_msg",
    "build_file_msg_with_media",
    "build_video_msg",
    "build_video_msg_with_media",
    "build_mixed_msg",
    "download_image",
    "load_local_image",
    "send_image_complete",
    "send_image_from_file",
    "send_voice_from_file",
    "send_file_from_file",
    "send_video_from_file",
    "mp3_to_silk",
]
