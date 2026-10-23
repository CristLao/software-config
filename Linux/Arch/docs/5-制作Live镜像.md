<h1><center>制作 Live 镜像</center></h1>

用 archiso 把当前系统做成可启动 ISO, 含 KDE 全套桌面和常用系统配置, 不含 AUR 包.
产物放入 Ventoy U 盘, 启动后进入与当前系统一致的便携环境, live 为内存运行, 改动重启即失.

参考: [ArchWiki archiso](https://wiki.archlinux.org/title/archiso)

# 定制 profile

```bash
sudo pacman -S archiso
cp -r /usr/share/archiso/configs/releng ~/archlive
```

# 加入 KDE 包

编辑 `~/archlive/packages.x86_64`, 末尾追加:

```
plasma-meta
kde-applications-meta
sddm
noto-fonts-cjk
fcitx5
fcitx5-chinese-addons
fcitx5-configtool
```

# 自动登录进桌面

不配置则启动后停在字符终端.

```bash
mkdir -p ~/archlive/airootfs/etc/systemd/system/multi-user.target.wants
ln -s /usr/lib/systemd/system/sddm.service ~/archlive/airootfs/etc/systemd/system/multi-user.target.wants/

mkdir -p ~/archlive/airootfs/etc/sddm.conf.d
nvim ~/archlive/airootfs/etc/sddm.conf.d/autologin.conf
# 写入以下内容, root 自动登录进 Plasma X11 会话:
# [Autologin]
# User=root
# Session=plasma
#
# [Users]
# MinimumUid=0
```

# 携带系统配置

用户配置写入 `airootfs/root/`, 因为 live 默认用户是 root.

```bash
mkdir -p ~/archlive/airootfs/etc/pacman.d
cp /etc/pacman.conf ~/archlive/airootfs/etc/          # multilib, archlinuxcn 源
cp /etc/pacman.d/mirrorlist ~/archlive/airootfs/etc/pacman.d/  # 国内镜像

mkdir -p ~/archlive/airootfs/root/.config/environment.d
cp -L ~/.config/environment.d/* ~/archlive/airootfs/root/.config/environment.d/  # 输入法环境变量, 不拷则 fcitx5 不可用
cp ~/.gitconfig ~/archlive/airootfs/root/
```

注意:

1. dotfiles 管理的文件常是软链接, 拷贝用 `cp -L` 解引用, 否则 live 里链接悬空失效
2. `/etc/fstab` 绝不能拷, live 会据此挂载本机分区
3. grub / mkinitcpio / hostname 拷了没用, live 用自己的引导; `~/.ssh` 别放进镜像

# 构建

```bash
sudo mkarchiso -v -w ~/archiso-work ~/archlive # 工作目录放磁盘, 勿放 /tmp
ls ~/archlive/out/ # 产物 archlinux-<日期>-x86_64.iso
```

成功标志: 日志末尾出现 `[mkarchiso] INFO: Done!`, 产物在 profile 目录的 `out/` 子目录, KDE 全套约 3.6G.

工作目录选择:

- 中间产物(包缓存 + 解包 + squashfs)可达 15GB+, 需放在磁盘分区
- `/tmp` 常是 tmpfs 内存盘, 容量小(如 7.7G), 放 `/tmp` 会写满报错:
  `error: could not extract ... (Write failed)` → `Failed to install packages to new root`
- 写满后清理残留: `sudo rm -rf /tmp/archiso-tmp`, 再换目录重新构建

# 使用

产物拷进 Ventoy U 盘, 重启选 U 盘启动, root 无密码直接进 KDE 桌面. 进入后验证: 中文输入可用, 终端和网络正常, 再关机.

# 注意

1. AUR 包不含在内, 需要时 live 内手动安装
2. live 内用 archlinuxcn 源装包, 先执行 `pacman -Sy archlinuxcn-keyring`
3. 构建临时目录 `-w` 需 10GB+ 空间, 构建约 30-60 分钟
4. NVIDIA 显卡 live 无独有驱动, 3D 性能弱
5. 大文件临时操作注意 `/tmp` 是否 tmpfs: 内存盘容量小, 大压缩包/构建操作都可能写满
