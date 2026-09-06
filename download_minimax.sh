#!/bin/bash

# ============================================
# MiniMax H3 モデル自動ダウンロードスクリプト
# PinkCherry beta-0.6 + 10Eros-Max beta2 対応版
# 選択式・中断再開対応・大きい順ダウンロード
# ゴミ掃除強化版（途中停止・Pod再起動対応）
# ============================================
#
# 【RunPod Webターミナルでの実行方法】
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/ruiness1234/runpod-minimax/main/download_minimax.sh)
#
# ※ 途中で Ctrl+C で止めても、同じコマンドを再実行すれば
#    未完了ファイルは aria2c -c で続きから再開できます。
# ※ 完了済みファイルはサイズチェックでスキップされます。
# ※ 共通ファイル（Text Encoder + VAE）は常にダウンロードされます。
# ※ 片方のみ選択時、選んでいない方の Diffusion Model は
#    途中ファイル含め徹底削除されます。
# ※ ダウンロードはサイズの大きい順に実行します。
# ※ 不完全ファイルがある場合「再開」か「削除して最初から」を選べます。
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
KEEP_DIFFUSION=()   # 残す diffusion モデル名
REMOVE_FILES=()

case $CHOICE in
  1)
    DOWNLOADS=("${PINKCHERRY[@]}" "${COMMON_FILES[@]}")
    KEEP_DIFFUSION=("$PINKCHERRY_NAME")
    REMOVE_FILES=("$EROS_NAME")
    echo "→ PinkCherry のみ + 共通ファイル（目安: 70GB以上）"
    echo "→ 存在する場合は 10Eros-Max 関連ファイルを削除します"
    ;;
  2)
    DOWNLOADS=("${EROS[@]}" "${COMMON_FILES[@]}")
    KEEP_DIFFUSION=("$EROS_NAME")
    REMOVE_FILES=("$PINKCHERRY_NAME")
    echo "→ 10Eros-Max のみ + 共通ファイル（目安: 75GB以上）"
    echo "→ 存在する場合は PinkCherry 関連ファイルを削除します"
    ;;
  3)
    DOWNLOADS=("${PINKCHERRY[@]}" "${EROS[@]}" "${COMMON_FILES[@]}")
    KEEP_DIFFUSION=("$PINKCHERRY_NAME" "$EROS_NAME")
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

echo "選択完了。"
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

# ---------- ユーティリティ ----------
human_size() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1} bytes"
}

# 指定パスの本体 + 関連一時ファイルをすべて削除
clean_related() {
    local path="$1"
    local removed=0
    for f in \
        "$path" \
        "${path}.aria2" \
        "${path}.tmp" \
        "${path}.part" \
        "${path}.aria2.tmp" \
        "${path}."*
    do
        if [ -e "$f" ]; then
            echo "[DELETE] $f"
            rm -f "$f"
            removed=1
        fi
    done
    return $removed
}

# 不要な Diffusion Model を徹底削除（本体 + 一時 + 名前が似た残骸）
remove_unwanted_diffusion() {
    local dir="$BASE_DIR/diffusion_models"
    echo "----- 不要モデル / ゴミの削除 (diffusion_models) -----"

    # 明示的に削除対象のもの
    for name in "${REMOVE_FILES[@]}"; do
        clean_related "$dir/$name" || true
    done

    # KEEP 以外の大きなファイル・一時ファイルを掃除
    shopt -s nullglob
    for f in "$dir"/*; do
        [ -e "$f" ] || continue
        local base=$(basename "$f")
        local keep=0
        for k in "${KEEP_DIFFUSION[@]}"; do
            if [[ "$base" == "$k" || "$base" == "$k".* ]]; then
                keep=1
                break
            fi
        done
        if [ "$keep" -eq 0 ]; then
            echo "[DELETE] 不要/ゴミ: $f"
            rm -f "$f"
        fi
    done
    shopt -u nullglob
    echo ""
}

# 共通ファイル用の一時ファイル掃除（完了済みなら .aria2 などを消す）
clean_temps_for_expected() {
    local subdir="$1"
    local filename="$2"
    local min_size="$3"
    local path="$BASE_DIR/$subdir/$filename"

    if [ -f "$path" ]; then
        local size=$(stat -c%s "$path" 2>/dev/null || echo 0)
        local threshold=$(( min_size * 95 / 100 ))
        if [ "$size" -ge "$threshold" ] && [ "$size" -gt 1000000 ]; then
            # 完了済み → 一時ファイルだけ消す
            for t in "${path}.aria2" "${path}.tmp" "${path}.part"; do
                if [ -e "$t" ]; then
                    echo "[CLEAN] 完了済みの一時ファイル削除: $t"
                    rm -f "$t"
                fi
            done
        fi
    fi
}

# ---------- ディスク状況表示 ----------
show_disk_info() {
    echo "----- ディスク状況 -----"
    if command -v df >/dev/null; then
        df -h "$BASE_DIR" 2>/dev/null || df -h /workspace 2>/dev/null || true
    fi
    echo "BASE_DIR 使用量:"
    du -sh "$BASE_DIR" 2>/dev/null || true
    echo ""
}

# ---------- 不完全ファイル検出 ----------
find_incomplete() {
    local has_incomplete=0
    echo "----- 不完全ファイル / 一時ファイルの確認 -----"

    for item in "${DOWNLOADS[@]}"; do
        IFS='|' read -r _u subdir filename minsize <<< "$item"
        local path="$BASE_DIR/$subdir/$filename"
        local size=0
        if [ -f "$path" ]; then
            size=$(stat -c%s "$path" 2>/dev/null || echo 0)
        fi
        local threshold=$(( minsize * 95 / 100 ))

        if [ -f "$path" ] && [ "$size" -lt "$threshold" ]; then
            echo "[INCOMPLETE] $subdir/$filename ($(human_size $size) / 目安 $(human_size $minsize))"
            has_incomplete=1
        fi

        # 一時ファイルだけの存在もチェック
        for t in "${path}.aria2" "${path}.tmp" "${path}.part"; do
            if [ -e "$t" ]; then
                echo "[TEMP] $t"
                has_incomplete=1
            fi
        done
    done

    # diffusion_models 内の予期しない大きなファイルも報告
    shopt -s nullglob
    for f in "$BASE_DIR/diffusion_models"/*; do
        [ -f "$f" ] || continue
        local base=$(basename "$f")
        local keep=0
        for k in "${KEEP_DIFFUSION[@]}"; do
            if [[ "$base" == "$k" || "$base" == "$k".* ]]; then
                keep=1
                break
            fi
        done
        if [ "$keep" -eq 0 ]; then
            local sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            if [ "$sz" -gt 100000000 ]; then  # 100MB超
                echo "[GARBAGE] $f ($(human_size $sz))"
                has_incomplete=1
            fi
        fi
    done
    shopt -u nullglob

    if [ "$has_incomplete" -eq 0 ]; then
        echo "不完全ファイル・大きなゴミは見つかりませんでした。"
    fi
    echo ""
    return $has_incomplete
}

# ---------- 実行フロー ----------
show_disk_info

# 不要モデルを先に削除
remove_unwanted_diffusion

# 共通ファイルの完了済み一時ファイル掃除
for item in "${COMMON_FILES[@]}"; do
    IFS='|' read -r _u subdir filename minsize <<< "$item"
    clean_temps_for_expected "$subdir" "$filename" "$minsize"
done

# 不完全ファイルがあるか確認し、ユーザーに選択させる
if find_incomplete; then
    echo "不完全ファイルまたはゴミが検出されました。"
    echo "  r) 再開する（既存の不完全ファイルを活かして続きからダウンロード）"
    echo "  c) ゴミをすべて削除して最初からダウンロードし直す"
    echo "  q) 終了"
    read -p "選択 (r/c/q): " ACTION
    echo ""

    case $ACTION in
        c|C)
            echo "----- 不完全ファイルを削除してクリーンな状態にします -----"
            for item in "${DOWNLOADS[@]}"; do
                IFS='|' read -r _u subdir filename minsize <<< "$item"
                local path="$BASE_DIR/$subdir/$filename"
                # 不完全なものだけ消す（完了済みは残す）
                if [ -f "$path" ]; then
                    local size=$(stat -c%s "$path" 2>/dev/null || echo 0)
                    local threshold=$(( minsize * 95 / 100 ))
                    if [ "$size" -lt "$threshold" ]; then
                        clean_related "$path" || true
                    else
                        # 完了済みなら一時ファイルだけ
                        clean_temps_for_expected "$subdir" "$filename" "$minsize"
                    fi
                else
                    clean_related "$path" || true
                fi
            done
            # 再度不要ファイル掃除
            remove_unwanted_diffusion
            echo "クリーンアップ完了。"
            show_disk_info
            ;;
        q|Q)
            echo "終了します。"
            exit 0
            ;;
        *)
            echo "→ 再開モードで続行します。"
            ;;
    esac
fi

# ========== ダウンロード関数 ==========
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
        echo "[SKIP] 既に完了: $filename ($(human_size $current_size))"
        # 完了済みなら一時ファイルを掃除
        for t in "${dest_path}.aria2" "${dest_path}.tmp" "${dest_path}.part"; do
            [ -e "$t" ] && rm -f "$t" && echo "[CLEAN] $t"
        done
        return 0
    fi

    if [ "$current_size" -gt 0 ]; then
        echo "[RESUME] 未完了を検出。続きから再開: $filename ($(human_size $current_size))"
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
            # 成功後も念のため一時ファイル掃除
            for t in "${dest_path}.aria2" "${dest_path}.tmp" "${dest_path}.part"; do
                [ -e "$t" ] && rm -f "$t"
            done
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
    echo "  - $fname ($(human_size $fsize))"
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
show_disk_info
