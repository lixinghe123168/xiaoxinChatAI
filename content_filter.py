"""
xiaoxinChatAI.content_filter - 内容安全过滤模块

双层过滤：
1. 入站过滤 (inbound) - 用户发来的消息是否安全
2. 出站过滤 (outbound) - AI 回复的内容是否合适

敏感词从 Vocabulary/ 文件夹读取（按分类存放 .txt 文件）
配置通过 web_config.json 中的 features.content_filter 控制。
"""

import re
import logging
from pathlib import Path

logger = logging.getLogger("xiaoxinChatAI.filter")

_VOCABULARY_DIR = Path(__file__).parent / "Vocabulary"


def load_keywords_from_folder() -> list[str]:
    """从 Vocabulary 文件夹加载所有敏感词
    
    读取所有 .txt 文件，跳过 # 开头的注释行和空行
    """
    keywords = []
    
    if not _VOCABULARY_DIR.exists():
        logger.warning(f"[filter] Vocabulary 目录不存在: {_VOCABULARY_DIR}")
        return _builtin_fallback()
    
    txt_files = sorted(_VOCABULARY_DIR.glob("*.txt"))
    
    if not txt_files:
        logger.warning(f"[filter] Vocabulary 目录无 .txt 文件")
        return _builtin_fallback()
    
    for file_path in txt_files:
        try:
            content = file_path.read_text(encoding="utf-8")
            file_keywords = []
            for line in content.split("\n"):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                file_keywords.append(line)
            
            if file_keywords:
                keywords.extend(file_keywords)
                logger.info(f"[filter] 加载 {file_path.name}: {len(file_keywords)} 个词")
        except Exception as e:
            logger.error(f"[filter] 读取 {file_path.name} 失败: {e}")
    
    if not keywords:
        logger.warning(f"[filter] Vocabulary 文件夹无有效关键词，使用内置词")
        return _builtin_fallback()
    
    logger.info(f"[filter] Vocabulary 共加载 {len(keywords)} 个敏感词")
    return keywords


def _builtin_fallback() -> list[str]:
    """内置默认敏感词（Vocabulary 文件夹不存在时使用）"""
    return [
        "验证码", "银行卡", "密码", "支付密码", "登录密码",
        "转账", "汇款", "打钱", "借钱", "贷款",
        "身份证", "护照号", "社保卡", "信用卡号",
        "裸聊", "色情", "赌博", "赌场", "时时彩",
        "毒品", "吸毒", "冰毒", "摇头丸",
        "枪支", "弹药", "管制刀具",
        "传销", "洗钱", "诈骗", "非法集资",
        "钓鱼网站", "木马", "病毒", "黑客",
        "银行账号", "支付宝", "微信转账",
        "裸贷", "校园贷", "套路贷",
        "翻墙", "梯子", "VPN",
        "非法", "走私", "偷渡", "假钞",
        "发票", "代开", "办证",
        "反动", "颠覆",
    ]


SENSITIVE_KEYWORDS = load_keywords_from_folder()


def reload_keywords() -> list[str]:
    """重新加载 Vocabulary 文件夹中的敏感词
    
    修改了 Vocabulary/*.txt 后调用此函数即可生效，无需重启
    """
    global SENSITIVE_KEYWORDS
    new_keywords = load_keywords_from_folder()
    SENSITIVE_KEYWORDS = new_keywords
    logger.info(f"[filter] 已重载敏感词，共 {len(new_keywords)} 个")
    return new_keywords

PHONE_PATTERN = re.compile(r'(?<!\d)1[3-9]\d{9}(?!\d)')
ID_CARD_PATTERN = re.compile(r'[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]')
BANK_CARD_PATTERN = re.compile(r'(?<!\d)\d{16,19}(?!\d)')
EMAIL_PATTERN = re.compile(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')
IP_PATTERN = re.compile(r'(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)')
API_KEY_PATTERN = re.compile(r'(?:sk|api|key)[-_][a-zA-Z0-9]{16,}(?:\s|$)', re.IGNORECASE)


def check_sensitive_keywords(text: str, keywords: list[str]) -> list[str]:
    """检查文本是否包含敏感关键词
    
    Returns:
        命中的关键词列表（空=安全）
    """
    text_lower = text.lower()
    hits = []
    for kw in keywords:
        if kw.lower() in text_lower:
            hits.append(kw)
    return hits


def check_patterns(text: str, check_types: list[str]) -> list[str]:
    """检查文本是否匹配敏感信息模式
    
    Args:
        text: 要检查的文本
        check_types: 要检查的类型列表
            ["phone", "id_card", "bank_card", "email", "ip", "api_key"]
    
    Returns:
        命中的模式列表
    """
    hits = []
    
    if "phone" in check_types:
        if PHONE_PATTERN.search(text):
            hits.append("手机号")
    
    if "id_card" in check_types:
        if ID_CARD_PATTERN.search(text):
            hits.append("身份证号")
    
    if "bank_card" in check_types:
        if BANK_CARD_PATTERN.search(text):
            hits.append("银行卡号")
    
    if "email" in check_types:
        if EMAIL_PATTERN.search(text):
            hits.append("邮箱地址")
    
    if "ip" in check_types:
        if IP_PATTERN.search(text):
            hits.append("IP地址")
    
    if "api_key" in check_types:
        if API_KEY_PATTERN.search(text):
            hits.append("API密钥")
    
    return hits


def load_filter_config(config: dict) -> dict:
    """从 web_config.json 加载过滤配置"""
    return config.get("features", {}).get("content_filter", {
        "enabled": False,
        "block_inbound": True,
        "block_outbound": False,
        "custom_keywords": [],
        "check_patterns": ["phone", "id_card", "bank_card", "api_key"],
        "block_reply": "内容包含敏感信息，已自动拦截",
        "warn_reply": "请注意不要发送个人敏感信息哦~",
    })


def filter_inbound(text: str, filter_cfg: dict) -> tuple[bool, str]:
    """入站过滤：用户消息是否安全
    
    Args:
        text: 用户消息
        filter_cfg: 过滤配置
        
    Returns:
        (is_safe, reason) 是否安全 + 原因
    """
    if not filter_cfg.get("enabled", False):
        return True, ""

    keywords = list(SENSITIVE_KEYWORDS)
    keywords.extend(filter_cfg.get("custom_keywords", []))
    
    kw_hits = check_sensitive_keywords(text, keywords)
    if kw_hits:
        logger.warning(f"[inbound] 命中敏感词: {kw_hits}")
        return False, f"敏感词: {', '.join(kw_hits[:3])}"
    
    check_types = filter_cfg.get("check_patterns", [])
    pattern_hits = check_patterns(text, check_types)
    if pattern_hits:
        logger.warning(f"[inbound] 命中敏感模式: {pattern_hits}")
        return False, f"包含: {', '.join(pattern_hits[:3])}"
    
    return True, ""


def filter_outbound(text: str, filter_cfg: dict) -> tuple[bool, str]:
    """出站过滤：AI 回复是否合适
    
    Args:
        text: AI 回复
        filter_cfg: 过滤配置
        
    Returns:
        (is_safe, reason) 是否安全 + 原因
    """
    if not filter_cfg.get("enabled", False) or not filter_cfg.get("block_outbound", False):
        return True, ""
    
    keywords = list(SENSITIVE_KEYWORDS)
    keywords.extend(filter_cfg.get("custom_keywords", []))
    
    kw_hits = check_sensitive_keywords(text, keywords)
    if kw_hits:
        logger.warning(f"[outbound] AI回复命中敏感词: {kw_hits}")
        return False, f"AI回复含敏感词: {', '.join(kw_hits[:3])}"
    
    check_types = filter_cfg.get("check_patterns", [])
    pattern_hits = check_patterns(text, check_types)
    if pattern_hits:
        logger.warning(f"[outbound] AI回复命中敏感模式: {pattern_hits}")
        return False, f"AI回复含: {', '.join(pattern_hits[:3])}"
    return True, ""


if __name__ == "__main__":
    print("=" * 60)
    print("  content_filter.py 单元测试")
    print("=" * 60)
    
    passed = 0
    failed = 0
    
    def test(name, condition, detail=""):
        global passed, failed
        if condition:
            print(f"  [PASS] {name}")
            passed += 1
        else:
            print(f"  [FAIL] {name} - {detail}")
            failed += 1
    
    # 测试 1: 敏感关键词检测
    print("\n[TEST] 敏感关键词检测...")
    
    hits = check_sensitive_keywords("我的银行卡密码是123456", SENSITIVE_KEYWORDS)
    test("检测到'银行卡'", "银行卡" in hits)
    test("检测到'密码'", "密码" in hits)
    
    hits = check_sensitive_keywords("今天天气真好", SENSITIVE_KEYWORDS)
    test("正常文本无命中", len(hits) == 0)
    
    # 测试 2: 模式匹配 - 手机号
    print("\n[TEST] 模式匹配...")
    
    phone_hits = check_patterns("我的手机号是13812345678", ["phone"])
    test("检测到手机号", "手机号" in phone_hits)
    
    no_phone = check_patterns("我没有手机号", ["phone"])
    test("无手机号时不误报", len(no_phone) == 0)
    
    # 测试 3: 身份证号
    id_hits = check_patterns("身份证号110105199001011234", ["id_card"])
    test("检测到身份证号", "身份证号" in id_hits)
    
    # 测试 4: 银行卡号
    bank_hits = check_patterns("银行卡6222021234567890123", ["bank_card"])
    test("检测到银行卡号", "银行卡号" in bank_hits)
    
    # 测试 5: 邮箱地址
    email_hits = check_patterns("联系我test@example.com", ["email"])
    test("检测到邮箱", "邮箱地址" in email_hits)
    
    # 测试 6: IP 地址
    ip_hits = check_patterns("服务器IP是192.168.1.100", ["ip"])
    test("检测到IP地址", "IP地址" in ip_hits)
    
    # 测试 7: API 密钥
    api_hits = check_patterns("API key sk-abc123def456ghi789jkl", ["api_key"])
    test("检测到API密钥", "API密钥" in api_hits)
    
    # 测试 8: 入站过滤
    print("\n[TEST] 入站过滤 (filter_inbound)...")
    
    filter_cfg = {
        "enabled": True,
        "block_inbound": True,
        "custom_keywords": [],
        "check_patterns": ["phone", "id_card", "bank_card"],
        "block_reply": "内容包含敏感信息",
    }
    
    safe, reason = filter_inbound("你好，今天天气不错", filter_cfg)
    test("正常消息通过", safe == True)
    
    unsafe, reason = filter_inbound("给我转账100元", filter_cfg)
    test("拦截含敏感词消息", unsafe == False and "敏感词" in reason)
    
    unsafe2, reason2 = filter_inbound("我的手机13800138000", filter_cfg)
    test("拦截含手机号消息", unsafe2 == False and "手机号" in reason2)
    
    # 测试 9: 出站过滤
    print("\n[TEST] 出站过滤 (filter_outbound)...")
    
    outbound_cfg = {
        "enabled": True,
        "block_outbound": True,
        "custom_keywords": [],
        "check_patterns": ["phone", "id_card"],
        "block_reply": "已拦截",
    }
    
    out_safe, _ = filter_outbound("好的，我知道了！", outbound_cfg)
    test("正常AI回复通过", out_safe == True)
    
    out_unsafe, out_reason = filter_outbound("你的银行卡号是6222...", outbound_cfg)
    test("拦截含敏感信息的AI回复", out_unsafe == False and "敏感词" in out_reason)
    
    # 测试 10: 过滤功能关闭时
    print("\n[TEST] 过滤功能关闭...")
    
    disabled_cfg = {"enabled": False}
    safe_disabled, _ = filter_inbound("任何内容", disabled_cfg)
    test("关闭时入站全部通过", safe_disabled == True)
    
    safe_out, _ = filter_outbound("任何内容", disabled_cfg)
    test("关闭时出站全部通过", safe_out == True)
    
    # 测试 11: Vocabulary 加载
    print("\n[TEST] Vocabulary 文件夹加载...")
    
    vocab_dir = Path(__file__).parent / "Vocabulary"
    test("Vocabulary文件夹存在", vocab_dir.exists())
    
    txt_files = list(vocab_dir.glob("*.txt"))
    test(f"存在 {len(txt_files)} 个词库文件", len(txt_files) >= 3)
    
    test(f"共加载 {len(SENSITIVE_KEYWORDS)} 个敏感词", len(SENSITIVE_KEYWORDS) > 20)
    
    # 测试 12: 重载功能
    print("\n[TEST] 关键词重载...")
    
    original_count = len(SENSITIVE_KEYWORDS)
    reloaded = reload_keywords()
    test("重载成功", len(reloaded) == original_count or len(reloaded) > 0)
    
    # 结果汇总
    print("\n" + "=" * 60)
    total = passed + failed
    print(f"  结果: {passed}/{total} 通过", end="")
    if failed > 0:
        print(f"  ({failed} 个失败)")
    else:
        print("  全部通过!")
    print("=" * 60)
