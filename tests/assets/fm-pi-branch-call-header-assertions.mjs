import { pathToFileURL } from "node:url";

const version = process.env.FM_STUB_PI_VERSION;
const tools = [];
const pi = {
  events: { on() {}, emit() {} },
  on() {},
  registerCommand() {},
  registerMessageRenderer() {},
  registerTool(tool) { tools.push(tool); },
  sendMessage() {},
  sendUserMessage() {},
};
const extension = await import(pathToFileURL(process.env.EXT).href);
extension.default(pi);
const theme = {
  fg(color, text) { return `<${color}>${text}</${color}>`; },
  bg(_color, text) { return text; },
  bold(text) { return `**${text}**`; },
};
const showsArgs = version === "0.99.0";
for (const [name, key, value] of [["fm_branch_outcomes", "recent", 2], ["fm_branch_processed", "through", 1]]) {
  const tool = tools.find((candidate) => candidate.name === name);
  if (!tool) throw new Error(`${name} was not registered`);
  const title = `<toolTitle>**${name}**</toolTitle>`;
  for (const expanded of [false, true]) {
    const stock = !showsArgs
      ? title
      : expanded
        ? `${title}\n<muted>  ${key}: ${value}</muted>`
        : `${title} <muted>${key}=${value}</muted>`;
    const shell = tool.renderCall({ [key]: value }, theme, { state: {}, expanded, isError: false, isPartial: false });
    const header = shell.children[0]?.text;
    if (header !== stock) {
      throw new Error(`Pi ${version} ${expanded ? "expanded" : "collapsed"} ${name} header ${JSON.stringify(header)} is not stock ${JSON.stringify(stock)}`);
    }
  }
}
