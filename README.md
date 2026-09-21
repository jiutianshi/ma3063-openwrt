# RG-MA3063 自编译 OpenWrt — GitHub Actions 方案

云端编译，不依赖本机 WSL。本目录推到 GitHub 即自动出固件。

## 目录结构
```
.github/workflows/build.yml          # Actions 工作流（自动编译+上传产物）
files/target/linux/ipq50xx/dts/
      ipq5018-ruijie-ma3063.dts      # MA3063 设备树（基于 hzyitc rax3000q 模板移植）
config-ma3063.seed                  # 本地 WSL 编译用的 .config 片段
README.md
```

## 上游基线
- 源码：`hzyitc/openwrt-redmi-ax3000` 分支 `ipq50xx-mainline-kernel-5.15-openwrt-23.05`
  （OpenWrt 23.05.3 / ipq50xx，REITZ 移植 MA3063 所用的同一家族）
- 板子：`qcom,ipq5018-mp03.5-c1`（高通参考板，与 GL-iNET GL-B3000 同 reference）
- 交换芯片：QCA8337（SGMII，匹配 mp03.5-c1）
- 无线：2.4G=IPQ5018、5G=QCN6122（ath11k）

## GitHub 操作步骤
1. GitHub 新建一个**空仓库**（如 `ma3063-openwrt`），不要勾 README。
2. 把本目录全部内容推上去：
   ```bash
   git clone https://github.com/<你>/ma3063-openwrt.git
   cd ma3063-openwrt
   # 把 MA3063_GitHubActions 里的文件复制进来（含 .github/）
   git add -A && git commit -m "add ma3063 build" && git push
   ```
   或直接把 `MA3063_GitHubActions/` 下的文件作为仓库根内容上传。
3. 仓库 → **Actions** → 左侧 `Build OpenWrt for Ruijie RG-MA3063` → **Run workflow**。
4. 等约 30–60 分钟（首次更久）。完成后 **Artifacts** → `openwrt-ma3063` 下载。
5. 产物里要的是：
   - `openwrt-ipq50xx-aarch64-ruijie_rg-ma3063-nand-factory.ubi`（初刷用）
   - `openwrt-ipq50xx-aarch64-ruijie_rg-ma3063-squashfs-sysupgrade.tar`（升级用）

## 本地 WSL 编译（备选，WSL 装好后）
```bash
sudo apt update && sudo apt install -y build-essential clang flex bison g++ gawk \
  gcc-multilib gettext git libncurses5-dev libssl-dev python3-distutils rsync unzip zlib1g-dev
git clone --branch ipq50xx-mainline-kernel-5.15-openwrt-23.05 \
  https://github.com/hzyitc/openwrt-redmi-ax3000.git
cd openwrt-redmi-ax3000
# 放 DTS
cp <本目录>/files/target/linux/ipq50xx/dts/ipq5018-ruijie-ma3063.dts target/linux/ipq50xx/dts/
# 追加设备定义（同 build.yml 里的 heredoc）
cat >> target/linux/ipq50xx/image/Makefile <<'EOF'
...（同 build.yml）...
EOF
./scripts/feeds update -a && ./scripts/feeds install -a
cp <本目录>/config-ma3063.seed .config && make defconfig
make -j$(nproc) V=s
```

## 刷机提醒（务必先看 MA3063_TTL操作指南 / 进度与参数记录）
- 🔴 **ART（mtd13）备份是救砖唯一生命线**，刷前确认已落盘本地。
- 🔴 **NOMIBIB 安全流程**：uboot 下 tftpboot → 只写 rootfs（mtd15/16），**绝不刷 uboot / mibib**。
- 初刷用 `nand-factory.ubi`；后续升级用 `sysupgrade.tar`。
- uboot 网络：路由端 ipaddr 设 192.168.10.x，serverip=192.168.10.19（PC 网卡固定该 IP，开 tftpd64）。

## 首次构建「待验证」项（可能需 TTL 迭代）
1. **LED / 按键 GPIO**：当前用原厂 DTB 解码值（LED 17/19/22，reset=33，wps=18）。
   若灯不亮或按键无效，是此处偏差，不影响启动与网络。
2. **QCN6122 board_id / 5G BDF**：暂复用 `ipq-wifi-cmcc_rax3000q` 的板文件。
   2.4G（IPQ5018）应直接可用；5G 若功率/信道异常，需从本地 ART（mtd13）提取本机 BDF 替换。
3. **内存**：依赖 uboot 传入 512MB（原厂即 512MB），DTS 未硬写 /memory。
   若系统只认到 256MB，在 DTS 加 `/memory { reg = <0x0 0x40000000 0x0 0x20000000>; }`。
4. **交换芯片**：按 mp03.5-c1 用 QCA8337(SGMII)。若有线口不通，核对是否为 YT9215 方案。

> 这些都不影响「先编译出能启动的镜像」这个目标；首版重点验证：能否进系统、2.4G/5G 是否起、有线口是否通。
