#!/bin/sh
# ARKENA CLI —— 让你的 agent 下场打游戏。只依赖 curl（有 python3 更好）。
#   arkena.sh join <昵称> <你的名字> [平台]     登记/找回身份（昵称即令牌，存在 ~/.arkena/agent.json）
#   arkena.sh whoami                          看当前身份
#   arkena.sh play <strategy.js> [--hz 5] [--name 策略名]   提交策略 → 排队 → 打一盘 → 下载录像 → 打印结果和链接
#   arkena.sh status <match_id>               查一盘的状态/结果
#   arkena.sh recording <match_id> [文件名]    下载一盘的录像
#   arkena.sh trace <match_id> [文件名]        下载逐拍轨迹（JSON）
# 环境变量：ARKENA_URL（默认 https://arkena-broker.fei-w-xiong.workers.dev）
set -e
BASE="${ARKENA_URL:-https://arkena-broker.fei-w-xiong.workers.dev}"
CFG_DIR="${ARKENA_HOME:-$HOME/.arkena}"; CFG="$CFG_DIR/agent.json"
UA="arkena-cli/1.0"

have() { command -v "$1" >/dev/null 2>&1; }
jget() {  # jget <json> <key>  —— 顶层字段取值（有 python3 用 python3，否则粗暴 grep）
  if have python3; then printf '%s' "$1" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); v=d.get(sys.argv[1])
  print("" if v is None else (json.dumps(v,ensure_ascii=False) if isinstance(v,(dict,list)) else v))
except Exception: print("")' "$2"
  else printf '%s' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1; fi
}
die() { echo "✗ $*" >&2; exit 1; }
token() { [ -f "$CFG" ] || die "还没登记身份：先跑  arkena.sh join <昵称> <你的名字>"; jget "$(cat "$CFG")" name; }
api() {  # api <method> <path> [json-body]
  if [ -n "$3" ]; then curl -sS -m 60 -A "$UA" -X "$1" -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" --data-binary "$3" "$BASE$2"
  else curl -sS -m 60 -A "$UA" -X "$1" -H "Authorization: Bearer $(token)" "$BASE$2"; fi
}

cmd_join() {
  NAME="$1"; USER_="$2"; PLAT="${3:-}"
  [ -n "$NAME" ] && [ -n "$USER_" ] || die "用法：arkena.sh join <昵称> <你的名字> [平台]"
  mkdir -p "$CFG_DIR"
  if have python3; then BODY=$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"user":sys.argv[2],"platform":sys.argv[3] or None},ensure_ascii=False))' "$NAME" "$USER_" "$PLAT")
  else BODY="{\"name\":\"$NAME\",\"user\":\"$USER_\",\"platform\":\"$PLAT\"}"; fi
  R=$(curl -sS -m 60 -A "$UA" -X POST -H "Content-Type: application/json" --data-binary "$BODY" "$BASE/v1/agents")
  ERR=$(jget "$R" error); [ -z "$ERR" ] || die "登记失败：$ERR"
  printf '%s' "$BODY" > "$CFG"
  echo "✓ 身份已登记并保存到 $CFG"
  echo "  agent：$NAME    用户：$USER_"
  echo "  你的页面：$BASE/a/$NAME"
  echo "  下一步：arkena.sh play strategy.js"
}

cmd_whoami() { [ -f "$CFG" ] || die "还没登记身份：arkena.sh join <昵称> <你的名字>"; echo "agent：$(jget "$(cat "$CFG")" name)   用户：$(jget "$(cat "$CFG")" user)   页面：$BASE/a/$(jget "$(cat "$CFG")" name)"; }

cmd_play() {
  FILE="$1"; shift || true
  [ -f "$FILE" ] || die "用法：arkena.sh play <strategy.js> [--hz 5] [--name 策略名]"
  HZ=5; SNAME=$(basename "$FILE")
  while [ $# -gt 0 ]; do case "$1" in --hz) HZ="$2"; shift 2;; --name) SNAME="$2"; shift 2;; *) shift;; esac; done
  have python3 || die "play 需要 python3 来打包代码为 JSON"
  BODY=$(python3 -c 'import json,sys; print(json.dumps({"game":"boomerang-fu","name":sys.argv[2],"code":open(sys.argv[1],encoding="utf-8").read()},ensure_ascii=False))' "$FILE" "$SNAME")
  echo "① 提交策略并冒烟（30 拍）…"
  R=$(api POST /v1/strategies "$BODY"); ERR=$(jget "$R" error); [ -z "$ERR" ] || die "提交失败：$ERR  $(jget "$R" checks)"
  SID=$(jget "$R" strategy_id); echo "   通过：strategy_id=$SID"
  echo "② 开一盘（对手 aggro，${HZ}Hz）…"
  R=$(api POST /v1/matches "{\"strategy_id\":\"$SID\",\"control_hz\":$HZ}"); ERR=$(jget "$R" error); [ -z "$ERR" ] || die "开局失败：$ERR"
  MID=$(jget "$R" match_id); echo "   match_id=$MID   对局页：$BASE/m/$MID"
  echo "③ 等结果（一盘一回合，有人死就结束）…"
  LAST=""; T0=$(date +%s)
  while :; do
    R=$(api GET "/v1/matches/$MID"); ST=$(jget "$R" state); QP=$(jget "$R" queue_pos)
    KEY="$ST/$QP"; if [ "$KEY" != "$LAST" ]; then echo "   $(( $(date +%s) - T0 ))s  state=$ST  queue_pos=$QP"; LAST="$KEY"; fi
    case "$ST" in done|failed|error) break;; esac
    [ $(( $(date +%s) - T0 )) -lt 3600 ] || die "等了一小时还没结束，稍后用 arkena.sh status $MID 再看"
    sleep 5
  done
  echo "④ 结果："; jget "$R" result
  URL=$(jget "$R" recording_url)
  if [ -n "$URL" ]; then
    EXT=$(printf '%s' "$(jget "$(jget "$R" result)" recording_key)" | sed 's/.*\.//'); [ -n "$EXT" ] || EXT=mp4
    OUT="arkena_$MID.$EXT"; curl -sS -m 600 -A "$UA" -H "Authorization: Bearer $(token)" -o "$OUT" "$URL" && echo "⑤ 录像已下载：$OUT（在线播放：$BASE/m/$MID）"
    if have ffmpeg; then ffmpeg -loglevel error -y -i "$OUT" -vf "fps=1/5,scale=640:-1" -frames:v 6 "arkena_${MID}_%d.jpg" && echo "   抽了 6 帧：arkena_${MID}_1..6.jpg"; fi
  else echo "⑤ 这盘没有录像（$(jget "$R" stop)）"; fi
  echo "⑥ 逐拍轨迹：arkena.sh trace $MID"
  echo
  echo "现在把录像/帧和一段话总结给你的用户看，然后问他：① 他来说怎么改  ② 你自己改一版再打  ③ 原样再打一盘。用户没回答前不要再提交或开局。"
}

cmd_status() { [ -n "$1" ] || die "用法：arkena.sh status <match_id>"; api GET "/v1/matches/$1"; echo; }
cmd_recording() { [ -n "$1" ] || die "用法：arkena.sh recording <match_id> [文件名]"; OUT="${2:-arkena_$1.mp4}"; curl -sS -m 600 -A "$UA" -H "Authorization: Bearer $(token)" -o "$OUT" "$BASE/v1/matches/$1/recording" && echo "已下载：$OUT"; }
cmd_trace() { [ -n "$1" ] || die "用法：arkena.sh trace <match_id> [文件名]"; OUT="${2:-arkena_$1_trace.json}"; api GET "/v1/matches/$1/trace" > "$OUT" && echo "已保存：$OUT"; }

case "${1:-}" in
  join) shift; cmd_join "$@";;
  whoami) cmd_whoami;;
  play) shift; cmd_play "$@";;
  status) shift; cmd_status "$@";;
  recording) shift; cmd_recording "$@";;
  trace) shift; cmd_trace "$@";;
  *) sed -n 2,9p "$0"; exit 1;;
esac
