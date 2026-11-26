// The Terminal page puts the bridge's messages back in their order (seq),
// whatever order Action Cable delivers them in (docs/terminal.md, "The
// order of the messages"). Needs only the Rails server and a user who may
// sign in (no bridge): the messages are handed to the page's controller as
// the channel would, swapped.
//
//   CONSOLE_EMAIL=me@example.org CONSOLE_PASSWORD=... \
//     HEADLESS_SCRIPT=terminal_order.js script/headless/run
//
// Prints one line per case and exits 1 when one fails.
const { chromium } = require("playwright");
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 }, locale: "en-US" });
  const base = process.env.CONSOLE_URL || "http://host.docker.internal:3000/";
  if (process.env.CONSOLE_EMAIL) {
    await page.goto(new URL("/session/new", base).href);
    await page.fill("input[name=email_address]", process.env.CONSOLE_EMAIL);
    await page.fill("input[name=password]", process.env.CONSOLE_PASSWORD || "");
    await Promise.all([page.waitForNavigation(), page.click("input[type=submit]")]);
  }
  await page.goto(new URL("/terminal", base).href);
  await page.waitForFunction(() => window.consoleTerminal && window.consoleTerminal.subscription, null, { timeout: 15000 });
  await page.waitForTimeout(1000);

  // Feeds messages to the page as if they came on its stream, for a
  // command the page believes runs (an id no row has).
  const feed = (id, msgs) => page.evaluate(([id, msgs]) => {
    const c = window.consoleTerminal;
    c.running = id;
    for (const m of msgs) c.received({ id, ...m });
  }, [id, msgs]);
  const screen = () => page.evaluate(() => {
    const b = window.consoleTerminal.term.buffer.active;
    const out = [];
    for (let i = 0; i < b.length; i++) out.push(b.getLine(i).translateToString(true));
    return out.join("\n");
  });
  const state = () => page.evaluate(() => ({ running: window.consoleTerminal.running, kept: window.consoleTerminal.orders ? window.consoleTerminal.orders.size : 0 }));

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail });

  // 1: done first, then the output, then started.
  await feed(990001, [
    { type: "done", seq: 3, status: "ok", output_bytes: 9 },
    { type: "output", seq: 2, data: "swapped-1\n" },
    { type: "started", seq: 1 },
  ]);
  let s = await state();
  check("done before its output: the output is shown, then the command ends",
        (await screen()).includes("swapped-1") && s.running === null && s.kept === 0, s);

  // 2: two outputs swapped, then done.
  await feed(990002, [
    { type: "started", seq: 1 },
    { type: "output", seq: 3, data: "second-2\n" },
    { type: "output", seq: 2, data: "first-2\n" },
    { type: "done", seq: 4, status: "ok", output_bytes: 17 },
  ]);
  let text = await screen();
  check("outputs swapped: shown in their order", text.indexOf("first-2") >= 0 && text.indexOf("first-2") < text.indexOf("second-2"),
        text.split("\n").filter((l) => l.includes("-2")));

  // 3: a message that never comes (seq 1): the rest goes on after the wait.
  await feed(990003, [
    { type: "output", seq: 2, data: "after-gap-3\n" },
    { type: "done", seq: 3, status: "ok", output_bytes: 12 },
  ]);
  s = await state();
  const held = s.running === 990003 && !(await screen()).includes("after-gap-3");
  await page.waitForTimeout(2600);
  s = await state();
  check("a gap not filled: kept, then handled in order after 2 s",
        held && (await screen()).includes("after-gap-3") && s.running === null && s.kept === 0, s);

  // 4: an older bridge (no seq): handled as they come.
  await feed(990004, [
    { type: "output", data: "no-seq-4\n" },
    { type: "done", status: "ok", output_bytes: 9 },
  ]);
  s = await state();
  check("no seq: as before", (await screen()).includes("no-seq-4") && s.running === null, s);

  // 5: a Tab's answer with its number.
  const tab = await page.evaluate(() => {
    const c = window.consoleTerminal;
    c.buf = [..."node l"]; c.cur = c.buf.length; c.draw();
    c.completing = 990005; c.tabLine = "node l";
    c.received({ type: "complete", id: 990005, seq: 1, word: "l", candidates: ["list"] });
    const line = c.buf.join("");
    c.buf = []; c.cur = 0; c.draw();
    return line;
  });
  check("a Tab's answer (seq 1)", tab === "node list ", tab);

  for (const r of results) console.log(`${r.ok ? "ok  " : "FAIL"} ${r.name}${r.ok ? "" : ` ${JSON.stringify(r.detail)}`}`);
  await browser.close();
  process.exit(results.every((r) => r.ok) ? 0 : 1);
})();
