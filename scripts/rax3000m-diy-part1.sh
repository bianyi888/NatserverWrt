#!/bin/bash
# rax3000m diy-part1: 在 ./scripts/feeds update 之前执行, 工作目录 = openwrt/
# 只接入本机型要用的插件源, 不改动源码里其它任何代码。

# daed 2026.x 需要新版 Go, 21.02 自带的 lang/golang 版本太老编不过,
# 所以把 kenzok8/golang 放在 packages 之前, 用它覆盖 feeds 里的同名包。
if ! grep -qF "kenzok8/golang" feeds.conf.default; then
  sed -i '1i src-git golang https://github.com/kenzok8/golang.git' feeds.conf.default
fi

# OAF (OpenAppFilter) 7.0.1 —— 图中 OAF 固件的同版本插件源。
# 注意: immortalwrt/packages 里也有 net/open-app-filter (appfilter/kmod-oaf 同名包),
# feeds 谁在前谁生效, 所以必须插在 packages 之前, 否则编进去的不是 7.0.1。
if ! grep -qF "destan19/OpenAppFilter" feeds.conf.default; then
  sed -i '1i src-git oaf https://github.com/destan19/OpenAppFilter.git' feeds.conf.default
fi

# kenzok8 的 dae/daed (提供 dae daed luci-app-daede vmlinux-btf)
if ! grep -qF "kenzok8/openwrt-daede" feeds.conf.default; then
  echo 'src-git daede https://github.com/kenzok8/openwrt-daede.git' >> feeds.conf.default
fi

# iStore 应用商店 (linkease/istore) —— 与参考脚本 imm.sh 装的是同一套包:
#   luci-app-store + luci-lib-taskd + luci-lib-xterm + taskd
# 源码编译进固件, 首次开机不依赖外网; 后续升级商店可直接跑 /usr/sbin/istore-setup。
# 该 feed 根目录下没有 Makefile, 包在 luci/ 二级目录, scripts/feeds 递归扫描能识别。
if ! grep -qF "linkease/istore" feeds.conf.default; then
  echo 'src-git istore https://github.com/linkease/istore.git' >> feeds.conf.default
fi

# iStore 同款主题 luci-theme-argon —— OpenWrt 21.02 必须用 luci-21 分支
# (master 面向新版 LuCI, 21.02 编不过)。放 package/ 而不是 feed, 免得 depth 不够扫不到。
if [ ! -f package/luci-theme-argon/Makefile ]; then
  rm -rf package/luci-theme-argon
  git clone --depth 1 -b luci-21 https://github.com/jjm2473/luci-theme-argon.git package/luci-theme-argon \
    || echo "WARN: 克隆 luci-theme-argon 失败 (网络?), 会在 diy-part2 检查时报错"
fi

echo "===== feeds.conf.default ====="
cat feeds.conf.default
