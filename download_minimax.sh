#!/bin/bash

# ============================================
# MiniMax H3 モデル自動ダウンロードスクリプト（修正強化版）
# PinkCherry beta-0.6 + PinkCherry v1_final (community turbo+pruned+int8) 対応
# ・厳格サイズチェック
# ・不完全/破損ファイル検出＋再開/強制再DL対応
# ・local スコープ修正
# ・aria2c 詳細ログ抑制 + 全体進捗サマリー + 目安残り時間
# ============================================
# Runpod動作環境
# Storage → EU-RO-1(RTX PRO 4500) → Edit(Pod作成へ)
# CPU → CPU 3GHz 2vCPUでDeploy
# Web terminalをEnabledにし、ターミナルを開いてコマンド実行
# ※動画生成時はGPU → ComfyUI13.0(Set overridesでContainer diskを20GBに、RTX PRO 4500でDeploy)
# ============================================
# 実行方法（RunPod Webターミナル）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/ruiness1234/runpod-minimax/main/download_minimax.sh)
#
# またはローカルファイルとして保存して:
#   bash download_minimax.sh
# ============================================

set -euo pipefail

# ========== 設定 ==========
BASE_DIR="/workspace/runpod-slim/ComfyUI/models"
HF_TOKEN=""                            # 必要ならトークンを入れる
CIVITAI_TOKEN=""                       # Civitaiダウンロード用（対話入力でも可）

CONNECTIONS=16
MAX_TRIES=0
RETRY_WAIT=10
PROGRESS_INTERVAL=2                    # サマリー更新間隔（秒）
# ==========================

echo "===== MiniMax H3 自動ダウンロード（強化版） ====="
echo "ベースディレクトリ: $BASE_DIR"
echo "（共通ファイル: Text Encoder + VAE は常にダウンロード）"
echo ""

COMMON_FILES=(
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|text_encoders|qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|15600000000"
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors|vae|minimax_h3_video_vae_fp16.safetensors|5200000000"
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors|vae|minimax_h3_audio_vae_fp32.safetensors|600000000"
)

PINKCHERRY_BETA_NAME="PinkCherry_fl2va_MiniMax_H3_int8_convrot-beta-0.6.safetensors"
PINKCHERRY_V1_NAME="PinkCherry_v1_bf16_fla2va_H3_TURBO_v3_int8_convrot_pruned.safetensors"

PINKCHERRY_BETA=(
  "https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/main/beta-0.6-fl2va/${PINKCHERRY_BETA_NAME}|diffusion_models|${PINKCHERRY_BETA_NAME}|34000000000"
)

PINKCHERRY_V1=(
  "https://civitai.com/api/download/models/3326433|diffusion_models|${PINKCHERRY_V1_NAME}|19500000000"
)

# ========== ユーティリティ関数 ==========
get_file_size() {
  local path="$1"
  if [ -f "$path" ]; then
    stat -c%s "$path" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

human_size() {
  local bytes="$1"
  numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes} bytes"
}

# 秒 → 目安表示（例: 1h23m / 4m12s / 45s）
human_eta() {
  local sec="$1"
  if [ -z "$sec" ] || [ "$sec" -lt 0 ] 2>/dev/null; then
    echo "--"
    return
  fi
  # 極端に大きい値は未確定扱い
  if [ "$sec" -gt 864000 ]; then
    echo "--"
    return
  fi
  local h=$((sec / 3600))
  local m=$(((sec % 3600) / 60))
  local s=$((sec % 60))
  if [ "$h" -gt 0 ]; then
    printf "%dh%02dm" "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf "%dm%02ds" "$m" "$s"
  else
    printf "%ds" "$s"
  fi
}

remove_unwanted() {
  local name="$1"
  local dir="$BASE_DIR/diffusion_models"
  local removed=0
  local f

  for f in \
    "$dir/$name" \
    "$dir/$name.aria2" \
    "$dir/$name.tmp" \
    "$dir/$name.part"
  do
    if [ -e "$f" ]; then
      echo "[DELETE] $f"
      rm -f "$f"
      removed=1
    fi
  done

  shopt -s nullglob
  for f in "$dir/$name".*; do
    if [ -e "$f" ]; then
      echo "[DELETE] $f"
      rm -f "$f"
      removed=1
    fi
  done
  shopt -u nullglob

  if [ "$removed" -eq 0 ]; then
    echo "[INFO] 削除対象なし: $name"
  fi
}

detect_incomplete() {
  local url subdir filename minsize dest_dir dest_path current_size threshold
  local incomplete_found=0
  local -a incomplete_list=()

  echo "----- 不完全ファイル / 一時ファイルの確認 -----"

  for item in "${DOWNLOADS[@]}"; do
    IFS='|' read -r url subdir filename minsize <<< "$item"
    dest_dir="$BASE_DIR/$subdir"
    dest_path="$dest_dir/$filename"

    for ext in .aria2 .tmp .part; do
      if [ -e "${dest_path}${ext}" ]; then
        echo "[INCOMPLETE] 一時ファイル: ${dest_path}${ext}"
        incomplete_list+=("${dest_path}${ext}")
        incomplete_found=1
      fi
    done

    current_size=$(get_file_size "$dest_path")
    threshold=$(( minsize * 95 / 100 ))

    if [ "$current_size" -gt 0 ] && [ "$current_size" -lt "$threshold" ]; then
      echo "[INCOMPLETE] サイズ不足: $filename ($(human_size $current_size) < 目安 $(human_size $minsize))"
      incomplete_list+=("$dest_path")
      incomplete_found=1
    elif [ "$current_size" -gt 0 ]; then
      echo "[OK] サイズ確認済み: $filename ($(human_size $current_size))"
    fi
  done

  if [ -d "$BASE_DIR/diffusion_models" ]; then
    shopt -s nullglob
    for f in "$BASE_DIR/diffusion_models"/*.{aria2,tmp,part}; do
      if [ -e "$f" ]; then
        echo "[GARBAGE] $f"
        incomplete_list+=("$f")
        incomplete_found=1
      fi
    done
    shopt -u nullglob
  fi

  if [ "$incomplete_found" -eq 0 ]; then
    echo "不完全ファイル・大きなゴミは見つかりませんでした。"
  else
    echo ""
    echo "不完全ファイルまたはゴミが検出されました。"
  fi

  INCOMPLETE_FOUND=$incomplete_found
  INCOMPLETE_LIST=("${incomplete_list[@]}")
}

clean_incomplete() {
  local f
  echo "----- 不完全ファイルを削除してクリーンな状態にします -----"
  for f in "${INCOMPLETE_LIST[@]}"; do
    if [ -e "$f" ]; then
      echo "[DELETE] $f"
      rm -f "$f"
    fi
  done
  for item in "${DOWNLOADS[@]}"; do
    IFS='|' read -r _ subdir filename _ <<< "$item"
    local dest="$BASE_DIR/$subdir/$filename"
    rm -f "${dest}.aria2" "${dest}.tmp" "${dest}.part" 2>/dev/null || true
  done
  echo "クリーンアップ完了。"
  echo ""
}

force_clean_all() {
  local item url subdir filename minsize dest
  echo "----- 完了済みを含む全対象ファイルを強制削除します -----"
  for item in "${DOWNLOADS[@]}"; do
    IFS='|' read -r url subdir filename minsize <<< "$item"
    dest="$BASE_DIR/$subdir/$filename"
    for f in "$dest" "${dest}.aria2" "${dest}.tmp" "${dest}.part"; do
      if [ -e "$f" ]; then
        echo "[FORCE DELETE] $f"
        rm -f "$f"
      fi
    done
    shopt -s nullglob
    for f in "$BASE_DIR/$subdir/$filename".*; do
      echo "[FORCE DELETE] $f"
      rm -f "$f"
    done
    shopt -u nullglob
  done
  echo "強制削除完了。"
  echo ""
}

validate_civitai_token() {
  local token="$1"
  local http_code
  if [ -z "$token" ]; then
    return 1
  fi
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    --connect-timeout 10 \
    --max-time 20 \
    "https://civitai.com/api/v1/me" 2>/dev/null || echo "000")
  if [ "$http_code" = "200" ]; then
    return 0
  else
    return 1
  fi
}

# 全対象の「現在の取得済みバイト合計」（分母は TOTAL_EXPECTED）
calc_bytes_done() {
  local item url subdir filename minsize dest_path sz total=0
  for item in "${DOWNLOADS[@]}"; do
    IFS='|' read -r url subdir filename minsize <<< "$item"
    dest_path="$BASE_DIR/$subdir/$filename"
    sz=$(get_file_size "$dest_path")
    # 完了済みは minsize 相当として数え、途中は実サイズ
    local th=$(( minsize * 98 / 100 ))
    if [ "$sz" -ge "$th" ] && [ "$sz" -gt 1000000 ]; then
      total=$((total + minsize))
    else
      total=$((total + sz))
    fi
  done
  echo "$total"
}

# 1行サマリー表示（上書き更新）
# 引数: current_filename
print_progress_line() {
  local current_name="$1"
  local now done_bytes pct speed_bps eta_sec elapsed gained
  now=$(date +%s)
  done_bytes=$(calc_bytes_done)

  if [ "${TOTAL_EXPECTED:-0}" -gt 0 ]; then
    pct=$(( done_bytes * 100 / TOTAL_EXPECTED ))
    if [ "$pct" -gt 100 ]; then pct=100; fi
  else
    pct=0
  fi

  elapsed=$(( now - SESSION_START ))
  gained=$(( done_bytes - SESSION_START_BYTES ))
  if [ "$gained" -lt 0 ]; then gained=0; fi

  eta_sec=""
  speed_bps=0
  if [ "$elapsed" -ge 3 ] && [ "$gained" -gt 0 ]; then
    speed_bps=$(( gained / elapsed ))
    local remain=$(( TOTAL_EXPECTED - done_bytes ))
    if [ "$remain" -lt 0 ]; then remain=0; fi
    if [ "$speed_bps" -gt 0 ]; then
      eta_sec=$(( remain / speed_bps ))
    fi
  fi

  local short_name="$current_name"
  if [ ${#short_name} -gt 42 ]; then
    short_name="${short_name:0:39}..."
  fi

  # 行をクリアしてから描画
  printf "\r\033[K"
  printf "[進捗] %d/%d ファイル | %s / %s (%d%%) | %s/s | 残り目安 %s | %s" \
    "$FILES_DONE" "$FILES_TOTAL" \
    "$(human_size "$done_bytes")" \
    "$(human_size "$TOTAL_EXPECTED")" \
    "$pct" \
    "$(human_size "$speed_bps")" \
    "$(human_eta "${eta_sec:-}")" \
    "$short_name"
}

# ダウンロード本体（aria2c は静音、進捗はサマリーのみ）
download_file() {
  local url="$1"
  local subdir="$2"
  local filename="$3"
  local min_complete_size="$4"
  local dest_dir="$BASE_DIR/$subdir"
  local dest_path="$dest_dir/$filename"
  local current_size=0
  local threshold
  local header_opt=""
  local final_url="$url"
  local aria_pid
  local aria_log
  local exit_code=0

  mkdir -p "$dest_dir"

  current_size=$(get_file_size "$dest_path")
  threshold=$(( min_complete_size * 98 / 100 ))

  if [ "$current_size" -ge "$threshold" ] && [ "$current_size" -gt 1000000 ]; then
    echo ""
    echo "[SKIP] 既に完了: $filename ($(human_size $current_size))"
    FILES_DONE=$((FILES_DONE + 1))
    print_progress_line "(skip)"
    echo ""
    return 0
  fi

  if [ "$current_size" -gt 0 ]; then
    echo ""
    echo "[RESUME] 続きから再開: $filename ($(human_size $current_size))"
  else
    echo ""
    echo "[DOWNLOAD] 開始: $filename"
  fi

  if [[ "$url" == *"huggingface.co"* ]] && [ -n "$HF_TOKEN" ]; then
    header_opt="--header=Authorization: Bearer $HF_TOKEN"
  elif [[ "$url" == *"civitai.com"* ]]; then
    if [ -n "$CIVITAI_TOKEN" ]; then
      if [[ "$url" == *"?"* ]]; then
        final_url="${url}&token=${CIVITAI_TOKEN}"
      else
        final_url="${url}?token=${CIVITAI_TOKEN}"
      fi
      header_opt="--header=Authorization: Bearer $CIVITAI_TOKEN"
    else
      echo "[WARN] Civitai ダウンロードです。CIVITAI_TOKEN が未設定の可能性があります。"
    fi
  fi

  while true; do
    aria_log=$(mktemp /tmp/aria2_XXXXXX.log)

    # 詳細ログはファイルへ。ターミナルには出さない
    set +e
    aria2c -c \
      -x "$CONNECTIONS" \
      -s "$CONNECTIONS" \
      -k 1M \
      --max-tries="$MAX_TRIES" \
      --retry-wait="$RETRY_WAIT" \
      --file-allocation=none \
      --console-log-level=error \
      --summary-interval=0 \
      --download-result=hide \
      --quiet=true \
      $header_opt \
      -d "$dest_dir" \
      -o "$filename" \
      "$final_url" \
      >"$aria_log" 2>&1 &
    aria_pid=$!
    set -e

    # 進捗サマリーループ
    while kill -0 "$aria_pid" 2>/dev/null; do
      print_progress_line "$filename"
      sleep "$PROGRESS_INTERVAL"
    done

    set +e
    wait "$aria_pid"
    exit_code=$?
    set -e

    print_progress_line "$filename"

    current_size=$(get_file_size "$dest_path")
    if [ "$exit_code" -eq 0 ] && [ "$current_size" -ge "$threshold" ]; then
      FILES_DONE=$((FILES_DONE + 1))
      echo ""
      echo "[SUCCESS] $filename 完了 ($(human_size $current_size))"
      rm -f "$aria_log"
      break
    fi

    # 失敗またはサイズ不足
    echo ""
    if [ "$exit_code" -ne 0 ]; then
      echo "[WARN] $filename 一時失敗 (exit=$exit_code)。${RETRY_WAIT}秒後に再試行..."
      if [ -s "$aria_log" ]; then
        echo "---- aria2c ログ末尾 ----"
        tail -n 8 "$aria_log" || true
        echo "------------------------"
      fi
    else
      echo "[WARN] ダウンロード後もサイズ不足: $filename ($(human_size $current_size))。再試行します..."
      rm -f "$dest_path" "${dest_path}.aria2" 2>/dev/null || true
    fi
    rm -f "$aria_log"
    sleep "$RETRY_WAIT"
  done
}

# ========== 対話フェーズ ==========
# ① モデル選択 → ② トークン → ③ 不完全ファイル。②で「①に戻る」可

while true; do
  echo "【①】ダウンロードする Diffusion Model を選択してください："
  echo ""
  echo "  1) PinkCherry beta-0.6 int8 のみ                    … ネットワークドライブ 70GB以上"
  echo "  2) PinkCherry v1_final (turbo+pruned+int8 community) のみ … ネットワークドライブ 55GB以上"
  echo "  3) 両方                                             … ネットワークドライブ 95GB以上"
  echo ""
  read -p "番号を入力 (1-3): " CHOICE
  echo ""

  DOWNLOADS=()
  REMOVE_FILES=()
  NEED_CIVITAI=0

  case $CHOICE in
    1)
      DOWNLOADS=("${PINKCHERRY_BETA[@]}" "${COMMON_FILES[@]}")
      REMOVE_FILES=("$PINKCHERRY_V1_NAME")
      echo "→ PinkCherry beta-0.6 のみ + 共通ファイル（目安: 70GB以上）"
      echo "→ 存在する場合は PinkCherry v1_final 関連ファイルを削除します"
      ;;
    2)
      DOWNLOADS=("${PINKCHERRY_V1[@]}" "${COMMON_FILES[@]}")
      REMOVE_FILES=("$PINKCHERRY_BETA_NAME")
      NEED_CIVITAI=1
      echo "→ PinkCherry v1_final (community turbo+pruned+int8) のみ + 共通ファイル（目安: 55GB以上）"
      echo "→ 存在する場合は PinkCherry beta-0.6 関連ファイルを削除します"
      ;;
    3)
      DOWNLOADS=("${PINKCHERRY_BETA[@]}" "${PINKCHERRY_V1[@]}" "${COMMON_FILES[@]}")
      REMOVE_FILES=()
      NEED_CIVITAI=1
      echo "→ 両方 + 共通ファイル（目安: 95GB以上）"
      ;;
    *)
      echo "無効な選択です。終了します。"
      exit 1
      ;;
  esac

  if [ ${#DOWNLOADS[@]} -gt 0 ]; then
    mapfile -t DOWNLOADS < <(printf '%s\n' "${DOWNLOADS[@]}" | sort -t'|' -k4 -nr)
    echo "→ ダウンロード順: サイズの大きい順"
  fi
  echo "選択完了。"
  echo ""

  if [ "$NEED_CIVITAI" -eq 0 ]; then
    break
  fi

  echo "【②】Civitai API トークンの入力"
  echo "  PinkCherry v1_final は Civitai 経由です。"
  echo "  トークンは Civitai → Account Settings → API Keys で発行できます。"
  echo ""

  TOKEN_OK=0
  while true; do
    if [ -n "${CIVITAI_TOKEN:-}" ]; then
      read -p "Civitai トークンを入力 (Enter で現在の設定値を使用): " input_token
      if [ -n "$input_token" ]; then
        CIVITAI_TOKEN="$input_token"
      fi
    else
      read -p "Civitai API トークンを入力してください: " CIVITAI_TOKEN
    fi

    if [ -z "${CIVITAI_TOKEN:-}" ]; then
      echo "[ERROR] トークンが空です。"
    else
      echo "トークンを検証中..."
      if validate_civitai_token "$CIVITAI_TOKEN"; then
        echo "[OK] トークンは有効です。"
        echo ""
        TOKEN_OK=1
        break
      else
        echo "[ERROR] トークンが無効、または通信に失敗しました。"
      fi
    fi

    echo ""
    echo "  r) 再入力する"
    echo "  b) ①のモデル選択に戻る"
    echo "  q) 処理を終了する"
    read -p "選択 (r/b/q): " RETRY_CHOICE
    case "$RETRY_CHOICE" in
      r|R)
        CIVITAI_TOKEN=""
        echo ""
        continue
        ;;
      b|B)
        CIVITAI_TOKEN=""
        echo ""
        echo "→ ①のモデル選択に戻ります。"
        echo ""
        TOKEN_OK=0
        break
        ;;
      q|Q)
        echo "終了します。"
        exit 0
        ;;
      *)
        echo "無効な選択です。終了します。"
        exit 1
        ;;
    esac
  done

  if [ "$TOKEN_OK" -eq 1 ]; then
    break
  fi
done

# ---------- ③ 不完全ファイル検出時の動作の選択 ----------
mkdir -p "$BASE_DIR"/{text_encoders,vae,diffusion_models,loras}

echo "【③】不完全ファイル / 強制再ダウンロードの確認"
detect_incomplete

FORCE_REDOWNLOAD=0
echo ""
echo "不完全ファイルまたはゴミが検出された場合、または強制再ダウンロードしたい場合："
echo "  r) 再開する（既存の不完全ファイルを活かして続きからダウンロード）"
echo "  c) ゴミ・不完全ファイルだけ削除して最初からダウンロードし直す"
echo "  f) 完了済みを含む「全対象ファイル」を削除して最初からダウンロードし直す ★推奨（破損対策）"
echo "  q) 終了"
read -p "選択 (r/c/f/q): " ACTION
echo ""

case "$ACTION" in
  r|R)
    echo "→ 既存ファイルを活かして再開します。"
    ;;
  c|C)
    clean_incomplete
    ;;
  f|F)
    force_clean_all
    FORCE_REDOWNLOAD=1
    ;;
  q|Q)
    echo "終了します。"
    exit 0
    ;;
  *)
    echo "無効な選択です。終了します。"
    exit 1
    ;;
esac

# ========== 以降ノンストップ ==========
echo "----- 対話入力完了。以降は自動実行します -----"
echo ""

if ! command -v aria2c &> /dev/null; then
  echo "[INFO] aria2c が見つかりません。インストールします..."
  apt-get update -qq
  apt-get install -y -qq aria2
  echo "[OK] aria2c インストール完了"
else
  echo "[OK] aria2c は既にインストール済み"
fi

if [ ${#REMOVE_FILES[@]} -gt 0 ]; then
  echo "----- 不要モデル / ゴミの削除 (diffusion_models) -----"
  for name in "${REMOVE_FILES[@]}"; do
    remove_unwanted "$name"
  done
  echo ""
fi

# 進捗用グローバル
TOTAL_EXPECTED=0
FILES_TOTAL=${#DOWNLOADS[@]}
FILES_DONE=0
for item in "${DOWNLOADS[@]}"; do
  IFS='|' read -r _ _ _ fsize <<< "$item"
  TOTAL_EXPECTED=$((TOTAL_EXPECTED + fsize))
done

echo "----- ダウンロード順（大きい順） -----"
for item in "${DOWNLOADS[@]}"; do
  IFS='|' read -r _ _ fname fsize <<< "$item"
  echo "  - $fname ($(human_size $fsize))"
done
echo ""
echo "合計目安サイズ: $(human_size "$TOTAL_EXPECTED") / ファイル数: $FILES_TOTAL"
echo "（進捗行は上書き更新。残り時間は開始後の平均速度からの目安です）"
echo ""

SESSION_START=$(date +%s)
SESSION_START_BYTES=$(calc_bytes_done)

for item in "${DOWNLOADS[@]}"; do
  IFS='|' read -r url subdir filename minsize <<< "$item"
  if [ "$FORCE_REDOWNLOAD" -eq 1 ]; then
    rm -f "$BASE_DIR/$subdir/$filename" 2>/dev/null || true
  fi
  download_file "$url" "$subdir" "$filename" "$minsize"
done

# 最終行を確定
echo ""
print_progress_line "(完了)"
echo ""
echo ""
echo "===== 全てのダウンロードが完了しました ====="
echo "保存先: $BASE_DIR"
echo "  - diffusion_models/"
echo "  - text_encoders/"
echo "  - vae/"
echo ""
echo "※ CLIP shape エラーが出た場合は、特に text_encoders/qwen3vl_... が破損している可能性が高いです。"
echo "  その場合は再度このスクリプトを実行し、選択肢で「f」を選んで強制再ダウンロードしてください。"
echo ""
echo "【補足】PinkCherry v1_final (community) は Civitai 経由です。"
echo "  認証エラーになる場合は有効な CIVITAI_TOKEN を入力してください。"
echo "  （Civitai → Account Settings → API Keys で発行可能）"