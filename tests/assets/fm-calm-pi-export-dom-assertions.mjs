import { readFileSync } from "node:fs";

const dom = readFileSync(process.argv[2], "utf8");
const messages = dom.match(/<div id="messages">([\s\S]*?)<\/main>/)?.[1];
const tree = dom.match(/<div[^>]*id="tree-container"[^>]*>([\s\S]*?)<div[^>]*id="tree-status"/)?.[1];
if (!messages || !tree) throw new Error("export DOM is missing the messages column or the session tree");
if (!/<div class="user-message"[^>]*>[\s\S]*Show a deterministic tool example\./.test(messages)) {
  throw new Error("genuine user prompt is missing from the conversation column");
}
if (!/<div class="assistant-message"[^>]*>[\s\S]*The deterministic tool example is complete\./.test(messages)) {
  throw new Error("genuine assistant reply is missing from the conversation column");
}
if (/<body[^>]*show-hidden-messages/.test(dom)) {
  throw new Error("export opened with hidden messages shown");
}
const rendersHiddenRows = /<div[^>]*class="[^"]*\bhook-message-hidden\b/.test(messages);
if (rendersHiddenRows && !/body:not\(\.show-hidden-messages\)\s+\.hook-message-hidden\s*\{[^}]*display:\s*none/.test(dom)) {
  throw new Error("export no longer hides terminal-hidden custom messages by default");
}
function stripHiddenHookMessages(html) {
  const marker = "<div";
  let out = "";
  let i = 0;
  while (i < html.length) {
    const start = html.indexOf(marker, i);
    if (start < 0) { out += html.slice(i); break; }
    const tagEnd = html.indexOf(">", start);
    if (tagEnd < 0) throw new Error("unclosed tag in the conversation column");
    const tag = html.slice(start, tagEnd + 1);
    const classes = tag.match(/class="([^"]*)"/)?.[1].split(/\s+/) ?? [];
    const hiddenHook = classes.includes("hook-message") && classes.includes("hook-message-hidden");
    if (!hiddenHook) {
      out += html.slice(i, start + marker.length);
      i = start + marker.length;
      continue;
    }
    out += html.slice(i, start);
    let depth = 0;
    let j = start;
    while (j < html.length) {
      const nextOpen = html.indexOf("<div", j);
      const nextClose = html.indexOf("</div>", j);
      if (nextClose < 0) throw new Error("unclosed hidden hook message");
      if (nextOpen >= 0 && nextOpen < nextClose) {
        depth += 1;
        j = nextOpen + 4;
      } else {
        depth -= 1;
        j = nextClose + 6;
        if (depth === 0) break;
      }
    }
    i = j;
  }
  return out;
}
const visible = stripHiddenHookMessages(messages);
if (visible.includes('<div class="hook-message"') || visible.includes("hook-message")) {
  throw new Error("a visible hook message leaked into the conversation column");
}
if (visible.includes("[firstmate-synthetic-input]") || visible.includes("/tmp/probe.status")) {
  throw new Error("a synthetic Firstmate row is visible in the conversation column");
}
for (const current of ["CURRENT_WATCHER_E2E", "CURRENT_TURN_END_E2E", "CURRENT_AWAY_E2E", "CURRENT_FROM_FIRSTMATE_E2E", "CURRENT_LAUNCH_BRIEF_E2E"]) {
  if (!visible.includes(current)) throw new Error(`operational input ${current} is missing from the conversation column`);
}
if (!tree.includes("firstmate-synthetic-input") || !tree.includes("/tmp/probe.status")) {
  throw new Error("the session tree lost the synthetic row");
}
