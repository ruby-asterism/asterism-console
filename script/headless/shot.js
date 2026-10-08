// node shot.js <out.png> [steps json]: see script/headless/run
const { chromium } = require("playwright");
const out = process.argv[2] || "shot.png";
const steps = JSON.parse(process.argv[3] || "[]");
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1500, height: 950 } });
  const logs = [];
  page.on("console", (m) => logs.push(`console.${m.type()}: ${m.text()}`));
  page.on("pageerror", (e) => logs.push(`pageerror: ${e.message}`));
  await page.goto(process.env.CONSOLE_URL || "http://host.docker.internal:3000/");
  await page.waitForFunction(() => window.consoleGraph && window.consoleGraph.nodes().length > 0, null, { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(2500);
  for (const s of steps) {
    if (s.wait) await page.waitForTimeout(s.wait);
    if (s.tapNode) await page.evaluate((id) => { const n = window.consoleGraph.getElementById(id); n.select(); n.emit("tap"); }, s.tapNode);
    if (s.tapKind) await page.evaluate((k) => { const n = window.consoleGraph.nodes(`[kind = '${k.kind}']`).filter(x => x.data('label').includes(k.label || "")).first(); n.select(); n.emit("tap"); }, s.tapKind);
    if (s.fill) await page.fill(s.fill[0], s.fill[1]);
    if (s.click) await page.click(s.click);
    if (s.press) await page.press(s.press[0], s.press[1]);
    if (s.uncheck) await page.uncheck(s.uncheck);
    if (s.check) await page.check(s.check);
    if (s.shot) await page.screenshot({ path: s.shot });
    if (s.text) logs.push(`text ${s.text}: ` + (await page.locator(s.text).innerText()).replace(/\s+/g, " ").slice(0, 1500));
    if (s.graph) logs.push("graph: " + JSON.stringify(await page.evaluate(() => {
      const by = {}; window.consoleGraph.nodes().forEach(n => { (by[n.data('kind')] ||= []).push(n.data('label')) }); return by; })));
  }
  await page.screenshot({ path: out });
  console.log(logs.join("\n"));
  await browser.close();
})();
