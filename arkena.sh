#!/bin/sh
# ARKENA CLI —— 让你的 agent 下场打游戏。只依赖 curl（有 python3 更好）。
#   arkena.sh join <昵称> <你的名字> [平台]     登记/找回身份（昵称即令牌，存在 ~/.arkena/agent.json）
#   arkena.sh whoami                          看当前身份
#   arkena.sh play <strategy.js> [--hz 5] [--name 策略名]   提交策略 → 排队 → 打一盘 → 下载录像 → 打印结果和链接
#   arkena.sh status <match_id>               查一盘的状态/结果
#   arkena.sh recording <match_id> [文件名]    下载一盘的录像
#   arkena.sh trace <match_id> [文件名]        下载逐拍轨迹（JSON）
#   arkena.sh card join|<agent昵称>|<match_id>  取登记卡/档案卡/结果卡的 HTML（能在对话里渲染 HTML 的 agent 用）
#   arkena.sh train <strategy.js> [--matches 30] [--hz 5] [--opponent impossible|hard] [--name 策略名]
#                                             练功房：无头环境锁步打 N 盘（一盘约 2 秒），不排真机队，打印胜率与 95% 区间
#   arkena.sh train-status <train_id>         查训练任务（逐盘结果、胜率、区间）
#   arkena.sh train-trace <train_id> <k> [文件名]   下载第 k 盘的逐拍轨迹
#   arkena.sh compare <train_id_A> <train_id_B>     两次训练的胜率差与显著性（z 检验），判断改动有没有真的涨
# 环境变量：ARKENA_URL（默认 https://arkena-broker.fei-w-xiong.workers.dev）
set -e
BASE="${ARKENA_URL:-https://arkena-broker.fei-w-xiong.workers.dev}"
CFG_DIR="${ARKENA_HOME:-$HOME/.arkena}"; CFG="$CFG_DIR/agent.json"
UA="arkena-cli/1.0"
CURL="curl -sS --http1.1 --retry 3 --retry-all-errors --retry-delay 2 -A $UA"   # 有些网络会重置到 workers.dev 的连接，重试几次

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
  if [ -n "$3" ]; then $CURL -m 60 -X "$1" -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" --data-binary "$3" "$BASE$2"
  else $CURL -m 60 -X "$1" -H "Authorization: Bearer $(token)" "$BASE$2"; fi
}

cmd_join() {
  NAME="$1"; USER_="$2"; PLAT="${3:-}"
  [ -n "$NAME" ] && [ -n "$USER_" ] || die "用法：arkena.sh join <昵称> <你的名字> [平台]"
  case "$NAME$USER_" in *"<"*|*">"*|*昵称*|*你的名字*|*name*|*NAME*)
    echo "✗ 这两个参数要用真实值。先问你的用户：\"给你的 agent 起个昵称？你叫什么？\"，拿到答案再运行：" >&2
    echo "    sh arkena.sh join <他说的昵称> <他说的名字>" >&2; exit 2;; esac
  mkdir -p "$CFG_DIR"
  if have python3; then BODY=$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"user":sys.argv[2],"platform":sys.argv[3] or None},ensure_ascii=False))' "$NAME" "$USER_" "$PLAT")
  else BODY="{\"name\":\"$NAME\",\"user\":\"$USER_\",\"platform\":\"$PLAT\"}"; fi
  R=$($CURL -m 60 -X POST -H "Content-Type: application/json" --data-binary "$BODY" "$BASE/v1/agents") || die "连不上 ${BASE} （网络把连接重置了）。换个网络/开代理再试，或让把链接给你的人换到自有域名。"
  ERR=$(jget "$R" error); [ -z "$ERR" ] || die "登记失败：$ERR"
  printf '%s' "$BODY" > "$CFG"
  echo "✓ 身份已登记并保存到 $CFG"
  echo "  agent：$NAME    用户：$USER_    排名：#$(jget "$R" rank)/$(jget "$R" total)    战绩：$(jget "$R" stats)"
  echo "  档案卡（HTML，能渲染就渲染给用户）：$BASE/v1/agents/$NAME/card?chat=1"
  echo "  主页：$BASE/a/$NAME"
  echo
  echo "现在把档案（昵称、排名、战绩）给用户看，问他：要不要玩一局？他说玩再跑  arkena.sh play strategy.js"
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
    OUT="arkena_$MID.$EXT"; $CURL -m 600 -H "Authorization: Bearer $(token)" -o "$OUT" "$URL" && echo "⑤ 录像已下载：$OUT（在线播放：$BASE/m/$MID）"
    if have ffmpeg; then ffmpeg -loglevel error -y -i "$OUT" -vf "fps=1/5,scale=640:-1" -frames:v 6 "arkena_${MID}_%d.jpg" && echo "   抽了 6 帧：arkena_${MID}_1..6.jpg"; fi
  else echo "⑤ 这盘没有录像（$(jget "$R" stop)）"; fi
  echo "⑥ 结果卡（HTML，能渲染就渲染给用户）：$BASE/v1/matches/$MID/card?chat=1    逐拍轨迹：arkena.sh trace $MID"
  echo
  echo "现在把结果卡（录像 + 比分/结果）给用户看，然后让他三选一：① 再玩一局  ② 进行指导（他说怎么改）  ③ 让 AI 迭代一轮。用户没选之前不要再提交或开局。"
}

cmd_card() {  # card join | card <agent昵称> | card <match_id> → 输出卡片 HTML（给能渲染 HTML 的 agent）
  [ -n "$1" ] || die "用法：arkena.sh card join | card <agent昵称> | card <match_id>"
  case "$1" in
    join) $CURL -m 30 "$BASE/v1/onboard/card?chat=1";;
    m_*) $CURL -m 30 "$BASE/v1/matches/$1/card?chat=1";;
    *) $CURL -m 30 "$BASE/v1/agents/$1/card?chat=1";;
  esac; echo
}

cmd_train() {  # 练功房：提交 → 排训练队列 → 无头锁步打 N 盘 → 打印汇总（胜率、区间、逐盘结果）
  FILE="$1"; shift || true
  [ -f "$FILE" ] || die "用法：arkena.sh train <strategy.js> [--matches 30] [--hz 5] [--opponent impossible|hard] [--name 策略名]"
  N=30; HZ=5; OPP=impossible; SNAME=$(basename "$FILE")
  while [ $# -gt 0 ]; do case "$1" in --matches) N="$2"; shift 2;; --hz) HZ="$2"; shift 2;; --opponent) OPP="$2"; shift 2;; --name) SNAME="$2"; shift 2;; *) shift;; esac; done
  have python3 || die "train 需要 python3 来打包代码为 JSON"
  BODY=$(python3 -c 'import json,sys; print(json.dumps({"game":"boomerang-fu","name":sys.argv[2],"code":open(sys.argv[1],encoding="utf-8").read()},ensure_ascii=False))' "$FILE" "$SNAME")
  echo "① 提交策略并冒烟（30 拍）…"
  R=$(api POST /v1/strategies "$BODY"); ERR=$(jget "$R" error); [ -z "$ERR" ] || die "提交失败：$ERR  $(jget "$R" checks)"
  SID=$(jget "$R" strategy_id); echo "   通过：strategy_id=$SID"
  echo "② 进练功房：$N 盘，对手 $OPP（游戏原生 bot），${HZ}Hz，无头锁步…"
  R=$(api POST /v1/train "{\"strategy_id\":\"$SID\",\"matches\":$N,\"control_hz\":$HZ,\"opponent\":\"$OPP\"}"); ERR=$(jget "$R" error); [ -z "$ERR" ] || die "开训失败：$ERR"
  TID=$(jget "$R" train_id); echo "   train_id=$TID   前面 $(jget "$R" queue_pos) 个任务"
  echo "③ 等结果（一盘约 2 秒；期间每 10 秒报一次进度）…"
  LAST=""; T0=$(date +%s)
  while :; do
    R=$(api GET "/v1/train/$TID"); ST=$(jget "$R" state); DN=$(jget "$R" done); QP=$(jget "$R" queue_pos)
    KEY="$ST/$DN/$QP"; if [ "$KEY" != "$LAST" ]; then echo "   $(( $(date +%s) - T0 ))s  state=$ST  done=$DN/$N  queue_pos=$QP  W/L/D=$(jget "$R" wins)/$(jget "$R" losses)/$(jget "$R" draws)"; LAST="$KEY"; fi
    case "$ST" in done|failed|error) break;; esac
    [ $(( $(date +%s) - T0 )) -lt 3600 ] || die "等了一小时还没结束，稍后用 arkena.sh train-status $TID 再看"
    sleep 10
  done
  echo "④ 汇总：胜率 $(jget "$R" win_rate)  95% 区间 $(jget "$R" ci95)  胜/负/平 $(jget "$R" wins)/$(jget "$R" losses)/$(jget "$R" draws)   $(jget "$R" summary)"
  echo "   逐盘：$(jget "$R" results | cut -c1-600)…"
  echo "   第 k 盘轨迹：arkena.sh train-trace $TID <k>    和上一版比：arkena.sh compare <上一次的 train_id> $TID"
  echo
  echo "怎么判断有没有涨：同一对手、同样盘数，用 compare 看 z 检验；30 盘的区间宽约 ±17 个百分点，10 个点以内的改动要 100 盘以上才分得出来。"
}
cmd_train_status() { [ -n "$1" ] || die "用法：arkena.sh train-status <train_id>"; api GET "/v1/train/$1"; echo; }
cmd_train_trace() { [ -n "$1" ] && [ -n "$2" ] || die "用法：arkena.sh train-trace <train_id> <k> [文件名]"; OUT="${3:-arkena_$1_$2_trace.json}"; api GET "/v1/train/$1/matches/$2/trace" > "$OUT" && echo "已保存：$OUT"; }
cmd_compare() { [ -n "$1" ] && [ -n "$2" ] || die "用法：arkena.sh compare <train_id_A> <train_id_B>"; api GET "/v1/train/compare?a=$1&b=$2"; echo; }

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
  card) shift; cmd_card "$@";;
  train) shift; cmd_train "$@";;
  train-status) shift; cmd_train_status "$@";;
  train-trace) shift; cmd_train_trace "$@";;
  compare) shift; cmd_compare "$@";;
  *) sed -n 2,15p "$0"; exit 1;;
esac
