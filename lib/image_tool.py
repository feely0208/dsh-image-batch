#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dsh-image-batch 的真实处理逻辑（Pillow）

由 bin/cli.mjs 通过 spawnSync 调用：
    python3 lib/image_tool.py <action> '<json payload>'
约定：
  - stdout 只输出一行 JSON（最后一行），人类可读文案由 Node 侧负责
  - stderr 输出异常栈（调试用）
  - 退出码：0 成功 / 1 运行失败 / 2 参数或输入问题 / 3 缺依赖（Pillow 或字体）
  - 只读输入文件，所有产物写进 --out 目录（默认 <输入目录>/_输出），同名不覆盖
"""

import glob
import json
import os
import re
import sys
import tempfile
import traceback
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont, ImageOps
except ImportError as exc:  # 缺依赖必须明确提示安装命令，不能静默
    print(json.dumps({
        "ok": False,
        "code": 3,
        "message": "缺少 Python 依赖：%s" % getattr(exc, "name", exc),
        "hint": "请先安装 Pillow：\n  python3 -m pip install Pillow\n"
                "如果 python3 也没有：\n  macOS: brew install python3\n  Ubuntu: sudo apt install python3",
    }, ensure_ascii=False))
    sys.exit(3)

SUPPORTED = {".jpg", ".jpeg", ".png", ".webp"}
SUPPORTED_LABEL = "jpg / jpeg / png / webp"

# 目录里出现这些格式时不静默吞掉，汇总到 skipped 里告诉用户
OTHER_IMAGE_EXTS = {
    ".gif", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".avif", ".ico", ".svg",
    ".psd", ".jfif", ".jp2", ".jxl", ".raw", ".cr2", ".nef", ".arw", ".dng",
}

SKIP_DIRS = {
    "_输出", "node_modules", ".git", "__pycache__", ".venv", "venv", "dist", "build",
}

# --position 的写法都收：完整名 / 两字母缩写 / 中文
POSITIONS = {
    "bottom-right": "bottom-right", "bottomright": "bottom-right", "br": "bottom-right", "右下": "bottom-right",
    "bottom-left": "bottom-left", "bottomleft": "bottom-left", "bl": "bottom-left", "左下": "bottom-left",
    "top-right": "top-right", "topright": "top-right", "tr": "top-right", "右上": "top-right",
    "top-left": "top-left", "topleft": "top-left", "tl": "top-left", "左上": "top-left",
    "center": "center", "centre": "center", "c": "center", "居中": "center", "中间": "center",
}

FORMATS = {"jpg", "jpeg", "png", "webp"}

# 风格：真实照片优先，短边 4% 的字号在这些字体下都可读
FONT_PINGFANG = "/System/Library/Fonts/PingFang.ttc"
FONT_FALLBACKS = [
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
]


# ── 错误与输出 ────────────────────────────────────────────────────

class ToolError(Exception):
    def __init__(self, message, hint="", code=2):
        super().__init__(message)
        self.message = message
        self.hint = hint
        self.code = code


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False))


def natural_key(text):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", text)]


def fmt_bytes(n):
    units = ["B", "KB", "MB", "GB"]
    value, i = float(n), 0
    while value >= 1024 and i < len(units) - 1:
        value /= 1024.0
        i += 1
    return ("%.0f %s" if (value >= 100 or i == 0) else "%.1f %s") % (value, units[i])


# ── 参数校验 ──────────────────────────────────────────────────────

def int_opt(payload, key, default):
    raw = payload.get(key)
    if raw is None or raw == "":
        return default
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise ToolError("参数 %s 需要整数，收到：%s" % (key, raw), "例：--%s 1920" % key.replace("_", "-"))
    if value <= 0:
        raise ToolError("参数 %s 必须大于 0，收到：%s" % (key, value), "例：--%s 1920" % key.replace("_", "-"))
    return value


def quality_opt(payload, default):
    value = int_opt(payload, "quality", default)
    if not 1 <= value <= 100:
        raise ToolError("--quality 必须在 1~100 之间，收到：%s" % value, "例：--quality 82")
    return value


def opacity_opt(payload, default=0.55):
    raw = payload.get("opacity")
    if raw is None or raw == "":
        return default
    try:
        value = float(raw)
    except (TypeError, ValueError):
        raise ToolError("--opacity 需要 0~1 的小数，收到：%s" % raw, "例：--opacity 0.55")
    if not 0 <= value <= 1:
        raise ToolError("--opacity 必须在 0~1 之间，收到：%s" % raw, "例：--opacity 0.55")
    return value


def normalize_position(raw):
    key = str(raw).strip().lower()
    if key in POSITIONS:
        return POSITIONS[key]
    raise ToolError(
        "不支持的 --position：%s" % raw,
        "可选：bottom-right（默认）/ bottom-left / top-right / top-left / center；"
        "也接受 br / bl / tr / tl / center。",
    )


def output_ext(payload):
    """compress 可选的 --format：把产物换成另一种格式（如 PNG → WebP）。"""
    raw = payload.get("format")
    if raw is None or raw == "":
        return None, None
    value = str(raw).strip().lower()
    if value not in FORMATS:
        raise ToolError("不支持的 --format：%s" % raw, "可选：jpg / png / webp")
    if value == "jpeg":
        value = "jpg"
    return value, "." + value


# ── 路径与文件收集 ────────────────────────────────────────────────

def resolve_out(payload, input_path):
    """输出目录：--out 优先，否则 <输入目录>/_输出（单文件时用其所在目录）。"""
    out = payload.get("out")
    if out:
        return Path(out).expanduser().resolve()
    base = Path(input_path).expanduser().resolve()
    if not base.is_dir():
        base = base.parent
    return base / "_输出"


def collect_images(input_path, out_dir=None):
    """接受单张图片或目录（递归），返回 (待处理文件, 被跳过的其它格式)。"""
    if not input_path:
        raise ToolError("缺少 --input（文件或目录）", "例：compress --input ./图片目录")
    root = Path(input_path).expanduser().resolve()
    if not root.exists():
        raise ToolError(
            "输入不存在：%s" % input_path,
            "请检查路径是否正确；传目录会递归处理其中的图片。",
        )
    if root.is_file():
        if root.suffix.lower() in SUPPORTED:
            return [root], []
        raise ToolError(
            "不是支持的图片格式：%s" % root.name,
            "支持：%s。其它格式（gif/heic/bmp 等）请先转成这几种。" % SUPPORTED_LABEL,
        )

    skip_out = str(out_dir.resolve()) if out_dir else None
    root_key = str(root)
    files, skipped = [], []
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        dirnames[:] = sorted(
            [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")],
            key=natural_key,
        )
        # 只跳过「输出目录」本身（嵌套在输入目录里时），输入目录自己不能跳过
        if skip_out and skip_out != root_key and str(current.resolve()) == skip_out:
            dirnames[:] = []
            continue
        for name in filenames:
            if name.startswith("."):
                continue  # .DS_Store / ._xxx 资源分叉文件
            path = current / name
            ext = path.suffix.lower()
            if ext in SUPPORTED:
                files.append(path)
            elif ext in OTHER_IMAGE_EXTS:
                skipped.append({
                    "input_name": str(path.relative_to(root)),
                    "reason": "不支持的格式 %s" % ext,
                })
    files.sort(key=lambda p: natural_key(str(p.relative_to(root))))
    skipped.sort(key=lambda s: natural_key(s["input_name"]))

    if not files:
        kind_set = "、".join(sorted({Path(s["input_name"]).suffix.lower() for s in skipped}))
        hint = "支持：%s。" % SUPPORTED_LABEL
        if skipped:
            hint = "目录里的图片都不是支持的格式（%s，共 %d 个）。%s" % (kind_set, len(skipped), hint)
        raise ToolError("目录里没有可处理的图片：%s" % root, hint)
    return files, skipped


def unique_path(directory, filename):
    """同名文件不覆盖，追加 _1/_2 序号。"""
    directory = Path(directory)
    target = directory / filename
    if not target.exists():
        return target
    stem, suffix = target.stem, target.suffix
    n = 1
    while (directory / ("%s_%d%s" % (stem, n, suffix))).exists():
        n += 1
    return directory / ("%s_%d%s" % (stem, n, suffix))


# ── 字体 ──────────────────────────────────────────────────────────

def pingfang_asset_paths():
    """macOS 新版把 PingFang 收进了 AssetsV2（不在 /System/Library/Fonts 下）。"""
    return sorted(glob.glob(
        "/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc"
    ))


def font_candidates(explicit=None):
    candidates = []
    if explicit:
        candidates.append(str(explicit))
    candidates.append(FONT_PINGFANG)
    candidates.extend(pingfang_asset_paths())
    candidates.extend(FONT_FALLBACKS)
    seen, ordered = set(), []
    for path in candidates:
        if path not in seen:
            seen.add(path)
            ordered.append(path)
    return ordered


def load_font(size, explicit=None):
    """按顺序找一个能真正渲染的字体；全都没有就明确报错，不静默画方块。"""
    if explicit:
        # 用户点名了字体：它不可用就直接报错，不偷偷换成别的字体
        path = str(explicit)
        try:
            if not os.path.exists(path):
                raise OSError("文件不存在")
            return ImageFont.truetype(path, size), path
        except OSError as exc:
            raise ToolError(
                "字体文件无法加载：%s（%s）" % (path, exc),
                "用 --font 指定一个真实存在的 .ttf/.ttc 字体文件；"
                "或去掉 --font 使用系统自带的 PingFang（%s）。" % FONT_PINGFANG,
                code=3,
            )
    tried = []
    for path in font_candidates():
        if not os.path.exists(path):
            tried.append(path)
            continue
        try:
            return ImageFont.truetype(path, size), path
        except OSError:
            tried.append(path)
    raise ToolError(
        "找不到可用的中文字体：%s" % FONT_PINGFANG,
        "已尝试：\n  %s\n"
        "macOS 一般自带 PingFang（/System/Library/Fonts 或 /System/Library/AssetsV2 下）；"
        "被裁剪时可用 --font <字体文件> 指定，或把水印文字换成纯英文（会用 Pillow 内置字体）。"
        % "\n  ".join(tried),
        code=3,
    )


def resolve_font(size, explicit, text):
    """纯英文且系统没字体时退回 Pillow 内置字体；中文必须用系统字体。"""
    try:
        return load_font(size, explicit)
    except ToolError:
        if explicit or any(ord(ch) > 127 for ch in text):
            raise
        try:
            font = ImageFont.load_default(size=size)
        except TypeError:  # 老版本 Pillow 不支持 size 参数
            font = ImageFont.load_default()
        return font, "Pillow 内置字体"


# ── 图像读写 ──────────────────────────────────────────────────────

def has_alpha(im):
    if im.mode in ("RGBA", "LA", "PA"):
        return True
    return im.mode == "P" and "transparency" in im.info


def flatten_white(im):
    """JPEG 没有透明通道：透明区域填白（而不是填黑）。"""
    if has_alpha(im):
        base = Image.new("RGB", im.size, (255, 255, 255))
        rgba = im.convert("RGBA")
        base.paste(rgba, (0, 0), rgba)
        return base
    return im.convert("RGB")


def load_image(src):
    """读入并解码（先按 EXIF 方向旋正，避免生成歪的缩略图）。"""
    with Image.open(str(src)) as im:
        im.load()
        raw_exif = im.info.get("exif")
        try:
            img = ImageOps.exif_transpose(im)
        except Exception:  # EXIF 方向信息残缺：保持原样
            img = im.copy()
        img = img.copy()
    return img, raw_exif


def exif_for_save(raw, keep):
    """--keep-exif 时保留元数据，但去掉 Orientation（方向已经烘焙进像素）。"""
    if not keep or not raw:
        return None
    try:
        exif = Image.Exif()
        exif.load(raw)
        exif.pop(0x0112, None)
        return exif
    except Exception:
        return None


def png_colors(quality):
    """把 --quality 映射成 PNG 调色板颜色数：82 → 约 200 色。"""
    q = max(1, min(100, int(quality)))
    return max(8, min(256, int(round(256 * (q / 100.0) ** 1.3))))


def save_image(im, target, quality=None, exif=None, quantize_png=False):
    """按目标扩展名保存；PNG 没有 quality 参数，用调色板量化来体现质量档位。"""
    ext = target.suffix.lower()
    kwargs = {"exif": exif} if exif is not None else {}
    if ext in (".jpg", ".jpeg"):
        out = flatten_white(im)
        q = 90 if quality is None else int(quality)
        out.save(str(target), "JPEG", quality=q, optimize=True, progressive=True, **kwargs)
    elif ext == ".png":
        out = im
        if quantize_png and quality is not None and quality < 95:
            colors = png_colors(quality)
            if has_alpha(out):
                out = out.convert("RGBA").quantize(
                    colors=colors, method=Image.Quantize.FASTOCTREE
                )
            else:
                out = out.convert("RGB").quantize(
                    colors=colors, method=Image.Quantize.MEDIANCUT
                )
        elif out.mode not in ("RGB", "RGBA", "P", "L", "LA"):
            out = out.convert("RGBA" if has_alpha(out) else "RGB")
        out.save(str(target), "PNG", optimize=True, **kwargs)
    elif ext == ".webp":
        out = im
        if out.mode not in ("RGB", "RGBA"):
            out = out.convert("RGBA" if has_alpha(out) else "RGB")
        q = 90 if quality is None else int(quality)
        out.save(str(target), "WEBP", quality=q, method=6, **kwargs)
    else:
        raise ToolError("不支持的输出格式：%s" % ext, "支持：%s。" % SUPPORTED_LABEL)


def image_format(path):
    try:
        with Image.open(str(path)) as im:
            return im.format or ""
    except Exception:
        return ""


def exif_tag_count(path):
    try:
        with Image.open(str(path)) as im:
            return len(im.getexif())
    except Exception:
        return 0


def make_record(src, target, im, extra=None):
    record = {
        "input": str(src),
        "input_name": src.name,
        "output": str(target),
        "output_name": target.name,
        "input_bytes": src.stat().st_size,
        "output_bytes": target.stat().st_size,
        "width": im.width,
        "height": im.height,
        "format": image_format(target),
    }
    if extra:
        record.update(extra)
    return record


# ── 结果组装 ──────────────────────────────────────────────────────

def size_note(records):
    total_in = sum(r["input_bytes"] for r in records)
    total_out = sum(r["output_bytes"] for r in records)
    if not records:
        return ""
    if total_in and total_out <= total_in:
        return "%s → %s（省 %d%%）" % (
            fmt_bytes(total_in), fmt_bytes(total_out),
            round((1 - total_out / float(total_in)) * 100),
        )
    return "%s → %s" % (fmt_bytes(total_in), fmt_bytes(total_out))


def compose_summary(head, records, skipped, failed, size=True):
    text = head
    if records and size:
        text += "：" + size_note(records)
    if skipped:
        kinds = "、".join(sorted({Path(s["input_name"]).suffix.lower() for s in skipped}))
        text += "；跳过 %d 个不支持的格式（%s）" % (len(skipped), kinds)
    if failed:
        text += "；%d 个文件处理失败" % len(failed)
    return text


def build_result(action, raw_input, out, records, skipped, failed, summary, extra=None):
    result = {
        "ok": True,
        "action": action,
        "input": str(Path(raw_input).expanduser().resolve()),
        "out": str(out),
        "files": records,
        "skipped": skipped,
        "failed": failed,
        "input_bytes": sum(r["input_bytes"] for r in records),
        "output_bytes": sum(r["output_bytes"] for r in records),
        "artifacts": [r["output"] for r in records],
        "summary": summary,
    }
    if extra:
        result.update(extra)
    return result


def begin(payload):
    raw_input = payload.get("input")
    if not raw_input:
        raise ToolError("缺少 --input（文件或目录）", "例：compress --input ./图片目录")
    out = resolve_out(payload, raw_input)
    files, skipped = collect_images(raw_input, out)
    out.mkdir(parents=True, exist_ok=True)
    return raw_input, files, skipped, out


# ── 各动作 ────────────────────────────────────────────────────────

def action_compress(payload):
    raw_input, files, skipped, out = begin(payload)
    max_width = int_opt(payload, "max_width", 1920)
    quality = quality_opt(payload, 82)
    keep_exif = bool(payload.get("keep_exif"))
    want_format, want_ext = output_ext(payload)

    records, failed = [], []
    for src in files:
        try:
            img, raw_exif = load_image(src)
            if img.width > max_width:
                ratio = max_width / float(img.width)
                img = img.resize(
                    (max_width, max(1, int(round(img.height * ratio)))), Image.LANCZOS
                )
            name = (src.stem + want_ext) if want_ext else src.name
            target = unique_path(out, name)
            save_image(
                img, target, quality=quality,
                exif=exif_for_save(raw_exif, keep_exif), quantize_png=True,
            )
            records.append(make_record(src, target, img))
        except ToolError:
            raise
        except Exception as exc:  # 一张坏图不该拖垮整批
            failed.append({"input_name": src.name, "reason": str(exc)})

    return build_result(
        "compress", raw_input, out, records, skipped, failed,
        compose_summary("压缩 %d 个文件" % len(records), records, skipped, failed),
        {"options": {"max_width": max_width, "quality": quality, "format": want_format}},
    )


def action_resize(payload):
    max_width = int_opt(payload, "max_width", None)
    max_height = int_opt(payload, "max_height", None)
    if not max_width and not max_height:
        raise ToolError(
            "resize 需要 --max-width 或 --max-height",
            "例：resize --input ./图片 --max-width 1280（只缩小，不放大）",
        )
    quality = quality_opt(payload, 92)
    keep_exif = bool(payload.get("keep_exif"))
    raw_input, files, skipped, out = begin(payload)

    records, failed = [], []
    for src in files:
        try:
            img, raw_exif = load_image(src)
            width, height = img.size
            scale = 1.0
            if max_width:
                scale = min(scale, max_width / float(width))
            if max_height:
                scale = min(scale, max_height / float(height))
            if scale < 1:
                img = img.resize(
                    (max(1, int(round(width * scale))), max(1, int(round(height * scale)))),
                    Image.LANCZOS,
                )
            target = unique_path(out, src.name)
            save_image(img, target, quality=quality,
                       exif=exif_for_save(raw_exif, keep_exif))
            records.append(make_record(src, target, img, {
                "src_width": width, "src_height": height,
            }))
        except ToolError:
            raise
        except Exception as exc:
            failed.append({"input_name": src.name, "reason": str(exc)})

    limit = []
    if max_width:
        limit.append("最宽 %d" % max_width)
    if max_height:
        limit.append("最高 %d" % max_height)
    head = "缩放 %d 个文件（%s，只缩小不放大）" % (len(records), "、".join(limit))
    return build_result(
        "resize", raw_input, out, records, skipped, failed,
        compose_summary(head, records, skipped, failed, size=False),
        {"options": {"max_width": max_width, "max_height": max_height, "quality": quality}},
    )


def place_text(position, text_w, text_h, width, height, margin):
    if position == "bottom-right":
        return max(margin, width - text_w - margin), max(margin, height - text_h - margin)
    if position == "bottom-left":
        return margin, max(margin, height - text_h - margin)
    if position == "top-right":
        return max(margin, width - text_w - margin), margin
    if position == "top-left":
        return margin, margin
    return max(0, (width - text_w) // 2), max(0, (height - text_h) // 2)


def action_watermark(payload):
    text = str(payload.get("text") or "")
    if not text.strip():
        raise ToolError(
            "缺少 --text（水印文字）",
            '例：watermark --input ./图片 --text "© 深鲸科技" --position bottom-right',
        )
    position = normalize_position(payload.get("position") or "bottom-right")
    opacity = opacity_opt(payload, 0.55)
    fixed_size = int_opt(payload, "font_size", None)
    if fixed_size is not None and fixed_size < 4:
        raise ToolError("--font-size 太小：%s" % fixed_size, "至少 4 像素；默认取图片短边的 4%。")
    explicit_font = payload.get("font") or os.environ.get("DSH_IMAGE_FONT")
    quality = quality_opt(payload, 92)
    keep_exif = bool(payload.get("keep_exif"))
    raw_input, files, skipped, out = begin(payload)

    alpha = max(1, min(255, int(round(255 * opacity))))
    records, failed = [], []
    for src in files:
        try:
            img, raw_exif = load_image(src)
            canvas = img.convert("RGBA")
            width, height = canvas.size
            size = fixed_size or max(8, int(round(min(width, height) * 0.04)))
            font, font_path = resolve_font(size, explicit_font, text)
            probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
            stroke = max(1, int(round(size / 20)))
            # 长文字自动缩到画面宽度的 90% 以内，避免被裁掉
            for _ in range(14):
                bbox = probe.textbbox((0, 0), text, font=font, stroke_width=stroke)
                text_w, text_h = bbox[2] - bbox[0], bbox[3] - bbox[1]
                if text_w <= width * 0.9 or size <= 8:
                    break
                size = max(8, int(size * 0.88))
                font, font_path = resolve_font(size, explicit_font, text)
                stroke = max(1, int(round(size / 20)))
            margin = max(8, int(round(min(width, height) * 0.03)))
            x, y = place_text(position, text_w, text_h, width, height, margin)

            layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
            draw = ImageDraw.Draw(layer)
            draw.text(
                (x - bbox[0], y - bbox[1]), text, font=font,
                fill=(255, 255, 255, alpha),
                stroke_width=stroke, stroke_fill=(0, 0, 0, int(alpha * 0.6)),
            )
            composited = Image.alpha_composite(canvas, layer)
            target = unique_path(out, src.name)
            save_image(composited, target, quality=quality,
                       exif=exif_for_save(raw_exif, keep_exif))
            records.append(make_record(src, target, composited, {
                "font_size": size,
                "position": position,
                "font": Path(font_path).name,
            }))
        except ToolError:
            raise
        except Exception as exc:
            failed.append({"input_name": src.name, "reason": str(exc)})

    head = "给 %d 个文件加水印「%s」（%s）" % (len(records), text, position)
    return build_result(
        "watermark", raw_input, out, records, skipped, failed,
        compose_summary(head, records, skipped, failed),
        {"options": {"text": text, "position": position, "opacity": opacity, "quality": quality}},
    )


def action_convert(payload):
    raw = payload.get("format")
    if raw is None or str(raw).strip() == "":
        raise ToolError(
            "缺少 --format（目标格式）",
            "例：convert --input ./图片 --format webp（可选 jpg / png / webp）",
        )
    value = str(raw).strip().lower()
    if value not in FORMATS:
        raise ToolError("不支持的 --format：%s" % raw, "可选：jpg / png / webp。")
    if value == "jpeg":
        value = "jpg"
    ext = "." + value
    quality = quality_opt(payload, 90)
    keep_exif = bool(payload.get("keep_exif"))
    raw_input, files, skipped, out = begin(payload)

    records, failed = [], []
    for src in files:
        try:
            img, raw_exif = load_image(src)
            out_img = flatten_white(img) if value == "jpg" else img
            target = unique_path(out, src.stem + ext)
            save_image(out_img, target, quality=quality,
                       exif=exif_for_save(raw_exif, keep_exif))
            records.append(make_record(src, target, out_img, {
                "from_format": image_format(src),
                "to_format": image_format(target),
            }))
        except ToolError:
            raise
        except Exception as exc:
            failed.append({"input_name": src.name, "reason": str(exc)})

    head = "转换 %d 个文件为 %s" % (len(records), value.upper())
    return build_result(
        "convert", raw_input, out, records, skipped, failed,
        compose_summary(head, records, skipped, failed),
        {"options": {"format": value, "quality": quality}},
    )


def action_strip(payload):
    keep_exif = bool(payload.get("keep_exif"))
    raw_input, files, skipped, out = begin(payload)

    records, failed = [], []
    for src in files:
        try:
            target = unique_path(out, src.name)
            with Image.open(str(src)) as im:
                im.load()
                raw_exif = im.info.get("exif")
                fmt = (im.format or "").upper()
                if keep_exif:
                    # 明确保留：只重新落盘，不删元数据（用于对照/不破坏性保存）
                    save_image(im, target, quality=95, exif=raw_exif)
                elif fmt == "JPEG" and im.mode in ("RGB", "L"):
                    # quality='keep' 沿用原量化表，像素几乎不变，元数据自然不写入
                    im.save(str(target), "JPEG", quality="keep", subsampling="keep", optimize=True)
                else:
                    save_image(im, target, quality=95)
            with Image.open(str(target)) as saved:
                out_width, out_height = saved.size
            records.append({
                "input": str(src),
                "input_name": src.name,
                "output": str(target),
                "output_name": target.name,
                "input_bytes": src.stat().st_size,
                "output_bytes": target.stat().st_size,
                "width": out_width,
                "height": out_height,
                "format": image_format(target),
                "exif_removed": not keep_exif,
                "exif_tags": exif_tag_count(target),
            })
        except ToolError:
            raise
        except Exception as exc:
            failed.append({"input_name": src.name, "reason": str(exc)})

    head = ("清除 %d 个文件的 EXIF/元数据" if not keep_exif
            else "保留 EXIF 重新保存 %d 个文件（--keep-exif）") % len(records)
    return build_result(
        "strip", raw_input, out, records, skipped, failed,
        compose_summary(head, records, skipped, failed),
        {"options": {"keep_exif": keep_exif}},
    )


# ── demo ─────────────────────────────────────────────────────────

def _demo_photo(path, size, quality=95, exif=None):
    noise = Image.effect_noise(size, 56).convert("RGB")
    gradient = Image.linear_gradient("L").resize(size).convert("RGB")
    img = Image.blend(noise, gradient, 0.45)
    kwargs = {"quality": quality}
    if exif is not None:
        kwargs["exif"] = exif
    img.save(str(path), **kwargs)


def _demo_transparent(path, size):
    width, height = size
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse((width * 0.10, height * 0.10, width * 0.60, height * 0.70),
                 fill=(36, 140, 214, 220))
    draw.rounded_rectangle((width * 0.45, height * 0.40, width * 0.90, height * 0.85),
                           radius=24, fill=(250, 180, 60, 200))
    img.save(str(path), optimize=True)


def _demo_exif():
    exif = Image.Exif()
    exif[0x010F] = "DeepWhale"
    exif[0x0110] = "DemoCam"
    exif[0x0132] = "2026:10:24 12:00:00"
    exif[0x0112] = 1
    return exif


def _demo_gif(path):
    frames = []
    for i in range(4):
        frame = Image.new("RGB", (160, 160), (20 + i * 40, 90, 160))
        ImageDraw.Draw(frame).rectangle((20, 20 + i * 20, 140, 60 + i * 20),
                                        fill=(250, 230, 90))
        frames.append(frame)
    frames[0].save(str(path), save_all=True, append_images=frames[1:], duration=200, loop=0)


def action_demo(payload):
    root = Path(tempfile.mkdtemp(prefix="dsh-image-batch-demo-"))
    inputs = root / "样例图"
    inputs.mkdir(parents=True, exist_ok=True)
    _demo_photo(inputs / "样例照片.jpg", (2400, 1600))
    _demo_transparent(inputs / "样例透明.png", (1200, 900))
    _demo_photo(inputs / "样例图.webp", (1600, 1000), quality=92)
    _demo_photo(inputs / "样例EXIF.jpg", (1400, 900), exif=_demo_exif())
    _demo_gif(inputs / "不支持的动图.gif")
    (inputs / "说明.txt").write_text("这个文件不是图片，会被安静忽略。\n", encoding="utf-8")

    out = root / "输出"
    steps, artifacts = [], []

    def run(label, fn, extra):
        call = {"input": str(inputs), "out": str(out / label)}
        call.update(extra)
        result = fn(call)
        steps.append({
            "label": label,
            "action": result.get("action"),
            "summary": result.get("summary", ""),
            "out": result.get("out"),
            "skipped": len(result.get("skipped") or []),
            "failed": len(result.get("failed") or []),
        })
        artifacts.extend(result.get("artifacts") or [])

    run("压缩", action_compress, {"max_width": 1200, "quality": 78})
    run("缩放", action_resize, {"max_width": 640})
    run("水印", action_watermark, {"text": "深鲸示例水印", "opacity": 0.55})
    run("转格式", action_convert, {"format": "webp"})
    run("去元数据", action_strip, {})

    return {
        "ok": True,
        "action": "demo",
        "demoRoot": str(root.resolve()),
        "steps": steps,
        "inputDir": str(inputs.resolve()),
        "summary": "演示完成：%d 个动作全部跑通，产物 %d 个" % (len(steps), len(artifacts)),
        "artifacts": artifacts,
    }


ACTIONS = {
    "compress": action_compress,
    "resize": action_resize,
    "watermark": action_watermark,
    "convert": action_convert,
    "strip": action_strip,
    "demo": action_demo,
}


def main(argv):
    if len(argv) < 3:
        emit({"ok": False, "code": 2,
              "message": "内部调用参数不足：需要 <action> 和 JSON payload",
              "hint": "请通过 bin/cli.mjs 调用本脚本。"})
        return 2
    action, raw = argv[1], argv[2]
    try:
        payload = json.loads(raw) if raw else {}
    except json.JSONDecodeError as exc:
        emit({"ok": False, "code": 2, "message": "参数 JSON 解析失败：%s" % exc, "hint": ""})
        return 2
    fn = ACTIONS.get(action)
    if not fn:
        emit({"ok": False, "code": 2, "message": "未知动作：%s" % action,
              "hint": "可用动作：%s" % " / ".join(k for k in ACTIONS if k != "demo")})
        return 2
    try:
        result = fn(payload)
        result.setdefault("ok", True)
        emit(result)
        return 0
    except ToolError as exc:
        emit({"ok": False, "code": exc.code, "message": exc.message, "hint": exc.hint})
        return exc.code
    except PermissionError as exc:
        emit({"ok": False, "code": 1,
              "message": "没有权限读写文件：%s" % exc,
              "hint": "检查输出目录是否有写权限，或输入文件是否被其它程序占用。"})
        return 1
    except Exception as exc:  # noqa: BLE001 —— 兜底，保证永远输出 JSON
        traceback.print_exc(file=sys.stderr)
        emit({"ok": False, "code": 1, "message": "处理失败：%s" % exc,
              "hint": "图片可能已损坏或不是真正的 jpg/png/webp；可先用图片查看器打开确认。"})
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
