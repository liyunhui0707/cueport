"use strict";
const button = document.getElementById("copy-checksum");
button.addEventListener("click", async () => {
  const status = document.getElementById("copy-status");
  try {
    await navigator.clipboard.writeText(document.getElementById("checksum").textContent.trim());
    status.textContent = "已复制 SHA256";
  } catch {
    status.textContent = "复制未完成，请选中上方校验和手动复制。";
  }
});

const examples = {
  question: ["有待处理的问题", "Atlas", "Codex 提出了一个新问题。", "iTerm2 / atlas"],
  working: ["正在执行", "Compass", "Codex 仍在工作，目前没有待处理的问题。", "iTerm2 / compass"],
  closed: ["终端已关闭", "Beacon", "原始终端无法核对，Cueport 已暂停跳转。", "iTerm2 / beacon"]
};
const exampleButtons = document.querySelectorAll("[data-example]");
for (const control of exampleButtons) {
  control.addEventListener("click", () => {
    const fields = ["sample-status", "sample-title", "sample-text", "sample-origin"];
    fields.forEach((id, i) => {
      document.getElementById(id).textContent = examples[control.dataset.example][i];
    });
    for (const item of exampleButtons) item.setAttribute("aria-pressed", String(item === control));
  });
}

// Draw elevation lines from a continuous field in normalized map coordinates.
const terrain = document.getElementById("terrain");
function drawTerrain() {
  const ctx = terrain.getContext("2d");
  if (!ctx) return;
  const {width, height} = terrain.getBoundingClientRect();
  if (!width || !height) return;
  const scale = Math.min(window.devicePixelRatio || 1, 2);
  terrain.width = Math.round(width * scale);
  terrain.height = Math.round(height * scale);
  ctx.scale(scale, scale);
  const spacing = 8;
  const cols = Math.ceil(width / spacing) + 1;
  const rows = Math.ceil(height / spacing) + 1;
  const field = Array.from({length: rows}, (_, j) => Array.from({length: cols}, (_, i) => {
    const x = i * spacing / width, y = j * spacing / height;
    return 1.4 * Math.sin(6*x + 2*y) + Math.cos(7*y - 3*x) + .5*Math.sin(8*x + 6*y) + .16*Math.cos(16*y - 10*x);
  }));
  for (let level = -3; level <= 3; level += .12) {
    ctx.beginPath();
    for (let j=0; j<rows-1; j++) for (let i=0; i<cols-1; i++) {
      const v = [field[j][i], field[j][i+1], field[j+1][i+1], field[j+1][i]];
      const xs = [i, i+1, i+1, i], ys = [j, j, j+1, j+1];
      let crossings = 0;
      for (let a=0; a<4; a++) {
        const b = (a+1)%4;
        if ((v[a] < level) === (v[b] < level)) continue;
        const t = (level-v[a])/(v[b]-v[a]);
        const px = (xs[a]+(xs[b]-xs[a])*t)*spacing, py = (ys[a]+(ys[b]-ys[a])*t)*spacing;
        if (crossings++ % 2 === 0) ctx.moveTo(px,py);
        else ctx.lineTo(px,py);
      }
    }
    ctx.lineWidth = .85;
    ctx.strokeStyle = "rgba(215,232,184,.36)";
    ctx.stroke();
  }
}
new ResizeObserver(drawTerrain).observe(terrain);
