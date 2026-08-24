#!/bin/bash

# ============================================
# ComfyUI 設定・ワークフロー バックアップスクリプト
# RunPod 向け・日付付きスナップショット
# ============================================
#
# 【RunPod Webターミナルでの実行方法】
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/ruiness1234/runpod-minimax/main/backup_comfyui.sh)
#   またはローカルに置いて:
#   bash backup_comfyui.sh
#
# 【バックアップ対象のイメージ】
#   - カスタムワークフロー (user/default/workflows など)
#   - custom_nodes の設定・コード（モデル本体は除外）
#   - 設定ファイル (extra_model_paths.yaml など)
#   - input / 小さなアセット
#   - その他軽量なカスタム設定
#
# 【除外するもの】
#   - models/ 配下の重いモデルファイル (.safetensors, .ckpt, .pt など)
#     → これらは download_minimax.sh 等で URL から再取得する想定
#   - output/ の生成結果（オプションで含め可能）
#   - 巨大なキャッシュ・一時ファイル
#
# バックアップ先: /workspace/backup/comfyui_snapshot_YYYYMMDD_HHMMSS.tar.gz
# 世代管理: 最新3世代のみ保持（古いものは確認なしで自動削除）
# その後、RunPod のファイルブラウザや scp / rsync でローカルにダウンロード
#
# ============================================

set -e

# ========== 設定部分 ==========
# ComfyUI のルート（環境に合わせて変更）
COMFYUI_ROOT="/workspace/runpod-slim/ComfyUI"

# バックアップ保存先
BACKUP_DIR="/workspace/backup"

# 保持するバックアップ世代数（これより古いものは自動削除）
MAX_BACKUPS=3

# タイムスタンプ
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SNAPSHOT_NAME="comfyui_snapshot_${TIMESTAMP}"
SNAPSHOT_PATH="${BACKUP_DIR}/${SNAPSHOT_NAME}"
ARCHIVE_PATH="${BACKUP_DIR}/${SNAPSHOT_NAME}.tar.gz"

# output/ を含めるか (y/n)。生成画像は重いのでデフォルトは除外
INCLUDE_OUTPUT="n"

# 除外する拡張子・パターン（モデル本体）
EXCLUDE_PATTERNS=(
  "*.safetensors"
  "*.ckpt"
  "*.pt"
  "*.pth"
  "*.bin"
  "*.onnx"
  "*.gguf"
  "*.engine"
  "*.tar"
  "*.tar.gz"
  "*.zip"
  "*.7z"
  "**/__pycache__/**"
  "**/.git/**"
  "**/models/**/*.safetensors"
  "**/models/**/*.ckpt"
  "**/models/**/*.pt"
  "**/models/**/*.pth"
  "**/models/**/*.bin"
)
# ==============================

echo "===== ComfyUI 設定・ワークフロー バックアップ ====="
echo "ComfyUI ルート: $COMFYUI_ROOT"
echo "バックアップ先: $BACKUP_DIR"
echo "保持世代数:     $MAX_BACKUPS"
echo ""

if [ ! -d "$COMFYUI_ROOT" ]; then
  echo "[ERROR] ComfyUI ディレクトリが見つかりません: $COMFYUI_ROOT"
  echo "        スクリプト上部の COMFYUI_ROOT を実際のパスに合わせてください。"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
mkdir -p "$SNAPSHOT_PATH"

# rsync / tar 用の除外オプションを組み立て
EXCLUDE_ARGS=()
for pat in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDE_ARGS+=(--exclude="$pat")
done

# 追加で models 配下の大容量を明示的に除外しつつ、空ディレクトリ構造は残したい場合は
# 後で models のディレクトリ構造だけコピーする

echo "----- バックアップ対象を収集中 -----"

# 1. 主要ディレクトリ・ファイルをコピー（除外パターン適用）
#    典型的な ComfyUI 構造を想定
TARGETS=(
  "user"
  "custom_nodes"
  "input"
  "web"
  "comfy"
  "comfy_extras"
  "script_examples"
  "extra_model_paths.yaml"
  "extra_model_paths.yaml.example"
  "config.ini"
  "config.json"
  "manager_config.ini"
  ".env"
  "requirements.txt"
  "requirements_versions.txt"
  "README.md"
)

# output を含める場合
if [ "$INCLUDE_OUTPUT" = "y" ] || [ "$INCLUDE_OUTPUT" = "Y" ]; then
  TARGETS+=("output")
  echo "→ output/ を含めます（サイズに注意）"
else
  echo "→ output/ は除外します（生成画像はバックアップしません）"
fi

for target in "${TARGETS[@]}"; do
  src="${COMFYUI_ROOT}/${target}"
  if [ -e "$src" ]; then
    echo "[COPY] $target"
    # ディレクトリの場合は再帰コピー（除外適用）
    if [ -d "$src" ]; then
      mkdir -p "${SNAPSHOT_PATH}/${target}"
      rsync -a --info=progress2 \
        "${EXCLUDE_ARGS[@]}" \
        "$src/" "${SNAPSHOT_PATH}/${target}/" 2>/dev/null || \
      rsync -a \
        "${EXCLUDE_ARGS[@]}" \
        "$src/" "${SNAPSHOT_PATH}/${target}/"
    else
      # 単一ファイル
      cp -a "$src" "${SNAPSHOT_PATH}/"
    fi
  else
    echo "[SKIP] 存在しません: $target"
  fi
done

# 2. models ディレクトリは「構造のみ」残す（重いファイルは除外）
#    後で download スクリプトで再取得する前提
if [ -d "${COMFYUI_ROOT}/models" ]; then
  echo "[COPY] models/ （ディレクトリ構造のみ・重いファイル除外）"
  mkdir -p "${SNAPSHOT_PATH}/models"
  # 空のサブディレクトリ構造を再現
  find "${COMFYUI_ROOT}/models" -type d | while read -r dir; do
    rel="${dir#${COMFYUI_ROOT}/}"
    mkdir -p "${SNAPSHOT_PATH}/${rel}"
  done
  # 軽量なファイル（.txt, .json, .yaml, .md など）だけコピー
  find "${COMFYUI_ROOT}/models" -type f \( \
    -name "*.txt" -o -name "*.json" -o -name "*.yaml" -o -name "*.yml" \
    -o -name "*.md" -o -name "*.py" -o -name "*.csv" \
  \) | while read -r f; do
    rel="${f#${COMFYUI_ROOT}/}"
    mkdir -p "${SNAPSHOT_PATH}/$(dirname "$rel")"
    cp -a "$f" "${SNAPSHOT_PATH}/${rel}"
  done
fi

# 3. ルート直下のその他軽量設定ファイルを拾う
echo "[COPY] ルート直下の設定ファイル"
find "$COMFYUI_ROOT" -maxdepth 1 -type f \( \
  -name "*.yaml" -o -name "*.yml" -o -name "*.json" -o -name "*.ini" \
  -o -name "*.cfg" -o -name "*.conf" -o -name "*.txt" -o -name "*.md" \
  -o -name "*.py" -o -name ".env*" \
\) ! -name "requirements*.txt" | while read -r f; do
  base=$(basename "$f")
  # 既にコピー済みならスキップ
  if [ ! -e "${SNAPSHOT_PATH}/${base}" ]; then
    cp -a "$f" "${SNAPSHOT_PATH}/"
    echo "  + $base"
  fi
done

# 4. バックアップメタ情報を記録
META_FILE="${SNAPSHOT_PATH}/BACKUP_INFO.txt"
{
  echo "ComfyUI Snapshot Backup"
  echo "======================="
  echo "Created: $(date -Iseconds)"
  echo "Host: $(hostname 2>/dev/null || echo unknown)"
  echo "ComfyUI Root: $COMFYUI_ROOT"
  echo "Include output/: $INCLUDE_OUTPUT"
  echo "Max backups kept: $MAX_BACKUPS"
  echo ""
  echo "Excluded patterns:"
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    echo "  - $pat"
  done
  echo ""
  echo "Note: Heavy model files (.safetensors etc.) are intentionally excluded."
  echo "      Re-download them with download_minimax.sh or equivalent scripts."
} > "$META_FILE"

# 5. アーカイブ作成
echo ""
echo "----- アーカイブ作成中 -----"
cd "$BACKUP_DIR"
tar -czf "${SNAPSHOT_NAME}.tar.gz" "${SNAPSHOT_NAME}"

# 一時ディレクトリを削除してアーカイブのみ残す
rm -rf "${SNAPSHOT_PATH}"

ARCHIVE_SIZE=$(stat -c%s "${ARCHIVE_PATH}" 2>/dev/null || echo 0)
HUMAN_SIZE=$(numfmt --to=iec-i --suffix=B "$ARCHIVE_SIZE" 2>/dev/null || echo "${ARCHIVE_SIZE} bytes")

# 6. 世代管理：最新 MAX_BACKUPS 個だけ残し、古いものを確認なしで削除
echo ""
echo "----- 古いバックアップの整理（最大 ${MAX_BACKUPS} 世代） -----"
mapfile -t BACKUP_LIST < <(ls -1t "${BACKUP_DIR}"/comfyui_snapshot_*.tar.gz 2>/dev/null || true)

TOTAL=${#BACKUP_LIST[@]}
if [ "$TOTAL" -gt "$MAX_BACKUPS" ]; then
  for ((i=MAX_BACKUPS; i<TOTAL; i++)); do
    OLD="${BACKUP_LIST[$i]}"
    echo "[DELETE] $OLD"
    rm -f "$OLD"
  done
  echo "→ $((TOTAL - MAX_BACKUPS)) 個の古いバックアップを削除しました"
else
  echo "→ 現在 ${TOTAL} 個（上限 ${MAX_BACKUPS} 以内のため削除なし）"
fi

echo ""
echo "===== バックアップ完了 ====="
echo "アーカイブ: ${ARCHIVE_PATH}"
echo "サイズ:     ${HUMAN_SIZE}"
echo ""
echo "【ローカルへのダウンロード例】"
echo "  1. RunPod の Jupyter / ファイルブラウザから直接ダウンロード"
echo "  2. scp の場合:"
echo "     scp root@<POD_IP>:${ARCHIVE_PATH} ./"
echo "  3. rsync の場合:"
echo "     rsync -avz root@<POD_IP>:${ARCHIVE_PATH} ./"
echo ""
echo "復元時は tar xzvf で展開し、必要なファイルを ComfyUI ルートに戻してください。"
echo "モデルは download_minimax.sh 等で再取得してください。"
