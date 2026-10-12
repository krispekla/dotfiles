// Opened by herdr (scripts/chrome-group.sh, cmd+/ t) as
//   launch.html?title=…&kind=work|review&url=…&url=…
// This tab turns into the first url and becomes the group's first tab; the other urls open next
// to it. Running it again for a group that is already open in this window focuses that group.
// Colours: work and review take from separate sets, and each new group takes the first colour
// of its set that no open group in the window uses yet.
const PALETTES = {
  work: ['blue', 'cyan', 'green', 'yellow'],
  review: ['purple', 'pink', 'red', 'orange'],
};
// Only local dev servers, Azure DevOps and Jira-style task links (https://<host>/browse/KEY-123)
// get opened, whatever the query string says
const ALLOWED =
  /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/|^https:\/\/dev\.azure\.com\/|^https:\/\/[^/]+\/browse\/[A-Z][A-Z0-9]+-\d+$/;

const params = new URLSearchParams(location.search);
const title = params.get('title') || 'worktree';
const kind = params.get('kind') === 'review' ? 'review' : 'work';
const urls = params.getAll('url').filter((url) => ALLOWED.test(url));

async function main() {
  const self = await chrome.tabs.getCurrent();
  const groups = await chrome.tabGroups.query({ windowId: self.windowId });

  const existing = groups.find((group) => group.title === title);
  if (existing) {
    const [first] = await chrome.tabs.query({ groupId: existing.id });
    await chrome.tabGroups.update(existing.id, { collapsed: false });
    await chrome.tabs.update(first.id, { active: true });
    await chrome.tabs.remove(self.id);
    return;
  }
  if (urls.length === 0) {
    document.body.textContent = 'Nothing to open: no allowed urls given.';
    return;
  }

  const used = new Set(groups.map((group) => group.color));
  const palette = PALETTES[kind];
  const color = palette.find((c) => !used.has(c)) ?? palette[groups.length % palette.length];

  const others = await Promise.all(
    urls.slice(1).map((url, i) =>
      chrome.tabs.create({ url, windowId: self.windowId, index: self.index + 1 + i, active: false }),
    ),
  );
  const groupId = await chrome.tabs.group({ tabIds: [self.id, ...others.map((tab) => tab.id)] });
  await chrome.tabGroups.update(groupId, { title, color });
  await chrome.tabs.update(self.id, { url: urls[0] });
}

main().catch((error) => {
  document.body.textContent = `herdr tab group failed: ${error}`;
});
