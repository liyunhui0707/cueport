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
