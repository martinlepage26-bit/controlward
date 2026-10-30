type PageCapture = {
  title: string;
  sourceURL: string;
  businessName: string;
  websiteURL: string;
  municipality: string;
  hints: Array<{ label: string; value: string }>;
};

type BridgeReply = {
  version: number;
  requestID: string;
  ok: boolean;
  error?: { code: string; message: string };
  paired?: boolean;
  pairingToken?: string;
  segments?: Array<{ id: string; label: string; priority: number }>;
  previewID?: string;
  status?: string;
  reasons?: string[];
  fields?: Array<{ name: string; value: string; sourceURL: string; excerpt: string }>;
  segment?: string;
  duplicate?: boolean;
  existing?: { id: string; name: string; domain: string; email: string; phone: string; status: string };
  qualificationNote?: string;
  captureTime?: string;
  saved?: boolean;
  updated?: boolean;
  recordID?: string;
  message?: string;
};

const $ = <T extends HTMLElement>(selector: string): T => {
  const element = document.querySelector<T>(selector);
  if (!element) throw new Error(`Missing UI element: ${selector}`);
  return element;
};

const connectButton = $("#connect") as HTMLButtonElement;
const pairButton = $("#pair") as HTMLButtonElement;
const unpairButton = $("#unpair") as HTMLButtonElement;
const captureButton = $("#capture") as HTMLButtonElement;
const evaluateButton = $("#evaluate") as HTMLButtonElement;
const saveButton = $("#save") as HTMLButtonElement;
const statusLine = $("#connection-status");
const messageBox = $("#message");
const form = $("#capture-form") as HTMLFormElement;
const previewBox = $("#preview");
const hintsBox = $("#page-hints");
const fieldsBox = $("#evidence-fields");
const segmentSelect = $("#segment") as HTMLSelectElement;
const businessInput = $("#business-name") as HTMLInputElement;
const websiteInput = $("#website-url") as HTMLInputElement;
const municipalityInput = $("#municipality") as HTMLInputElement;
const allowFetchInput = $("#allow-fetch") as HTMLInputElement;
const confirmSaveInput = $("#confirm-save") as HTMLInputElement;
const duplicateChoice = $("#duplicate-choice");
const saveDecision = $("#save-decision") as HTMLSelectElement;
const languageSelect = $("#language") as HTMLSelectElement;
const translations: Record<string, Record<string, string>> = {
  en: {
    language: "Language", brand: "CONTROLWARD · CHROME COMPANION", title: "Business capture", intro: "Capture, qualify, review, then save. Nothing is read or sent until you choose an action.",
    check: "Check connection", pair: "Pair this extension", unpair: "Unpair", capture: "Capture", captureIntro: "Only the current page’s basic business metadata is read after you click.",
    capturePage: "Capture current page", businessName: "Business name", website: "Business website to fetch", municipality: "Municipality hint (unverified; not used for location/RBQ rules)",
    segment: "ControlWard segment", chooseSegment: "Choose a ControlWard segment", fetchConsent: "I reviewed the business name, website, municipality and segment, and authorize ControlWard to fetch this public business website under its existing safeguards.",
    evaluate: "Evaluate with ControlWard", review: "Qualification and review", reviewCaution: "The existing ControlWard rules produce this status; it is not marketing approval.",
    possibleDuplicate: "Possible duplicate", decision: "Decision", chooseDecision: "Choose one; no automatic update", update: "Update the existing record after this review", skip: "Skip — do not change the register",
    saveStep: "Save", saveConsent: "I reviewed the evidence, qualification status and duplicate result. I explicitly authorize this local ControlWard Leads change.", save: "Save to ControlWard",
    footer: "No Worker key is stored here. This extension does not contact the PHAROS Worker, create outreach, or send messages.",
    statusConnected: "Paired with ControlWard on this Mac", statusTokenMissing: "ControlWard is paired, but the browser token is missing; use the documented reset steps", statusPairRequired: "Connected; pairing is required before capture",
    statusDisconnected: "ControlWard native host disconnected", statusUnavailable: "Native host unavailable"
  },
  fr: {
    language: "Langue", brand: "CONTROLWARD · EXTENSION CHROME", title: "Capture d’entreprise", intro: "Capturez, qualifiez, révisez, puis enregistrez. Rien n’est lu ni envoyé avant votre action.",
    check: "Vérifier la connexion", pair: "Associer cette extension", unpair: "Dissocier", capture: "Capture", captureIntro: "Les métadonnées commerciales de la page active sont lues uniquement après votre clic.",
    capturePage: "Capturer la page active", businessName: "Nom de l’entreprise", website: "Site Web commercial à vérifier", municipality: "Municipalité (indice non vérifié; non utilisée pour les règles RBQ ou de territoire)",
    segment: "Segment ControlWard", chooseSegment: "Choisir un segment ControlWard", fetchConsent: "J’ai vérifié le nom, le site Web, la municipalité et le segment; j’autorise ControlWard à consulter ce site commercial public selon ses mesures de protection existantes.",
    evaluate: "Évaluer avec ControlWard", review: "Qualification et révision", reviewCaution: "Ce statut provient des règles ControlWard existantes; ce n’est pas une approbation marketing.",
    possibleDuplicate: "Doublon possible", decision: "Décision", chooseDecision: "Choisir; aucune mise à jour automatique", update: "Mettre à jour la fiche existante après révision", skip: "Ignorer — ne pas modifier le registre",
    saveStep: "Enregistrer", saveConsent: "J’ai révisé les preuves, le statut de qualification et le résultat des doublons. J’autorise explicitement cette modification locale dans ControlWard Leads.", save: "Enregistrer dans ControlWard",
    footer: "Aucune clé Worker n’est stockée ici. Cette extension ne contacte pas le Worker PHAROS, ne crée pas de prospection et n’envoie aucun message.",
    statusConnected: "Associée à ControlWard sur ce Mac", statusTokenMissing: "ControlWard est associé, mais le jeton du navigateur manque; suivez la procédure de réinitialisation", statusPairRequired: "Connectée; l’association est requise avant la capture",
    statusDisconnected: "Connexion à l’hôte ControlWard interrompue", statusUnavailable: "Hôte natif indisponible"
  }
};
let language: "en" | "fr" = "en";
function localize() {
  document.documentElement.lang = language;
  for (const element of Array.from(document.querySelectorAll<HTMLElement>("[data-cw-i18n]"))) {
    const key = element.dataset.cwI18n || "";
    const value = translations[language][key];
    if (value) element.textContent = value;
  }
}
function translated(key: string): string { return translations[language][key] || translations.en[key] || key; }

let port: chrome.runtime.Port | null = null;
let token = "";
let sourceURL = "";
let previewID = "";
let currentReply: BridgeReply | null = null;
let requests = new Map<string, { resolve: (v: BridgeReply) => void; reject: (e: Error) => void; timer: number }>();

function showMessage(text: string, kind: "info" | "error" | "success" = "info") {
  messageBox.textContent = text;
  messageBox.className = `message ${kind}`;
  messageBox.hidden = !text;
}

function wirePort(): chrome.runtime.Port {
  if (port) return port;
  const nativePort = chrome.runtime.connectNative("com.controlward.chrome_bridge");
  nativePort.onMessage.addListener((reply: BridgeReply) => {
    const pending = requests.get(reply.requestID);
    if (!pending) return;
    window.clearTimeout(pending.timer);
    requests.delete(reply.requestID);
    pending.resolve(reply);
  });
  nativePort.onDisconnect.addListener(() => {
    port = null;
    const detail = chrome.runtime.lastError?.message || "Native host disconnected.";
    for (const [, pending] of requests) {
      window.clearTimeout(pending.timer);
      pending.reject(new Error(detail));
    }
    requests.clear();
    statusLine.textContent = translated("statusDisconnected");
    statusLine.className = "status error";
  });
  port = nativePort;
  return nativePort;
}

function request(op: string, extra: Record<string, unknown> = {}): Promise<BridgeReply> {
  const nativePort = wirePort();
  const requestID = crypto.randomUUID();
  const payload = { version: 1, requestID, op, extensionID: chrome.runtime.id, ...extra };
  return new Promise<BridgeReply>((resolve, reject) => {
    const timer = window.setTimeout(() => {
      requests.delete(requestID);
      reject(new Error("ControlWard did not respond in time."));
    }, 120_000);
    requests.set(requestID, { resolve, reject, timer });
    try { nativePort.postMessage(payload); }
    catch (error) {
      window.clearTimeout(timer);
      requests.delete(requestID);
      reject(error instanceof Error ? error : new Error("Unable to reach ControlWard."));
    }
  }).then(reply => {
    if (!reply.ok) throw new Error(reply.error?.message || "ControlWard rejected this request.");
    return reply;
  });
}

async function refreshConnection() {
  try {
    const reply = await request("status");
    token = (await chrome.storage.local.get("controlWardPairingToken")).controlWardPairingToken || "";
    const paired = Boolean(reply.paired && token);
    statusLine.textContent = paired ? translated("statusConnected") : reply.paired ? translated("statusTokenMissing") : translated("statusPairRequired");
    statusLine.className = `status ${paired ? "connected" : ""}`;
    pairButton.disabled = Boolean(reply.paired);
    unpairButton.disabled = !paired;
    captureButton.disabled = !paired;
    segmentSelect.replaceChildren(new Option(translated("chooseSegment"), ""));
    for (const segment of reply.segments || []) {
      segmentSelect.add(new Option(`${segment.label} · priority ${segment.priority}`, segment.id));
    }
    if (!(reply.segments || []).length) showMessage("ControlWard’s confirmed segment configuration is unavailable. Build the app with its bundled lead resources.", "error");
  } catch (error) {
    statusLine.textContent = translated("statusUnavailable");
    statusLine.className = "status error";
    showMessage(error instanceof Error ? error.message : String(error), "error");
  }
}

async function captureActivePage() {
  try {
    const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    const tab = tabs[0];
    if (!tab?.id || !tab.url || !/^https?:\/\//i.test(tab.url)) throw new Error("Open an ordinary public business page before capture.");
    const result = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: extractPageFields });
    const captured = result[0]?.result as PageCapture | undefined;
    if (!captured) throw new Error("Could not read a business name from this page.");
    sourceURL = stripTracking(captured.sourceURL || tab.url);
    businessInput.value = captured.businessName;
    websiteInput.value = captured.websiteURL;
    municipalityInput.value = captured.municipality;
    hintsBox.replaceChildren();
    const title = document.createElement("p");
    title.textContent = `Captured from ${sourceURL}`;
    hintsBox.append(title);
    for (const hint of captured.hints) {
      const line = document.createElement("p");
      line.textContent = `${hint.label}: ${hint.value}`;
      hintsBox.append(line);
    }
    hintsBox.hidden = false;
    previewBox.hidden = true;
    currentReply = null;
    previewID = "";
    form.hidden = false;
    showMessage("Review and correct the name, business website, municipality and segment. ControlWard will fetch only the selected website through its existing guarded pipeline.");
  } catch (error) {
    showMessage(error instanceof Error ? error.message : String(error), "error");
  }
}

function extractPageFields(): PageCapture {
  const sourceURL = `${location.origin}${location.pathname}`;
  const entities: any[] = [];
  const addEntity = (value: any) => {
    if (Array.isArray(value)) value.forEach(addEntity);
    else if (value && typeof value === "object") {
      if (Array.isArray(value["@graph"])) value["@graph"].forEach(addEntity);
      else entities.push(value);
    }
  };
  for (const script of Array.from(document.querySelectorAll('script[type="application/ld+json"]')).slice(0, 40)) {
    try { addEntity(JSON.parse(script.textContent || "")); } catch { /* malformed page metadata is ignored */ }
  }
  const businessTypes = /organization|localbusiness|professionalservice|medicalbusiness|store|homeandconstructionbusiness/i;
  const entity = entities.find(item => {
    const type = Array.isArray(item["@type"]) ? item["@type"].join(" ") : String(item["@type"] || "");
    return businessTypes.test(type) && typeof item.name === "string" && item.name.trim();
  });
  const read = (value: any): string => typeof value === "string" ? value.trim() : "";
  const address = entity?.address;
  const municipality = read(address?.addressLocality) || read(entity?.addressLocality);
  const candidateSite = read(entity?.url) || document.querySelector<HTMLLinkElement>('link[rel="canonical"]')?.href || location.origin;
  const websiteURL = /^https?:\/\//i.test(candidateSite) ? new URL(candidateSite).origin : location.origin;
  const emailLink = document.querySelector<HTMLAnchorElement>('a[href^="mailto:"]')?.href?.replace(/^mailto:/i, "").split("?")[0] || "";
  const phoneLink = document.querySelector<HTMLAnchorElement>('a[href^="tel:"]')?.href?.replace(/^tel:/i, "") || "";
  const hints: Array<{ label: string; value: string }> = [];
  if (emailLink) hints.push({ label: "Page email hint (unverified)", value: emailLink.slice(0, 180) });
  if (phoneLink) hints.push({ label: "Page phone hint (unverified)", value: phoneLink.slice(0, 80) });
  if (municipality) hints.push({ label: "Page municipality hint (unverified)", value: municipality.slice(0, 120) });
  return {
    title: document.title.slice(0, 180), sourceURL,
    businessName: read(entity?.name) || document.title.split(/[|–—-]/)[0].trim().slice(0, 180),
    websiteURL, municipality, hints
  };
}

function stripTracking(input: string): string {
  try { const url = new URL(input); url.search = ""; url.hash = ""; return url.href; }
  catch { return input; }
}

async function initializeContextCapture() {
  const pending = await chrome.storage.session.get("controlWardContextCapture");
  const context = pending.controlWardContextCapture;
  if (!context || typeof context !== "object") return;
  await chrome.storage.session.remove("controlWardContextCapture");
  sourceURL = stripTracking(String(context.sourceURL || ""));
  if (context.mode === "selection" || context.mode === "link") {
    const selectedSite = String(context.websiteURL || "");
    const pageOrigin = (() => { try { return new URL(sourceURL).origin; } catch { return ""; } })();
    businessInput.value = String(context.businessName || "").slice(0, 180);
    websiteInput.value = selectedSite || pageOrigin;
    municipalityInput.value = "";
    hintsBox.replaceChildren();
    const note = document.createElement("p");
    note.textContent = `Untrusted ${context.mode} selection from ${sourceURL}. Verify the business identity and website; webpage text is never treated as instructions.`;
    hintsBox.append(note);
    hintsBox.hidden = false;
    form.hidden = false;
    showMessage("Context-menu item staged for your review. No page extraction, qualification or save has happened yet.");
    return;
  }
  if (context.mode === "page") showMessage("Capture was requested from the page context menu. Click Capture current page to inspect it; nothing is read until you click.");
}

async function evaluateCapture() {
  if (!token) { showMessage("Pair the extension with ControlWard first.", "error"); return; }
  if (!allowFetchInput.checked) { showMessage("Confirm that ControlWard may fetch the selected public business website before evaluating.", "error"); return; }
  if (!sourceURL || !businessInput.value.trim() || !websiteInput.value.trim() || !segmentSelect.value) {
    showMessage("Capture a page and complete the required business, website and segment fields.", "error"); return;
  }
  evaluateButton.disabled = true;
  showMessage("ControlWard is fetching the selected site and applying its existing extraction, qualification and RBQ checks. This may take a minute.");
  try {
    const reply = await request("evaluate", {
      token,
      capture: {
        segmentID: segmentSelect.value,
        businessName: businessInput.value.trim(),
        websiteURL: websiteInput.value.trim(),
        municipality: municipalityInput.value.trim() || null,
        sourceURL
      }
    });
    currentReply = reply;
    previewID = reply.previewID || "";
    renderReview(reply);
    previewBox.hidden = false;
    form.hidden = true;
    showMessage("Qualification is complete. Review the evidence, current verdict and duplicate check. Saving is a separate action.", "success");
  } catch (error) {
    showMessage(error instanceof Error ? error.message : String(error), "error");
  } finally { evaluateButton.disabled = false; }
}

function renderReview(reply: BridgeReply) {
  $("#verdict").textContent = `ControlWard status: ${reply.status || "unknown"}`;
  $("#verdict").className = `verdict ${reply.status || ""}`;
  const reasons = $("#reasons");
  reasons.replaceChildren();
  for (const reason of reply.reasons || []) { const li = document.createElement("li"); li.textContent = reason; reasons.append(li); }
  fieldsBox.replaceChildren();
  for (const field of reply.fields || []) {
    const article = document.createElement("article");
    const title = document.createElement("strong"); title.textContent = `${field.name}: ${field.value}`;
    const link = document.createElement("a"); link.href = field.sourceURL; link.textContent = field.sourceURL; link.target = "_blank"; link.rel = "noreferrer";
    const excerpt = document.createElement("p"); excerpt.textContent = field.excerpt;
    article.append(title, link, excerpt); fieldsBox.append(article);
  }
  if (reply.duplicate && reply.existing) {
    duplicateChoice.hidden = false;
    saveDecision.value = "";
    const existing = reply.existing;
    $("#duplicate-summary").textContent = `Possible existing record: ${existing.name} (${existing.domain || "no domain"}), status ${existing.status}${existing.email ? `, email ${existing.email}` : ""}${existing.phone ? `, phone ${existing.phone}` : ""}. Choose Update (explicit overwrite/review) or Skip; no automatic merge is permitted here.`;
  } else { duplicateChoice.hidden = true; saveDecision.value = "create"; }
  $("#qualification-note").textContent = reply.qualificationNote || "";
  $("#capture-time").textContent = reply.captureTime ? `Native fetch time: ${reply.captureTime}` : "";
  confirmSaveInput.checked = false;
  saveButton.disabled = true;
}

async function saveReviewed() {
  if (!currentReply || !previewID || !token) return;
  const decision = currentReply.duplicate ? saveDecision.value : "create";
  if (currentReply.duplicate && !["update", "skip"].includes(decision)) {
    showMessage("Choose Update or Skip for the possible duplicate.", "error"); return;
  }
  if (!confirmSaveInput.checked) { showMessage("Review the status, evidence and duplicate result, then check the save confirmation.", "error"); return; }
  const actionText = decision === "skip" ? "skip without changing ControlWard" : decision === "update" ? "update the existing ControlWard lead" : "create a new ControlWard lead";
  const exact = `${actionText}\n\nBusiness: ${businessInput.value.trim()}\nWebsite: ${websiteInput.value.trim()}\nVerdict: ${currentReply.status}\n\nContinue?`;
  if (!window.confirm(exact)) return;
  saveButton.disabled = true;
  try {
    const reply = await request("save", { token, previewID, decision, confirm: true });
    if (reply.saved) {
      showMessage(`${reply.message || "Saved."} Record ${reply.recordID || ""}${reply.updated ? " (updated existing record)" : " (new record)"}.`, "success");
      previewBox.hidden = true;
      currentReply = null; previewID = "";
      confirmSaveInput.checked = false;
      await refreshConnection();
    } else {
      showMessage(reply.message || "Skipped; no record was changed.", "info");
      previewBox.hidden = true;
      currentReply = null; previewID = "";
    }
  } catch (error) {
    showMessage(error instanceof Error ? error.message : String(error), "error");
    saveButton.disabled = false;
  }
}

languageSelect.addEventListener("change", async () => {
  language = languageSelect.value === "fr" ? "fr" : "en";
  await chrome.storage.local.set({ controlWardLanguage: language });
  localize();
  void refreshConnection();
});
connectButton.addEventListener("click", () => { void refreshConnection(); });
pairButton.addEventListener("click", async () => {
  try {
    const status = await request("status");
    if (status.paired) throw new Error("This host is already paired. Unpair with the original extension token or follow the reset instructions.");
    const reply = await request("pair");
    if (!reply.pairingToken) throw new Error("ControlWard did not return a pairing token.");
    token = reply.pairingToken;
    await chrome.storage.local.set({ controlWardPairingToken: token });
    showMessage("Paired. The token is stored in this extension’s local storage, not sync storage.", "success");
    await refreshConnection();
  } catch (error) { showMessage(error instanceof Error ? error.message : String(error), "error"); }
});
unpairButton.addEventListener("click", async () => {
  if (!token || !window.confirm("Unpair this Chrome extension from ControlWard on this Mac?")) return;
  try {
    await request("unpair", { token });
    token = "";
    await chrome.storage.local.remove("controlWardPairingToken");
    previewBox.hidden = true; form.hidden = true;
    showMessage("Unpaired. No lead data was changed.", "success");
    await refreshConnection();
  } catch (error) { showMessage(error instanceof Error ? error.message : String(error), "error"); }
});
captureButton.addEventListener("click", () => { void captureActivePage(); });
evaluateButton.addEventListener("click", () => { void evaluateCapture(); });
confirmSaveInput.addEventListener("change", () => { saveButton.disabled = !confirmSaveInput.checked || !currentReply || (Boolean(currentReply.duplicate) && !["update", "skip"].includes(saveDecision.value)); });
saveDecision.addEventListener("change", () => { saveButton.disabled = !confirmSaveInput.checked || (Boolean(currentReply?.duplicate) && !["update", "skip"].includes(saveDecision.value)); });
saveButton.addEventListener("click", () => { void saveReviewed(); });

void (async () => {
  const stored = await chrome.storage.local.get("controlWardLanguage");
  language = stored.controlWardLanguage === "fr" ? "fr" : "en";
  languageSelect.value = language;
  localize();
  await refreshConnection();
  await initializeContextCapture();
})();
