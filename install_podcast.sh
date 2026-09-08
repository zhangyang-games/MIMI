#!/bin/bash
# ══════════════════════════════════════════════════════════
#  MIMI 口播新闻 —— 每日新闻自动生成双人对话播客并推送到Telegram
#  依附于 MIMI 小秘书（复用 ~/mimi/library/feeds.opml 图书馆）
# ══════════════════════════════════════════════════════════

GREEN='\033[0;32m'; PINK='\033[38;5;213m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'; BOLD='\033[1m'

MIMI_HOME="$HOME/mimi"
PODCAST_DIR="$MIMI_HOME/podcast"
CONFIG_FILE="$PODCAST_DIR/config.json"
LIBRARY_OPML="$MIMI_HOME/library/feeds.opml"

echo ""
echo -e "${PINK}${BOLD}  🎙️  MIMI 口播新闻 —— 安装 / 管理向导${NC}"
echo -e "${DIM}  ──────────────────────────────────────────────────${NC}"
echo ""

# ── 1. 基础依赖检查 ──────────────────────────────────────
_detect_pkg_manager() {
    if   command -v apt-get &>/dev/null; then PKG="apt"
    elif command -v apk     &>/dev/null; then PKG="apk"
    elif command -v dnf     &>/dev/null; then PKG="dnf"
    elif command -v yum     &>/dev/null; then PKG="yum"
    elif command -v pacman  &>/dev/null; then PKG="pacman"
    elif command -v zypper  &>/dev/null; then PKG="zypper"
    else PKG="unknown"; fi
}
_detect_pkg_manager

if ! command -v python3 &>/dev/null; then
    echo -e "${RED}  ❌ 没找到 python3，请先安装 python3 再运行本脚本${NC}"
    exit 1
fi

if ! command -v ffmpeg &>/dev/null; then
    echo -e "${YELLOW}  🔧 缺少 ffmpeg（用于把语音转换成Telegram能识别的格式），正在自动安装...${NC}"
    case "$PKG" in
        apt)    apt-get update -qq 2>/dev/null; apt-get install -y ffmpeg -qq 2>/dev/null ;;
        apk)    apk add --no-cache ffmpeg 2>/dev/null ;;
        dnf)    dnf install -y ffmpeg 2>/dev/null ;;
        yum)    yum install -y ffmpeg 2>/dev/null ;;
        pacman) pacman -Sy --noconfirm ffmpeg 2>/dev/null ;;
        zypper) zypper --non-interactive install ffmpeg 2>/dev/null ;;
        *) echo -e "${RED}  无法自动识别包管理器，请手动安装 ffmpeg 后重新运行${NC}"; exit 1 ;;
    esac
    if ! command -v ffmpeg &>/dev/null; then
        echo -e "${RED}  ❌ ffmpeg 自动安装失败，请手动安装（如 apt install ffmpeg）后重试${NC}"
        exit 1
    fi
    echo -e "${GREEN}  ✅ ffmpeg 安装完成${NC}"
fi

PIP_BIN="pip3"; command -v pip3 &>/dev/null || PIP_BIN="pip"
if ! python3 -c "import google.genai" &>/dev/null; then
    echo -e "${YELLOW}  🔧 正在安装 google-genai（Gemini官方SDK）...${NC}"
    $PIP_BIN install --quiet --break-system-packages google-genai requests 2>/dev/null \
        || $PIP_BIN install --quiet google-genai requests 2>/dev/null
fi
if ! python3 -c "import requests" &>/dev/null; then
    $PIP_BIN install --quiet --break-system-packages requests 2>/dev/null \
        || $PIP_BIN install --quiet requests 2>/dev/null
fi

mkdir -p "$PODCAST_DIR"

# ── 2. 写入 podcast.py 工作脚本 ──────────────────────────
cat > "$PODCAST_DIR/podcast.py" << 'PODCAST_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MIMI 口播新闻 —— 每日新闻 → AI 双人对话稿 → Gemini TTS 语音 → Telegram 推送
"""
import os, re, sys, json, random, wave, base64, subprocess, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
LOG_PATH = os.path.join(HERE, "podcast.log")

def log(msg):
    line = f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

# ── 图书馆 RSS 抓取（与 mimi.sh 主脚本逻辑一致）────────────
def load_opml_feeds(opml_path, max_feeds=20):
    feeds = []
    if not os.path.exists(opml_path):
        return feeds
    try:
        with open(opml_path, "r", encoding="utf-8") as f:
            content = f.read()
        matches = re.findall(
            r'<outline[^>]+title="([^"]*)"[^>]+type="rss"[^>]+xmlUrl="([^"]*)"', content)
        if not matches:
            matches = re.findall(r'<outline[^>]+xmlUrl="([^"]*)"[^>]+title="([^"]*)"', content)
            matches = [(b, a) for a, b in matches]
        for title, url in matches[:max_feeds]:
            if url:
                feeds.append({"name": title or url, "url": url})
    except Exception as e:
        log(f"解析 feeds.opml 出错: {e}")
    return feeds

def fetch_rss(url, max_items=5):
    try:
        import requests
        headers = {"User-Agent": "Mozilla/5.0 (compatible; MimiPodcast/1.0)"}
        r = requests.get(url, headers=headers, timeout=15)
        r.encoding = r.apparent_encoding or "utf-8"
        text = r.text
        items = re.findall(r'<item[^>]*>(.*?)</item>', text, re.S)
        if not items:
            items = re.findall(r'<entry[^>]*>(.*?)</entry>', text, re.S)

        def clean(s):
            s = re.sub(r'<!\[CDATA\[(.*?)\]\]>', r'\1', s, flags=re.S)
            s = re.sub(r'<[^>]+>', '', s)
            return s.strip()

        results = []
        for item in items[:max_items]:
            title = re.search(r'<title[^>]*>(.*?)</title>', item, re.S)
            desc = re.search(r'<description[^>]*>(.*?)</description>', item, re.S)
            t = clean(title.group(1)) if title else "无标题"
            d = clean(desc.group(1))[:200] if desc else ""
            results.append({"title": t, "desc": d})
        return results
    except Exception as e:
        log(f"抓取RSS失败 {url}: {e}")
        return []

def fetch_news_material(opml_path, max_feeds=6, items_per_feed=3):
    feeds = load_opml_feeds(opml_path)
    if not feeds:
        return ""
    random.shuffle(feeds)
    selected = feeds[:max_feeds]
    all_items = []
    for feed in selected:
        for a in fetch_rss(feed["url"], items_per_feed):
            a["source"] = feed["name"]
            all_items.append(a)
    if not all_items:
        return ""
    lines = [f"【{a['source']}】{a['title']}\n{a.get('desc','')}" for a in all_items]
    return "\n\n".join(lines)

# ── 生成双人对话脚本（Gemini 文本模型）──────────────────
def generate_dialogue_script(client, cfg, news_text):
    host_a, host_b = cfg["HOST_A_NAME"], cfg["HOST_B_NAME"]
    prompt = f"""你要把下面这些新闻素材，改写成两位电台主持人 {host_a} 和 {host_b} 之间的口语化对话稿，
像真人聊天一样轻松吐槽、互相接话、偶尔调侃，不要照本宣科念新闻标题，也不要用"据悉""据报道"这种书面语。
控制在 700-1000 字左右（大约3-5分钟语音时长）。
挑其中最值得聊的5-8条即可，不用每条都讲。
开头简单打个招呼报一下日期，结尾自然收尾，不要写"谢谢收听"这种模板话。

严格按照下面的格式输出，每一句一行，不要有多余的解释、旁白或markdown符号：
{host_a}: 说的内容
{host_b}: 说的内容
{host_a}: 说的内容
...（依此类推）

新闻素材：
{news_text}
"""
    resp = client.models.generate_content(model=cfg["TEXT_MODEL"], contents=prompt)
    return resp.text.strip()

def clean_dialogue_lines(script_text, host_a, host_b):
    """只保留形如 '主持人名: 内容' 的行，过滤模型偶尔多输出的杂质"""
    lines = []
    for raw in script_text.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        m = re.match(rf'^({re.escape(host_a)}|{re.escape(host_b)})\s*[:：]\s*(.+)$', raw)
        if m:
            lines.append(f"{m.group(1)}: {m.group(2)}")
    return "\n".join(lines)

# ── 语音合成（Gemini 多说话人 TTS）──────────────────────
def synthesize_audio(client, cfg, dialogue_text, out_wav_path):
    from google.genai import types
    speech_config = types.SpeechConfig(
        multi_speaker_voice_config=types.MultiSpeakerVoiceConfig(
            speaker_voice_configs=[
                types.SpeakerVoiceConfig(
                    speaker=cfg["HOST_A_NAME"],
                    voice_config=types.VoiceConfig(
                        prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=cfg["HOST_A_VOICE"])
                    ),
                ),
                types.SpeakerVoiceConfig(
                    speaker=cfg["HOST_B_NAME"],
                    voice_config=types.VoiceConfig(
                        prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=cfg["HOST_B_VOICE"])
                    ),
                ),
            ]
        )
    )
    resp = client.models.generate_content(
        model=cfg["TTS_MODEL"],
        contents=dialogue_text,
        config=types.GenerateContentConfig(
            response_modalities=["AUDIO"],
            speech_config=speech_config,
        ),
    )
    data = resp.candidates[0].content.parts[0].inline_data.data
    if isinstance(data, str):
        data = base64.b64decode(data)
    with wave.open(out_wav_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(24000)
        wf.writeframes(data)

def wav_to_ogg(wav_path, ogg_path):
    subprocess.run(
        ["ffmpeg", "-y", "-i", wav_path, "-c:a", "libopus", "-b:a", "64k", ogg_path],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

# ── 推送到 Telegram ─────────────────────────────────────
def send_telegram_voice(cfg, ogg_path, caption):
    import requests
    url = f"https://api.telegram.org/bot{cfg['TELEGRAM_BOT_TOKEN']}/sendVoice"
    with open(ogg_path, "rb") as f:
        r = requests.post(
            url,
            data={"chat_id": cfg["TELEGRAM_USER_ID"], "caption": caption},
            files={"voice": f},
            timeout=60,
        )
    if r.status_code != 200:
        raise RuntimeError(f"Telegram推送失败: {r.status_code} {r.text[:300]}")

def send_telegram_text(cfg, text):
    import requests
    url = f"https://api.telegram.org/bot{cfg['TELEGRAM_BOT_TOKEN']}/sendMessage"
    try:
        requests.post(url, data={"chat_id": cfg["TELEGRAM_USER_ID"], "text": text}, timeout=15)
    except Exception:
        pass

def main():
    cfg = load_config()
    from google import genai
    client = genai.Client(api_key=cfg["GEMINI_API_KEY"])

    log("开始抓取图书馆新闻...")
    news_text = fetch_news_material(
        cfg.get("OPML_PATH", ""),
        max_feeds=cfg.get("MAX_FEEDS", 6),
        items_per_feed=cfg.get("ITEMS_PER_FEED", 3),
    )
    if not news_text:
        log("没抓到任何新闻素材，中止本次生成（检查 feeds.opml 是否有可用的RSS源）")
        send_telegram_text(cfg, "⚠️ 今天的口播新闻没生成——图书馆里没抓到新闻素材，检查一下RSS订阅源吧。")
        return

    log("正在用 Gemini 生成双人对话稿...")
    raw_script = generate_dialogue_script(client, cfg, news_text)
    dialogue = clean_dialogue_lines(raw_script, cfg["HOST_A_NAME"], cfg["HOST_B_NAME"])
    if not dialogue:
        log("生成的对话稿格式不对，中止")
        send_telegram_text(cfg, "⚠️ 今天的口播新闻生成失败——AI返回的对话格式不对，可以手动跑一遍看日志。")
        return

    wav_path = os.path.join(HERE, "today.wav")
    ogg_path = os.path.join(HERE, "today.ogg")

    log("正在用 Gemini TTS 合成语音...")
    synthesize_audio(client, cfg, dialogue, wav_path)

    log("正在转换音频格式...")
    wav_to_ogg(wav_path, ogg_path)

    today_str = datetime.date.today().strftime("%Y-%m-%d")
    log("正在推送到 Telegram...")
    send_telegram_voice(cfg, ogg_path, caption=f"🎙️ {today_str} 新闻口播")

    for p in (wav_path, ogg_path):
        try: os.remove(p)
        except Exception: pass

    log("完成！")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"❌ 出错: {e}")
        try:
            cfg = load_config()
            send_telegram_text(cfg, f"⚠️ 今天的口播新闻生成出错了：{e}")
        except Exception:
            pass
        sys.exit(1)
PODCAST_PY_EOF

echo -e "${GREEN}  ✅ podcast.py 已写入 $PODCAST_DIR${NC}"

# ── 3. 首次安装 / 配置向导 ────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo ""
    echo -e "${PINK}  首次安装，需要配置几项信息：${NC}"
    echo ""

    GEMINI_API_KEY=""
    TG_TOKEN=""
    TG_USER_ID=""

    # 尝试从已有的MIMI机器人里找一个用Google的，问是否复用
    if [ -d "$MIMI_HOME/bots" ]; then
        for BOT_CFG in "$MIMI_HOME"/bots/*/config.json; do
            [ -f "$BOT_CFG" ] || continue
            PROVIDER=$(python3 -c "import json;print(json.load(open('$BOT_CFG')).get('PROVIDER',''))" 2>/dev/null)
            if [ "$PROVIDER" == "google" ]; then
                BOT_NAME=$(basename "$(dirname "$BOT_CFG")")
                echo -e "${YELLOW}  发现机器人「$BOT_NAME」用的是 Gemini，要不要直接复用它的 API Key 和 Telegram 信息？(y/n): ${NC}"
                read -p "  > " REUSE
                if [[ "$REUSE" == "y" || "$REUSE" == "Y" ]]; then
                    GEMINI_API_KEY=$(python3 -c "import json;print(json.load(open('$BOT_CFG')).get('API_KEY',''))" 2>/dev/null)
                    TG_TOKEN=$(python3 -c "import json;print(json.load(open('$BOT_CFG')).get('BOT_TOKEN',''))" 2>/dev/null)
                    TG_USER_ID=$(python3 -c "import json;print(json.load(open('$BOT_CFG')).get('USER_ID',''))" 2>/dev/null)
                    break
                fi
            fi
        done
    fi

    if [ -z "$GEMINI_API_KEY" ]; then
        read -p "  请输入 Gemini API Key（aistudio.google.com/apikey 申请）: " GEMINI_API_KEY
    fi
    if [ -z "$TG_TOKEN" ]; then
        read -p "  请输入 Telegram Bot Token（@BotFather 拿到的）: " TG_TOKEN
    fi
    if [ -z "$TG_USER_ID" ]; then
        read -p "  请输入你的 Telegram User ID（@userinfobot 拿到的）: " TG_USER_ID
    fi

    read -p "  主持人A的名字（回车用默认「阿新」）: " HOST_A
    HOST_A=${HOST_A:-阿新}
    read -p "  主持人B的名字（回车用默认「阿播」）: " HOST_B
    HOST_B=${HOST_B:-阿播}

    read -p "  每天几点自动生成？（0-23，回车用默认 7）: " PUSH_HOUR
    PUSH_HOUR=${PUSH_HOUR:-7}

    if [ ! -f "$LIBRARY_OPML" ]; then
        echo -e "${YELLOW}  ⚠️ 没找到 $LIBRARY_OPML（MIMI图书馆的RSS订阅文件）${NC}"
        echo -e "${DIM}     口播新闻需要它提供新闻素材，建议先在 mimi.sh 主菜单的「l 图书馆」里配置好RSS源再来测试。${NC}"
    fi

    python3 - "$CONFIG_FILE" "$GEMINI_API_KEY" "$TG_TOKEN" "$TG_USER_ID" "$HOST_A" "$HOST_B" "$PUSH_HOUR" "$LIBRARY_OPML" << 'PYEOF'
import json, sys
(_, path, key, token, uid, ha, hb, hour, opml) = sys.argv
cfg = {
    "GEMINI_API_KEY": key,
    "TELEGRAM_BOT_TOKEN": token,
    "TELEGRAM_USER_ID": uid,
    "OPML_PATH": opml,
    "TEXT_MODEL": "gemini-3.7-flash",
    "TTS_MODEL": "gemini-2.5-flash-preview-tts",
    "HOST_A_NAME": ha,
    "HOST_B_NAME": hb,
    "HOST_A_VOICE": "Puck",
    "HOST_B_VOICE": "Kore",
    "MAX_FEEDS": 6,
    "ITEMS_PER_FEED": 3,
    "PUSH_HOUR": int(hour),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
print("配置已写入", path)
PYEOF

    # 写入 crontab
    CRON_CMD="cd $PODCAST_DIR && /usr/bin/env python3 podcast.py >> $PODCAST_DIR/podcast.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$PODCAST_DIR/podcast.py"; echo "0 $PUSH_HOUR * * * $CRON_CMD") | crontab -
    echo -e "${GREEN}  ✅ 已设置每天 ${PUSH_HOUR}:00 自动推送（crontab）${NC}"

    echo ""
    read -p "  要不要现在立即测试跑一次？(y/n): " TEST_NOW
    if [[ "$TEST_NOW" == "y" || "$TEST_NOW" == "Y" ]]; then
        cd "$PODCAST_DIR" && python3 podcast.py
    fi

    echo ""
    echo -e "${GREEN}${BOLD}  🎉 安装完成！以后想改配置/测试，再运行一次本脚本即可。${NC}"
    exit 0
fi

# ── 4. 已安装过 —— 显示管理菜单 ──────────────────────────
while true; do
    echo ""
    echo -e "${PINK}  已安装。请选择操作：${NC}"
    echo -e "  1) 🎧 立即测试生成一次"
    echo -e "  2) ⏰ 修改推送时间"
    echo -e "  3) 🎭 修改主持人名字/音色"
    echo -e "  4) 📜 查看最近日志"
    echo -e "  5) 🗑️  卸载（删除文件和定时任务）"
    echo -e "  0) 退出"
    read -p "  > " CHOICE
    case "$CHOICE" in
        1) cd "$PODCAST_DIR" && python3 podcast.py ;;
        2)
            read -p "  新的推送小时 (0-23): " NEW_HOUR
            python3 -c "
import json
p='$CONFIG_FILE'
c=json.load(open(p))
c['PUSH_HOUR']=int('$NEW_HOUR')
json.dump(c, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
"
            CRON_CMD="cd $PODCAST_DIR && /usr/bin/env python3 podcast.py >> $PODCAST_DIR/podcast.log 2>&1"
            (crontab -l 2>/dev/null | grep -v "$PODCAST_DIR/podcast.py"; echo "0 $NEW_HOUR * * * $CRON_CMD") | crontab -
            echo -e "${GREEN}  已更新为每天 ${NEW_HOUR}:00${NC}"
            ;;
        3)
            read -p "  主持人A名字: " NA
            read -p "  主持人B名字: " NB
            echo -e "${DIM}  可选音色: Puck(活泼) Kore(沉稳) Charon(播音腔) Zephyr(明亮) Fenrir(易激动) Aoede(轻快) Leda(年轻)${NC}"
            read -p "  主持人A音色 (回车保留原值): " VA
            read -p "  主持人B音色 (回车保留原值): " VB
            python3 -c "
import json
p='$CONFIG_FILE'
c=json.load(open(p))
if '$NA': c['HOST_A_NAME']='$NA'
if '$NB': c['HOST_B_NAME']='$NB'
if '$VA': c['HOST_A_VOICE']='$VA'
if '$VB': c['HOST_B_VOICE']='$VB'
json.dump(c, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
"
            echo -e "${GREEN}  已更新${NC}"
            ;;
        4) tail -n 40 "$PODCAST_DIR/podcast.log" 2>/dev/null || echo "还没有日志" ;;
        5)
            read -p "  确定要卸载吗？会删除 $PODCAST_DIR 和对应的定时任务 (y/n): " CONFIRM
            if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                (crontab -l 2>/dev/null | grep -v "$PODCAST_DIR/podcast.py") | crontab -
                rm -rf "$PODCAST_DIR"
                echo -e "${GREEN}  已卸载${NC}"
                exit 0
            fi
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}  无效选择${NC}" ;;
    esac
done
