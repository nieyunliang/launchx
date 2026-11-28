#!/bin/zsh
# 按领域分组跑测试，只跑改动相关的部分。
#
#   scripts/test.sh                  除翻页性能外全部（约 3 秒，与 swift test 相同）
#   scripts/test.sh core             布局 / 存储 / 索引 / 排序 / 整理 / 网格 / 本地化 / Dock / 图标 / 壁纸
#   scripts/test.sh paging           翻页 / 手势 / 捏合逻辑（不开窗口）
#   scripts/test.sh uninstall        卸载器 / 完全磁盘访问
#   scripts/test.sh model            LaunchpadModel 行为 + 历次回归
#   scripts/test.sh ui               真实窗口挂载根视图（短暂开窗）
#   scripts/test.sh perf             翻页性能（开窗连续翻页约 100 秒）
#   scripts/test.sh all              全部，含翻页性能
#   scripts/test.sh core model       可同时指定多组
#
# 额外参数用 -- 隔开后原样传给 swift test，例如：
#   scripts/test.sh model -- --skip AuditRound3
# 注意：多个 --filter 之间是「或」关系，要缩小范围请直接用 swift test --filter <套件名>。
set -euo pipefail
cd "${0:A:h}/.."

typeset -A targets=(
  core      LaunchXCoreTests
  paging    LaunchXPagingTests
  uninstall LaunchXUninstallTests
  model     LaunchXModelTests
  ui        LaunchXUITests
  perf      LaunchXPerfTests
)

groups=()
passthrough=()
while (( $# )); do
  if [[ $1 == -- ]]; then shift; passthrough=("$@"); break; fi
  groups+=("$1"); shift
done

if (( ${#groups} == 0 )); then
  exec swift test "${passthrough[@]}"
fi

filters=()
for g in "${groups[@]}"; do
  case $g in
    all)
      export LAUNCHX_PERF=1
      exec swift test "${passthrough[@]}"
      ;;
    perf)
      export LAUNCHX_PERF=1
      ;|
    *)
      if [[ -z ${targets[$g]:-} ]]; then
        print -u2 "未知分组：$g（可用：${(k)targets} all）"
        exit 2
      fi
      filters+=(--filter "^${targets[$g]}\\.")
      ;;
  esac
done

exec swift test "${filters[@]}" "${passthrough[@]}"
