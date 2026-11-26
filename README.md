# 夏威夷果开罐器
适用于 Apple 芯片 Mac，需 macOS 12 或更新版本。

1. 从 [Releases](../../releases/latest) 下载 `ArchiveHere-v1.3.1-Installer.zip` 并解压，双击「安装夏威夷果开罐器.app」。
2. 在窗口中点左边的应用图标。进度条完成后，「夏威夷果开罐器.app」就位于「应用程序」。
3. 点右边的终端图标，按终端提示完成当前账户的默认打开方式设置。macOS 若显示确认提示，请按需确认。

此后可在访达中直接双击受支持的压缩包，解压到同一目录。已安装的解压应用无主窗口，完成后自动退出。如果某种格式显示关联失败，可在访达中选中该格式的文件，按 ⌘I，选择「打开方式 → 夏威夷果开罐器 → 全部更改」。

## 如果 macOS 提示无法验证开发者

本版本未经过 Apple 公证。尝试打开后，可在「系统设置 → 隐私与安全性」点「仍要打开」。
https://support.apple.com/zh-cn/102445

## 支持的常见格式

归档包括 RAR、7z、ZIP、ZIPX、TAR、CAB、LHA/LZH、CPIO、XAR 和 AR。
还支持 GZ、BZ2、XZ、LZIP、LZMA、Unix Compress（.Z）、Brotli、LZFSE、标准 LZ4 及各自的 TAR 组合后缀。
Zstandard（.zst）、加密包和分卷包暂不支持。

## 从源码构建

在 Apple 芯片 Mac 上安装 Xcode 命令行工具，然后运行 `./build-launcher.sh`。安装器生成在 `build/` 中。

## 1.3.1 修复

支持应用包和 Python.framework 使用的内部相对符号链接。仍拒绝硬链接、特殊文件、绝对链接、越界链接、循环及悬空链接，并保留解压期间的禁止跟随链接写入保护。发布单个目录前还会检查链接在移动后仍留在目录内部。

回归检查：`python3 tests/test_archive.py /绝对路径/夏威夷果开罐器.app/Contents/MacOS/ArchiveHere`。
