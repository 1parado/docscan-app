/**
 * Central map of the user-visible strings the suites drive.
 *
 * Every tap/assert in the suites goes through here rather than repeating
 * literals, so when the UI copy changes exactly one file has to be updated —
 * and `node android_test/probe.cjs` tells you which entries drifted instead of
 * failing with a bare "element not found".
 */
'use strict';

const TABS = { scan: '扫描', docs: '文档' };

const HOME = {
  brand: 'DocScan',
  modes: { color: '彩色', gray: '灰度', bw: '黑白' },
  autoCrop: '裁边',
  shoot: '拍摄',
  album: '相册',
  recents: '最近的文档',
  sessionPrefix: '已拍',
  workingPrefix: '处理中',
  clear: '清空',
  next: '下一步',
  sortHint: '长按页面可排序或删除',
  editingHint: '排序中',
};

/**
 * The ◀ × ▶ row a long-pressed page gets. The labels are the app's own
 * semantics, so this is both the handle the suites aim at and the contract the
 * widget has to keep.
 */
const PAGES = {
  prev: (n) => `第 ${n} 页前移`,
  delete: (n) => `删除第 ${n} 页`,
  next: (n) => `第 ${n} 页后移`,
};

const CAMERA = {
  single: '单页',
  multi: '多页',
  autoDetect: '自动', // the 自动检测 toggle (icon-only, matched positionally)
  close: '关闭',
  doneHint: '继续拍下一页',
  shotPrefix: '页就绪',
  unavailable: '相机不可用',
};

const ADJUST = {
  title: '调整裁剪',
  cancel: '取消',
  apply: '应用并重扫',
};

const RESULT = {
  title: '导出 PDF',
  doneTitle: '完成',
  pagesMeta: 'A4',
  nameLabel: '文档名',
  save: '保存到文档',
  home: '回首页',
  share: '分享 PDF',
  exportFail: '导出失败',
  // '有 2 页未检测到边缘 · 点页面手动裁剪' — the only place the app says a page
  // went through the pipeline without an edge, now that the warp runs at 下一步.
  cropWarning: '页未检测到边缘',
  cropBadge: '待裁剪',
};

const DOCS = {
  title: '文档',
  multiSelect: '多选',
  selectedPrefix: '已选',
  batchRename: '批量命名',
  delete: '删除',
  done: '完成',
  renameSheet: '重命名',
  cancel: '取消',
  renameSave: '保存',
  batchSheet: '批量重命名',
  filterHint: '按名称筛选',
  dateFilter: '日期',
  countPrefix: '个文档',
  empty: '还没有文档',
  emptyFiltered: '没有匹配的文档',
  share: '分享',
  print: '打印',
  openFail: '无法打开',
};

/** Strings the app must never print on a healthy run. */
const DEFECT_MARKERS = [
  'Unhandled Exception',
  'LateInitializationError',
  'RangeError',
  'NoSuchMethodError',
  'RenderFlex overflow',
  'Camera is not initialized',
];

/**
 * Which labels prove we are on a given screen. Used by `onScreen()`.
 * Any one hit is enough, so the probe stays useful after a redesign.
 */
const SCREEN_SIGNATURES = {
  home: [HOME.shoot, HOME.album],
  camera: [CAMERA.single, CAMERA.multi],
  adjust: [ADJUST.title, ADJUST.apply],
  result: [RESULT.save, RESULT.title],
  docs: [DOCS.countPrefix, DOCS.title],
  picker: ['近期的图片', 'JPG', 'Photos', 'DCIM'],
};

function onScreen(nodes) {
  const text = nodes.map((n) => `${n.desc} ${n.text}`).join(' | ');
  for (const [name, keys] of Object.entries(SCREEN_SIGNATURES)) {
    if (keys.some((k) => text.includes(k))) return name;
  }
  return 'unknown';
}

module.exports = { TABS, HOME, PAGES, CAMERA, ADJUST, RESULT, DOCS, DEFECT_MARKERS, SCREEN_SIGNATURES, onScreen };
