# 图片批量处理

**一句话**：整目录的图片一次处理完 —— 批量压缩、按比例改尺寸、加文字水印、转格式、去 EXIF。只读输入，产物单独输出，不覆盖原文件。

## 什么时候用

用户说这些话时用：

- 「把这批图片压缩一下」「压到 2MB 以内」「传到平台前压一压」「图太大了，帮我缩一下」
- 「统一缩到 1280 宽」「把这几百张图的尺寸改成一样」
- 「给这批图加上公司水印」「水印打在右下角，别太显眼」
- 「全部转成 WebP / 转成 JPG」「png 太多了，转 jpg」
- 「把照片里的 GPS/拍摄信息去掉再发出去」「清一下 EXIF」
- 用户给了一个装满图片的目录（常见于商品图、交付图、素材库），要求批量处理

## 怎么调用

```bash
<cli 路径> --help
```

```bash
# 批量压缩（--max-width 默认 1920，--quality 默认 82）
<cli 路径> compress --input <文件或目录> [--out <输出目录>] [--max-width 1920] [--quality 82] [--format webp] [--json]

# 按比例改尺寸（--max-width / --max-height 至少给一个；只缩小不放大）
<cli 路径> resize --input <文件或目录> [--out <输出目录>] [--max-width 1280] [--max-height 960] [--json]

# 加文字水印（--text 必填；--position 默认 bottom-right；--opacity 默认 0.55）
<cli 路径> watermark --input <文件或目录> [--out <输出目录>] --text "© 深鲸科技" \
  [--position bottom-right|bottom-left|top-right|top-left|center] [--opacity 0.55] \
  [--font-size 64] [--font <字体文件>] [--json]

# 转格式（jpg/png/webp；透明图转 jpg 时背景填白）
<cli 路径> convert --input <文件或目录> [--out <输出目录>] --format webp [--quality 90] [--json]

# 去 EXIF/元数据（--keep-exif 保留，用来对照）
<cli 路径> strip --input <文件或目录> [--out <输出目录>] [--keep-exif] [--json]

# 自造样例跑完整流程（不碰用户文件），推荐先跑这个确认环境正常
<cli 路径> --demo
```

## 输出约定（要向用户说清）

- **不修改输入文件**；输出默认写到 `<输入目录>/_输出`，可用 `--out` 指定。
- 同名产物不覆盖：自动变成 `照片_1.jpg`、`照片_2.jpg`。
- 目录递归处理，跳过 `_输出` 目录；支持 `jpg / jpeg / png / webp`。
- 其它格式（`.gif`、`.heic`、`.bmp`、`.tiff`、`.avif` …）**明确跳过并在汇总里点名**，不静默丢。
- 一张坏图不拖垮整批：好图照出产物，坏图进 `failed`，退出码 1。
- 退出码：`0` 成功 / `1` 处理失败 / `2` 参数或输入错误 / `3` 缺依赖（python3、Pillow、中文字体）。
- `--json` 时输出结构化结果（每个文件的产物路径、压缩前后字节数、新尺寸、实际字号/字体、EXIF 标签数）。

## 边界（必须向用户说清）

- **不是修图软件**：不抠图、不去水印、不磨皮、不智能裁剪；`resize` 只等比缩放，不裁画面。
- 不支持动图 GIF（会只剩一帧，所以直接跳过）、HEIC/HEIF、BMP、TIFF、SVG、PSD、AVIF；手机 HEIC 先用「预览」导出 JPG。
- **不是无损压缩**：JPEG/WebP 重编码必然有损；PNG 的 `--quality` 是映射调色板颜色数（82 ≈ 190 色），属于减色。
  想像素级不变只能用 `strip`（对 JPEG 沿用原量化表）。
- 默认**丢弃 EXIF/ICC**（外发更安全）；`--keep-exif` 可保留，但方向标签会被去掉（缩放时已按 EXIF 方向旋正，留着会二次旋转）。
- CMYK JPEG 会转成 sRGB；印刷用途不要用它。
- 水印只支持一行文字：不换行、不旋转、不平铺、不支持图片/logo；中文用系统 PingFang，找不到会明确报错（退出 3），
  不会画出方块字；纯英文可用 Pillow 内置字体兜底。
- 不批量重命名、不整理目录、不处理 PDF/视频/RAW；`--input` 不吃通配符（交给 shell 展开）。
- 缺 `python3` 或 `Pillow` 时明确打印 `python3 -m pip install Pillow`，不静默失败。
- 不联网、不上传图片，全部在本机处理。
