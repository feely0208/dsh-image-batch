import { createPlugin, pkgRootFrom } from '@deepwhale-cn/dsh-guard-core/plugin';

export const { name, inject, apply } = createPlugin({
  name: 'image-batch',
  pkgRoot: pkgRootFrom(import.meta.url),
  skillFile: 'skill/image-batch.md',
  binFile: 'bin/cli.mjs',
  description: '图片批量压缩 / 改尺寸 / 加水印 / 转格式（Pillow）',
  whenToUse: '用户提到「图片批量处理」或任务属于该场景时使用',
});
