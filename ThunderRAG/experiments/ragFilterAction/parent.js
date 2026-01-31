const Cu = Components.utils;

function importModule(mjsPath, jsmPath) {
  if (ChromeUtils.importESModule) {
    try {
      return ChromeUtils.importESModule(mjsPath);
    } catch (e) {
      // Fall through to legacy JSM import.
    }
  }
  return Cu.import(jsmPath);
}

var { ExtensionCommon } = importModule(
  "resource://gre/modules/ExtensionCommon.sys.mjs",
  "resource://gre/modules/ExtensionCommon.jsm"
);
var { MailServices } = importModule(
  "resource:///modules/MailServices.sys.mjs",
  "resource:///modules/MailServices.jsm"
);

if (ChromeUtils.importGlobalProperties) {
  ChromeUtils.importGlobalProperties(["fetch", "Blob", "Headers"]);
} else if (Cu.importGlobalProperties) {
  Cu.importGlobalProperties(["fetch", "Blob", "Headers"]);
}

const Cc = Components.classes;
const Ci = Components.interfaces;

const ioService = Cc["@mozilla.org/network/io-service;1"].getService(Ci.nsIIOService);
const obsService = Cc["@mozilla.org/observer-service;1"].getService(Ci.nsIObserverService);
const consoleService = Cc["@mozilla.org/consoleservice;1"].getService(Ci.nsIConsoleService);
const windowMediator = Cc["@mozilla.org/appshell/window-mediator;1"].getService(
  Ci.nsIWindowMediator
);

const ACTION_ID = "rag-filter-action@example.com#PostMessageToEndpoint";

let filterEditorObserver = null;

function isFilterEditorWindow(win) {
  try {
    const uri = win?.document?.documentURI;
    return (
      typeof uri === "string" &&
      uri.endsWith("FilterEditor.xhtml") &&
      win.document?.documentElement?.id === "FilterEditor"
    );
  } catch (e) {
    return false;
  }
}

function patchFilterEditorWindow(win) {
  try {
    if (!isFilterEditorWindow(win)) {
      return;
    }

    if (win.__ragFilterActionPatched) {
      return;
    }
    win.__ragFilterActionPatched = true;

    const Wrapper = win.customElements?.get("ruleactiontarget-wrapper");
    if (!Wrapper || !Wrapper.prototype || typeof Wrapper.prototype._getChildNode !== "function") {
      consoleService.logStringMessage(
        "[ragFilterAction] FilterEditor patch: ruleactiontarget-wrapper not available"
      );
      return;
    }

    if (!Wrapper.prototype.__ragFilterActionPatched) {
      const originalGetChildNode = Wrapper.prototype._getChildNode;
      Wrapper.prototype._getChildNode = function (type) {
        if (type === ACTION_ID) {
          return win.document.createXULElement("ruleactiontarget-forwardto");
        }
        return originalGetChildNode.call(this, type);
      };
      Wrapper.prototype.__ragFilterActionPatched = true;
    }

    for (const wrapper of win.document.querySelectorAll("ruleactiontarget-wrapper")) {
      const type = wrapper.getAttribute("type");
      if (type === ACTION_ID) {
        wrapper.removeAttribute("type");
        wrapper.setAttribute("type", type);
      }
    }

    consoleService.logStringMessage("[ragFilterAction] FilterEditor patch installed");
  } catch (e) {
    consoleService.logStringMessage(`[ragFilterAction] FilterEditor patch failed: ${e}`);
  }
}

function startFilterEditorObserver() {
  if (filterEditorObserver) {
    return;
  }

  filterEditorObserver = {
    observe(subject, topic, data) {
      if (topic !== "domwindowopened") {
        return;
      }

      try {
        let win = null;

        // In Thunderbird 140, subject isn't guaranteed to be an nsISupports
        // that implements QueryInterface, so we try multiple strategies.
        if (subject && typeof subject.addEventListener === "function") {
          win = subject;
        } else if (subject && typeof subject.QueryInterface === "function") {
          try {
            win = subject.QueryInterface(Ci.nsIDOMWindow);
          } catch (e) {
            // Fall through.
          }
        }

        if (!win && subject && typeof subject.getInterface === "function") {
          try {
            win = subject.getInterface(Ci.nsIDOMWindow);
          } catch (e) {
            // Fall through.
          }
        }

        if (!win && subject && typeof subject.QueryInterface === "function") {
          try {
            win = subject
              .QueryInterface(Ci.nsIInterfaceRequestor)
              .getInterface(Ci.nsIDOMWindow);
          } catch (e) {
            // Fall through.
          }
        }

        if (!win) {
          consoleService.logStringMessage(
            `[ragFilterAction] domwindowopened handler failed: unable to get window from subject (${typeof subject})`
          );
          return;
        }

        win.addEventListener(
          "DOMContentLoaded",
          () => {
            patchFilterEditorWindow(win);
          },
          { once: true }
        );
      } catch (e) {
        consoleService.logStringMessage(`[ragFilterAction] domwindowopened handler failed: ${e}`);
      }
    },
    QueryInterface: ChromeUtils.generateQI(["nsIObserver"]),
  };

  obsService.addObserver(filterEditorObserver, "domwindowopened");

  try {
    const existing = windowMediator.getMostRecentWindow("mailnews:filtereditor");
    if (existing) {
      patchFilterEditorWindow(existing);
    }
  } catch (e) {
    consoleService.logStringMessage(`[ragFilterAction] existing FilterEditor patch check failed: ${e}`);
  }
}

function stopFilterEditorObserver() {
  if (!filterEditorObserver) {
    return;
  }
  try {
    obsService.removeObserver(filterEditorObserver, "domwindowopened");
  } catch (e) {
    consoleService.logStringMessage(`[ragFilterAction] removeObserver failed: ${e}`);
  }
  filterEditorObserver = null;
}

function hasCustomAction(filterService) {
  try {
    let existing = filterService.getCustomAction(ACTION_ID);
    return !!existing;
  } catch (e) {
    // Fall through.
  }

  try {
    let actions = filterService.getCustomActions();
    return actions.some(a => a && a.id === ACTION_ID);
  } catch (e) {
    return false;
  }
}

function parseAndValidateUrl(actionValue) {
  if (!actionValue || !actionValue.trim()) {
    return { ok: false, error: "Endpoint must not be empty." };
  }

  let trimmed = actionValue.trim();
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) {
    trimmed = `http://${trimmed}`;
  }

  let url;
  try {
    url = ioService.newURI(trimmed, null, null);
  } catch (e) {
    return { ok: false, error: "Endpoint must be a valid URL." };
  }

  if (!url.schemeIs("http") && !url.schemeIs("https")) {
    return { ok: false, error: "Endpoint must be http(s)." };
  }

  if (!url.host) {
    return { ok: false, error: "Endpoint must include a host." };
  }

  return { ok: true, url: url.spec };
}

function streamMessageToUint8Array(msgHdr, msgWindow) {
  return new Promise((resolve, reject) => {
    try {
      let uri = msgHdr.folder.getUriForMsg(msgHdr);
      let msgService = MailServices.messageServiceFromURI(uri);

      let chunks = [];
      let total = 0;

      let listener = {
        onStartRequest(request) {},

        onDataAvailable(request, inputStream, offset, count) {
          let binaryInputStream = Cc["@mozilla.org/binaryinputstream;1"].createInstance(
            Ci.nsIBinaryInputStream
          );
          binaryInputStream.setInputStream(inputStream);
          let bytes = binaryInputStream.readByteArray(count);
          chunks.push(bytes);
          total += bytes.length;
        },

        onStopRequest(request, statusCode) {
          if (!Components.isSuccessCode(statusCode)) {
            reject(new Error(`streamMessage failed: ${statusCode}`));
            return;
          }

          let out = new Uint8Array(total);
          let pos = 0;
          for (let arr of chunks) {
            out.set(arr, pos);
            pos += arr.length;
          }
          resolve(out);
        },

        QueryInterface: ChromeUtils.generateQI(["nsIStreamListener", "nsIRequestObserver"]),
      };

      msgService.streamMessage(uri, listener, msgWindow, null, false, "", false);
    } catch (e) {
      reject(e);
    }
  });
}

async function postMessage(endpoint, rawBytes, msgHdr) {
  let blob = new Blob([rawBytes], { type: "message/rfc822" });

  let headers = new Headers();
  headers.set("Content-Type", "message/rfc822");
  headers.set("X-Thunderbird-Message-Id", msgHdr.messageId || "");

  let resp = await fetch(endpoint, {
    method: "POST",
    headers,
    body: blob,
  });

  if (!resp.ok) {
    throw new Error(`POST failed: ${resp.status} ${resp.statusText}`);
  }
}

function makeCustomAction() {
  return {
    id: ACTION_ID,

    get name() {
      return "ThunderRAG";
    },

    isValidForType(type, scope) {
      return true;
    },

    validateActionValue(actionValue, actionFolder, filterType) {
      let result = parseAndValidateUrl(actionValue);
      if (!result.ok) {
        return result.error;
      }
      return null;
    },

    allowDuplicates: true,

    applyAction(msgHdrs, actionValue, copyListener, filterType, msgWindow) {
      (async () => {
        try {
          let parsed = parseAndValidateUrl(actionValue);
          if (!parsed.ok) {
            throw new Error(parsed.error);
          }

          for (let msgHdr of msgHdrs) {
            let raw = await streamMessageToUint8Array(msgHdr, msgWindow);
            await postMessage(parsed.url, raw, msgHdr);
          }
        } catch (e) {
          console.error(e);
        } finally {
          if (copyListener) {
            try {
              copyListener.OnStopCopy(0);
            } catch (e) {
              console.error(e);
            }
          }
        }
      })();
    },

    get isAsync() {
      return true;
    },

    get needsBody() {
      return true;
    },

    QueryInterface: ChromeUtils.generateQI(["nsIMsgFilterCustomAction"]),
  };
}

var ragFilterAction = class extends ExtensionCommon.ExtensionAPI {
  onStartup() {
    try {
      consoleService.logStringMessage("[ragFilterAction] onStartup: attempting to register custom action");
      let filterService = MailServices.filters;
      if (!hasCustomAction(filterService)) {
        try {
          filterService.addCustomAction(makeCustomAction());
          consoleService.logStringMessage("[ragFilterAction] onStartup: custom action registered");
        } catch (e) {
          consoleService.logStringMessage(`[ragFilterAction] onStartup: addCustomAction failed: ${e}`);
        }
      } else {
        consoleService.logStringMessage("[ragFilterAction] onStartup: custom action already registered");
      }

      try {
        let actions = filterService.getCustomActions();
        consoleService.logStringMessage(`[ragFilterAction] onStartup: custom actions count = ${actions.length}`);
      } catch (e) {
        consoleService.logStringMessage(`[ragFilterAction] onStartup: unable to list custom actions: ${e}`);
      }

      startFilterEditorObserver();
    } catch (e) {
      console.error(e);
      consoleService.logStringMessage(`[ragFilterAction] onStartup: registration failed: ${e}`);
    }
  }

  onShutdown(isAppShutdown) {
    if (isAppShutdown) {
      return;
    }

    try {
      stopFilterEditorObserver();
      obsService.notifyObservers(null, "startupcache-invalidate", null);
    } catch (e) {
      console.error(e);
    }
  }

  getAPI(context) {
    return {
      ragFilterAction: {
        register: async () => {
          try {
            consoleService.logStringMessage("[ragFilterAction] register(): attempting to register custom action");
            let filterService = MailServices.filters;
            if (!hasCustomAction(filterService)) {
              try {
                filterService.addCustomAction(makeCustomAction());
                consoleService.logStringMessage("[ragFilterAction] register(): custom action registered");
              } catch (e) {
                consoleService.logStringMessage(`[ragFilterAction] register(): addCustomAction failed: ${e}`);
              }
            } else {
              consoleService.logStringMessage("[ragFilterAction] register(): custom action already registered");
            }

            try {
              let actions = filterService.getCustomActions();
              consoleService.logStringMessage(`[ragFilterAction] register(): custom actions count = ${actions.length}`);
            } catch (e) {
              consoleService.logStringMessage(`[ragFilterAction] register(): unable to list custom actions: ${e}`);
            }

            startFilterEditorObserver();
          } catch (e) {
            consoleService.logStringMessage(`[ragFilterAction] register(): failed: ${e}`);
          }
        },
        unregister: async () => {
          // No removal API exists on nsIMsgFilterService; best-effort noop.
        },
      },
    };
  }
};
