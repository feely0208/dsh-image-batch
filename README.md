# @deepwhale-cn/dsh-image-batch

[![Listed on dsh-plugin.org](https://dsh-plugin.org/badges/listed.svg)](https://dsh-plugin.org/plugins/feely0208/dsh-image-batch)

**整目录的图片一次处理完**：批量压缩、按比例改尺寸、加文字水印、转格式、去 EXIF —— 不用打开修图软件，也不动原图。

**关键词**：图片批量压缩 · 批量改尺寸 · 批量加水印 · 图片转 WebP · 去掉 EXIF · 命令行压缩图片 · 商品图批量处理 · 朋友圈九宫格批量压

## 不装会怎样

一百张商品图要压到 1920 宽以内再上传：不装就得一张张拖进修图软件、导出、确认体积，做完一下午就没了；
压到第 60 张时手滑覆盖了原图，平台那边还得重新拍。

要给整批图打上公司水印、把 PNG 全转成 WebP 省流量、把照片里的拍摄地点（EXIF）清掉再发外网 ——
这些活机械但量大，人工慢、容易漏，让 AI 直接改原文件更没退路：改坏了没有备份。

这个插件一次处理整个目录：只读输入、产物写到单独的输出目录、同名不覆盖，
每一步都告诉你处理了几个、省了多少体积、哪些格式被跳过了。

## 能做什么

| 子命令 | 作用 | 产物（可核对） |
|---|---|---|
| `compress` | 批量压缩：`--max-width` 默认 1920，`--quality` 默认 82；JPEG/PNG/WebP 都支持 | 压缩后的图片；JSON 给出每个文件压缩前后的字节数 |
| `resize` | 按 `--max-width` / `--max-height` 等比缩放（只缩小，不放大） | 缩好的图片；JSON 给出原尺寸 → 新尺寸 |
| `watermark` | 加文字水印：`--text` 必填，`--position` 默认右下，`--opacity` 默认 0.55，字号默认短边 4% | 带水印的图片；JSON 给出实际字号、位置、字体 |
| `convert` | 批量转 `--format jpg/png/webp`；透明图转 JPG 时背景填白 | 转好格式的图片；JSON 给出 from → to 格式 |
| `strip` | 去掉 EXIF/元数据（拍摄设备、时间、GPS）；`--keep-exif` 保留做对照 | 干净图片；JSON 给出 EXIF 标签数 |

共同约定：

- **不修改输入文件**：只读，产物写进 `--out`，默认 `<输入目录>/_输出`；
- **同名不覆盖**：已存在时自动变成 `照片_1.jpg`、`照片_2.jpg`；
- 目录递归处理，支持 `jpg / jpeg / png / webp`；`.gif`、`.heic`、`.bmp`、`.tiff` 等**明确跳过并汇总**，不静默丢；
- 一张坏图不会拖垮整批：好图照出产物，坏图进 `failed` 清单，退出码 1；
- `--json` 输出结构化结果，方便脚本 / CI 断言。

```bash
# 整目录压缩到 1920 以内，质量 80
dsh-image-batch compress --input ./商品图 --out ./商品图_压缩 --max-width 1920 --quality 80

# 压缩并顺手转成 WebP（PNG 照片常用）
dsh-image-batch compress --input ./截图 --format webp --quality 78

# 统一缩到 1280 宽
dsh-image-batch resize --input ./照片 --max-width 1280

# 右下角打中文水印
dsh-image-batch watermark --input ./交付图 --text "© 深鲸科技" --opacity 0.5

# 转格式 / 去 EXIF
dsh-image-batch convert --input ./素材 --format jpg
dsh-image-batch strip --input ./外发 --out ./外发_干净
```

## 不能做什么

- ❌ **不是修图软件**：不做抠图、去水印、磨皮、调色、智能裁剪；`resize` 只做等比缩放，不裁画面。
- ❌ 不支持 `.gif`（动图会只剩一帧，所以直接跳过）、`.heic`、`.heif`、`.bmp`、`.tiff`、`.svg`、`.psd`、`.avif`；
  手机 HEIC 请先用「预览」导出成 JPG 再处理。
- ❌ **不是无损压缩**：JPEG/WebP 重新编码必然有损，`--quality` 越低越明显；PNG 没有 quality 参数，
  这里用 `--quality` 映射调色板颜色数（82 ≈ 200 色），属于**减色**，不是无损。
  要像素级不变只能 `strip`（对 JPEG 沿用原量化表，几乎不重压缩）。
- ❌ **不保留元数据**：compress / resize / watermark / convert 默认丢掉 EXIF 与 ICC；需要保留时加 `--keep-exif`，
  但方向（Orientation）会被去掉 —— 因为缩放时已经按 EXIF 方向把画面旋正，留着会二次旋转。
- ❌ 不处理 CMYK 专色印刷输出：CMYK JPEG 会转成 sRGB 的 RGB，印刷用途请别用它。
- ❌ 水印只支持**一行文字**：不换行、不旋转、不平铺、不支持图片/logo 水印；字体默认系统 PingFang，
  可用 `--font` 指定字体文件。
- ❌ 不批量重命名、不整理目录、不处理 PDF / 视频 / RAW；`--input` 不接受通配符（交给 shell 展开）。
- ✅ 全部在本机由 Pillow 处理，不联网、不上传图片。

## 安装

```bash
dsh plugin --profile web add @deepwhale-cn/dsh-image-batch
```

运行依赖本机的 **python3 + Pillow**（插件不会替你装）。缺依赖时 CLI 会直接打印安装命令，并以退出码 3 结束：

```bash
python3 -m pip install Pillow
# macOS 没有 python3 时
brew install python3
```

中文水印使用系统中文字体（优先 `/System/Library/Fonts/PingFang.ttc`，缺失时按顺序回退到其它系统中文字体）；
全都找不到时明确报「找不到可用的中文字体」并退出 3，不会画出一堆方块。纯英文水印可用 Pillow 内置字体兜底。

## 用法

```bash
dsh-image-batch --help
dsh-image-batch --demo        # 自造样例图跑完整流程，打印产物路径
dsh-image-batch <action> --input <文件或目录> [--out <目录>] [--json]
```

`--demo` 会在系统临时目录里造几张样例图（大照片、透明 PNG、WebP、带 EXIF 的 JPG、一个不支持的 GIF），
依次跑 compress / resize / watermark / convert / strip，不动你的任何文件，跑完直接看产物路径就知道它能干什么。

退出码：`0` 成功 · `1` 部分或全部文件处理失败 · `2` 参数/输入错误 · `3` 缺依赖（python3 / Pillow / 中文字体）。

## License

MIT © 温州深鲸智能科技有限公司
