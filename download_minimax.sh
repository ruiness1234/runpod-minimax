#!/bin/bash

# ============================================
# MiniMax H3 モデル自動ダウンロードスクリプト
# PinkCherry beta-0.6 + 10Eros-Max beta2 対応版
# 選択式・中断再開対応・大きい順ダウンロード
# Storage → EU-RO-1(RTX PRO 4500) → Edit(Pod作成へ)
# GPU → ComfyUI13.0(Set overridesでContainer diskを20GBに、RTX PRO 4500でDeploy)
# Web terminalをEnabledにし、ターミナルを開いてコマンド実行
# ============================================
#
# 【RunPod Webターミナルでの実行方法】
#
# 初回・再開とも同じコマンド:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/ruiness1234/runpod-minimax/main/download_minimax.sh)
#
# ※ 途中で Ctrl+C で止めても、同じコマンドを再実行すれば
#    未完了ファイルは aria2c -c で続きから再開されます。
# ※ 完了済みファイルはサイズチェックでスキップされます。
# ※ 共通ファイル（Text Encoder + VAE）は常にダウンロードされます。
# ※ 片方のみ選択時、選んでいない方の Diffusion Model は
#    途中ファイル含め削除されます。
# ※ ダウンロードはサイズの大きい順に実行します。
#
# ============================================

set -e

# ========== 設定部分 ==========
BASE_DIR="/workspace/runpod-slim/ComfyUI/models"
HF_TOKEN=""                            # 必要ならトークンを入れる

CONNECTIONS=16
MAX_TRIES=0
RETRY_WAIT=10
# ==============================

# ========== 選択メニュー（一番最初） ==========
echo "===== MiniMax H3 自動ダウンロード ====="
echo "ベースディレクトリ: $BASE_DIR"
echo "（共通ファイル: Text Encoder + VAE は常にダウンロード）"
echo ""
echo "ダウンロードする Diffusion Model を選択してください："
echo ""
echo "  1) PinkCherry beta-0.6 int8 のみ     … ネットワークドライブ 70GB以上"
echo "  2) 10Eros-Max fl2va beta2 pruned のみ … ネットワークドライブ 75GB以上"
echo "  3) 両方                               … ネットワークドライブ 110GB以上"
echo ""
read -p "番号を入力 (1-3): " CHOICE
echo ""

# 形式: URL|subdir|filename|完了とみなす最小バイト数
COMMON_FILES=(
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|text_encoders|qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|15000000000"
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors|vae|minimax_h3_video_vae_fp16.safetensors|5000000000"
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors|vae|minimax_h3_audio_vae_fp32.safetensors|500000000"
)

PINKCHERRY_NAME="PinkCherry_fl2va_MiniMax_H3_int8_convrot-beta-0.6.safetensors"
EROS_NAME="10Eros_Max_h3_fl2va_beta2_pruned.safetensors"

PINKCHERRY=(
  "https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/main/beta-0.6-fl2va/${PINKCHERRY_NAME}|diffusion_models|${PINKCHERRY_NAME}|34000000000"
)

EROS=(
  "https://huggingface.co/TenStrip/10Eros-Max/resolve/main/${EROS_NAME}|diffusion_models|${EROS_NAME}|40000000000"
)

DOWNLOADS=()
REMOVE_FILES=()

case $CHOICE in
  1)
    DOWNLOADS=("${PINKCHERRY[@]}" "${COMMON_FILES[@]}")
    REMOVE_FILES=("$EROS_NAME")
    echo "→ PinkCherry のみ + 共通ファイル（目安: 70GB以上）"
    echo "→ 存在する場合は 10Eros-Max 関連ファイルを削除します"
    ;;
  2)
    DOWNLOADS=("${EROS[@]}" "${COMMON_FILES[@]}")
    REMOVE_FILES=("$PINKCHERRY_NAME")
    echo "→ 10Eros-Max のみ + 共通ファイル（目安: 75GB以上）"
    echo "→ 存在する場合は PinkCherry 関連ファイルを削除します"
    ;;
  3)
    DOWNLOADS=("${PINKCHERRY[@]}" "${EROS[@]}" "${COMMON_FILES[@]}")
    REMOVE_FILES=()
    echo "→ 両方 + 共通ファイル（目安: 110GB以上）"
    ;;
  *)
    echo "無効な選択です。終了します。"
    exit 1
    ;;
esac

# サイズ（4列目）の大きい順に並べ替え
if [ ${#DOWNLOADS[@]} -gt 0 ]; then
    mapfile -t DOWNLOADS < <(
        printf '%s\n' "${DOWNLOADS[@]}" | sort -t'|' -k4 -nr
    )
    echo "→ ダウンロード順: サイズの大きい順"
fi

echo "選択完了。この後は完了まで自動で進みます。"
echo ""

# ========== ここからノンストップ ==========

if ! command -v aria2c &> /dev/null; then
    echo "[INFO] aria2c が見つかりません。インストールします..."
    apt-get update -qq
    apt-get install -y -qq aria2
    echo "[OK] aria2c インストール完了"
else
    echo "[OK] aria2c は既にインストール済み"
fi

mkdir -p "$BASE_DIR"/{text_encoders,vae,diffusion_models,loras}

# 選んでいない方のファイルを削除（本体 + aria2 一時ファイル）
remove_unwanted() {
    local name="$1"
    local dir="$BASE_DIR/diffusion_models"
    local removed=0

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

if [ ${#REMOVE_FILES[@]} -gt 0 ]; then
    echo "----- 不要モデルの削除 -----"
    for name in "${REMOVE_FILES[@]}"; do
        remove_unwanted "$name"
    done
    echo ""
fi

# 完成サイズ以上ならスキップ / 未完成なら aria2c -c で再開
download_file() {
    local url="$1"
    local subdir="$2"
    local filename="$3"
    local min_complete_size="$4"
    local dest_dir="$BASE_DIR/$subdir"
    local dest_path="$dest_dir/$filename"

    mkdir -p "$dest_dir"

    local current_size=0
    if [ -f "$dest_path" ]; then
        current_size=$(stat -c%s "$dest_path" 2>/dev/null || echo 0)
    fi

    local threshold=$(( min_complete_size * 95 / 100 ))
    if [ "$current_size" -ge "$threshold" ] && [ "$current_size" -gt 1000000 ]; then
        echo "[SKIP] 既に完了: $filename ($(numfmt --to=iec-i --suffix=B $current_size 2>/dev/null || echo ${current_size} bytes))"
        return 0
    fi

    if [ "$current_size" -gt 0 ]; then
        echo "[RESUME] 未完了を検出。続きから再開: $filename ($(numfmt --to=iec-i --suffix=B $current_size 2>/dev/null || echo ${current_size} bytes))"
    else
        echo "[DOWNLOAD] $filename を開始..."
    fi

    local header_opt=""
    if [ -n "$HF_TOKEN" ]; then
        header_opt="--header=Authorization: Bearer $HF_TOKEN"
    fi

    while true; do
        if aria2c -c \
            -x $CONNECTIONS \
            -s $CONNECTIONS \
            -k 1M \
            --max-tries=$MAX_TRIES \
            --retry-wait=$RETRY_WAIT \
            --file-allocation=none \
            --console-log-level=notice \
            --summary-interval=10 \
            $header_opt \
            -d "$dest_dir" \
            -o "$filename" \
            "$url"; then
            echo "[SUCCESS] $filename ダウンロード完了"
            break
        else
            echo "[WARN] $filename 一時失敗。${RETRY_WAIT}秒後に再開します..."
            sleep $RETRY_WAIT
        fi
    done
}

echo "----- ダウンロード順（大きい順） -----"
for item in "${DOWNLOADS[@]}"; do
    IFS='|' read -r _u _s fname fsize <<< "$item"
    echo "  - $fname ($(numfmt --to=iec-i --suffix=B $fsize 2>/dev/null || echo $fsize bytes))"
done
echo ""

for item in "${DOWNLOADS[@]}"; do
    IFS='|' read -r url subdir filename minsize <<< "$item"
    download_file "$url" "$subdir" "$filename" "$minsize"
done

echo ""
echo "===== 全てのダウンロードが完了しました ====="
echo "保存先: $BASE_DIR"
echo "  - diffusion_models/"
echo "  - text_encoders/"
echo "  - vae/"
