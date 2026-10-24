#!/usr/bin/env node
/**
 * 图片批量处理 CLI（Node ESM）
 *
 * 形态：
 *   dsh-image-batch --help                 （无参数也打印 help，退出 0）
 *   dsh-image-batch --demo                 （自造样例跑完整流程，退出 0）
 *   dsh-image-batch <action> --input <文件或目录> [--out <目录>] [--json]
 *
 * 真实逻辑全部委托 python3 + Pillow（lib/image_tool.py），
 * Node 只负责参数校验、调用与人类可读输出（不自己解码图片）。
 *
 * 契约：
 *   - 不改输入文件；只写 --out（默认 <输入目录>/_输出）
 *   - 同名产物不覆盖，自动加 _1 / _2 后缀
 *   - 缺 python3 / Pillow / 中文字体时明确说「缺什么、怎么装」，非 0 退出
 */
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PKG_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PY_SCRIPT = join(PKG_ROOT, 'lib', 'image_tool.py');
const TITLE = '图片批量处理';
const CMD = 'dsh-image-batch';
const LINE = '─'.repeat(56);

const ACTIONS = {
  compress: '批量压缩（--max-width 默认 1920，--quality 默认 82）',
  resize: '按比例缩放（--max-width / --max-height，只缩小不放大）',
  watermark: '加文字水印（--text 必填，--position 默认 bottom-right）',
  convert: '转格式（--format jpg|png|webp，jpg 透明底填白）',
  strip: '去掉 EXIF/元数据（--keep-exif 保留）',
};

const POSITIONS = new Set([
  'bottom-right', 'bottom-left', 'bottomright', 'bottomleft', 'br', 'bl',
  '右下', '左下',
  'top-right', 'top-left', 'topright', 'topleft', 'tr', 'tl',
  '右上', '左上',
  'center', 'centre', 'c', '居中', '中间',
]);
const FORMATS = new Set(['jpg', 'jpeg', 'png', 'webp']);

const PY_HINT = [
  '图片处理需要 python3 + Pillow。安装：',
  '  python3 -m pip install Pillow',
  '没有 python3 时：',
  '  macOS: brew install python3',
  '  Ubuntu: sudo apt install python3',
].join('\n');

function help() {
  console.log(`${TITLE}

用法：
  ${CMD} <action> --input <文件或目录> [--out <目录>] [--json]
  ${CMD} --demo
  ${CMD} --help

子命令：
${Object.entries(ACTIONS).map(([k, v]) => `  ${k.padEnd(10)}${v}`).join('\n')}

参数：
  --input, -i   图片文件或目录（目录递归处理，支持 jpg / jpeg / png / webp）
  --out, -o     输出目录；默认 <输入目录>/_输出；同名不覆盖，自动加 _1 序号
  --max-width   最长边上限（compress 默认 1920；resize 必填其一）
  --max-height  最高上限（resize 用）
  --quality     1~100；compress 默认 82，其余动作默认 90~92
  --format      compress：产物转成该格式；convert：目标格式 jpg|png|webp
  --text        水印文字（watermark 必填，支持中文）
  --position    水印位置：bottom-right（默认）/ bottom-left / top-right / top-left / center
  --opacity     水印不透明度 0~1，默认 0.55
  --font-size   水印字号，默认取图片短边的 4%
  --font        字体文件路径（默认用系统 PingFang.ttc，找不到会明确报错）
  --keep-exif   保留原始 EXIF（默认会去掉；strip 用它做对照）
  --json        输出 JSON（给脚本/CI 用）
  --demo        自造样例图，跑完整流程并打印产物路径

示例：
  ${CMD} compress --input ./照片 --out ./压缩 --max-width 1600 --quality 80
  ${CMD} resize --input ./照片 --max-width 1280
  ${CMD} watermark --input ./照片 --text "© 深鲸科技" --position bottom-right
  ${CMD} convert --input ./照片 --format webp
  ${CMD} strip --input ./照片

依赖：python3 + Pillow（缺失时会提示安装命令）；
中文水印需要系统字体（优先 /System/Library/Fonts/PingFang.ttc）。`);
  process.exit(0);
}

function fail(message, hint = '', code = 2, json = false, extra = {}) {
  if (json) {
    console.log(JSON.stringify({ ok: false, code, message, hint, ...extra }, null, 2));
  } else {
    console.error(`❌ ${message}`);
    if (hint) {
      for (const line of String(hint).split('\n')) console.error(`   ${line}`);
    }
  }
  process.exit(code);
}

function fmtBytes(n) {
  if (n == null || !Number.isFinite(n)) return '—';
  const units = ['B', 'KB', 'MB', 'GB'];
  let value = n;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  return `${value >= 100 || i === 0 ? Math.round(value) : value.toFixed(1)} ${units[i]}`;
}

function fmtDelta(inBytes, outBytes) {
  const text = `${fmtBytes(inBytes)} → ${fmtBytes(outBytes)}`;
  if (!inBytes || outBytes > inBytes) return text;
  const saved = Math.round((1 - outBytes / inBytes) * 100);
  return `${text}（-${saved}%）`;
}

function findPython() {
  const candidates = [
    process.env.DSH_PYTHON,
    process.env.IMAGE_BATCH_PYTHON,
    '/opt/homebrew/bin/python3',
    '/usr/local/bin/python3',
    'python3',
    '/usr/bin/python3',
  ].filter(Boolean);
  let sawPython = false;
  for (const cand of candidates) {
    const r = spawnSync(cand, ['-c', 'import PIL'], { encoding: 'utf8', timeout: 15000 });
    if (r.error) continue;
    sawPython = true;
    if (r.status === 0) return { python: cand };
  }
  return sawPython
    ? { error: '找到 python3，但缺少 Pillow（PIL 导入失败）' }
    : { error: '未找到 python3' };
}

function parseArgs(argv) {
  const opt = {
    action: null, input: null, out: null, json: false, demo: false,
    maxWidth: null, maxHeight: null, quality: null, format: null,
    text: null, position: null, opacity: null, fontSize: null, font: null,
    keepExif: false,
  };
  const positiveInt = (flag, raw) => {
    const value = Number(raw);
    if (!Number.isInteger(value) || value <= 0) {
      fail(`参数 ${flag} 需要正整数，收到：${raw}`, `例：${flag} 1920`);
    }
    return value;
  };

  for (let i = 0; i < argv.length; i++) {
    const raw = argv[i];
    const eq = raw.indexOf('=');
    const flag = eq > 0 ? raw.slice(0, eq) : raw;
    const inline = eq > 0 ? raw.slice(eq + 1) : undefined;

    if (flag === '--json') {
      opt.json = true;
      continue;
    }
    if (flag === '--demo') {
      opt.demo = true;
      continue;
    }
    if (flag === '--keep-exif') {
      opt.keepExif = true;
      continue;
    }
    if (flag === '--help' || flag === '-h') help();

    if (['--input', '-i', '--out', '-o', '--max-width', '--max-height',
      '--quality', '--format', '--text', '--position', '--opacity',
      '--font-size', '--font'].includes(flag)) {
      let value = inline;
      if (value === undefined) {
        value = argv[i + 1];
        if (value === undefined || value.startsWith('--')) {
          fail(`参数 ${flag} 缺少取值`, `例：${flag} <值>`);
        }
        i += 1;
      }
      switch (flag) {
        case '--input':
        case '-i':
          opt.input = value;
          break;
        case '--out':
        case '-o':
          opt.out = value;
          break;
        case '--max-width':
          opt.maxWidth = positiveInt(flag, value);
          break;
        case '--max-height':
          opt.maxHeight = positiveInt(flag, value);
          break;
        case '--quality': {
          const q = Number(value);
          if (!Number.isInteger(q) || q < 1 || q > 100) {
            fail(`--quality 必须在 1~100 之间，收到：${value}`, '例：--quality 82');
          }
          opt.quality = q;
          break;
        }
        case '--opacity': {
          const o = Number(value);
          if (!Number.isFinite(o) || o < 0 || o > 1) {
            fail(`--opacity 必须在 0~1 之间，收到：${value}`, '例：--opacity 0.55');
          }
          opt.opacity = o;
          break;
        }
        case '--font-size': {
          const s = Number(value);
          if (!Number.isInteger(s) || s < 4) {
            fail(`--font-size 至少 4（像素），收到：${value}`, '例：--font-size 64');
          }
          opt.fontSize = s;
          break;
        }
        case '--format': {
          const f = String(value).toLowerCase();
          if (!FORMATS.has(f)) {
            fail(`不支持的 --format：${value}`, '可选：jpg / png / webp');
          }
          opt.format = f;
          break;
        }
        case '--position':
          if (!POSITIONS.has(String(value).toLowerCase())) {
            fail(
              `不支持的 --position：${value}`,
              '可选：bottom-right（默认）/ bottom-left / top-right / top-left / center',
            );
          }
          opt.position = value;
          break;
        case '--text':
          opt.text = value;
          break;
        case '--font':
          opt.font = value;
          break;
        default:
          break;
      }
      continue;
    }

    if (flag.startsWith('-')) {
      fail(`未知参数：${raw}`, `用 ${CMD} --help 查看支持的参数。`);
    }
    if (!opt.action) {
      opt.action = raw;
      continue;
    }
    fail(`多余的参数：${raw}`, '一次只能执行一个子命令。');
  }
  return opt;
}

function payloadOf(opt) {
  return {
    input: opt.input,
    out: opt.out,
    max_width: opt.maxWidth,
    max_height: opt.maxHeight,
    quality: opt.quality,
    format: opt.format,
    text: opt.text,
    position: opt.position,
    opacity: opt.opacity,
    font_size: opt.fontSize,
    font: opt.font,
    keep_exif: opt.keepExif,
  };
}

function callPython(python, action, payload) {
  const r = spawnSync(python, [PY_SCRIPT, action, JSON.stringify(payload)], {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
  });
  if (r.error) fail(`调用 python 失败：${r.error.message}`, PY_HINT, 3);
  const lines = (r.stdout || '').trim().split('\n').filter(Boolean);
  let result = null;
  try {
    result = JSON.parse(lines[lines.length - 1] || '');
  } catch {
    /* 下面统一报错 */
  }
  if (!result) {
    const detail = (r.stderr || '').trim().split('\n').slice(-5).join('\n');
    fail('Python 处理失败（没有拿到有效结果）', detail || PY_HINT, r.status || 1);
  }
  return result;
}

function describe(file, action) {
  const parts = [];
  if (action === 'resize') {
    parts.push(`${file.src_width}×${file.src_height} → ${file.width}×${file.height}`);
    parts.push(fmtDelta(file.input_bytes, file.output_bytes));
  } else if (action === 'watermark') {
    parts.push(`${file.position} · 字号 ${file.font_size}`);
    parts.push(fmtDelta(file.input_bytes, file.output_bytes));
  } else if (action === 'convert') {
    parts.push(`${file.from_format} → ${file.to_format}`);
    parts.push(fmtDelta(file.input_bytes, file.output_bytes));
  } else if (action === 'strip') {
    parts.push(file.exif_removed ? 'EXIF 已清除' : 'EXIF 已保留');
    parts.push(fmtDelta(file.input_bytes, file.output_bytes));
  } else {
    parts.push(`${file.width}×${file.height}`);
    parts.push(fmtDelta(file.input_bytes, file.output_bytes));
  }
  return parts.join(' · ');
}

function human(res) {
  console.log('');
  console.log(`  ${TITLE} · ${res.action}`);
  console.log(`  ${LINE}`);
  console.log(`  输入       ${res.input}`);
  console.log(`  输出目录   ${res.out}`);
  console.log('');
  for (const file of res.files || []) {
    console.log(`  ✓ ${file.input_name} → ${file.output_name}  ${describe(file, res.action)}`);
  }
  for (const skip of res.skipped || []) {
    console.log(`  ⤼ 跳过 ${skip.input_name}（${skip.reason}）`);
  }
  for (const bad of res.failed || []) {
    console.log(`  ✗ 失败 ${bad.input_name}（${bad.reason}）`);
  }
  if (res.summary) {
    console.log('');
    console.log(`  ${res.summary}`);
  }
  if (res.artifacts && res.artifacts.length) {
    console.log('\n  产物：');
    for (const artifact of res.artifacts) console.log(`    ${artifact}`);
  }
  console.log('');
}

function humanDemo(res) {
  console.log('');
  console.log(`  ${TITLE} · 演示（--demo）`);
  console.log(`  ${LINE}`);
  console.log(`  演示目录   ${res.demoRoot}`);
  console.log('');
  for (const step of res.steps || []) {
    console.log(`  ✓ ${String(step.label || step.action).padEnd(6)} ${step.summary}`);
  }
  console.log('\n  产物：');
  for (const artifact of res.artifacts || []) console.log(`    ${artifact}`);
  console.log('');
}

const argv = process.argv.slice(2);
if (argv.length === 0) help();
if (argv.includes('--help') || argv.includes('-h')) help();

const opt = parseArgs(argv);
const found = findPython();
if (found.error) {
  fail(`${found.error}，无法处理图片`, PY_HINT, 3, opt.json, { dependency: 'python' });
}

if (opt.demo) {
  const res = callPython(found.python, 'demo', {});
  if (!res.ok) fail(res.message, res.hint, res.code || 1, opt.json);
  if (opt.json) console.log(JSON.stringify(res, null, 2));
  else humanDemo(res);
  process.exit(0);
}

if (!opt.action) {
  fail('缺少子命令', `可用子命令：${Object.keys(ACTIONS).join(' / ')}\n用 ${CMD} --help 查看详情。`, 2, opt.json);
}
if (!Object.hasOwn(ACTIONS, opt.action)) {
  fail(`未知子命令：${opt.action}`, `可用子命令：${Object.keys(ACTIONS).join(' / ')}`, 2, opt.json);
}
if (!opt.input) {
  fail('缺少 --input（文件或目录）', `例：${CMD} ${opt.action} --input ./图片目录`, 2, opt.json);
}
if (opt.action === 'watermark' && !(opt.text && opt.text.trim())) {
  fail('缺少 --text（水印文字）',
    `例：${CMD} watermark --input ./图片 --text "© 深鲸科技"`, 2, opt.json);
}
if (opt.action === 'convert' && !opt.format) {
  fail('缺少 --format（目标格式）',
    `例：${CMD} convert --input ./图片 --format webp`, 2, opt.json);
}
if (opt.action === 'resize' && !opt.maxWidth && !opt.maxHeight) {
  fail('resize 需要 --max-width 或 --max-height',
    `例：${CMD} resize --input ./图片 --max-width 1280（只缩小，不放大）`, 2, opt.json);
}

const res = callPython(found.python, opt.action, payloadOf(opt));
if (!res.ok) fail(res.message, res.hint, res.code || 1, opt.json);

if (opt.json) console.log(JSON.stringify(res, null, 2));
else human(res);
// 部分文件坏了：产物照出，但退出码要如实反映
process.exit(res.failed && res.failed.length ? 1 : 0);
