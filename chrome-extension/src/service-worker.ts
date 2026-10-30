chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "controlward-capture-page",
    title: "Capture this business / Capturer cette entreprise with ControlWard…",
    contexts: ["page"]
  });
  chrome.contextMenus.create({
    id: "controlward-capture-selection",
    title: "Review selected text / Réviser le texte sélectionné as a ControlWard business…",
    contexts: ["selection"]
  });
  chrome.contextMenus.create({
    id: "controlward-capture-link",
    title: "Review this link / Réviser ce lien as a ControlWard website…",
    contexts: ["link"]
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab?.id) return;
  const sourceURL = tab.url ? stripTrackingForContext(tab.url) : "";
  if (info.menuItemId === "controlward-capture-selection") {
    await chrome.storage.session.set({ controlWardContextCapture: {
      sourceURL,
      businessName: (info.selectionText || "").slice(0, 180),
      websiteURL: "",
      mode: "selection"
    } });
  } else if (info.menuItemId === "controlward-capture-link") {
    await chrome.storage.session.set({ controlWardContextCapture: {
      sourceURL,
      businessName: "",
      websiteURL: info.linkUrl ? stripTrackingForContext(info.linkUrl) : "",
      mode: "link"
    } });
  } else if (info.menuItemId === "controlward-capture-page") {
    await chrome.storage.session.set({ controlWardContextCapture: { sourceURL, mode: "page" } });
  } else return;
  await chrome.sidePanel.open({ tabId: tab.id });
});

function stripTrackingForContext(value: string): string {
  try { const url = new URL(value); url.search = ""; url.hash = ""; return url.href; }
  catch { return ""; }
}
