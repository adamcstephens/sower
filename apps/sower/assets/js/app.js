// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let initAutoDismiss = () => {
  document.querySelectorAll("[data-auto-dismiss-ms]").forEach((element) => {
    if (element.dataset.autoDismissInit === "true") {
      return;
    }

    let timeout = Number.parseInt(element.dataset.autoDismissMs || "0", 10);

    if (!Number.isFinite(timeout) || timeout <= 0) {
      return;
    }

    element.dataset.autoDismissInit = "true";

    window.setTimeout(() => {
      element.classList.add("opacity-0");

      window.setTimeout(() => {
        element.remove();
      }, 300);
    }, timeout);
  });
};

let Hooks = {};

Hooks.SetCookie = {
  mounted() {
    this.handleEvent("sower:set-cookie", ({ key, value }) => {
      if (typeof key !== "string" || typeof value !== "string") return;
      const oneYear = 60 * 60 * 24 * 365;
      document.cookie = `${key}=${encodeURIComponent(value)}; Max-Age=${oneYear}; Path=/; SameSite=Lax`;
    });
  },
};

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: {
    _csrf_token: csrfToken,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => {
  topbar.hide();
  initAutoDismiss();
});

window.addEventListener("DOMContentLoaded", () => {
  initAutoDismiss();
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
