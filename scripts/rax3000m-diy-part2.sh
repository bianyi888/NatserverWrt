#!/bin/bash
# rax3000m diy-part2: 在 ./scripts/feeds install -a 之后、cp .config 之前执行, 工作目录 = openwrt/
# 只补 21.02 (kernel 5.4 / OpenWrt 21.02) 缺的 dae/daed 依赖 + 最小品牌改动, 其余代码不动:
#   1. target/linux/generic/config-5.4: DEBUG_INFO/BTF/XDP/BPF_EVENTS
#   2. include/bpf.mk (21.02 根本没有, dae/daed 的 Makefile 会 include, 缺了连 make 解析都会失败)
#   3. config/Config-kernel.in: 补 KERNEL_DEBUG_INFO_BTF (dae/daed 的 BTF source 选项靠它)
#   4. feeds/packages/net/v2ray-geodata: 上游 2023 的 dlc.dat 已被删 (404), 换成仍存活的 tag
#   5. 主机名 / 版本描述

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

# ---------- 1b. 补 include/bpf.mk: 21.02 树里没有, 而 dae/daed 的 Makefile 都 include 它 ----------
# 没有它 make 解析 Makefile 就会报 "No such file", 导致 dae/daed 连 download/compile 目标都跑不到。
BPF_MK_SRC=""
for c in ../scripts/rax3000m-bpf.mk scripts/rax3000m-bpf.mk; do
  [ -f "$c" ] && BPF_MK_SRC="$c" && break
done
if [ -f include/bpf.mk ]; then
  ok "include/bpf.mk 已存在"
elif [ -n "$BPF_MK_SRC" ]; then
  cp "$BPF_MK_SRC" include/bpf.mk && ok "已补上 include/bpf.mk (来自 $BPF_MK_SRC)" || err "补 include/bpf.mk 失败"
else
  err "找不到 rax3000m-bpf.mk"
fi
if [ -f include/bpf.mk ] && grep -q 'BPF_KARCH:=' include/bpf.mk && grep -q 'BPF_HEADERS_DIR:=' include/bpf.mk \
   && grep -q 'ifneq ($(TOPDIR),)' include/bpf.mk; then
  ok "include/bpf.mk 内容正确 (BPF_KARCH / BPF_HEADERS_DIR / 强制走系统 clang)"
else
  err "include/bpf.mk 内容不对"
fi

# ---------- 1c. 补 KERNEL_DEBUG_INFO_BTF (21.02 的 Config-kernel.in 没有这个符号) ----------
# dae/daed 的 Makefile 里 choice 依赖 KERNEL_DEBUG_INFO_BTF, 符号不存在时只能退到
# vmlinux-btf 那条路 (要额外整棵树编一遍 shadow kernel, 又慢又容易挂), 所以这里补上。
CKI=config/Config-kernel.in
if grep -qE "^[[:space:]]*config KERNEL_DEBUG_INFO_BTF$" "$CKI"; then
  ok "Config-kernel.in 已有 KERNEL_DEBUG_INFO_BTF"
else
  awk '
    /^config KERNEL_DEBUG_INFO$/ { seen=1; print; next }
    seen == 1 && /^config / {
      print "config KERNEL_DEBUG_INFO_BTF"
      print "\tbool \"Compile with BPF Type Format (BTF) information\""
      print "\tdepends on KERNEL_DEBUG_INFO"
      print "\tdefault y"
      print "\thelp"
      print "\t  Generate BTF type info so CO-RE eBPF programs (dae/daed) can load."
      print "\t  Requires pahole (dwarves) on the build host."
      print ""
      seen=2
    }
    { print }
  ' "$CKI" > "$CKI.new" && mv "$CKI.new" "$CKI"
  grep -qE "^[[:space:]]*config KERNEL_DEBUG_INFO_BTF$" "$CKI" \
    && ok "已补 KERNEL_DEBUG_INFO_BTF 到 Config-kernel.in" || err "补 KERNEL_DEBUG_INFO_BTF 失败"
fi

# ---------- 1d. v2ray-geodata: 上游删掉了 2023 的 dlc.dat 资源, 换成仍存活的 tag ----------
GEO_MK=feeds/packages/net/v2ray-geodata/Makefile
GEO_VER=20260731025111
GEO_HASH=e2045f0da8823eb6edac0e08e56ac3b02edc94810d4e767c02d209bbb94efaa0
if [ -f "$GEO_MK" ]; then
  awk -v ver="$GEO_VER" -v hash="$GEO_HASH" '
    /^GEOSITE_VER:=/ { print "GEOSITE_VER:=" ver; next }
    /^define Download\/geosite$/ { inb=1; print; next }
    inb && /^ *HASH:=/ { print "  HASH:=" hash; next }
    inb && /^endef$/ { inb=0 }
    { print }
  ' "$GEO_MK" > "$GEO_MK.new" && mv "$GEO_MK.new" "$GEO_MK"
  grep -q "GEOSITE_VER:=$GEO_VER" "$GEO_MK" && grep -q "HASH:=$GEO_HASH" "$GEO_MK" \
    && ok "v2ray-geodata geosite 已指向 $GEO_VER" || err "v2ray-geodata 打补丁失败"
else
  err "找不到 $GEO_MK"
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
