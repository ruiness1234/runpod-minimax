#!/bin/bash

# ============================================
# MiniMax H3 モデル自動ダウンロードスクリプト（修正強化版）
# PinkCherry beta-0.6 + PinkCherry v1_final (community turbo+pruned+int8) 対応
# ・厳格サイズチェック
# ・不完全/破損ファイル検出＋再開/強制再DL対応
# ・local スコープ修正
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
CIVITAI_TOKEN=""                       # Civitaiダウンロード用（必要なら入れる）

CONNECTIONS=16
MAX_TRIES=0
RETRY_WAIT=10
# ==========================

echo "===== MiniMax H3 自動ダウンロード（強化版） ====="
echo "ベースディレクトリ: $BASE_DIR"
echo "（共通ファイル: Text Encoder + VAE は常にダウンロード）"
echo ""
echo "ダウンロードする Diffusion Model を選択してください："
echo ""
echo "  1) PinkCherry beta-0.6 int8 のみ                    … ネットワークドライブ 70GB以上"
echo "  2) PinkCherry v1_final (turbo+pruned+int8 community) のみ … ネットワークドライブ 55GB以上"
echo "  3) 両方                                             … ネットワークドライブ 95GB以上"
echo ""
read -p "番号を入力 (1-3): " CHOICE
echo ""

# 形式: URL|subdir|filename|完了とみなす最小バイト数（ほぼ実サイズ）
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

# コミュニティ製 v1_final (extraltodeus / Civitai modelVersion 3326433)
# Civitaiはトークン必須の場合があるため、CIVITAI_TOKEN を設定推奨
PINKCHERRY_V1=(
  "https://civitai.com/api/download/models/3326433|diffusion_models|${PINKCHERRY_V1_NAME}|19500000000"
)

DOWNLOADS=()
REMOVE_FILES=()

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
    echo "→ PinkCherry v1_final (community turbo+pruned+int8) のみ + 共通ファイル（目安: 55GB以上）"
    echo "→ 存在する場合は PinkCherry beta-0.6 関連ファイルを削除します"
    ;;
  3)
    DOWNLOADS=("${PINKCHERRY_BETA[@]}" "${PINKCHERRY_V1[@]}" "${COMMON_FILES[@]}")
    REMOVE_FILES=()
    echo "→ 両方 + 共通ファイル（目安: 95GB以上）"
    ;;
  *)
    echo "無効な選択です。終了します。"
    exit 1
    ;;
esac

# サイズ（4列目）の大きい順に並べ替え
if [ ${#DOWNLOADS[@]} -gt 0 ]; then
  mapfile -t DOWNLOADS < <(printf '%s\n' "${DOWNLOADS[@]}" | sort -t'|' -k4 -nr)
  echo "→ ダウンロード順: サイズの大きい順"
fi

echo "選択完了。"
echo ""

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

# 選んでいない方のファイルを削除
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

# 不完全・一時ファイルを検出
detect_incomplete() {
  local url subdir filename minsize dest_dir dest_path current_size threshold
  local incomplete_found=0
  local -a incomplete_list=()

  echo "----- 不完全ファイル / 一時ファイルの確認 -----"

  for item in "${DOWNLOADS[@]}"; do
    IFS='|' read -r url subdir filename minsize <<< "$item"
    dest_dir="$BASE_DIR/$subdir"
    dest_path="$dest_dir/$filename"

    # 一時ファイル
    for ext in .aria2 .tmp .part; do
      if [ -e "${dest_path}${ext}" ]; then
        echo "[INCOMPLETE] 一時ファイル: ${dest_path}${ext}"
        incomplete_list+=("${dest_path}${ext}")
        incomplete_found=1
      fi
    done

    # 本体サイズチェック（95%以上で「一応完了寄り」だが、強制再DL時は無視）
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

  # diffusion_models 内のその他ゴミも軽くチェック
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

  # 配列をグローバルに渡す代わりにフラグとリストを返す形で扱う
  INCOMPLETE_FOUND=$incomplete_found
  INCOMPLETE_LIST=("${incomplete_list[@]}")
}

# 不完全ファイルだけ削除
clean_incomplete() {
  local f
  echo "----- 不完全ファイルを削除してクリーンな状態にします -----"
  for f in "${INCOMPLETE_LIST[@]}"; do
    if [ -e "$f" ]; then
      echo "[DELETE] $f"
      rm -f "$f"
    fi
  done
  # 念のため対象ファイルの一時ファイルも掃除
  for item in "${DOWNLOADS[@]}"; do
    IFS='|' read -r _ subdir filename _ <<< "$item"
    local dest="$BASE_DIR/$subdir/$filename"
    rm -f "${dest}.aria2" "${dest}.tmp" "${dest}.part" 2>/dev/null || true
  done
  echo "クリーンアップ完了。"
  echo ""
}

# 対象ファイルをすべて強制削除（完了済み含む）
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
    # 余分な拡張子付きも
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

# ダウンロード本体
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

  mkdir -p "$dest_dir"

  current_size=$(get_file_size "$dest_path")
  threshold=$(( min_complete_size * 98 / 100 ))   # より厳しく（98%）

  if [ "$current_size" -ge "$threshold" ] && [ "$current_size" -gt 1000000 ]; then
    echo "[SKIP] 既に完了: $filename ($(human_size $current_size))"
    return 0
  fi

  if [ "$current_size" -gt 0 ]; then
    echo "[RESUME] 未完了を検出。続きから再開: $filename ($(human_size $current_size))"
  else
    echo "[DOWNLOAD] $filename を開始..."
  fi

  # Hugging Face / Civitai 認証
  if [[ "$url" == *"huggingface.co"* ]] && [ -n "$HF_TOKEN" ]; then
    header_opt="--header=Authorization: Bearer $HF_TOKEN"
  elif [[ "$url" == *"civitai.com"* ]]; then
    if [ -n "$CIVITAI_TOKEN" ]; then
      # クエリに token を付与（Civitai推奨）
      if [[ "$url" == *"?"* ]]; then
        final_url="${url}&token=${CIVITAI_TOKEN}"
      else
        final_url="${url}?token=${CIVITAI_TOKEN}"
      fi
      header_opt="--header=Authorization: Bearer $CIVITAI_TOKEN"
    else
      echo "[WARN] Civitai ダウンロードです。CIVITAI_TOKEN が未設定のため認証エラーになる可能性があります。"
      echo "      スクリプト上部の CIVITAI_TOKEN に API キーを設定してください。"
    fi
  fi

  while true; do
    if aria2c -c \
      -x "$CONNECTIONS" \
      -s "$CONNECTIONS" \
      -k 1M \
      --max-tries="$MAX_TRIES" \
      --retry-wait="$RETRY_WAIT" \
      --file-allocation=none \
      --console-log-level=notice \
      --summary-interval=10 \
      $header_opt \
      -d "$dest_dir" \
      -o "$filename" \
      "$final_url"; then

      # ダウンロード後の最終サイズチェック
      current_size=$(get_file_size "$dest_path")
      if [ "$current_size" -lt "$threshold" ]; then
        echo "[WARN] ダウンロード後もサイズ不足: $filename ($(human_size $current_size))。再試行します..."
        rm -f "$dest_path" "${dest_path}.aria2" 2>/dev/null || true
        sleep "$RETRY_WAIT"
        continue
      fi

      echo "[SUCCESS] $filename ダウンロード完了 ($(human_size $current_size))"
      break
    else
      echo "[WARN] $filename 一時失敗。${RETRY_WAIT}秒後に再開します..."
      sleep "$RETRY_WAIT"
    fi
  done
}

# ========== メイン処理 ==========
if ! command -v aria2c &> /dev/null; then
  echo "[INFO] aria2c が見つかりません。インストールします..."
  apt-get update -qq
  apt-get install -y -qq aria2
  echo "[OK] aria2c インストール完了"
else
  echo "[OK] aria2c は既にインストール済み"
fi

mkdir -p "$BASE_DIR"/{text_encoders,vae,diffusion_models,loras}

# 不要モデル削除
if [ ${#REMOVE_FILES[@]} -gt 0 ]; then
  echo "----- 不要モデル / ゴミの削除 (diffusion_models) -----"
  for name in "${REMOVE_FILES[@]}"; do
    remove_unwanted "$name"
  done
  echo ""
fi

# 不完全ファイル確認
detect_incomplete

FORCE_REDOWNLOAD=0
if [ "${INCOMPLETE_FOUND:-0}" -eq 1 ] || true; then
  # 常に選択肢を出す（完了済みでも強制再DLできるように）
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
fi

echo "----- ダウンロード順（大きい順） -----"
for item in "${DOWNLOADS[@]}"; do
  IFS='|' read -r _ _ fname fsize <<< "$item"
  echo "  - $fname ($(human_size $fsize))"
done
echo ""

for item in "${DOWNLOADS[@]}"; do
  IFS='|' read -r url subdir filename minsize <<< "$item"
  if [ "$FORCE_REDOWNLOAD" -eq 1 ]; then
    # 強制時はスキップ判定を無効化するため一時的にサイズを0扱いにする（download_file内で再チェック）
    rm -f "$BASE_DIR/$subdir/$filename" 2>/dev/null || true
  fi
  download_file "$url" "$subdir" "$filename" "$minsize"
done

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
echo "  認証エラーになる場合はスクリプト上部の CIVITAI_TOKEN に API キーを設定してください。"
echo "  （Civitai → Account Settings → API Keys で発行可能）"
