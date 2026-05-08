"""
xiaoxinChatAI.memory - 长期记忆模块

双层记忆架构:
- 短期记忆: chat_histories (最近20轮，在内存中)
- 长期记忆: LongTermMemory (使用 SQLite 持久化存储)

存储方式改为 SQLite，告别 JSON 文件的瓶颈：
- 不再有 200 条上限，轻松支持 10 万+ 条记忆
- 使用 FTS5 全文索引替代关键词硬匹配
- 增量写入，不重写整个文件
- ACID 事务安全，不怕断电
"""

import sqlite3
import re
import time
import json
import hashlib
import logging
from pathlib import Path
from datetime import datetime, timezone, timedelta
from collections import Counter

logger = logging.getLogger("xiaoxinChatAI.memory")

MEMORY_DIR = Path(__file__).parent / "memory_data"
DB_FILE = MEMORY_DIR / "long_term_memory.db"


class LongTermMemory:
    """长期记忆管理器（SQLite 版）
    
    功能:
    1. 存储: 对话存入 SQLite，FTS5 全文索引
    2. 检索: 关键词 + 全文搜索 + 实体提取三重匹配
    3. 自动过期: 超过指定天数的记忆自动清理
    4. 去重: 自动合并相似内容
    """
    
    def __init__(
        self,
        db_path: Path | None = None,
        max_memories_per_user: int = 20000,
        expire_days: int = 90,
        min_keyword_length: int = 2,
    ):
        self.db_path = db_path or DB_FILE
        self.max_memories_per_user = max_memories_per_user
        self.expire_days = expire_days
        self.min_keyword_length = min_keyword_length
        
        self._init_db()
    
    def _get_conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.execute("PRAGMA cache_size=-8000")
        return conn
    
    def _init_db(self):
        """初始化数据库表结构"""
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = self._get_conn()
        try:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS memories (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    content TEXT NOT NULL,
                    keywords TEXT DEFAULT '',
                    role TEXT DEFAULT 'user',
                    timestamp INTEGER NOT NULL,
                    source_context TEXT DEFAULT '',
                    access_count INTEGER DEFAULT 0,
                    last_accessed INTEGER DEFAULT 0,
                    content_hash TEXT DEFAULT ''
                )
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_memories_user 
                ON memories(user_id, timestamp DESC)
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_memories_hash 
                ON memories(user_id, content_hash)
            """)
            
            conn.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts 
                USING fts5(content, keywords, content='memories', content_rowid='rowid')
            """)
            
            conn.execute("""
                CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
                    INSERT INTO memories_fts(rowid, content, keywords)
                    VALUES (new.rowid, new.content, new.keywords);
                END;
            """)
            conn.execute("""
                CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
                    INSERT INTO memories_fts(memories_fts, rowid, content, keywords)
                    VALUES ('delete', old.rowid, old.content, old.keywords);
                END;
            """)
            
            conn.commit()
            logger.info(f"[memory] 数据库初始化完成: {self.db_path}")
        finally:
            conn.close()
    
    def _rebuild_fts(self):
        """重建全文索引"""
        conn = self._get_conn()
        try:
            conn.execute("INSERT INTO memories_fts(memories_fts) VALUES('rebuild')")
            conn.commit()
            logger.info("[memory] FTS 索引重建完成")
        finally:
            conn.close()
    
    def _extract_keywords(self, text: str) -> list[str]:
        """从文本中提取关键词（与原来逻辑一致）"""
        stop_words = {
            "的", "了", "是", "在", "我", "有", "和", "就", "不", "人", "都", "一",
            "一个", "上", "也", "很", "到", "说", "要", "去", "你", "会", "着", "没有",
            "看", "好", "自己", "这", "她", "他", "它", "们", "那个", "什么", "这个",
            "吗", "呢", "吧", "啊", "哦", "嗯", "哈", "呀", "嘛", "呗", "哇", "诶",
            "可以", "知道", "觉得", "感觉", "应该", "可能", "就是", "还是", "或者",
            "因为", "所以", "但是", "然后", "如果", "虽然", "已经", "正在", "一直",
            "真的", "特别", "比较", "非常", "挺", "蛮", "超", "巨", "好", "太",
            "怎么", "为什么", "哪", "多少", "几个", "谁", "哪里", "什么时候",
            "对", "对吧", "对不对", "是不是", "能不能", "有没有", "会不会",
            "那", "这样", "那样", "这么", "那么", "如何", "怎样",
        }
        
        text = text.strip()
        keywords = []
        
        quoted_parts = re.findall(r'[""\u300c\u300d\u3010\u3011\u300a\u300b](.+?)[""\u300d\u3011\u300b]', text)
        for part in quoted_parts:
            if len(part) >= self.min_keyword_length and part not in stop_words:
                keywords.append(part)
        
        patterns = [
            r'[\u4e00-\u9fff]{2,6}',
            r'[A-Za-z][A-Za-z0-9_]*',
            r'\d+[\u4e00-\u9fff]+',
            r'[\u4e00-\u9fff]+\d+',
        ]
        
        for pattern in patterns:
            matches = re.findall(pattern, text)
            for m in matches:
                word = m.strip()
                if (len(word) >= self.min_keyword_length and 
                    word not in stop_words and
                    word not in keywords):
                    keywords.append(word)
        
        important_markers = [
            (r'(喜欢|爱|讨厌|害怕|担心|期待|希望|想|想学|想去|想吃|想玩|想买)(.+?)', lambda m: m.group(2).strip()),
            (r'(叫|名叫|名字是|叫作)(.+?)', lambda m: m.group(2).strip()),
            (r'(在|住|来自|家乡是)(.+?)(?:的|，|。|$)', lambda m: m.group(2).strip()),
            (r'(工作|职业|专业|学的是|读的是)(.+?)', lambda m: m.group(2).strip()),
            (r'(生日|出生|星座|属相)(.+?)', lambda m: m.group(2).strip()),
        ]
        
        for pattern, extractor in important_markers:
            match = re.search(pattern, text)
            if match:
                value = extractor(match)
                if value and len(value) >= 1 and value not in keywords:
                    keywords.append(value)
        
        counter = Counter(keywords)
        result = [word for word, count in counter.most_common(15)]
        
        return result[:10]
    
    def _extract_ngram_keywords(self, text: str) -> list[str]:
        """从文本提取短 n-gram 关键词（2-3字），用于精确 LIKE 匹配
        
        与 _extract_keywords 互补：_extract_keywords 提取语义关键词，
        本方法提取所有短字符片段，适合 LIKE '%xx%' 精确命中。
        """
        stop_words = {
            "的", "了", "是", "在", "我", "有", "和", "就", "不", "人", "都", "一",
            "一个", "上", "也", "很", "到", "说", "要", "去", "你", "会", "着", "没有",
            "看", "好", "自己", "这", "她", "他", "它", "们", "那个", "什么", "这个",
            "吗", "呢", "吧", "啊", "哦", "嗯", "哈", "呀", "嘛", "呗", "哇", "诶",
            "可以", "知道", "觉得", "感觉", "应该", "可能", "就是", "还是", "或者",
            "因为", "所以", "但是", "然后", "如果", "虽然", "已经", "正在", "一直",
            "真的", "特别", "比较", "非常", "挺", "蛮", "超", "巨", "太",
            "怎么", "为什么", "哪", "多少", "几个", "谁", "哪里", "什么时候",
            "对", "对吧", "对不对", "是不是", "能不能", "有没有", "会不会",
            "那", "这样", "那样", "这么", "那么", "如何", "怎样",
        }

        text = re.sub(r'[^\u4e00-\u9fffA-Za-z0-9]', '', text)
        ngrams = set()

        for i in range(len(text)):
            for n in (2, 3):
                if i + n <= len(text):
                    gram = text[i:i + n]
                    if gram not in stop_words and len(gram) >= 2:
                        ngrams.add(gram)

        return list(ngrams)[:10]

    def add(
        self,
        user_id: str,
        content: str,
        role: str = "user",
        context_summary: str = "",
    ) -> str:
        """添加一条记忆
        
        自动去重：相同用户 + 相同内容哈希 不重复添加
        
        Returns:
            新增记忆的 ID
        """
        content = content.strip()
        if not content:
            return ""
        
        content_hash = hashlib.md5(content.encode()).hexdigest()
        keywords = self._extract_keywords(content)
        keywords_str = " ".join(keywords)
        now = int(time.time())
        
        conn = self._get_conn()
        try:
            existing = conn.execute(
                "SELECT id FROM memories WHERE user_id=? AND content_hash=?",
                (user_id, content_hash),
            ).fetchone()
            
            if existing:
                conn.execute(
                    "UPDATE memories SET timestamp=?, source_context=?, access_count=access_count+1 WHERE id=?",
                    (now, context_summary, existing["id"]),
                )
                conn.commit()
                logger.debug(f"[memory] ~ [{user_id}] 更新已有记忆: {content[:40]}...")
                return existing["id"]
            
            mem_id = f"{now}_{hashlib.md5(content.encode()).hexdigest()[:8]}"
            
            count = conn.execute(
                "SELECT COUNT(*) as c FROM memories WHERE user_id=?",
                (user_id,),
            ).fetchone()["c"]
            
            if count >= self.max_memories_per_user:
                oldest = conn.execute("""
                    SELECT id FROM memories 
                    WHERE user_id=? 
                    ORDER BY access_count ASC, timestamp ASC 
                    LIMIT 1
                """, (user_id,)).fetchone()
                if oldest:
                    conn.execute("DELETE FROM memories WHERE id=?", (oldest["id"],))
                    logger.debug(f"[memory] 用户{user_id}记忆已满，移除最旧一条")
            
            conn.execute("""
                INSERT INTO memories (id, user_id, content, keywords, role, timestamp, source_context, access_count, last_accessed, content_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
            """, (mem_id, user_id, content, keywords_str, role, now, context_summary, now, content_hash))
            
            conn.execute("""
                INSERT INTO memories_fts(rowid, content, keywords)
                VALUES (?, ?, ?)
            """, (conn.execute("SELECT rowid FROM memories WHERE id=?", (mem_id,)).fetchone()["rowid"], content, keywords_str))
            
            conn.commit()
            logger.info(f"[memory] + [{user_id}] {role}: {content[:40]}... (关键词: {keywords[:5]})")
            
            return mem_id
            
        except sqlite3.Error as e:
            logger.error(f"[memory] 添加记忆失败: {e}")
            return ""
        finally:
            conn.close()
    
    def search(
        self,
        user_id: str,
        query: str,
        top_k: int = 5,
        min_score: float = 0.3,
    ) -> list[dict]:
        """搜索相关记忆
        
        三重匹配策略:
        1. FTS5 全文搜索（最优先）
        2. 关键词匹配
        3. 实体提取匹配
        
        Returns:
            相关记忆列表
        """
        query = query.strip()
        if not query:
            return []
        
        conn = self._get_conn()
        try:
            query_keywords = self._extract_keywords(query)
            seen_hashes = set()
            scored = []
            
            # 0. 关键词精确匹配（最高优先级）
            # 使用短 n-gram（2-3字）做精确关键词命中，解决长关键词无法匹配的问题
            ngram_keywords = self._extract_ngram_keywords(query)
            all_match_kw = list(dict.fromkeys(query_keywords + ngram_keywords))[:8]

            if all_match_kw:
                kw_placeholders = " OR ".join(["keywords LIKE ?"] * len(all_match_kw))
                kw_params = [f"%{kw}%" for kw in all_match_kw]

                exact_rows = conn.execute(f"""
                    SELECT m.id, m.content, m.keywords, m.role, m.timestamp,
                           m.source_context, m.access_count
                    FROM memories m
                    WHERE m.user_id=? AND ({kw_placeholders})
                    ORDER BY m.access_count DESC, m.timestamp DESC
                    LIMIT ?
                """, (user_id, *kw_params, top_k * 2)).fetchall()

                for row in exact_rows:
                    h = hashlib.md5(row["content"].encode()).hexdigest()
                    if h in seen_hashes:
                        continue
                    seen_hashes.add(h)

                    mem_keywords = set(row["keywords"].split()) if row["keywords"] else set()
                    qk_all = set(all_match_kw)
                    overlap = len(qk_all & mem_keywords)

                    age_days = (time.time() - row["timestamp"]) / 86400
                    recency = 1.0 if age_days < 7 else (0.8 if age_days < 30 else 0.6)
                    keyword_score = min(overlap / max(len(qk_all), 1), 1.0) * 0.95

                    scored.append({
                        "content": row["content"],
                        "score": round(keyword_score * recency, 3),
                        "keywords": list(qk_all & mem_keywords),
                        "role": row["role"],
                        "age_days": round(age_days, 1),
                        "context": row["source_context"],
                        "source": "keyword_exact",
                    })
            
            # 1. FTS5 全文搜索
            fts_terms = " OR ".join(
                f'"{kw}"' for kw in query_keywords[:5]
            ) if query_keywords else ""
            
            if fts_terms:
                try:
                    rows = conn.execute(f"""
                        SELECT m.id, m.content, m.keywords, m.role, m.timestamp, 
                               m.source_context, m.access_count
                        FROM memories_fts f
                        JOIN memories m ON f.rowid = m.rowid
                        WHERE m.user_id=? AND memories_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                    """, (user_id, fts_terms, top_k * 2)).fetchall()
                    
                    for row in rows:
                        h = hashlib.md5(row["content"].encode()).hexdigest()
                        if h in seen_hashes:
                            continue
                        seen_hashes.add(h)
                        
                        age_days = (time.time() - row["timestamp"]) / 86400
                        recency = 1.0 + max(0, (7 - age_days) / 7 * 0.5) if age_days < 7 else 1.0
                        if age_days > 30:
                            recency = 0.7
                        
                        scored.append({
                            "content": row["content"],
                            "score": round(0.7 * recency, 3),
                            "keywords": row["keywords"].split() if row["keywords"] else [],
                            "role": row["role"],
                            "age_days": round(age_days, 1),
                            "context": row["source_context"],
                            "source": "fts5",
                        })
                except sqlite3.OperationalError:
                    pass
            
            # 2. 关键词匹配（作为补充）
            if query_keywords:
                placeholders = " OR ".join(["keywords LIKE ?"] * min(len(query_keywords), 5))
                like_params = [f"%{kw}%" for kw in query_keywords[:5]]
                
                rows = conn.execute(f"""
                    SELECT id, content, keywords, role, timestamp, source_context
                    FROM memories
                    WHERE user_id=? AND ({placeholders})
                    ORDER BY timestamp DESC
                    LIMIT ?
                """, (user_id, *like_params, top_k)).fetchall()
                
                for row in rows:
                    h = hashlib.md5(row["content"].encode()).hexdigest()
                    if h in seen_hashes:
                        continue
                    seen_hashes.add(h)
                    
                    mem_keywords = set(row["keywords"].split()) if row["keywords"] else set()
                    qk_set = set(query_keywords)
                    overlap = len(qk_set & mem_keywords)
                    total_unique = len(qk_set | mem_keywords)
                    jaccard = overlap / total_unique if total_unique > 0 else 0
                    
                    age_days = (time.time() - row["timestamp"]) / 86400
                    recency = 1.0
                    if age_days < 1:
                        recency = 1.5
                    elif age_days < 7:
                        recency = 1.2
                    elif age_days > 30:
                        recency = 0.7
                    
                    keyword_bonus = sum(2 for kw in qk_set & mem_keywords if len(kw) >= 3)
                    final_score = (jaccard + keyword_bonus * 0.05) * recency
                    
                    if final_score >= min_score:
                        scored.append({
                            "content": row["content"],
                            "score": round(final_score, 3),
                            "keywords": list(qk_set & mem_keywords),
                            "role": row["role"],
                            "age_days": round(age_days, 1),
                            "context": row["source_context"],
                            "source": "jaccard",
                        })
            
            results = self._rrf_fuse(scored)[:top_k]
            
            for r in results:
                logger.debug(f"[memory] 检索命中: score={r['score']} source={r.get('source','?')} | {r['content'][:40]}")
            
            return results
            
        except sqlite3.Error as e:
            logger.error(f"[memory] 搜索失败: {e}")
            return []
        finally:
            conn.close()
    
    def _rrf_fuse(self, candidates: list[dict], k: int = 10) -> list[dict]:
        """RRF (Reciprocal Rank Fusion) 融合多检索源结果
        
        RRF 公式: score(d) = Σ 1/(k + rank_i(d))
        其中 rank_i(d) 是文档 d 在第 i 个检索器中的排名
        
        不同检索源各有所长，RRF 能公平地融合它们的排序，
        避免某个来源的高分结果完全淹没其他来源的有效结果。
        """
        if not candidates:
            return []

        sources: dict[str, list[dict]] = {}
        for c in candidates:
            src = c.get("source", "unknown")
            if src not in sources:
                sources[src] = []
            sources[src].append(c)

        for src_list in sources.values():
            src_list.sort(key=lambda x: x["score"], reverse=True)

        content_scores: dict[str, tuple[float, dict]] = {}
        for src, src_list in sources.items():
            for rank, item in enumerate(src_list, start=1):
                content = item["content"]
                rrf_score = 1.0 / (k + rank)
                if content in content_scores:
                    old_score, old_item = content_scores[content]
                    content_scores[content] = (old_score + rrf_score, item)
                else:
                    content_scores[content] = (rrf_score, item)

        fused = []
        for content, (rrf_score, item) in content_scores.items():
            item["score"] = round(rrf_score, 4)
            fused.append(item)

        fused.sort(key=lambda x: x["score"], reverse=True)
        return fused

    def get_recent(
        self,
        user_id: str,
        n: int = 10,
        role: str | None = None,
    ) -> list[dict]:
        """获取最近的记忆"""
        conn = self._get_conn()
        try:
            role_filter = "AND role=?" if role else ""
            params = [user_id]
            if role:
                params.append(role)
            
            rows = conn.execute(f"""
                SELECT content, role, keywords, timestamp
                FROM memories
                WHERE user_id=? {role_filter}
                ORDER BY timestamp DESC
                LIMIT ?
            """, (*params, n)).fetchall()
            
            return [
                {
                    "content": row["content"],
                    "role": row["role"],
                    "keywords": row["keywords"].split() if row["keywords"] else [],
                    "age_days": round((time.time() - row["timestamp"]) / 86400, 1),
                }
                for row in rows
            ]
        finally:
            conn.close()
    
    def delete_by_id(self, user_id: str, memory_id: str) -> bool:
        """根据 ID 删除单条记忆"""
        conn = self._get_conn()
        try:
            cursor = conn.execute(
                "DELETE FROM memories WHERE id=? AND user_id=?",
                (memory_id, user_id),
            )
            conn.commit()
            return cursor.rowcount > 0
        except sqlite3.Error as e:
            logger.error(f"[memory] 删除失败: {e}")
            return False
        finally:
            conn.close()
    
    def cleanup_expired(self) -> int:
        """清理过期记忆"""
        cutoff_time = time.time() - (self.expire_days * 86400)
        conn = self._get_conn()
        try:
            cursor = conn.execute(
                "DELETE FROM memories WHERE timestamp < ?",
                (cutoff_time,),
            )
            removed = cursor.rowcount
            if removed > 0:
                conn.commit()
                self._rebuild_fts()
                logger.info(f"[memory] 清理完成，移除 {removed} 条过期记忆")
            return removed
        finally:
            conn.close()
    
    def clear_all(self) -> int:
        """清空所有长期记忆"""
        conn = self._get_conn()
        try:
            cursor = conn.execute("SELECT COUNT(*) as c FROM memories")
            count = cursor.fetchone()["c"]
            
            conn.execute("DELETE FROM memories")
            conn.execute("INSERT INTO memories_fts(memories_fts) VALUES('rebuild')")
            conn.commit()
            
            logger.info(f"[memory] 已清空所有长期记忆, 共 {count} 条")
            return count
        finally:
            conn.close()
    
    def get_stats(self) -> dict:
        """获取记忆统计信息"""
        conn = self._get_conn()
        try:
            total = conn.execute("SELECT COUNT(*) as c FROM memories").fetchone()["c"]
            
            user_counts = conn.execute("""
                SELECT user_id, COUNT(*) as count, 
                       MIN(timestamp) as oldest, MAX(timestamp) as newest
                FROM memories
                GROUP BY user_id
            """).fetchall()
            
            stats = {
                "total_memories": total,
                "total_users": len(user_counts),
                "users_detail": {},
            }
            
            now = time.time()
            for uc in user_counts:
                stats["users_detail"][uc["user_id"]] = {
                    "count": uc["count"],
                    "oldest_age_days": round((now - uc["oldest"]) / 86400, 1),
                    "newest_age_days": round((now - uc["newest"]) / 86400, 1),
                }
            
            if user_counts:
                all_timestamps = [uc["oldest"] for uc in user_counts] + [uc["newest"] for uc in user_counts]
                stats["oldest_memory_days"] = round((now - min(all_timestamps)) / 86400, 1)
                stats["newest_memory_days"] = round((now - max(all_timestamps)) / 86400, 1)
            
            return stats
        finally:
            conn.close()
    
    def clear_user(self, user_id: str) -> int:
        """清空指定用户的所有记忆"""
        conn = self._get_conn()
        try:
            cursor = conn.execute(
                "DELETE FROM memories WHERE user_id=?",
                (user_id,),
            )
            removed = cursor.rowcount
            conn.commit()
            logger.info(f"[memory] 已清空用户 {user_id} 的记忆, 共 {removed} 条")
            return removed
        finally:
            conn.close()


def should_store_memory(content: str, role: str = "user") -> bool:
    """智能判断一条消息是否值得存入长期记忆

    有价值的信息（存）：
    - 个人喜好/厌恶（喜欢、讨厌、爱吃等）
    - 个人经历/事实（工作、学校、家乡等）
    - 具体事件/计划（去了哪、要去哪、做了什么）
    - 重要话题（用户主动展开讨论的内容）
    - 包含引号""的特定表述

    无价值的信息（不存）：
    - 简短回应（嗯、哦、好、哈哈等）
    - 日常问候（吃了没、在干嘛、晚安等）
    - 无信息量的AI客套话
    """
    content = content.strip()
    if not content or len(content) < 4:
        return False

    trivial_patterns = [
        r"^(嗯|哦|噢|啊|哈|嘿|嗨|哟|欸|喂|啦|呗|嘛|咯)$",
        r"^(好|是|对|行|ok|好的|好吧|好滴|好哒|好叭|好趴|好喔|好嘞|好咯)$",
        r"^(知道|懂了|明白|收到|了解|可以|没事|没有|不会|是吧|对啊|没错)$",
        r"^(哈哈|哈哈哈|hhhh|笑死|太搞笑了|6|666|nb)$",
        r"^(早安|晚安|早|晚好|中午好|下午好|晚上好|早安呀|晚安呀|晚安啦)$",
        r"^(吃了|吃了没|在干嘛|干嘛呢|忙啥|睡没|睡了没|还没睡|醒了吗|咋了|怎么了)$",
        r"^(来了|来了来了|好的来了|收到收到|来了来了来了)$",
        r"^(酱紫咯|对对对对|好滴好滴|懂了懂了|知道啦|明白啦)$",
        r"^(你好|你好呀|hi|hello|嗨|嗨喽)$",
        r"^\s*\[?(?:EMOJI|表情)\]?\s*$",
    ]

    for pattern in trivial_patterns:
        if re.match(pattern, content, re.IGNORECASE):
            return False

    meaningful_patterns = [
        r"(喜欢|爱|讨厌|害怕|担心|期待|希望|想|想学|想去|想吃|想玩|想买)",
        r"(叫|名叫|名字是|叫作|人称|称呼)",
        r"(在|住|来自|家乡是|住在|家住|出生|籍贯)",
        r"(工作|职业|专业|学的是|读的是|公司|学校|班级|岗位|行业)",
        r"(生日|出生|星座|属相|年龄|岁)",
        r"([" "\u300c\u300d]..+[" "\u300d\u300b])",
        r"(推荐|建议|安利|种草|分享|收藏)",
        r"(去过|去过|玩过|吃过|看过|读过|听过|体验过)",
        r"(要去|想去|打算|计划|准备|预约|报名)",
        r"(记得|忘记|想起|回忆|印象|以前|之前|上次)",
        r"(猫|狗|宠物|养了|买了|入手|种草|收藏)",
        r"(好吃|好喝|好玩|好看|好听|好用|值得)",
        r"(太贵|便宜|划算|性价比|优惠|打折|省钱)",
    ]

    for pattern in meaningful_patterns:
        if re.search(pattern, content):
            return True

    if role == "user" and len(content) >= 8:
        return True

    return False


memory_store = LongTermMemory()


def format_retrieved_memories(memories: list[dict]) -> str:
    """将检索到的记忆格式化为可注入 prompt 的文本"""
    if not memories:
        return ""
    
    lines = ["## 相关记忆（来自之前的对话）\n"]
    
    for i, mem in enumerate(memories, 1):
        role_label = "对方" if mem.get("role") == "user" else "你"
        age_str = f"{mem.get('age_days', '?')}天前"
        
        line = f"{i}. [{role_label}] ({age_str}): {mem['content']}"
        lines.append(line)
    
    lines.append("\n⚠️ 以上是之前聊过的相关内容，如果用户提到的话题与这些记忆相关，请自然地引用或延续，不要刻意重复原话。\n")
    
    return "\n".join(lines) if memories else ""



if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
    
    print("=" * 50)
    print("  xiaoxinChatAI 长期记忆系统测试 (SQLite)")
    print("=" * 50)
    
    import tempfile
    import os
    
    test_db = Path(tempfile.gettempdir()) / "xiaoxinChatAI_memory_test.db"
    if test_db.exists():
        os.remove(test_db)
    
    store = LongTermMemory(db_path=test_db)
    test_uid = "test_user_001"
    
    store.add(test_uid, "我喜欢吃火锅，尤其是麻辣锅", role="user", context_summary="饮食偏好")
    store.add(test_uid, "我明天要去北京出差", role="user", context_summary="行程安排")
    store.add(test_uid, "我家养了一只叫豆豆的猫", role="user", context_summary="宠物")
    store.add(test_uid, "我在字节跳动工作，做后端开发", role="user", context_summary="工作信息")
    store.add(test_uid, "你叫小欣，是我的AI助手", role="assistant", context_summary="自我介绍")
    
    print("\n--- 测试搜索 ---")
    
    for query, desc in [
        ("今天想吃火锅，去哪家好？", "饮食相关"),
        ("豆豆最近怎么样", "宠物相关"),
        ("工作好累啊", "工作相关"),
        ("你是谁", "自我介绍"),
    ]:
        results = store.search(test_uid, query)
        print(f"\n查询 [{desc}]: '{query}'")
        for r in results:
            print(f"  [{r['score']:.2f}] {r['content']}")
        if not results:
            print(f"  (无结果)")
    
    print("\n--- 统计信息 ---")
    stats = store.get_stats()
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    
    print("\n--- 去重测试 ---")
    id1 = store.add(test_uid, "我喜欢吃火锅", role="user")
    id2 = store.add(test_uid, "我喜欢吃火锅", role="user")
    print(f"第一次添加: {id1}")
    print(f"第二次添加: {id2}")
    print(f"去重{'成功' if id1 == id2 else '失败'} (ID相同=去重)")
    
    print("\n--- 清理 ---")
    os.remove(test_db)
    print("测试数据库已清理")
