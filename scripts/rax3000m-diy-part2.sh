#!/bin/bash
# rax3000m diy-part2: 在 ./scripts/feeds install -a 之后、cp .config 之前执行, 工作目录 = openwrt/
# 只补 21.02 (kernel 5.4) 缺的 dae/daed 内核开关 + 做主机名/描述的最小改动, 其余代码不动。

fail=0
err() { echo "ERROR: $1" >&2; fail=1; }
ok()  { echo "OK: $1"; }

# ---------- 1. 内核 BTF / XDP / BPF_EVENTS (21.02 的 Config-kernel.in 没有对应 KERNEL_* 符号) ----------
GK=target/linux/generic/config-5.4
if [ ! -f "$GK" ]; then
  err "$GK 不存在"
else
  # DEBUG_INFO 是 BTF 的前置; REDUCED 会削掉 pahole 需要的 DWARF, 顺手关掉
  sed -i \
    -e 's/^# CONFIG_DEBUG_INFO is not set$/CONFIG_DEBUG_INFO=y/' \
    -e 's/^CONFIG_DEBUG_INFO_REDUCED=y$/# CONFIG_DEBUG_INFO_REDUCED is not set/' \
    -e 's/^# CONFIG_DEBUG_INFO_BTF is not set$/CONFIG_DEBUG_INFO_BTF=y/' \
    -e 's/^# CONFIG_DEBUG_INFO_DWARF4 is not set$/CONFIG_DEBUG_INFO_DWARF4=y/' \
    -e 's/^# CONFIG_XDP_SOCKETS is not set$/CONFIG_XDP_SOCKETS=y/' \
    "$GK"

  # 这几个符号在 5.4 generic config 里可能压根没有对应行, 没匹配上就追加
  add_opt() { grep -q "^$1=" "$GK" || echo "$1=$2" >> "$GK"; }
  add_opt CONFIG_DEBUG_INFO y
  add_opt CONFIG_DEBUG_INFO_DWARF4 y
  add_opt CONFIG_DEBUG_INFO_BTF y
  add_opt CONFIG_XDP_SOCKETS y
  # BPF_EVENTS 在 5.4 是非提示符号(default y), 依赖 KPROBE_EVENTS + PERF_EVENTS;
  # 这里显式写死, 若依赖不满足内核 oldconfig 会自动丢弃, 不影响编译。
  add_opt CONFIG_BPF_EVENTS y

  grep -q '^CONFIG_DEBUG_INFO=y'           "$GK" && ok "generic config: DEBUG_INFO=y"          || err "DEBUG_INFO 未打开"
  grep -q '^# CONFIG_DEBUG_INFO_REDUCED is not set$' "$GK" && ok "generic config: DEBUG_INFO_REDUCED off" || err "DEBUG_INFO_REDUCED 仍打开"
  grep -q '^CONFIG_DEBUG_INFO_BTF=y'       "$GK" && ok "generic config: DEBUG_INFO_BTF=y"      || err "DEBUG_INFO_BTF 未打开"
  grep -q '^CONFIG_XDP_SOCKETS=y'          "$GK" && ok "generic config: XDP_SOCKETS=y"         || err "XDP_SOCKETS 未打开"
  grep -q '^CONFIG_BPF_EVENTS=y'           "$GK" && ok "generic config: BPF_EVENTS=y"          || err "BPF_EVENTS 未打开"
fi

# KPROBES / KPROBE_EVENTS / FTRACE 走 .config 的 CONFIG_KERNEL_* (21.02 Config-kernel.in 里有这些符号),
# 不用改源码, 只在下面校验一下确实是可用符号。
CK=config/Config-kernel.in
# 注意: if 块里的符号带缩进, 所以用 ^\s*config 而不是 ^config
for sym in KERNEL_DEBUG_INFO KERNEL_FTRACE KERNEL_KPROBES KERNEL_KPROBE_EVENTS KERNEL_PERF_EVENTS KERNEL_CGROUPS KERNEL_CGROUP_BPF; do
  if grep -qE "^[[:space:]]*config $sym$" "$CK"; then
    ok "Config-kernel.in 有 $sym"
  else
    err "Config-kernel.in 缺少 $sym"
  fi
done

# 确认装进 package/ 的 OAF 是 destan19 的 7.0.1, 而不是 immortalwrt/packages 的同名包
# (两个 feed 都有 appfilter, 谁先被 feeds install 谁生效, 所以逐个核对 PKG_VERSION)
AF_MKS=$(grep -Rsl "PKG_NAME:=appfilter" package/feeds/ 2>/dev/null)
if [ -z "$AF_MKS" ]; then
  err "package/feeds 里找不到 appfilter"
else
  for mk in $AF_MKS; do
    if grep -q "PKG_VERSION:=7.0.1" "$mk"; then
      ok "appfilter = 7.0.1 ($mk)"
    else
      err "appfilter 不是 7.0.1: $mk ($(grep -m1 'PKG_VERSION' "$mk" || echo '?'))"
    fi
  done
fi

for mk in $(grep -Rsl "KernelPackage/oaf" package/feeds/ 2>/dev/null); do
  case "$mk" in
    package/feeds/oaf/*) ok "kmod-oaf 来自 destan19 ($mk)" ;;
    *) err "kmod-oaf 不是 destan19 的: $mk" ;;
  esac
done
[ -n "$(grep -Rsl 'KernelPackage/oaf' package/feeds/ 2>/dev/null)" ] || err "package/feeds 里找不到 kmod-oaf"

if [ -e package/feeds/packages/open-app-filter ]; then
  err "immortalwrt/packages 的 open-app-filter 也装上了, 会和 destan19 的 7.0.1 打架"
else
  ok "immortalwrt/packages 的 open-app-filter 已被 oaf feed 覆盖"
fi

for p in luci-app-oaf dae daed luci-app-daede vmlinux-btf; do
  if [ -n "$(find package/feeds -mindepth 2 -maxdepth 2 -name "$p" 2>/dev/null)" ]; then
    ok "$p 已装入 package/feeds"
  else
    err "$p 没有装入 package/feeds"
  fi
done

# ---------- 2. 最小品牌改动: 主机名 + 版本描述 ----------
if [ -f package/base-files/files/bin/config_generate ]; then
  sed -i "s/hostname='[^']*'/hostname='NatserverWrt'/g" package/base-files/files/bin/config_generate
  grep -q "hostname='NatserverWrt'" package/base-files/files/bin/config_generate \
    && ok "hostname -> NatserverWrt" || err "hostname NatserverWrt 未生效"
else
  err "找不到 package/base-files/files/bin/config_generate"
fi

if [ -f package/base-files/files/etc/openwrt_release ]; then
  grep -q "DISTRIB_DESCRIPTION='NatserverWrt" package/base-files/files/etc/openwrt_release || \
    echo "DISTRIB_DESCRIPTION='NatserverWrt RAX3000M eMMC + OAF7.0.1 + daed'" >> package/base-files/files/etc/openwrt_release
  ok "openwrt_release 描述已写入"
else
  err "找不到 package/base-files/files/etc/openwrt_release"
fi

# ---------- 3. feeds 校验 ----------
if ./scripts/feeds list 2>/dev/null | grep -qE '^(oaf|appfilter|luci-app-oaf|kmod-oaf)\b'; then
  ok "feeds 里有 OAF"
else
  err "feeds 里没有 OAF (diy-part1 的 oaf 源没生效)"
fi
if ./scripts/feeds list 2>/dev/null | grep -qE '^(dae|daed|luci-app-daede|vmlinux-btf)\b'; then
  ok "feeds 里有 dae/daed"
else
  err "feeds 里没有 dae/daed (diy-part1 的 daede 源没生效)"
fi

echo "===== feeds 摘要 ====="
./scripts/feeds list 2>/dev/null | grep -E '^(oaf|appfilter|luci-app-oaf|kmod-oaf|dae|daed|luci-app-daede|vmlinux-btf|golang)\b' || true

if [ "$fail" -ne 0 ]; then
  echo "ERROR: rax3000m diy-part2 检查失败" >&2
  exit 1
fi
echo "rax3000m diy-part2 done"
