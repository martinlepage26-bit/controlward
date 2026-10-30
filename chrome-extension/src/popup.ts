document.querySelector<HTMLButtonElement>("#open")?.addEventListener("click", async () => {
  const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const tabId = tabs[0]?.id;
  if (tabId === undefined) return;
  await chrome.sidePanel.open({ tabId });
  window.close();
});
