#!/bin/bash
# @deepwhale-cn/dsh-image-batch · 双向验证
# 正例：用 Pillow 现场造图（大照片 JPG / 纯色 PNG / 透明 PNG / WebP / 带 EXIF 的 JPG），
#       逐项断言 compress、resize、watermark、convert、strip 的产物真的变了、尺寸真的对；
# 反例：坏输入、缺参数、缺依赖必须非 0 退出并说明缺什么。
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check(){ # check <描述> <命令...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>"$TMP/last_err"; then ok "$desc"
  else bad "$desc"; sed -n '1,6p' "$TMP/last_err" | sed 's/^/       /'; fi
}
say(){ echo ""; echo "  【$1】"; }

PY="${DSH_PYTHON:-/opt/homebrew/bin/python3}"
[ -x "$PY" ] || PY="$(command -v python3 || true)"
if [ -z "${PY:-}" ] || ! "$PY" -c "import PIL" >/dev/null 2>&1; then
  echo ""; echo "  ❌ 本机缺少 python3 + Pillow，无法造样例，测试未执行"
  echo "     python3 -m pip install Pillow"; echo ""; exit 3
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dsh-image-batch-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/输入"; OUT="$TMP/输出"
mkdir -p "$FIX" "$OUT"

echo ""; echo "  @deepwhale-cn/dsh-image-batch · 双向验证"
echo "  ────────────────────────────────────────────────────────"

# ── 造正例样本（Pillow，不依赖手工二进制） ──────────────────────────
"$PY" - "$FIX" <<'PY' || { echo "  ❌ 造样例失败"; exit 1; }
import os
import sys
from PIL import Image, ImageDraw

root = sys.argv[1]

def photo(path, size, quality=95, exif=None):
    noise = Image.effect_noise(size, 56).convert("RGB")
    gradient = Image.linear_gradient("L").resize(size).convert("RGB")
    img = Image.blend(noise, gradient, 0.45)
    kwargs = {"quality": quality}
    if exif is not None:
        kwargs["exif"] = exif
    img.save(path, **kwargs)

# 1. 大照片：压缩主力用例（2400 宽，会被默认 --max-width 1920 缩小）
photo(os.path.join(root, "照片A.jpg"), (2400, 1600))
# 2. 纯色 PNG：PNG 压缩 / 量化用例
solid = Image.new("RGB", (1600, 1200), (214, 38, 60))
draw = ImageDraw.Draw(solid)
for i in range(12):
    draw.rectangle((60 + i * 120, 80, 140 + i * 120, 1120),
                   fill=(20 + i * 15, 90, 160))
solid.save(os.path.join(root, "纯色B.png"), optimize=True)
# 3. 透明 PNG：convert jpg 填白 / 水印像素断言用例
rgba = Image.new("RGBA", (1200, 900), (0, 0, 0, 0))
draw = ImageDraw.Draw(rgba)
draw.ellipse((100, 100, 700, 700), fill=(30, 140, 200, 200))
draw.rectangle((500, 300, 1100, 800), fill=(250, 180, 60, 180))
rgba.save(os.path.join(root, "透明C.png"), optimize=True)
# 4. WebP 输入
photo(os.path.join(root, "图库D.webp"), (1600, 1000), quality=92)
# 5. 带 EXIF 的 JPG：strip / --keep-exif 用例
exif = Image.Exif()
exif[0x010F] = "DeepWhale"
exif[0x0110] = "DemoCam"
exif[0x0132] = "2026:10:24 12:00:00"
exif[0x0112] = 1
photo(os.path.join(root, "带EXIF.jpg"), (1400, 900), exif=exif)
# 6. 中文 + 空格文件名；扩展名 .jpeg（convert 时应归一成 .jpg）
photo(os.path.join(root, "中文 名字 E.jpeg"), (900, 600))
# 7. 不支持的格式（必须跳过并汇总）
frames = [Image.new("RGB", (160, 160), (20 + i * 40, 90, 160)) for i in range(3)]
frames[0].save(os.path.join(root, "不支持的动图.gif"),
               save_all=True, append_images=frames[1:], duration=200, loop=0)
# 8. 非图片文件（应被安静忽略，不进 skipped 清单）
with open(os.path.join(root, "说明.txt"), "w", encoding="utf-8") as fh:
    fh.write("不是图片，应该被安静忽略\n")
PY

cat > "$TMP/check.py" <<'PY'
# 断言脚本：check.py <用例> <参数...>
import json
import os
import sys
from pathlib import Path

from PIL import Image, ImageChops


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if data.get("ok") is not True:
        fail("JSON 里 ok 不是 true：%s" % data)
    return data


def open_rgba(path):
    with Image.open(path) as im:
        im.load()
        return im.convert("RGBA").copy()


def flatten(im):
    """透明区域按白底合成，才看得见「在透明画布上画字」的变化。"""
    base = Image.new("RGB", im.size, (255, 255, 255))
    rgba = im.convert("RGBA")
    base.paste(rgba, (0, 0), rgba)
    return base


def changed(a, b, threshold=8):
    """返回 (改动像素数, 改动区域 bbox, 亮度差总和)。"""
    diff = ImageChops.difference(flatten(a), flatten(b)).convert("L")
    hist = diff.histogram()
    count = sum(hist[threshold + 1:])
    total = sum(i * hist[i] for i in range(len(hist)))
    box = diff.point(lambda v: 255 if v > threshold else 0).getbbox()
    return count, box, total


def case_compress(out_dir, json_path, src_dir):
    data = load_json(json_path)
    assert data["action"] == "compress", data["action"]
    names = {r["input_name"] for r in data["files"]}
    for expected in ["照片A.jpg", "纯色B.png", "透明C.png", "图库D.webp",
                     "带EXIF.jpg", "中文 名字 E.jpeg"]:
        assert expected in names, "漏处理：%s（实际 %s）" % (expected, sorted(names))
    assert len(data["files"]) == 6, "应处理 6 个支持的文件，实际 %d" % len(data["files"])

    skipped = {s["input_name"]: s["reason"] for s in data["skipped"]}
    assert "不支持的动图.gif" in skipped, "gif 没有被跳过汇总：%s" % data["skipped"]
    assert "gif" in skipped["不支持的动图.gif"], "跳过原因没说格式：%s" % skipped
    assert "说明.txt" not in str(data["skipped"]), "非图片文件不该进入跳过清单"

    photo = next(r for r in data["files"] if r["input_name"] == "照片A.jpg")
    assert photo["width"] == 1920, "默认 max-width 1920 没生效：宽 %d" % photo["width"]
    assert abs(photo["height"] - round(1600 * 1920 / 2400)) <= 1, \
        "等比缩放高度不对：%d" % photo["height"]
    assert photo["output_bytes"] < photo["input_bytes"] * 0.6, \
        "照片压缩幅度太小：%d → %d" % (photo["input_bytes"], photo["output_bytes"])
    assert photo["format"] == "JPEG", "格式被意外改了：%s" % photo["format"]

    for rec in data["files"]:
        assert rec["width"] <= 1920, "%s 宽度超过 1920" % rec["input_name"]
        assert rec["output_bytes"] < rec["input_bytes"], \
            "%s 压缩后未变小（%d → %d）" % (rec["input_name"], rec["input_bytes"], rec["output_bytes"])
        assert os.path.exists(rec["output"]), "产物不存在：%s" % rec["output"]

    png = next(r for r in data["files"] if r["input_name"] == "纯色B.png")
    assert png["format"] == "PNG", "PNG 输入默认应保持 PNG：%s" % png["format"]
    assert png["output_bytes"] < png["input_bytes"] * 0.8, "PNG 量化没起作用"

    for artifact in data["artifacts"]:
        assert os.path.exists(artifact), "JSON 里的产物不存在：%s" % artifact
        assert os.path.realpath(os.path.dirname(artifact)) == os.path.realpath(out_dir), \
            "产物没有全部写进 --out：%s" % artifact
    assert not (Path(src_dir) / "_输出").exists(), "把产物写进了输入目录"


def case_compress_webp(out_dir, json_path):
    data = load_json(json_path)
    assert len(data["files"]) == 1, data["files"]
    rec = data["files"][0]
    assert rec["output_name"].endswith(".webp"), \
        "compress --format webp 没改扩展名：%s" % rec["output_name"]
    assert rec["format"] == "WEBP", "产物格式不是 WebP：%s" % rec["format"]
    assert rec["output_bytes"] < rec["input_bytes"], "转 WebP 后反而变大"
    assert rec["width"] == 1920, "max-width 没生效：%d" % rec["width"]


def case_resize(out_dir, json_path, expect_w, expect_h_from):
    data = load_json(json_path)
    expect_h_from = (expect_h_from or "").strip()
    name, expect_h = (None, None)
    if expect_h_from:
        name, raw_h = expect_h_from.split(":")
        expect_h = int(raw_h)
    for rec in data["files"]:
        if expect_w:
            assert rec["width"] == int(expect_w), "%s 宽度应为 %s，实际 %d" % (
                rec["input_name"], expect_w, rec["width"])
            ratio_src = rec["src_width"] / float(rec["src_height"])
            ratio_out = rec["width"] / float(rec["height"])
            assert abs(ratio_src - ratio_out) < 0.01, "%s 比例没保持：%.3f vs %.3f" % (
                rec["input_name"], ratio_src, ratio_out)
        if name and rec["input_name"] == name:
            assert rec["height"] == expect_h, "%s 高度应为 %d，实际 %d" % (
                name, expect_h, rec["height"])
            assert rec["width"] == 400, "%s 宽度应随比例变成 400，实际 %d" % (
                name, rec["width"])


def case_resize_noupscale(out_dir, json_path):
    data = load_json(json_path)
    rec = data["files"][0]
    assert rec["width"] == rec["src_width"], \
        "小图被放大了：%d → %d" % (rec["src_width"], rec["width"])
    assert rec["height"] == rec["src_height"], \
        "小图被放大了：%d → %d" % (rec["src_height"], rec["height"])


def case_watermark_default(out_dir, json_path, src_dir, src_name):
    data = load_json(json_path)
    assert len(data["files"]) == 6, "水印应处理 6 个文件，实际 %d" % len(data["files"])
    rec = next(r for r in data["files"] if r["input_name"] == src_name)
    assert os.path.exists(rec["output"]), "水印产物不存在：%s" % rec["output"]
    before = open_rgba(os.path.join(src_dir, src_name))
    after = open_rgba(rec["output"])
    assert before.size == after.size, "水印改变了图片尺寸：%s → %s" % (before.size, after.size)
    count, box, _ = changed(before, after)
    assert count > 200, "水印像素变化太少（%d），可能没画上去" % count
    width, height = before.size
    assert box[0] >= width * 0.5 and box[1] >= height * 0.6, \
        "水印不在右下角（改动区域 %s，图 %dx%d）" % (box, width, height)
    expected_size = round(min(width, height) * 0.04)
    assert rec["font_size"] == expected_size, \
        "默认字号应为短边 4%% = %d，实际 %d" % (expected_size, rec["font_size"])
    assert rec["position"] == "bottom-right", rec["position"]
    assert rec["font"], "JSON 没给出实际使用的字体"


def case_watermark_position(out_dir, json_path, src_dir, src_name, corner):
    data = load_json(json_path)
    rec = next(r for r in data["files"] if r["input_name"] == src_name)
    before = open_rgba(os.path.join(src_dir, src_name))
    after = open_rgba(rec["output"])
    count, box, _ = changed(before, after)
    width, height = before.size
    assert count > 100, "水印没画上去（%d 像素变化）" % count
    if corner == "top-left":
        assert box[2] <= width * 0.5 and box[3] <= height * 0.4, \
            "水印不在左上角（改动区域 %s）" % (box,)
    else:
        assert box[0] >= width * 0.5 and box[1] >= height * 0.6, \
            "水印不在右下角（改动区域 %s）" % (box,)


def case_watermark_opacity(soft_json, strong_json, src_dir, src_name):
    soft = load_json(soft_json)
    strong = load_json(strong_json)
    src = open_rgba(os.path.join(src_dir, src_name))
    soft_rec = next(r for r in soft["files"] if r["input_name"] == src_name)
    strong_rec = next(r for r in strong["files"] if r["input_name"] == src_name)
    _, _, soft_total = changed(src, open_rgba(soft_rec["output"]))
    _, _, strong_total = changed(src, open_rgba(strong_rec["output"]))
    assert soft_total > 0 and strong_total > 0, "两种不透明度都没画出水印"
    assert strong_total > soft_total * 1.5, \
        "opacity 没起作用：0.9 的差异 %d 不大于 0.2 的 %d" % (strong_total, soft_total)


def case_watermark_fontsize(out_dir, json_path, src_dir, src_name):
    data = load_json(json_path)
    rec = next(r for r in data["files"] if r["input_name"] == src_name)
    assert rec["font_size"] == 40, "--font-size 40 没生效：%d" % rec["font_size"]
    before = open_rgba(os.path.join(src_dir, src_name))
    after = open_rgba(rec["output"])
    count, _, _ = changed(before, after)
    assert count > 100, "指定字号后没画上水印"


def case_convert(out_dir, json_path, expect_format, expect_ext):
    data = load_json(json_path)
    assert len(data["files"]) == 6, "convert 应处理 6 个文件，实际 %d" % len(data["files"])
    for rec in data["files"]:
        assert rec["output_name"].endswith(expect_ext), \
            "%s 扩展名应为 %s，实际 %s" % (rec["input_name"], expect_ext, rec["output_name"])
        assert os.path.exists(rec["output"]), "产物不存在：%s" % rec["output"]
        with Image.open(rec["output"]) as im:
            assert im.format == expect_format, \
                "%s 实际格式 %s，期望 %s" % (rec["output_name"], im.format, expect_format)
        assert rec["to_format"] == expect_format, rec["to_format"]


def case_convert_white(out_dir, json_path, src_name):
    data = load_json(json_path)
    rec = next(r for r in data["files"] if r["input_name"] == src_name)
    with Image.open(rec["output"]) as im:
        assert im.format == "JPEG", im.format
        assert im.mode == "RGB", "JPEG 不该有 alpha 通道：%s" % im.mode
        corner = im.convert("RGB").getpixel((0, 0))
    assert corner == (255, 255, 255), "透明背景没有填白，左上角是 %s" % (corner,)


def case_strip(out_dir, json_path, src_dir):
    data = load_json(json_path)
    assert len(data["files"]) == 6, "strip 应处理 6 个文件，实际 %d" % len(data["files"])
    for rec in data["files"]:
        with Image.open(rec["output"]) as im:
            tags = im.getexif()
            assert len(tags) == 0, "%s 仍残留 %d 个 EXIF 标签" % (rec["output_name"], len(tags))
            assert (im.width, im.height) == (rec["width"], rec["height"])
        assert rec["exif_removed"] is True
        assert rec["exif_tags"] == 0, "%s EXIF 计数 %d" % (rec["output_name"], rec["exif_tags"])
    # 带 EXIF 的那张：qualify='keep' 不重新压缩，像素几乎不变
    rec = next(r for r in data["files"] if r["input_name"] == "带EXIF.jpg")
    before = open_rgba(os.path.join(src_dir, "带EXIF.jpg"))
    after = open_rgba(rec["output"])
    _, _, total = changed(before, after)
    per_pixel = total / float(before.size[0] * before.size[1])
    assert per_pixel < 3, "strip 对 JPEG 改动过大（平均 %.2f/像素），应沿用原量化表" % per_pixel


def case_strip_keep(out_dir, json_path):
    data = load_json(json_path)
    assert len(data["files"]) == 1, data["files"]
    rec = data["files"][0]
    with Image.open(rec["output"]) as im:
        tags = im.getexif()
        assert len(tags) >= 3, "--keep-exif 没保留元数据：只剩 %d 个标签" % len(tags)
    assert rec["exif_removed"] is False
    assert rec["exif_tags"] >= 3


def case_partial(out_dir, json_path):
    data = load_json(json_path)
    failed = {f["input_name"] for f in data["failed"]}
    assert "坏图.jpg" in failed, "坏图没有记入 failed：%s" % data["failed"]
    assert data["files"], "同目录的好图也没处理成功"
    for rec in data["files"]:
        assert os.path.exists(rec["output"]), "好图的产物不存在：%s" % rec["output"]
    assert "失败" in data["summary"], "summary 没有提到失败：%s" % data["summary"]


def case_demo(json_path):
    with open(json_path, encoding="utf-8") as fh:
        data = json.load(fh)
    assert data.get("ok") is True, data
    assert data.get("action") == "demo", data.get("action")
    steps = data.get("steps", [])
    assert len(steps) == 5, "演示步骤应为 5 个，实际 %d" % len(steps)
    actions = {s.get("action") for s in steps}
    assert actions == {"compress", "resize", "watermark", "convert", "strip"}, actions
    for step in steps:
        assert step.get("summary"), "步骤 %s 没有 summary" % step.get("action")
    artifacts = data.get("artifacts", [])
    assert len(artifacts) >= 15, "演示产物太少：%d" % len(artifacts)
    for path in artifacts:
        assert os.path.exists(path), "演示产物不存在：%s" % path
    assert os.path.isdir(data["demoRoot"]), "demoRoot 不存在：%s" % data["demoRoot"]
    print(data["demoRoot"])


def case_inputs_untouched(src_dir, snapshot_path):
    with open(snapshot_path, encoding="utf-8") as fh:
        before = json.load(fh)
    now = sorted(os.listdir(src_dir))
    assert sorted(before.keys()) == now, \
        "输入目录里多了/少了文件：%s vs %s" % (sorted(before.keys()), now)
    for name, size in before.items():
        path = os.path.join(src_dir, name)
        assert os.path.getsize(path) == size, "输入文件被改了：%s" % name


CASES = {
    "compress": case_compress,
    "compress_webp": case_compress_webp,
    "resize": case_resize,
    "resize_noupscale": case_resize_noupscale,
    "watermark_default": case_watermark_default,
    "watermark_position": case_watermark_position,
    "watermark_opacity": case_watermark_opacity,
    "watermark_fontsize": case_watermark_fontsize,
    "convert": case_convert,
    "convert_white": case_convert_white,
    "strip": case_strip,
    "strip_keep": case_strip_keep,
    "partial": case_partial,
    "demo": case_demo,
    "inputs_untouched": case_inputs_untouched,
}

name, args = sys.argv[1], sys.argv[2:]
fn = CASES.get(name)
if not fn:
    fail("未知用例：%s" % name)
try:
    fn(*args)
except AssertionError as exc:
    fail("断言失败：%s" % exc)
print("ok")
PY

# 输入文件快照（逐个大小），收尾时核对「没有写进输入目录 / 没有改输入文件」
SNAPSHOT="$TMP/inputs.json"
"$PY" - "$FIX" "$SNAPSHOT" <<'PY' || { echo "  ❌ 快照失败"; exit 1; }
import json, os, sys
root, out = sys.argv[1], sys.argv[2]
data = {name: os.path.getsize(os.path.join(root, name)) for name in sorted(os.listdir(root))}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False)
PY
BEFORE=$(shasum -a 256 "$FIX"/* 2>/dev/null | shasum -a 256)

say "CLI 形态（--help / 无参数 / 参数校验）"
node bin/cli.mjs --help >"$TMP/help.txt" 2>&1 && ok "--help 退出 0" || bad "--help 退出非 0"
grep -q "子命令" "$TMP/help.txt" && ok "--help 列出子命令" || bad "--help 缺少子命令列表"
grep -q "Pillow" "$TMP/help.txt" && ok "--help 说明 python/Pillow 依赖" || bad "--help 未说明依赖"
grep -q "watermark" "$TMP/help.txt" && ok "--help 含 watermark 用法" || bad "--help 缺 watermark"
node bin/cli.mjs >/dev/null 2>&1 && ok "无参数时打印 help 且退出 0" || bad "无参数未退出 0"
NEG=$(node bin/cli.mjs nosuch --input "$FIX" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "未知子命令 → 非 0 退出（$RC）" || bad "未知子命令仍退出 0"
echo "$NEG" | grep -q "未知子命令" && ok "提示「未知子命令」" || bad "未知子命令提示不对：$NEG"
NEG=$(node bin/cli.mjs compress 2>&1); RC=$?
[ $RC -ne 0 ] && ok "缺 --input → 非 0 退出（$RC）" || bad "缺 --input 仍退出 0"
echo "$NEG" | grep -q "缺少 --input" && ok "提示「缺少 --input」" || bad "缺 --input 提示不对：$NEG"
NEG=$(node bin/cli.mjs watermark --input "$FIX" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "watermark 缺 --text → 非 0 退出（$RC）" || bad "缺 --text 仍退出 0"
echo "$NEG" | grep -q "缺少 --text" && ok "提示「缺少 --text」" || bad "缺 --text 提示不对：$NEG"
NEG=$(node bin/cli.mjs convert --input "$FIX" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "convert 缺 --format → 非 0 退出（$RC）" || bad "缺 --format 仍退出 0"
echo "$NEG" | grep -q "缺少 --format" && ok "提示「缺少 --format」" || bad "缺 --format 提示不对：$NEG"
NEG=$(node bin/cli.mjs convert --input "$FIX" --format bmp 2>&1); RC=$?
[ $RC -ne 0 ] && ok "convert --format bmp → 非 0 退出（$RC）" || bad "非法格式仍退出 0"
echo "$NEG" | grep -q "不支持的 --format" && ok "提示「不支持的 --format」" || bad "非法格式提示不对：$NEG"
NEG=$(node bin/cli.mjs resize --input "$FIX" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "resize 缺尺寸 → 非 0 退出（$RC）" || bad "resize 缺尺寸仍退出 0"
echo "$NEG" | grep -q "resize 需要" && ok "提示「resize 需要 --max-width/--max-height」" || bad "resize 提示不对：$NEG"
NEG=$(node bin/cli.mjs watermark --input "$FIX" --text x --position 斜着 2>&1); RC=$?
[ $RC -ne 0 ] && ok "非法 --position → 非 0 退出（$RC）" || bad "非法 position 仍退出 0"
echo "$NEG" | grep -q "不支持的 --position" && ok "提示「不支持的 --position」" || bad "position 提示不对"
NEG=$(node bin/cli.mjs compress --input "$FIX" --quality 0 2>&1); RC=$?
[ $RC -ne 0 ] && ok "--quality 越界 → 非 0 退出（$RC）" || bad "--quality 越界仍退出 0"
echo "$NEG" | grep -q "quality" && ok "提示 quality 取值范围" || bad "quality 越界提示不对"
DEP=$("$PY" -S lib/image_tool.py compress '{}' 2>&1); RC=$?
[ $RC -eq 3 ] && ok "缺 Pillow 依赖时退出码 3" || bad "缺依赖退出码应为 3，实际 $RC"
echo "$DEP" | grep -q "pip install Pillow" && ok "缺依赖明确提示 pip install Pillow" || bad "缺依赖没有安装提示"

say "正例 · compress 批量压缩"
node bin/cli.mjs compress --input "$FIX" --out "$OUT/压缩" --json >"$TMP/compress.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "compress 退出 0" || bad "compress 退出 $RC"
check "6 个文件都处理、gif 明确跳过、体积变小、宽 ≤1920、比例正确" \
  "$PY" "$TMP/check.py" compress "$OUT/压缩" "$TMP/compress.json" "$FIX"
node bin/cli.mjs compress --input "$FIX/照片A.jpg" --format webp --out "$OUT/压缩webp" --json >"$TMP/compress_webp.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "compress --format webp 退出 0" || bad "compress --format webp 退出 $RC"
check "JPG → WebP 压缩与转格式同时生效" \
  "$PY" "$TMP/check.py" compress_webp "$OUT/压缩webp" "$TMP/compress_webp.json"
node bin/cli.mjs compress --input "$FIX" --out "$OUT/压缩" --json >/dev/null 2>&1
[ -f "$OUT/压缩/照片A_1.jpg" ] && ok "同名产物不覆盖（照片A_1.jpg）" || bad "同名产物被覆盖或未加序号"

say "正例 · resize 按比例缩放"
node bin/cli.mjs resize --input "$FIX" --max-width 400 --out "$OUT/缩放" --json >"$TMP/resize.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "resize --max-width 400 退出 0" || bad "resize 退出 $RC"
check "宽度 400 且比例保持（误差 <1%）" \
  "$PY" "$TMP/check.py" resize "$OUT/缩放" "$TMP/resize.json" 400 ""
node bin/cli.mjs resize --input "$FIX/纯色B.png" --max-height 300 --out "$OUT/缩放高" --json >"$TMP/resize_h.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "resize --max-height 300 退出 0" || bad "resize --max-height 退出 $RC"
check "高 300、宽按比例 400（1600×1200）" \
  "$PY" "$TMP/check.py" resize "$OUT/缩放高" "$TMP/resize_h.json" "" "纯色B.png:300"
node bin/cli.mjs resize --input "$FIX/照片A.jpg" --max-width 4000 --out "$OUT/缩放不放大" --json >"$TMP/resize_up.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "resize 上限大于原图时退出 0" || bad "resize 上限大于原图退出 $RC"
check "只缩小不放大（2400×1600 保持原样）" \
  "$PY" "$TMP/check.py" resize_noupscale "$OUT/缩放不放大" "$TMP/resize_up.json"

say "正例 · watermark 文字水印"
node bin/cli.mjs watermark --input "$FIX" --out "$OUT/水印" --text "© 深鲸 2026" --json >"$TMP/wm.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "watermark（中文）退出 0" || bad "watermark 退出 $RC"
check "水印像素真的变了、在右下角、默认字号=短边 4%" \
  "$PY" "$TMP/check.py" watermark_default "$OUT/水印" "$TMP/wm.json" "$FIX" "透明C.png"
node bin/cli.mjs watermark --input "$FIX/透明C.png" --out "$OUT/水印左上" --text "左上角水印" --position tl --json >"$TMP/wm_tl.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "--position tl 退出 0" || bad "--position tl 退出 $RC"
check "水印画在左上角（--position tl）" \
  "$PY" "$TMP/check.py" watermark_position "$OUT/水印左上" "$TMP/wm_tl.json" "$FIX" "透明C.png" "top-left"
node bin/cli.mjs watermark --input "$FIX/透明C.png" --out "$OUT/水印淡" --text "透明度测试" --opacity 0.2 --json >"$TMP/wm_soft.json" 2>&1
node bin/cli.mjs watermark --input "$FIX/透明C.png" --out "$OUT/水印浓" --text "透明度测试" --opacity 0.9 --json >"$TMP/wm_strong.json" 2>&1
check "opacity 0.2 / 0.9 的像素差异随不透明度增大" \
  "$PY" "$TMP/check.py" watermark_opacity "$TMP/wm_soft.json" "$TMP/wm_strong.json" "$FIX" "透明C.png"
node bin/cli.mjs watermark --input "$FIX/透明C.png" --out "$OUT/水印字号" --text "字号" --font-size 40 --json >"$TMP/wm_size.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "--font-size 40 退出 0" || bad "--font-size 40 退出 $RC"
check "--font-size 按指定值生效且水印可见" \
  "$PY" "$TMP/check.py" watermark_fontsize "$OUT/水印字号" "$TMP/wm_size.json" "$FIX" "透明C.png"
NEG=$(node bin/cli.mjs watermark --input "$FIX/透明C.png" --out "$OUT/水印坏字体" \
  --text "字体" --font "$TMP/不存在的字体.ttc" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "字体文件不存在 → 非 0 退出（$RC）" || bad "字体缺失仍退出 0"
echo "$NEG" | grep -q "字体文件无法加载" && ok "明确报「字体文件无法加载」" || bad "字体错误提示不对：$NEG"
echo "$NEG" | grep -q "PingFang" && ok "提示里给出系统字体 PingFang 方案" || bad "字体提示缺少 PingFang 说明"

say "正例 · convert 批量转格式"
node bin/cli.mjs convert --input "$FIX" --out "$OUT/转jpg" --format jpg --json >"$TMP/cv_jpg.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "convert --format jpg 退出 0" || bad "convert jpg 退出 $RC"
check "6 个产物均为 JPEG，扩展名 .jpg（.jpeg 已归一）" \
  "$PY" "$TMP/check.py" convert "$OUT/转jpg" "$TMP/cv_jpg.json" JPEG .jpg
check "透明 PNG 转 JPG 后透明区填白（左上角 255,255,255）" \
  "$PY" "$TMP/check.py" convert_white "$OUT/转jpg" "$TMP/cv_jpg.json" "透明C.png"
node bin/cli.mjs convert --input "$FIX" --out "$OUT/转png" --format png --json >"$TMP/cv_png.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "convert --format png 退出 0" || bad "convert png 退出 $RC"
check "6 个产物均为 PNG" "$PY" "$TMP/check.py" convert "$OUT/转png" "$TMP/cv_png.json" PNG .png
node bin/cli.mjs convert --input "$FIX" --out "$OUT/转webp" --format webp --json >"$TMP/cv_webp.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "convert --format webp 退出 0" || bad "convert webp 退出 $RC"
check "6 个产物均为 WebP" "$PY" "$TMP/check.py" convert "$OUT/转webp" "$TMP/cv_webp.json" WEBP .webp
node bin/cli.mjs convert --input "$FIX/透明C.png" --out "$OUT/透明webp" --format webp >/dev/null 2>&1
"$PY" - "$OUT/透明webp/透明C.webp" <<'PY' && ok "PNG→WebP 保留了透明通道" || bad "PNG→WebP 丢了透明通道"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGBA")
assert im.getpixel((0, 0))[3] == 0, im.getpixel((0, 0))
assert im.getpixel((600, 450))[3] > 0
PY

say "正例 · strip 去 EXIF/元数据"
"$PY" - "$FIX/带EXIF.jpg" <<'PY' && ok "样例带 EXIF（输入侧对照成立）" || bad "样例没有 EXIF，用例无效"
import sys
from PIL import Image
im = Image.open(sys.argv[1])
assert len(im.getexif()) >= 3, len(im.getexif())
PY
node bin/cli.mjs strip --input "$FIX" --out "$OUT/去元数据" --json >"$TMP/strip.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "strip 退出 0" || bad "strip 退出 $RC"
check "6 个产物 EXIF 全为空、尺寸不变、JPEG 像素几乎不变" \
  "$PY" "$TMP/check.py" strip "$OUT/去元数据" "$TMP/strip.json" "$FIX"
node bin/cli.mjs strip --input "$FIX/带EXIF.jpg" --out "$OUT/保留EXIF" --keep-exif --json >"$TMP/strip_keep.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "strip --keep-exif 退出 0" || bad "strip --keep-exif 退出 $RC"
check "--keep-exif 确实保留元数据（≥3 个标签）" \
  "$PY" "$TMP/check.py" strip_keep "$OUT/保留EXIF" "$TMP/strip_keep.json"

say "正例 · 默认输出目录 / 单文件输入 / 中文文件名"
mkdir -p "$TMP/默认目录" && cp "$FIX/照片A.jpg" "$TMP/默认目录/"
node bin/cli.mjs compress --input "$TMP/默认目录" >/dev/null 2>&1
[ -f "$TMP/默认目录/_输出/照片A.jpg" ] && ok "未给 --out 时默认写到 <输入目录>/_输出" || bad "默认输出目录不对"
node bin/cli.mjs compress --input "$FIX/照片A.jpg" --out "$TMP/单文件" >/dev/null 2>&1
[ -f "$TMP/单文件/照片A.jpg" ] && ok "支持单个文件输入" || bad "单文件输入失败"
[ -f "$OUT/压缩/中文 名字 E.jpeg" ] && ok "中文 + 空格文件名正常处理" || bad "中文文件名处理失败"

say "正例 · --demo 自造样例跑完整流程"
node bin/cli.mjs --demo --json >"$TMP/demo.json" 2>&1
RC=$?
[ $RC -eq 0 ] && ok "--demo 退出 0" || bad "--demo 退出 $RC"
DROOT=$("$PY" "$TMP/check.py" demo "$TMP/demo.json" 2>"$TMP/last_err")
[ $? -eq 0 ] && ok "5 个动作全跑通，产物均真实存在且步骤有摘要" \
  || { bad "demo 产物校验失败"; sed -n '1,4p' "$TMP/last_err" | sed 's/^/       /'; }
[ -n "${DROOT:-}" ] && rm -rf "$DROOT"

say "插件壳 · lib/index.js 导出与技能注入"
node -e "import('./lib/index.js').then(m=>{const miss=['name','inject','apply'].filter(k=>!(k in m));if(miss.length){console.error('缺导出：'+miss);process.exit(1)}if(m.name!=='image-batch'){console.error('name 不对：'+m.name);process.exit(1)}if(!Array.isArray(m.inject)||!m.inject.includes('skills')){console.error('inject 不对');process.exit(1)}})" >/dev/null 2>&1 \
  && ok "导出 name/inject/apply，name=image-batch" || bad "插件导出不对（缺 node_modules 链接？）"
if [ -e node_modules/@deepwhale-cn/dsh-guard-core ]; then
  ROOT="$PWD" node --input-type=module - <<'JS' && ok "apply 注册技能，<cli 路径> 已替换成 bin 绝对路径" || bad "技能注入失败"
const root = process.env.ROOT;
const mod = await import(root + '/lib/index.js');
let registered = null;
mod.apply({ skills: { register: (s) => { registered = s; } }, logger: { info() {}, warn() {}, error() {} } });
if (!registered) { console.error('没有注册技能'); process.exit(1); }
if (registered.name !== 'image-batch') { console.error('技能名不对：' + registered.name); process.exit(1); }
if (registered.content.includes('<cli 路径>')) { console.error('技能正文里的占位符没被替换'); process.exit(1); }
if (!registered.content.includes(root + '/bin/cli.mjs')) { console.error('技能正文里没有 bin 绝对路径'); process.exit(1); }
if (!registered.content.startsWith('# 图片批量处理')) { console.error('技能正文不是本插件的'); process.exit(1); }
JS
else
  echo "  ⏭ 跳过技能注入检查（未安装 @deepwhale-cn/dsh-guard-core，先 npm install）"
fi

say "反例 · 坏输入必须非 0 退出并说明缺什么"
NEG=$(node bin/cli.mjs compress --input "$TMP/根本不存在" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "不存在的输入 → 非 0 退出（$RC）" || bad "不存在的输入仍退出 0"
echo "$NEG" | grep -q "不存在" && ok "提示「输入不存在」" || bad "缺少错误提示：$NEG"
mkdir -p "$TMP/空目录"
NEG=$(node bin/cli.mjs compress --input "$TMP/空目录" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "空目录 → 非 0 退出（$RC）" || bad "空目录仍退出 0"
echo "$NEG" | grep -q "没有可处理的图片" && ok "提示「没有可处理的图片」" || bad "空目录提示不对：$NEG"
mkdir -p "$TMP/只有gif" && cp "$FIX/不支持的动图.gif" "$TMP/只有gif/"
NEG=$(node bin/cli.mjs compress --input "$TMP/只有gif" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "只有不支持的格式 → 非 0 退出（$RC）" || bad "只有 gif 仍退出 0"
echo "$NEG" | grep -q "gif" && ok "提示里点名被跳过的格式（gif）" || bad "没说明跳过了 gif：$NEG"
mkdir -p "$TMP/混合" && cp "$FIX/照片A.jpg" "$TMP/混合/"
printf 'not really a jpeg' > "$TMP/混合/坏图.jpg"
node bin/cli.mjs compress --input "$TMP/混合" --out "$TMP/混合出" --json >"$TMP/partial.json" 2>&1; RC=$?
[ $RC -eq 1 ] && ok "坏图拖累时退出码 1（部分成功）" || bad "坏图退出码应为 1，实际 $RC"
check "好图仍出产物、坏图记入 failed、summary 提到失败" \
  "$PY" "$TMP/check.py" partial "$TMP/混合出" "$TMP/partial.json"
NEG=$(node bin/cli.mjs convert --input "$FIX/照片A.jpg" --format PNG --out "$TMP/大写格式" 2>&1); RC=$?
[ $RC -eq 0 ] && [ -f "$TMP/大写格式/照片A.png" ] && ok "--format PNG 大小写不敏感" \
  || bad "大写 --format 处理失败（$RC）"
node bin/cli.mjs compress --input "$TMP/根本不存在" --json >"$TMP/err.json" 2>&1; RC=$?
[ $RC -ne 0 ] && ok "--json 模式下错误也非 0 退出" || bad "--json 错误仍退出 0"
"$PY" - "$TMP/err.json" <<'PY' && ok "--json 错误输出可解析且含 message/hint" || bad "--json 错误输出不可解析"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is False
assert data["message"] and data["hint"]
PY

say "收尾 · 输入文件零改动"
CHECK1=$(shasum -a 256 "$FIX"/* 2>/dev/null | shasum -a 256)
[ "$BEFORE" = "$CHECK1" ] && ok "输入文件 sha256 全部未变" || bad "输入文件被修改了"
check "输入目录没多出文件、每个输入大小未变" \
  "$PY" "$TMP/check.py" inputs_untouched "$FIX" "$SNAPSHOT"

echo ""
echo "  ────────────────────────────────────────────────────────"
echo "  通过 $PASS · 失败 $FAIL"
echo ""
[ "$FAIL" -eq 0 ] || exit 1
