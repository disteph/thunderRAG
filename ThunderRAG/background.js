async function startup() {
  try {
    if (browser.ragFilterAction?.register) {
      await browser.ragFilterAction.register();
    }
  } catch (e) {
    console.error(e);
  }
}

function openQueryTab() {
  try {
    const url = browser.runtime.getURL("ui/query.html");
    browser.tabs.create({ url });
  } catch (e) {
    console.error(e);
  }
}

if (browser.browserAction && browser.browserAction.onClicked) {
  browser.browserAction.onClicked.addListener(() => {
    openQueryTab();
  });
}

browser.runtime.onMessage.addListener(async (msg) => {
  try {
    if (!msg || typeof msg !== "object") {
      return;
    }

    if (msg.type === "openMessageByHeaderMessageId") {
      let headerMessageId = msg.headerMessageId;
      if (!headerMessageId || typeof headerMessageId !== "string") {
        throw new Error("Missing headerMessageId");
      }

      headerMessageId = headerMessageId.trim();

      async function resolveMessageId(hmid) {
        const result = await browser.messages.query({ headerMessageId: hmid });
        const first = result?.messages?.[0];
        return first ? first.id : null;
      }

      let messageId = await resolveMessageId(headerMessageId);
      if (!messageId && headerMessageId.startsWith("<") && headerMessageId.endsWith(">")) {
        messageId = await resolveMessageId(headerMessageId.slice(1, -1));
      }

      if (!messageId) {
        throw new Error(`Message not found for headerMessageId: ${headerMessageId}`);
      }

      return await browser.messageDisplay.open({
        messageId,
        location: "tab",
        active: true,
      });
    }
  } catch (e) {
    console.error(e);
  }
});

startup();
